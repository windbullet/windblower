import Foundation
@preconcurrency import AMSMB2

private final class BoundedRangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let expected: Int
    let offset: UInt64
    let completion: @Sendable (Result<Data, Error>) -> Void
    var data = Data()
    var rejection: Error?
    init(expected: Int, offset: UInt64, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.expected = expected; self.offset = offset; self.completion = completion
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true,
              response.expectedContentLength == -1 || response.expectedContentLength == Int64(expected) else {
            rejection = PureToneError.message("服务器未返回请求的原文件范围"); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= expected else { rejection = PureToneError.message("范围响应超过缓冲上限"); dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error = rejection ?? error { completion(.failure(error)) }
        else if data.count != expected { completion(.failure(PureToneError.message("范围响应长度不足"))) }
        else { completion(.success(data)) }
    }
}
enum BoundedRangeRequest {
    static func start(_ request: URLRequest, expected: Int, offset: UInt64, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let delegate = BoundedRangeDelegate(expected: expected, offset: offset, completion: completion)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }
}

// Synchronous adapter used only by the dedicated native decoder worker.
// The render thread never enters this class. Eight 1 MiB pages bound memory usage.
final class RangeByteSource: @unchecked Sendable {
    typealias Fetch = @Sendable (UInt64, Int, @escaping @Sendable (Result<Data, Error>) -> Void) -> Void
    let length: UInt64
    let fileExtension: String
    private let fetch: Fetch
    private var pages: [UInt64: Data] = [:]
    private var order: [UInt64] = []
    private let lock = NSLock()
    private var cancelled = false
    private let pageSize: UInt64 = 1_048_576
    init(length: UInt64, fileExtension: String, fetch: @escaping Fetch) {
        self.length = length; self.fileExtension = fileExtension; self.fetch = fetch
    }
    var native: PTByteSource {
        PTByteSource(context: Unmanaged.passUnretained(self).toOpaque(), read: { context, offset, buffer, count in
            guard let context, let buffer else { return -1 }
            return Unmanaged<RangeByteSource>.fromOpaque(context).takeUnretainedValue().read(offset: offset, buffer: buffer, count: count)
        }, length: length)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Data, Error>?
        func set(_ value: Result<Data, Error>) { lock.lock(); result = value; lock.unlock() }
        func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    private func read(offset: UInt64, buffer: UnsafeMutableRawPointer, count: Int) -> Int64 {
        guard offset < length else { return 0 }
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { return -1 }
        let page = offset / pageSize
        let base = page * pageSize
        if pages[page] == nil {
            let expected = Int(min(pageSize, length - base))
            let semaphore = DispatchSemaphore(value: 0); let reply = Reply()
            fetch(base, expected) { result in reply.set(result); semaphore.signal() }
            let deadline = Date().addingTimeInterval(35)
            while semaphore.wait(timeout: .now() + 0.1) != .success {
                lock.lock(); let stopped = cancelled; lock.unlock()
                if stopped || Date() >= deadline { return -1 }
            }
            guard let response = reply.get(), case .success(let data) = response, data.count == expected else { return -1 }
            pages[page] = data; order.removeAll { $0 == page }; order.append(page)
            if order.count > 8 { pages.removeValue(forKey: order.removeFirst()) }
        }
        guard let data = pages[page] else { return -1 }
        let start = Int(offset - base); let n = min(count, data.count - start)
        data.withUnsafeBytes { bytes in buffer.copyMemory(from: bytes.baseAddress!.advanced(by: start), byteCount: n) }
        return Int64(n)
    }
    struct StreamInfo: Sendable {
        var sampleRate: Double; var duration: Double; var channels: Int; var bitDepth: Int
    }
    func probe() throws -> StreamInfo {
        var info = PTFileInfo()
        guard pt_source_info(native, fileExtension, &info) == 1 else { throw PureToneError.core }
        return StreamInfo(sampleRate: info.sampleRate, duration: info.duration, channels: Int(info.channels), bitDepth: Int(info.bitsPerSample))
    }
    func createPlayer(rate: Double, configuration: EQConfiguration) throws -> UInt {
        var eq = configuration.native(rate: rate)
        guard let player = pt_player_create_source(native, fileExtension, rate, &eq) else { throw PureToneError.core }
        return UInt(bitPattern: player)
    }
}
