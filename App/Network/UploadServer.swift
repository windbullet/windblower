import Foundation
import FlyingFox
import Observation
import CryptoKit
import UIKit
import Darwin

struct UploadManifest: Codable, Sendable {
    var id: String
    var path: String
    var size: UInt64
    var sha256: String
    var offset: UInt64
    var completed = false
}

actor UploadStore {
    let importer: ImportService
    let accessCode: String
    private var completing: Set<String> = []
    init(importer: ImportService, accessCode: String) { self.importer = importer; self.accessCode = accessCode }
    private func manifestURL(_ id: String) -> URL { Paths.uploads.appendingPathComponent(id + ".json") }
    private func partURL(_ id: String) -> URL { Paths.uploads.appendingPathComponent(id + ".part") }
    private func validID(_ id: String) -> Bool { id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    private func load(_ id: String) throws -> UploadManifest {
        guard validID(id) else { throw PureToneError.message("无效的上传编号") }
        return try JSONDecoder().decode(UploadManifest.self, from: Data(contentsOf: manifestURL(id)))
    }
    private func save(_ manifest: UploadManifest) throws { try JSONEncoder().encode(manifest).write(to: manifestURL(manifest.id), options: .atomic) }
    private func response<T: Encodable>(_ body: T, status: HTTPStatusCode = .ok) throws -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"], body: try JSONEncoder().encode(body))
    }
    func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.path
        if path == "/" || path == "/upload.js" || path == "/sha256.js" || path == "/style.css" {
            let name = path == "/" ? "index.html" : String(path.dropFirst())
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Resources/Web"),
                  let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return HTTPResponse(statusCode: .notFound) }
            let type = name.hasSuffix(".html") ? "text/html; charset=utf-8" : (name.hasSuffix(".css") ? "text/css" : "text/javascript")
            return HTTPResponse(statusCode: .ok, headers: [.contentType: type, HTTPHeader("X-Content-Type-Options"): "nosniff"], body: data)
        }
        guard request.headers[.authorization] == "Bearer \(accessCode)" else { return try response(["error": "访问码不正确"], status: .unauthorized) }
        // No cross-origin API access: the bundled page talks only to its own server.
        if let origin = request.headers[HTTPHeader("Origin")], let host = request.headers[.host], origin != "http://\(host)" {
            return HTTPResponse(statusCode: .forbidden)
        }
        if path == "/api/uploads", request.method == .POST {
            struct Start: Decodable { var path: String; var size: UInt64; var sha256: String }
            guard let length = request.bodySequence.count, length <= 8192 else { return HTTPResponse(statusCode: .payloadTooLarge) }
            let body = try await request.bodyData
            let input = try JSONDecoder().decode(Start.self, from: body)
            let safePath = try FileIntegrity.safeRelative(input.path)
            guard ["flac", "mp3", "lrc", "txt", "yrc", "krc", "qrc", "jpg", "jpeg", "png"].contains((safePath as NSString).pathExtension.lowercased()) else { throw PureToneError.message("不支持的音乐或伴随文件格式") }
            guard input.sha256.count == 64, input.sha256.allSatisfy(\.isHexDigit), input.size > 0 else {
                throw PureToneError.message("文件长度或校验值无效")
            }
            let id = SHA256.hash(data: Data("\(safePath)|\(input.size)|\(input.sha256.lowercased())".utf8)).map { String(format: "%02x", $0) }.joined()
            if var existing = try? load(id) {
                if !existing.completed && !completing.contains(id) {
                    existing.offset = (try? FileManager.default.attributesOfItem(atPath: partURL(id).path)[.size] as? NSNumber)?.uint64Value ?? 0
                    try save(existing)
                }
                return try response(existing)
            }
            let capacity = try Paths.uploads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard input.size < UInt64(max(0, capacity - 64 * 1_048_576)) else { throw PureToneError.message("iPad 储存空间不足") }
            let manifest = UploadManifest(id: id, path: safePath, size: input.size, sha256: input.sha256.lowercased(), offset: 0)
            guard FileManager.default.createFile(atPath: partURL(id).path, contents: nil) else { throw PureToneError.message("无法创建上传文件") }
            try save(manifest); return try response(manifest)
        }
        let components = path.split(separator: "/")
        guard components.count >= 3, components[0] == "api", components[1] == "uploads" else { return HTTPResponse(statusCode: .notFound) }
        let id = String(components[2]); var manifest = try load(id)
        if request.method == .GET { return try response(manifest) }
        if request.method == .PUT {
            guard !manifest.completed, let offsetText = request.headers[HTTPHeader("X-Upload-Offset")], let offset = UInt64(offsetText), offset == manifest.offset else {
                return try response(["error": "上传位置已变化，请重试"], status: .conflict)
            }
            guard let length = request.bodySequence.count, length > 0, length <= 1_048_576, offset + UInt64(length) <= manifest.size else {
                return HTTPResponse(statusCode: .payloadTooLarge)
            }
            // Each request is bounded to 1 MiB. Read before opening the file to avoid actor reentrancy races.
            let bytes = try await request.bodyData
            let current = try load(id)
            guard current.offset == offset, bytes.count == length else { return HTTPResponse(statusCode: .conflict) }
            let handle = try FileHandle(forWritingTo: partURL(id)); defer { try? handle.close() }
            try handle.seek(toOffset: offset); try handle.write(contentsOf: bytes); try handle.synchronize()
            manifest.offset += UInt64(bytes.count); try save(manifest); return try response(manifest)
        }
        if request.method == .POST, components.last == "complete" {
            if manifest.completed { return try response(manifest) }
            guard !completing.contains(id) else { return HTTPResponse(statusCode: .conflict) }
            completing.insert(id); defer { completing.remove(id) }
            guard manifest.offset == manifest.size, try FileIntegrity.sha256(partURL(id)) == manifest.sha256 else {
                throw PureToneError.message("SHA-256 校验失败，原文件未入库")
            }
            // Preserve extension for the decoder/importer, without exposing an incomplete song to the library.
            let staged = Paths.uploads.appendingPathComponent(id + "." + (manifest.path as NSString).pathExtension)
            try FileManager.default.moveItem(at: partURL(id), to: staged)
            do { _ = try await importer.ingest(staged, relative: manifest.path, move: true) }
            catch { if FileManager.default.fileExists(atPath: staged.path) { try? FileManager.default.moveItem(at: staged, to: partURL(id)) }; throw error }
            manifest.completed = true; try save(manifest)
            await MainActor.run { NotificationCenter.default.post(name: .pureToneLibraryChanged, object: nil) }
            return try response(manifest)
        }
        return HTTPResponse(statusCode: .notFound)
    }
}

extension Notification.Name { static let pureToneLibraryChanged = Notification.Name("PureTone.LibraryChanged") }

private struct UploadHandler: HTTPHandler {
    let store: UploadStore
    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        do { return try await store.handle(request) }
        catch { return HTTPResponse(statusCode: .badRequest, headers: [.contentType: "application/json"], body: (try? JSONEncoder().encode(["error": error.localizedDescription])) ?? Data()) }
    }
}

@MainActor @Observable final class UploadServer {
    var running = false
    var address = ""
    var code = ""
    var error: String?
    private var server: HTTPServer?
    private var task: Task<Void, Never>?
    private var importer: ImportService
    init(importer: ImportService) { self.importer = importer }
    func start() {
        guard !running else { return }
        if code.isEmpty { code = String(format: "%06d", Int.random(in: 100000...999999)) }
        let store = UploadStore(importer: importer, accessCode: code)
        let created = HTTPServer(address: .inet(port: 8080), handler: UploadHandler(store: store))
        server = created; address = "http://\(Self.wifiIP() ?? "ipad.local"):8080"; running = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do { try await created.run() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            running = false; UIApplication.shared.isIdleTimerDisabled = false
        }
    }
    func stop() {
        task?.cancel(); task = nil
        if let server { Task { await server.stop() } }
        server = nil; running = false; UIApplication.shared.isIdleTimerDisabled = false
    }
    static func wifiIP() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let item = current.pointee
            if let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: item.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
            }
            pointer = item.ifa_next
        }
        return nil
    }
}
