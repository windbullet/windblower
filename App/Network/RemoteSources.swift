import Foundation
import Security
@preconcurrency import AMSMB2
import CryptoKit

enum RemoteKind: String, Codable, CaseIterable, Identifiable {
    case smb, webDAV, http, dlna
    var id: String { rawValue }
    var title: String { switch self { case .smb: "SMB 2/3"; case .webDAV: "WebDAV"; case .http: "HTTP(S) 音频"; case .dlna: "DLNA（手动地址）" } }
}
struct RemoteServer: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: RemoteKind
    var address: String
    var username: String
    var share: String = ""
}
struct RemoteItem: Identifiable, Sendable {
    var id: String
    var title: String
    var isDirectory: Bool
    var resource: URL?
    var size: Int64?
    var originalStatus: String = "来源未验证"
    var explicitlyTranscoded = false
}
enum Credentials {
    static func save(_ password: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PureTone.NAS", kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = Data(password.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PureToneError.message("无法保存 NAS 密码") }
    }
    static func password(id: UUID) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PureTone.NAS", kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String; let attributes: [String: String]; var text = ""; var children: [Node] = []
        init(_ name: String, _ attributes: [String: String] = [:]) { self.name = name.components(separatedBy: ":").last ?? name; self.attributes = attributes }
        func first(_ name: String) -> Node? { children.first { $0.name == name } }
        func descendants(_ name: String) -> [Node] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
        var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let root = Node("root"); var stack: [Node] = []
    static func parse(_ data: Data) throws -> Node {
        let delegate = XMLTree(); delegate.stack = [delegate.root]
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? PureToneError.message("服务器返回无效 XML") }
        return delegate.root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name, attributes); stack.last?.children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { stack.removeLast() }
}

actor RemoteSources {
    private struct RemoteIdentity: Codable, Equatable {
        var size: Int64?
        var validator: String?
        var reliable: Bool { size != nil && validator != nil }
    }
    private struct CacheRecord: Codable { var sha256: String; var identity: RemoteIdentity }
    private struct CachedURL: Sendable { var url: URL }
    private let db: Database
    private var smbClients: [UUID: SMB2Manager] = [:]
    private let session: URLSession
    private var cacheRequests: [String: Task<CachedURL, Error>] = [:]
    init(db: Database) {
        self.db = db
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true; configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }
    func servers() throws -> [RemoteServer] { try db.all(RemoteServer.self, kind: "server") }
    func save(_ server: RemoteServer, password: String) throws {
        guard let url = URL(string: server.address), let scheme = url.scheme?.lowercased(),
              (server.kind == .smb ? scheme == "smb" : ["http", "https"].contains(scheme)), url.host != nil,
              url.user == nil, url.password == nil else { throw PureToneError.message("请输入有效地址；账号密码请填在独立输入框") }
        try Credentials.save(password, id: server.id); try db.put(server, kind: "server", id: server.id.uuidString)
        smbClients.removeValue(forKey: server.id)
    }
    private func client(_ server: RemoteServer) async throws -> SMB2Manager {
        if let existing = smbClients[server.id] { return existing }
        guard let url = URL(string: server.address), let client = SMB2Manager(url: url, credential: URLCredential(user: server.username.isEmpty ? "guest" : server.username, password: Credentials.password(id: server.id), persistence: .forSession)) else { throw PureToneError.message("无效的 SMB 地址") }
        try await client.connectShare(name: server.share); smbClients[server.id] = client; return client
    }
    private func request(_ url: URL, server: RemoteServer, method: String = "GET") -> URLRequest {
        var result = URLRequest(url: url); result.httpMethod = method
        if !server.username.isEmpty { result.setValue("Basic " + Data("\(server.username):\(Credentials.password(id: server.id))".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        result.setValue("PureTone/0.1", forHTTPHeaderField: "User-Agent")
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return result
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PureToneError.message("服务器请求失败：\((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        return data
    }
    func browse(_ server: RemoteServer, path: String = "") async throws -> [RemoteItem] {
        guard let base = URL(string: server.address) else { throw PureToneError.message("无效的服务器地址") }
        switch server.kind {
        case .smb:
            let client = try await client(server)
            let entries: [[URLResourceKey: any Sendable]] = try await withCheckedThrowingContinuation { continuation in
                client.contentsOfDirectory(atPath: path) { continuation.resume(with: $0) }
            }
            return entries.compactMap { entry in
                guard let name = entry[.nameKey] as? String, name != ".", name != ".." else { return nil }
                let child = path.isEmpty ? name : path + "/" + name
                return RemoteItem(id: child, title: name, isDirectory: entry[.fileResourceTypeKey] as? URLFileResourceType == .directory,
                                  size: (entry[.fileSizeKey] as? NSNumber)?.int64Value, originalStatus: "SMB 原文件字节")
            }
        case .http:
            return [RemoteItem(id: base.absoluteString, title: base.lastPathComponent, isDirectory: false, resource: base)]
        case .webDAV:
            let url = path.isEmpty ? base : (URL(string: path, relativeTo: base)?.absoluteURL ?? base)
            var req = request(url, server: server, method: "PROPFIND")
            req.setValue("1", forHTTPHeaderField: "Depth"); req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>".utf8)
            let tree = try XMLTree.parse(try await fetch(req))
            return tree.descendants("response").compactMap { node in
                guard let href = node.first("href")?.value, let resource = URL(string: href, relativeTo: base)?.absoluteURL,
                      resource.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return nil }
                return RemoteItem(id: resource.absoluteString, title: node.descendants("displayname").first?.value.nonempty ?? resource.lastPathComponent,
                                  isDirectory: !node.descendants("collection").isEmpty, resource: resource,
                                  size: node.descendants("getcontentlength").first.flatMap { Int64($0.value) }, originalStatus: "WebDAV 原文件字节")
            }
        case .dlna:
            let description = try XMLTree.parse(try await fetch(request(base, server: server)))
            guard let service = description.descendants("service").first(where: { $0.first("serviceType")?.value.contains("ContentDirectory") == true }),
                  let control = service.first("controlURL")?.value, let controlURL = URL(string: control, relativeTo: base)?.absoluteURL,
                  let serviceType = service.first("serviceType")?.value else { throw PureToneError.message("找不到 DLNA ContentDirectory 服务，请填写设备描述 URL") }
            var results: [RemoteItem] = []; var offset = 0
            repeat {
                var req = request(controlURL, server: server, method: "POST")
                req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type"); req.setValue("\"\(serviceType)#Browse\"", forHTTPHeaderField: "SOAPAction")
                let objectID = (path.isEmpty ? "0" : path).xmlEscaped
                req.httpBody = Data("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:Browse xmlns:u=\"\(serviceType)\"><ObjectID>\(objectID)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(offset)</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>".utf8)
                let soap = try XMLTree.parse(try await fetch(req))
                guard let result = soap.descendants("Result").first?.value else { throw PureToneError.message("DLNA 返回缺少目录数据") }
                let didl = try XMLTree.parse(Data(result.utf8))
                for container in didl.descendants("container") {
                    if let id = container.attributes["id"] { results.append(RemoteItem(id: id, title: container.first("title")?.value ?? id, isDirectory: true)) }
                }
                for item in didl.descendants("item") {
                    let resources = item.children.filter { $0.name == "res" }
                    let selected = resources.first { !($0.attributes["protocolInfo"] ?? "").contains("DLNA.ORG_CI=1") } ?? resources.first
                    guard let selected, let url = URL(string: selected.value) else { continue }
                    let protocolInfo = selected.attributes["protocolInfo"] ?? ""
                    let transcoded = protocolInfo.contains("DLNA.ORG_CI=1")
                    results.append(RemoteItem(id: item.attributes["id"] ?? url.absoluteString, title: item.first("title")?.value ?? url.lastPathComponent,
                                              isDirectory: false, resource: url, size: selected.attributes["size"].flatMap(Int64.init),
                                              originalStatus: transcoded ? "服务器转码资源" : (protocolInfo.contains("DLNA.ORG_CI=0") ? "服务器声明原始资源" : "服务器未声明是否转码"), explicitlyTranscoded: transcoded))
                }
                let count = soap.descendants("NumberReturned").first.flatMap { Int($0.value) } ?? 0
                let total = soap.descendants("TotalMatches").first.flatMap { Int($0.value) } ?? 0
                offset += count
                if count == 0 || offset >= total { break }
            } while offset < 100_000
            return results
        }
    }
    func cachedOriginal(_ item: RemoteItem, server: RemoteServer) async throws -> URL {
        guard !item.explicitlyTranscoded else { throw PureToneError.message("此资源被服务器标记为转码，未作为原版播放") }
        let ext = item.resource?.pathExtension.nonempty ?? (item.title as NSString).pathExtension
        guard ["flac", "mp3"].contains(ext.lowercased()) else { throw PureToneError.message("请选择 FLAC 或 MP3 原始音频文件") }
        let key = SHA256.hash(data: Data("\(server.id)|\(item.id)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = cacheRequests[key] { return try await existing.value.url }
        let task = Task { CachedURL(url: try await downloadOriginal(item, server: server, key: key, fileExtension: ext.lowercased())) }
        cacheRequests[key] = task
        defer { cacheRequests.removeValue(forKey: key) }
        return try await task.value.url
    }
    private func identity(_ item: RemoteItem, server: RemoteServer) async throws -> RemoteIdentity {
        if server.kind == .smb {
            let attributes = try await client(server).attributesOfItem(atPath: item.id)
            let date = attributes[.contentModificationDateKey] as? Date
            return RemoteIdentity(size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value, validator: date.map { "smb:\($0.timeIntervalSince1970)" })
        }
        guard let url = item.resource else { throw PureToneError.message("音频地址不存在") }
        let (_, response) = try await session.data(for: request(url, server: server, method: "HEAD"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return RemoteIdentity() // Without a validator the original is downloaded again.
        }
        let etag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        return RemoteIdentity(size: http.expectedContentLength >= 0 ? http.expectedContentLength : nil,
                              validator: etag.map { "etag:\($0)" } ?? http.value(forHTTPHeaderField: "Last-Modified").map { "modified:\($0)" })
    }
    private func downloadOriginal(_ item: RemoteItem, server: RemoteServer, key: String, fileExtension ext: String) async throws -> URL {
        let dest = Paths.cache.appendingPathComponent(key + "." + ext.lowercased())
        let marker = dest.appendingPathExtension("complete")
        let before = try await identity(item, server: server)
        if before.reliable, let data = try? Data(contentsOf: marker), let record = try? JSONDecoder().decode(CacheRecord.self, from: data),
           record.identity == before, let hash = try? FileIntegrity.sha256(dest), hash == record.sha256 { return dest }
        let part = dest.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: part)
        defer { try? FileManager.default.removeItem(at: part) }
        if server.kind == .smb {
            let client = try await client(server)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let output = try FileHandle(forWritingTo: part); defer { try? output.close() }
            guard let length = before.size, length > 0 else { throw PureToneError.message("无法确认 SMB 原文件长度") }
            var offset: UInt64 = 0
            while offset < UInt64(length) {
                try Task.checkCancellation()
                let requested = min(1_048_576, UInt64(length) - offset)
                let data = try await client.contents(atPath: item.id, range: offset..<(offset + requested))
                guard data.count == Int(requested) else { throw PureToneError.message("SMB 原文件读取中断") }
                try output.write(contentsOf: data); offset += UInt64(data.count)
            }
            try output.synchronize()
        } else {
            guard let url = item.resource else { throw PureToneError.message("音频地址不存在") }
            var req = request(url, server: server)
            if let validator = before.validator, validator.hasPrefix("etag:") { req.setValue(String(validator.dropFirst(5)), forHTTPHeaderField: "If-Match") }
            if let validator = before.validator, validator.hasPrefix("modified:") { req.setValue(String(validator.dropFirst(9)), forHTTPHeaderField: "If-Unmodified-Since") }
            let (temporary, response) = try await session.download(for: req)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw PureToneError.message("下载原文件失败") }
            try FileManager.default.moveItem(at: temporary, to: part)
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expected = before.size ?? item.size, expected >= 0, expected != bytes { throw PureToneError.message("网络资源长度不一致，尚未作为完整文件使用") }
        if before.reliable, try await identity(item, server: server) != before { throw PureToneError.message("原文件在下载期间发生变化，请重新读取") }
        let hash = try FileIntegrity.sha256(part)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: part, to: dest)
        try JSONEncoder().encode(CacheRecord(sha256: hash, identity: before)).write(to: marker, options: .atomic)
        return dest
    }
    func stream(_ item: RemoteItem, server: RemoteServer) async throws -> RangeByteSource {
        guard !item.explicitlyTranscoded else { throw PureToneError.message("不能将服务器转码资源作为原版播放") }
        let ext = (item.resource?.pathExtension.nonempty ?? (item.title as NSString).pathExtension).lowercased()
        guard ["mp3", "flac"].contains(ext) else { throw PureToneError.message("串流需使用 FLAC 或 MP3 原文件 URL") }
        if server.kind == .smb {
            let client = try await client(server)
            let attributes = try await client.attributesOfItem(atPath: item.id)
            let length = (attributes[.fileSizeKey] as? NSNumber)?.uint64Value ?? 0
            guard length > 0 else { throw PureToneError.message("无法读取网络文件长度") }
            return RangeByteSource(length: length, fileExtension: ext) { offset, count, completion in
                client.contents(atPath: item.id, range: offset..<(offset + UInt64(count)), progress: nil, completionHandler: completion)
            }
        }
        guard let url = item.resource else { throw PureToneError.message("网络音频 URL 不存在") }
        var probe = request(url, server: server)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (probeBytes, response) = try await session.bytes(for: probe)
        defer { probeBytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ UInt64($0) }), total > 0 else {
            throw PureToneError.message("服务器不支持原文件范围读取，请使用“缓存后播放”")
        }
        let baseRequest = request(url, server: server)
        return RangeByteSource(length: total, fileExtension: ext) { offset, count, completion in
            var req = baseRequest; req.setValue("bytes=\(offset)-\(offset + UInt64(count) - 1)", forHTTPHeaderField: "Range")
            BoundedRangeRequest.start(req, expected: count, offset: offset, completion: completion)
        }
    }
}

extension String {
    var nonempty: String? { isEmpty ? nil : self }
    var xmlEscaped: String { replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
}
