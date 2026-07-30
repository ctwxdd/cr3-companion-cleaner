import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WebRemotePhoto: Codable, Sendable {
    let id: String
    let name: String
    let folder: String
    let blurProbability: Double
    let issues: [String]
    let flags: [String]
    let needsReview: Bool
    let burstGroup: Int?
    let burstRank: Int?
    let duplicateGroup: Int?
}

struct WebRemoteRawFile: Codable, Sendable {
    let id: String
    let name: String
    let folder: String
    let byteCount: Int64
    let xmpCount: Int
}

struct WebRemoteFolder: Codable, Sendable {
    let path: String
    let name: String
}

struct WebRemoteBackupState: Codable, Sendable {
    let cameraCardPath: String?
    let destinationPath: String?
    let checking: Bool
    let checkCompleted: Bool
    let copying: Bool
    let stage: String
    let completedCount: Int
    let totalCount: Int?
    let copiedBytes: Int64
    let backedUpCount: Int
    let missingCount: Int
    let requiredBytes: Int64
    let availableBytes: Int64
    let hasEnoughSpace: Bool
    let verifiedCount: Int
    let failureMessages: [String]

    static let empty = WebRemoteBackupState(
        cameraCardPath: nil, destinationPath: nil, checking: false,
        checkCompleted: false, copying: false, stage: "", completedCount: 0,
        totalCount: nil, copiedBytes: 0, backedUpCount: 0, missingCount: 0,
        requiredBytes: 0, availableBytes: 0, hasEnoughSpace: false,
        verifiedCount: 0, failureMessages: []
    )
}

struct WebRemoteState: Codable, Sendable {
    let folderName: String?
    let dryRun: Bool
    let analyzing: Bool
    let analysisCompleted: Bool
    let analyzedCount: Int
    let currentFile: String
    let canUndo: Bool
    let photos: [WebRemotePhoto]
    let browsing: Bool
    let browseCompleted: Bool
    let browseInspectedCount: Int
    let browsePhotos: [WebRemotePhoto]
    let rawScanning: Bool
    let rawScanCompleted: Bool
    let rawInspectedCount: Int
    let rawCurrentFolder: String
    let rawTotalBytes: Int64
    let rawFiles: [WebRemoteRawFile]
    let rawCleaning: Bool
    let rawCleanupMessage: String?
    let rootFolderName: String?
    let selectedRelativePath: String
    let canGoUp: Bool
    let folders: [WebRemoteFolder]
    let backup: WebRemoteBackupState

    static let empty = WebRemoteState(
        folderName: nil,
        dryRun: true,
        analyzing: false,
        analysisCompleted: false,
        analyzedCount: 0,
        currentFile: "",
        canUndo: false,
        photos: [],
        browsing: false,
        browseCompleted: false,
        browseInspectedCount: 0,
        browsePhotos: [],
        rawScanning: false,
        rawScanCompleted: false,
        rawInspectedCount: 0,
        rawCurrentFolder: "",
        rawTotalBytes: 0,
        rawFiles: [],
        rawCleaning: false,
        rawCleanupMessage: nil,
        rootFolderName: nil,
        selectedRelativePath: "",
        canGoUp: false,
        folders: [],
        backup: .empty
    )
}

/// Tiny LAN-only HTTP server. It exposes only fixed routes and opaque media IDs.
final class WebRemoteServer: @unchecked Sendable {
    typealias StateProvider = @MainActor @Sendable () -> WebRemoteState
    typealias PhotoURLProvider = @MainActor @Sendable (String) -> URL?
    typealias Action = @MainActor @Sendable () -> Void
    typealias IDsAction = @MainActor @Sendable ([String]) -> Void
    typealias BoolAction = @MainActor @Sendable (Bool) -> Void
    typealias StringAction = @MainActor @Sendable (String) -> Void
    typealias StatusHandler = @MainActor @Sendable (String?, String?, String?) -> Void

    private let queue = DispatchQueue(label: "CR3CompanionCleaner.WebRemote")
    private let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CR3CompanionCleaner.WebRemote.Images"
        queue.qualityOfService = .userInitiated
        let info = ProcessInfo.processInfo
        queue.maxConcurrentOperationCount = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
            ? 2 : min(4, max(2, info.activeProcessorCount / 4))
        return queue
    }()
    private let stateProvider: StateProvider
    private let photoURLProvider: PhotoURLProvider
    private let rawURLProvider: PhotoURLProvider
    private let scanRawAction: Action
    private let browseAction: Action
    private let analyzeAction: Action
    private let cancelAction: Action
    private let trashAction: IDsAction
    private let trashRawAction: IDsAction
    private let undoAction: Action
    private let dryRunAction: BoolAction
    private let selectFolderAction: StringAction
    private let backupCheckAction: Action
    private let backupAction: Action
    private let statusHandler: StatusHandler
    private let imageCache = NSCache<NSString, NSData>()
    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: SocketClient] = [:]
    private var bonjourService: NetService?
    private var pin = ""
    private var sessionToken = ""
    private var failedLogins = 0
    private static let preferredPort: UInt16 = 8765
    private static let pinDefaultsKey = "WebRemote.pairedPIN"
    private static let tokenDefaultsKey = "WebRemote.pairedSessionToken"

    init(
        stateProvider: @escaping StateProvider,
        photoURLProvider: @escaping PhotoURLProvider,
        rawURLProvider: @escaping PhotoURLProvider,
        scanRawAction: @escaping Action,
        browseAction: @escaping Action,
        analyzeAction: @escaping Action,
        cancelAction: @escaping Action,
        trashAction: @escaping IDsAction,
        trashRawAction: @escaping IDsAction,
        undoAction: @escaping Action,
        dryRunAction: @escaping BoolAction,
        selectFolderAction: @escaping StringAction,
        backupCheckAction: @escaping Action,
        backupAction: @escaping Action,
        statusHandler: @escaping StatusHandler
    ) {
        self.stateProvider = stateProvider
        self.photoURLProvider = photoURLProvider
        self.rawURLProvider = rawURLProvider
        self.scanRawAction = scanRawAction
        self.browseAction = browseAction
        self.analyzeAction = analyzeAction
        self.cancelAction = cancelAction
        self.trashAction = trashAction
        self.trashRawAction = trashRawAction
        self.undoAction = undoAction
        self.dryRunAction = dryRunAction
        self.selectFolderAction = selectFolderAction
        self.backupCheckAction = backupCheckAction
        self.backupAction = backupAction
        self.statusHandler = statusHandler
        imageCache.totalCostLimit = Int(min(
            UInt64(256 * 1_024 * 1_024),
            max(UInt64(64 * 1_024 * 1_024), ProcessInfo.processInfo.physicalMemory / 128)
        ))
    }

    deinit {
        acceptSource?.cancel()
        if listenSocket >= 0 { Darwin.close(listenSocket) }
        for client in clients.values { Darwin.close(client.fileDescriptor) }
        bonjourService?.stop()
    }

    func start() throws {
        guard listenSocket < 0 else { return }
        let defaults = UserDefaults.standard
        pin = defaults.string(forKey: Self.pinDefaultsKey)
            ?? String(format: "%06d", Int.random(in: 0...999_999))
        sessionToken = defaults.string(forKey: Self.tokenDefaultsKey)
            ?? UUID().uuidString + UUID().uuidString
        defaults.set(pin, forKey: Self.pinDefaultsKey)
        defaults.set(sessionToken, forKey: Self.tokenDefaultsKey)
        failedLogins = 0

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Self.posixError("Create IPv4 socket") }
        var reuseAddress: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout.size(ofValue: reuseAddress))) == 0 else {
            let error = Self.posixError("Configure IPv4 socket")
            Darwin.close(socket)
            throw error
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.preferredPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(socket, SOMAXCONN) == 0 else {
            let error = Self.posixError("Start IPv4 listener")
            Darwin.close(socket)
            throw error
        }
        _ = fcntl(socket, F_SETFL, O_NONBLOCK)

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &boundAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &boundLength)
            }
        }) == 0 else {
            let error = Self.posixError("Read IPv4 listener port")
            Darwin.close(socket)
            throw error
        }

        listenSocket = socket
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        acceptSource = source
        source.resume()

        let port = Int32(UInt16(bigEndian: boundAddress.sin_port))
        let service = NetService(domain: "local.", type: "_cr3cleaner._tcp.", name: "CR3 Companion Cleaner", port: port)
        bonjourService = service
        service.publish()
        let host = ProcessInfo.processInfo.hostName.isEmpty
            ? (Self.localIPv4Address() ?? "127.0.0.1")
            : ProcessInfo.processInfo.hostName
        Task { @MainActor in statusHandler("http://\(host):\(port)", pin, nil) }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenSocket >= 0 { Darwin.close(listenSocket) }
        listenSocket = -1
        for client in clients.values {
            client.source.cancel()
            Darwin.close(client.fileDescriptor)
        }
        clients.removeAll()
        bonjourService?.stop()
        bonjourService = nil
        sessionToken = ""
        UserDefaults.standard.removeObject(forKey: Self.pinDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenDefaultsKey)
        imageCache.removeAllObjects()
        Task { @MainActor in statusHandler(nil, nil, nil) }
    }

    private func acceptConnections() {
        while true {
            let clientSocket = Darwin.accept(listenSocket, nil, nil)
            guard clientSocket >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            _ = fcntl(clientSocket, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
            let client = SocketClient(fileDescriptor: clientSocket, source: source)
            clients[clientSocket] = client
            source.setEventHandler { [weak self, weak client] in
                guard let client else { return }
                self?.receive(from: client)
            }
            source.resume()
        }
    }

    private func receive(from client: SocketClient) {
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.recv(client.fileDescriptor, &bytes, bytes.count, 0)
            if count > 0 {
                client.buffer.append(bytes, count: count)
                if client.buffer.count > 1_048_576 {
                    detach(client)
                    send(.text("Request too large", status: 413), on: client.fileDescriptor)
                    return
                }
                if let request = HTTPRequest.parse(client.buffer) {
                    detach(client)
                    route(request, on: client.fileDescriptor)
                    return
                }
            } else if count == 0 {
                close(client)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close(client)
                return
            }
        }
    }

    private func detach(_ client: SocketClient) {
        client.source.cancel()
        clients.removeValue(forKey: client.fileDescriptor)
        _ = fcntl(client.fileDescriptor, F_SETFL, 0)
    }

    private func close(_ client: SocketClient) {
        client.source.cancel()
        clients.removeValue(forKey: client.fileDescriptor)
        Darwin.close(client.fileDescriptor)
    }

    private func route(_ request: HTTPRequest, on connection: Int32) {
        if request.method == "POST", request.path == "/login" {
            login(request, on: connection)
            return
        }
        if request.method == "GET", request.path == "/health" {
            send(.text("OK"), on: connection)
            return
        }

        let authenticated = request.cookies["cr3_session"] == sessionToken && !sessionToken.isEmpty
        if request.method == "GET", request.path == "/" {
            send(.html(authenticated ? Self.appHTML : Self.loginHTML.replacingOccurrences(of: "{{ERROR}}", with: "")), on: connection)
            return
        }
        guard authenticated else {
            send(.html(Self.loginHTML.replacingOccurrences(of: "{{ERROR}}", with: ""), status: 401), on: connection)
            return
        }

        if request.method == "GET", request.path == "/api/state" {
            Task {
                let state = await stateProvider()
                guard let data = try? JSONEncoder().encode(state) else {
                    send(.text("Encoding error", status: 500), on: connection)
                    return
                }
                send(.data(data, contentType: "application/json; charset=utf-8"), on: connection)
            }
            return
        }

        if request.method == "GET", request.path == "/image" {
            guard let id = request.query["id"],
                  let kind = request.query["kind"],
                  ["thumb", "preview", "rawThumb", "rawPreview"].contains(kind) else {
                send(.text("Bad request", status: 400), on: connection)
                return
            }
            Task {
                let isRaw = kind.hasPrefix("raw")
                let url = isRaw ? await rawURLProvider(id) : await photoURLProvider(id)
                guard let url else {
                    send(.text("Not found", status: 404), on: connection)
                    return
                }
                let maxPixel = kind.hasSuffix("Thumb") || kind == "thumb" ? 320 : 1_600
                let cacheKey = "\(isRaw ? "raw" : "photo")-\(id)-\(maxPixel)"
                if let cached = imageCache.object(forKey: cacheKey as NSString) {
                    send(.jpeg(cached as Data), on: connection)
                    return
                }
                imageQueue.addOperation {
                    guard let jpeg = Self.makeJPEG(from: url, maxPixel: maxPixel) else {
                        self.send(.text("Preview unavailable", status: 422), on: connection)
                        return
                    }
                    self.imageCache.setObject(jpeg as NSData, forKey: cacheKey as NSString, cost: jpeg.count)
                    self.send(.jpeg(jpeg), on: connection)
                }
            }
            return
        }

        guard request.method == "POST", request.headers["x-cr3-remote"] == "1" else {
            send(.text("Not found", status: 404), on: connection)
            return
        }
        switch request.path {
        case "/api/scan-raw":
            Task { @MainActor in scanRawAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/browse":
            Task { @MainActor in browseAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/analyze":
            Task { @MainActor in analyzeAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/cancel":
            Task { @MainActor in cancelAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/undo":
            Task { @MainActor in undoAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/dry-run":
            let value = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Bool])?["value"]
            guard let value else { send(.text("Bad request", status: 400), on: connection); return }
            Task { @MainActor in dryRunAction(value) }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/select-folder":
            let path = (try? JSONSerialization.jsonObject(with: request.body) as? [String: String])?["path"]
            guard let path, path.utf8.count <= 2_048 else {
                send(.text("Invalid folder", status: 400), on: connection)
                return
            }
            Task { @MainActor in selectFolderAction(path) }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/check-backup":
            Task { @MainActor in backupCheckAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/start-backup":
            Task { @MainActor in backupAction() }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/trash":
            let ids = (try? JSONSerialization.jsonObject(with: request.body) as? [String: [String]])?["ids"]
            guard let ids, !ids.isEmpty, ids.count <= 500 else {
                send(.text("Select 1–500 photos", status: 400), on: connection)
                return
            }
            Task { @MainActor in trashAction(ids) }
            send(.json("{\"ok\":true}"), on: connection)
        case "/api/trash-raw":
            let ids = (try? JSONSerialization.jsonObject(with: request.body) as? [String: [String]])?["ids"]
            guard let ids, !ids.isEmpty, ids.count <= 500 else {
                send(.text("Select 1–500 RAW files", status: 400), on: connection)
                return
            }
            Task { @MainActor in trashRawAction(ids) }
            send(.json("{\"ok\":true}"), on: connection)
        default:
            send(.text("Not found", status: 404), on: connection)
        }
    }

    private func login(_ request: HTTPRequest, on connection: Int32) {
        guard failedLogins < 10 else {
            send(.text("Too many attempts. Restart Web Remote on the Mac.", status: 429), on: connection)
            return
        }
        let form = String(data: request.body, encoding: .utf8) ?? ""
        let submittedPIN = form.split(separator: "&")
            .first(where: { $0.hasPrefix("pin=") })
            .map { String($0.dropFirst(4)) }?
            .removingPercentEncoding
        guard submittedPIN == pin else {
            failedLogins += 1
            send(.html(Self.loginHTML.replacingOccurrences(of: "{{ERROR}}", with: "Incorrect PIN"), status: 401), on: connection)
            return
        }
        failedLogins = 0
        send(.redirect(cookie: "cr3_session=\(sessionToken); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"), on: connection)
    }

    private func send(_ response: HTTPResponse, on connection: Int32) {
        let data = response.encoded
        DispatchQueue.global(qos: .utility).async {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(connection, base.advanced(by: sent), bytes.count - sent, MSG_NOSIGNAL)
                    guard count > 0 else { break }
                    sent += count
                }
            }
            Darwin.shutdown(connection, SHUT_RDWR)
            Darwin.close(connection)
        }
    }

    private static func makeJPEG(from url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: maxPixel <= 320 ? 0.72 : 0.88
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func localIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var preferred: String?
        var fallback: String?
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var address = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                &address,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let value = String(cString: host)
            let name = String(cString: interface.ifa_name)
            if name == "en0" { preferred = value }
            fallback = fallback ?? value
        }
        return preferred ?? fallback
    }

    private static func posixError(_ operation: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }
}

private final class SocketClient {
    let fileDescriptor: Int32
    let source: DispatchSourceRead
    var buffer = Data()

    init(fileDescriptor: Int32, source: DispatchSourceRead) {
        self.fileDescriptor = fileDescriptor
        self.source = source
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let cookies: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " "), first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + length else { return nil }
        let target = String(first[1])
        let components = URLComponents(string: target)
        let query = Dictionary(
            (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, last in last }
        )
        let cookies = Dictionary(
            (headers["cookie"] ?? "").split(separator: ";").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0].trimmingCharacters(in: .whitespaces), parts[1])
            },
            uniquingKeysWith: { _, last in last }
        )
        return HTTPRequest(
            method: String(first[0]),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            cookies: cookies,
            body: Data(data[bodyStart..<(bodyStart + length)])
        )
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    let extraHeaders: [String]

    var encoded: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 303: reason = "See Other"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 422: reason = "Unprocessable Content"
        case 429: reason = "Too Many Requests"
        default: reason = "Internal Server Error"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
            "Connection: close"
        ]
        headers.append(contentsOf: extraHeaders)
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    static func data(_ data: Data, contentType: String, status: Int = 200) -> Self {
        .init(status: status, contentType: contentType, body: data, extraHeaders: [])
    }
    static func text(_ value: String, status: Int = 200) -> Self {
        data(Data(value.utf8), contentType: "text/plain; charset=utf-8", status: status)
    }
    static func html(_ value: String, status: Int = 200) -> Self {
        data(Data(value.utf8), contentType: "text/html; charset=utf-8", status: status)
    }
    static func json(_ value: String, status: Int = 200) -> Self {
        data(Data(value.utf8), contentType: "application/json; charset=utf-8", status: status)
    }
    static func jpeg(_ data: Data) -> Self {
        .init(status: 200, contentType: "image/jpeg", body: data, extraHeaders: ["Cache-Control: private, max-age=3600"])
    }
    static func redirect(cookie: String) -> Self {
        .init(status: 303, contentType: "text/plain", body: Data(), extraHeaders: ["Location: /", "Set-Cookie: \(cookie)"])
    }
}

private extension WebRemoteServer {
    static let loginHTML = #"""
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>CR3 Cleaner Remote</title>
<style>body{font:16px -apple-system;margin:0;background:#111;color:#eee;display:grid;place-items:center;min-height:100vh}.box{width:min(86vw,360px);background:#222;padding:28px;border-radius:18px}input,button{box-sizing:border-box;width:100%;padding:14px;border-radius:10px;border:0;font-size:18px}button{margin-top:12px;background:#0a84ff;color:white;font-weight:700}.error{color:#ff9f0a;min-height:24px}</style></head>
<body><form class="box" method="post" action="/login"><h2>CR3 Companion Cleaner</h2><p>Enter the pairing PIN shown on your Mac. This phone stays paired for future launches.</p><p class="error">{{ERROR}}</p><input name="pin" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autofocus required placeholder="6-digit PIN"><button>Connect</button></form></body></html>
"""#

    static let appHTML = #"""
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover"><title>CR3 Cleaner Remote</title>
<style>
:root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}button,.card,.viewer,.viewer *{touch-action:manipulation}body{margin:0;background:#101114;color:#f5f5f7}header{position:sticky;top:0;z-index:5;background:#1b1c20ee;backdrop-filter:blur(18px);padding:12px max(12px,env(safe-area-inset-left));border-bottom:1px solid #333}.top,.controls,.actions{display:flex;gap:9px;align-items:center;flex-wrap:wrap}.top h1{font-size:18px;margin:0;flex:1}.status{font-size:13px;color:#aaa;margin:7px 0}.controls select,.controls button,.controls label,.actions button{border:0;border-radius:9px;background:#303136;color:#fff;padding:10px 12px;font:inherit}.controls select{flex:1;min-width:180px}.controls button.primary,.actions button{background:#0a84ff}.controls button:disabled,.actions button:disabled{opacity:.45}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;padding:12px 12px 100px}.card{position:relative;background:#202126;border-radius:12px;overflow:hidden;border:2px solid transparent}.card.selected{border-color:#0a84ff}.card img{width:100%;height:145px;object-fit:cover;display:block;background:#292a2e}.meta{padding:8px}.name{font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.issue{font-size:12px;color:#ffb340;line-height:1.3;margin-top:4px}.group{font-size:11px;color:#aaa;margin-top:4px}.check{position:absolute;top:8px;right:8px;width:25px;height:25px;accent-color:#0a84ff}.actions{position:fixed;z-index:6;bottom:0;left:0;right:0;padding:10px 12px calc(10px + env(safe-area-inset-bottom));background:#1b1c20ee;backdrop-filter:blur(18px);border-top:1px solid #333}.actions span{flex:1}.viewer{display:none;position:fixed;inset:0;z-index:20;background:#000;align-items:center;justify-content:center}.viewer.open{display:flex}.previewStage{position:absolute;inset:54px 0 150px;display:grid;place-items:center;overflow:hidden}.previewStage img{grid-area:1/1;max-width:100%;max-height:100%;object-fit:contain;transition:opacity .10s}.previewStage .low{filter:blur(.25px)}.viewer .close,.viewer .nav{position:absolute;z-index:2;border:0;border-radius:50%;background:#333c;color:#fff;width:44px;height:44px;font-size:22px}.close{top:calc(12px + env(safe-area-inset-top));right:12px}.prev{left:10px}.next{right:10px}.viewerName{position:absolute;top:calc(18px + env(safe-area-inset-top));left:60px;right:60px;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.filmstrip{position:absolute;left:0;right:0;bottom:calc(72px + env(safe-area-inset-bottom));height:72px;display:flex;align-items:center;gap:4px;overflow-x:auto;padding:6px calc(50vw - 28px);scroll-snap-type:x mandatory;scrollbar-width:none;touch-action:pan-x;-webkit-overflow-scrolling:touch}.filmstrip::-webkit-scrollbar{display:none}.filmstrip button{flex:0 0 52px;height:58px;padding:0;border:2px solid transparent;border-radius:7px;overflow:hidden;background:#111;scroll-snap-align:center;transition:border-color .08s,transform .08s}.filmstrip button.active{border-color:#fff;transform:scaleY(1.06)}.filmstrip img{width:100%;height:100%;display:block;object-fit:cover}.viewerActions{position:absolute;bottom:calc(12px + env(safe-area-inset-bottom));left:12px;right:12px;display:flex;justify-content:center;gap:9px}.viewerActions button{border:0;border-radius:11px;background:#2e3037;color:white;padding:12px 16px;font:inherit;font-weight:650}.viewerActions .danger{background:#bf3a35;color:white!important}.empty{padding:70px 20px;text-align:center;color:#aaa}@media(max-width:520px){.grid{grid-template-columns:repeat(2,1fr)}.card img{height:135px}.nav{display:none}.previewStage{inset:54px 0 165px}}
.more{grid-column:1/-1;margin:8px auto 20px;border:0;border-radius:9px;background:#0a84ff;color:white;padding:12px 18px;font:inherit}
.shell{max-width:1100px;margin:auto}.brand{display:flex;align-items:center;gap:11px}.logo{display:grid;place-items:center;width:40px;height:40px;border-radius:12px;background:linear-gradient(145deg,#34aadc,#0866ff);font-size:21px;box-shadow:0 8px 24px #087cff44}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:10px;color:#75baff}.brand h1{font-size:19px;margin:2px 0}.folderPill{max-width:42vw;padding:7px 10px;border-radius:999px;background:#ffffff10;color:#d7d7dc;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.summary{display:grid;grid-template-columns:repeat(3,1fr);gap:9px;margin-top:12px}.summaryCard{padding:12px;border:1px solid #ffffff12;border-radius:14px;background:linear-gradient(145deg,#292b32cc,#1d1f25cc)}.summaryCard b{display:block;font-size:22px}.summaryCard span{font-size:11px;color:#999fa9}.tabs{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin-top:12px;padding:4px;border-radius:12px;background:#0d0e11}.tabs button{border:0;border-radius:9px;padding:10px 5px;background:transparent;color:#9297a1;font:inherit;font-size:13px;font-weight:650}.tabs button.active{background:#30333c;color:white;box-shadow:0 2px 8px #0006}.panelHead{display:flex;align-items:center;gap:9px;flex-wrap:wrap;padding:12px}.panelHead select{flex:1;min-width:180px}.panelHead select,.panelHead button,.panelHead label,.rawHero button{border:1px solid #ffffff14;border-radius:10px;background:#24262d;color:white;padding:10px 12px;font:inherit}.primary{background:linear-gradient(145deg,#1495ff,#0866ee)!important;border:0!important;font-weight:700}.danger{color:#ff9f9a!important}.rawPanel{padding:12px 12px 90px}.rawHero{padding:18px;border:1px solid #ffffff12;border-radius:18px;background:linear-gradient(145deg,#232731,#191b21);box-shadow:0 15px 45px #0005}.rawHero h2{margin:0 0 6px;font-size:20px}.rawHero p{margin:0 0 15px;color:#a5a9b1;line-height:1.45}.rawButtons{display:flex;gap:9px;flex-wrap:wrap}.rawStatus{margin-top:13px;color:#75baff;font-size:13px}.rawList{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;margin-top:12px}.rawRow{position:relative;overflow:hidden;border:2px solid transparent;border-radius:12px;background:#1d1f24}.rawRow.selected{border-color:#0a84ff}.rawRow img{display:block;width:100%;height:145px;object-fit:cover;background:#292a2e}.rawInfo{padding:9px}.rawName{font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.rawPath,.rawMeta{font-size:11px;color:#9196a0;margin-top:3px}.rawCheck{position:absolute;z-index:2;top:8px;right:8px;width:25px;height:25px;accent-color:#0a84ff}.backupPaths{display:grid;gap:8px;margin:14px 0}.backupPath{padding:10px;border-radius:10px;background:#ffffff08}.backupPath b{display:block;font-size:11px;color:#75baff;margin-bottom:3px}.backupPath span{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.backupStats{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin:12px 0}.backupStats div{padding:10px;border-radius:10px;background:#0d0e1299}.backupStats b{display:block;font-size:18px}.backupFailures{margin-top:10px;color:#ff9f9a;font-size:12px;white-space:pre-wrap}.muted{color:#999fa9}[hidden]{display:none!important}@media(max-width:520px){header{padding-top:calc(12px + env(safe-area-inset-top))}.summaryCard b{font-size:20px}.panelHead select{width:100%}.rawList{grid-template-columns:repeat(2,1fr)}.rawRow img{height:135px}}
.folderChooser{display:grid;grid-template-columns:auto minmax(0,1fr);gap:7px;margin-top:9px}.folderChooser button{min-width:0;border:1px solid #ffffff12;border-radius:9px;background:#202229;color:#e8e8ed;padding:9px;font:inherit}.folderChooser button:disabled{opacity:.45}.folderSheet{position:fixed;inset:0;z-index:30;display:grid;align-items:end;background:#000b}.folderSheetCard{max-height:78vh;display:flex;flex-direction:column;border-radius:22px 22px 0 0;background:#1c1e24;border:1px solid #ffffff18;padding:14px 14px calc(14px + env(safe-area-inset-bottom));box-shadow:0 -20px 60px #0009}.folderSheetHead{display:flex;align-items:center;gap:9px}.folderSheetHead h2{flex:1;margin:0;font-size:18px}.folderSheetHead button{border:0;border-radius:9px;background:#30333b;color:white;padding:9px 12px}.folderSearch{margin:12px 0;padding:12px;border:1px solid #ffffff16;border-radius:11px;background:#101116;color:white;font:inherit}.folderList{overflow:auto;display:grid;gap:6px}.folderList button{text-align:left;border:1px solid #ffffff10;border-radius:11px;background:#26282f;color:white;padding:12px;font:inherit}.folderList button:active{background:#087cff}
.grid{gap:4px}.card img,.rawRow img,.filmstrip img{object-fit:contain}.grid.browse{gap:3px;padding:3px 3px 100px;grid-template-columns:repeat(auto-fill,minmax(112px,1fr))}.grid.browse .card{border-radius:3px;background:#050505}.grid.browse .card img{width:100%;height:auto;max-height:none;aspect-ratio:auto;object-fit:contain}.grid.browse .meta{padding:5px}.grid.browse .issue,.grid.browse .group{display:none}.previewStage{touch-action:none}.previewCanvas{width:100%;height:100%;display:grid;place-items:center;transform-origin:center;will-change:transform}.previewCanvas img{grid-area:1/1;width:100%;height:100%;max-width:none;max-height:none;object-fit:contain}
</style></head><body>
<div class="shell"><header><div class="top"><div class="brand"><div class="logo">◫</div><div><div class="eyebrow">Private Mac Remote</div><h1>Companion Cleaner</h1></div></div><b class="folderPill" id="folder">No folder</b></div><div class="status" id="status">Connecting…</div><div class="summary"><div class="summaryCard"><b id="photoStat">—</b><span>Review photos</span></div><div class="summaryCard"><b id="rawStat">—</b><span>Orphaned RAW</span></div><div class="summaryCard"><b id="backupStat">—</b><span>Need backup</span></div></div><nav class="tabs"><button id="reviewTab" class="active">Photo Review</button><button id="rawTab">RAW Orphans</button><button id="backupTab">Backup</button></nav><div class="folderChooser"><button id="upFolder" aria-label="Parent folder">↑ Up</button><button id="browseFolders">Browse folders…</button></div></header>
<section id="reviewPanel"><div class="panelHead"><select id="filter" aria-label="Photo filter"><option value="all">All review flags</option><option value="browse">Browse all photos (no AI)</option><option value="strongBlur">Strong blur (75%+)</option><option value="anyBlur">Any blur</option><option value="blink">Closed eye / blink</option><option value="faceQuality">Low face quality</option><option value="underexposed">Underexposed</option><option value="overexposed">Overexposed</option><option value="lowResolution">Low resolution</option><option value="duplicate">Exact duplicates</option><option value="burstBest">Best of each burst</option><option value="bursts">All burst photos</option></select><button id="browse">Browse Photos</button><label><input type="checkbox" id="dry"> Dry Run</label><button class="primary" id="analyze">Analyze Photos</button><button id="undo">Undo</button></div><main id="grid" class="grid"></main></section>
<section id="rawPanel" class="rawPanel" hidden><div class="rawHero"><h2>RAW Companion Scan</h2><p>Find orphaned CR3 files, preview their embedded JPEG, and move selected CR3/XMP files to macOS Trash after confirmation. JPG files are never changed.</p><div class="rawButtons"><button class="primary" id="scanRaw">Scan RAW</button><button class="danger" id="cancel" hidden>Cancel</button></div><div class="rawStatus" id="rawStatus">Ready to scan</div></div><div class="rawList" id="rawList"></div></section>
<section id="backupPanel" class="rawPanel" hidden><div class="rawHero"><h2>Camera Card Backup</h2><p>Back up every visible file, including videos. Each copy is read back and SHA-256 verified before it is marked successful.</p><div class="backupPaths"><div class="backupPath"><b>MEMORY CARD</b><span id="backupSource">Select on Mac</span></div><div class="backupPath"><b>DESTINATION</b><span id="backupDestination">Select on Mac</span></div></div><div class="backupStats" id="backupStats"></div><div class="rawButtons"><button class="primary" id="checkBackup">Check Backup</button><button class="primary" id="startBackup" hidden>Back Up &amp; Verify</button><button class="danger" id="cancelBackup" hidden>Cancel</button></div><div class="rawStatus" id="backupStatus">Choose the memory card and destination on the Mac.</div><div class="backupFailures" id="backupFailures"></div></div></section>
<div class="actions" id="actions"><span id="count">0 selected</span><button id="trash" disabled>Move to Trash</button></div></div>
<div class="actions" id="rawActions" hidden><span id="rawCount">0 RAW selected</span><button id="trashRaw" disabled>Move RAW to Trash</button></div>
<div id="folderSheet" class="folderSheet" hidden><div class="folderSheetCard"><div class="folderSheetHead"><h2>Choose a folder</h2><button id="closeFolders">Done</button></div><input id="folderSearch" class="folderSearch" type="search" placeholder="Search authorized folders" autocomplete="off"><div id="folderList" class="folderList"></div></div></div>
<div id="viewer" class="viewer"><button class="close" aria-label="Close">×</button><button class="nav prev" aria-label="Previous">‹</button><div id="previewStage" class="previewStage"><div id="previewCanvas" class="previewCanvas"><img id="previewLow" class="low"><img id="preview"></div></div><button class="nav next" aria-label="Next">›</button><div class="viewerName" id="viewerName"></div><div id="filmstrip" class="filmstrip" aria-label="Photo thumbnails"></div><div class="viewerActions"><button id="viewerKeep">Keep &amp; Next</button><button id="viewerUndo">Undo</button><button id="viewerTrash" class="danger">Move to Trash</button></div></div>
<script>
const $=s=>document.querySelector(s),selected=new Set(),selectedRaw=new Set();let state=null,shown=[],rawShown=[],current=-1,rawCurrent=-1,viewerMode='photo',lastSignature='',renderLimit=80,rawLimit=40,activeTab='review',viewerLoadToken=0,filmstripKey='',filmstripFrame=0,zoomScale=1,zoomX=0,zoomY=0,pinchStart=0,pinchScale=1,panStart=null,wasPinching=false;
async function api(path,body){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-CR3-Remote':'1'},body:JSON.stringify(body||{})});if(!r.ok)alert(await r.text());await refresh(true)}
function matches(p,f){if(f==='all')return p.needsReview;if(f==='strongBlur')return p.blurProbability>=.75;if(f==='anyBlur')return p.flags.includes('blur');if(f==='blink')return p.flags.includes('blink');if(f==='faceQuality')return p.flags.includes('faceQuality');if(f==='underexposed')return p.flags.includes('underexposed');if(f==='overexposed')return p.flags.includes('overexposed');if(f==='lowResolution')return p.flags.includes('lowResolution');if(f==='duplicate')return p.flags.includes('duplicate');if(f==='burstBest')return p.burstRank===1;return p.burstGroup!=null}
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
function renderReview(){const f=$('#filter').value,source=f==='browse'?(state.browsePhotos||[]):state.photos;shown=f==='browse'?source:source.filter(p=>matches(p,f));$('#grid').classList.toggle('browse',f==='browse');const valid=new Set(source.map(p=>p.id));for(const id of selected)if(!valid.has(id))selected.delete(id);const visible=shown.slice(0,renderLimit);$('#grid').innerHTML=visible.length?visible.map(p=>`<article class="card ${selected.has(p.id)?'selected':''}" data-id="${p.id}"><input class="check" type="checkbox" ${selected.has(p.id)?'checked':''} aria-label="Select"><img loading="lazy" src="/image?kind=thumb&id=${encodeURIComponent(p.id)}"><div class="meta"><div class="name">${esc(p.name)}</div><div class="issue">${f==='browse'?'Browse only • no AI':esc(p.issues.join(' • ')||'Looks OK')}</div><div class="group">${p.burstGroup?'Burst '+p.burstGroup+(p.burstRank===1?' • Best':' • #'+p.burstRank):''}${p.duplicateGroup?' Duplicate '+p.duplicateGroup:''}</div></div></article>`).join('')+(shown.length>visible.length?`<button class="more">Load 80 more (${shown.length-visible.length} remaining)</button>`:''):`<div class="empty">${f==='browse'?(state.browsing?'Indexing photos…':state.browseCompleted?'No JPG/JPEG photos found.':'Press Browse Photos to build a lightweight index.'):'No photos match this filter. Run Analyze Photos to create review results.'}</div>`;bindCards();const more=$('#grid .more');if(more)more.onclick=()=>{renderLimit+=80;renderReview()};updateSelection()}
function formatBytes(n){if(!n)return'0 B';const u=['B','KB','MB','GB','TB'];const i=Math.min(Math.floor(Math.log(n)/Math.log(1024)),u.length-1);return`${(n/Math.pow(1024,i)).toFixed(i?1:0)} ${u[i]}`}
function renderRaw(){rawShown=state.rawFiles||[];const valid=new Set(rawShown.map(f=>f.id));for(const id of selectedRaw)if(!valid.has(id))selectedRaw.delete(id);const visible=rawShown.slice(0,rawLimit);$('#rawList').innerHTML=visible.length?visible.map(f=>`<article class="rawRow ${selectedRaw.has(f.id)?'selected':''}" data-id="${f.id}"><input class="rawCheck" type="checkbox" ${selectedRaw.has(f.id)?'checked':''} aria-label="Select RAW"><img loading="lazy" src="/image?kind=rawThumb&id=${encodeURIComponent(f.id)}"><div class="rawInfo"><div class="rawName">${esc(f.name)}</div><div class="rawPath">${esc(f.folder)}</div><div class="rawMeta">${formatBytes(f.byteCount)}${f.xmpCount?` • ${f.xmpCount} XMP`:''}</div></div></article>`).join('')+(rawShown.length>visible.length?`<button class="more">Load 40 more (${rawShown.length-visible.length} remaining)</button>`:''):(state.rawScanCompleted?'<div class="empty">Every CR3 has a JPG/JPEG companion.</div>':'<div class="empty">Run Scan RAW to find orphaned CR3 files.</div>');bindRawCards();const more=$('#rawList .more');if(more)more.onclick=()=>{rawLimit+=40;renderRaw()};updateRawSelection()}
function renderBackup(){const b=state.backup,busy=state.analyzing||state.browsing||state.rawScanning||state.rawCleaning||b.checking||b.copying;$('#backupSource').textContent=b.cameraCardPath||'Select on Mac';$('#backupDestination').textContent=b.destinationPath||'Select on Mac';$('#backupStat').textContent=b.checkCompleted?b.missingCount.toLocaleString():'—';$('#checkBackup').disabled=busy||!b.cameraCardPath||!b.destinationPath;$('#checkBackup').textContent=b.checkCompleted?'Check Again':'Check Backup';$('#startBackup').hidden=!b.checkCompleted||!b.missingCount;$('#startBackup').disabled=busy||!b.hasEnoughSpace;$('#cancelBackup').hidden=!b.checking&&!b.copying;$('#backupStats').innerHTML=b.checkCompleted?`<div><b>${b.backedUpCount.toLocaleString()}</b><span>Already backed up</span></div><div><b>${b.missingCount.toLocaleString()}</b><span>Need backup</span></div><div><b>${formatBytes(b.requiredBytes)}</b><span>Required</span></div><div><b>${formatBytes(b.availableBytes)}</b><span>Available</span></div>`:'';$('#backupStatus').textContent=b.copying?`${b.stage} • ${b.completedCount}/${b.totalCount||b.missingCount} • ${formatBytes(b.copiedBytes)}`:b.checking?`${b.stage} • ${b.completedCount}/${b.totalCount||'…'}`:b.verifiedCount?`${b.verifiedCount} copied and SHA-256 verified${b.failureMessages.length?' • '+b.failureMessages.length+' failed':''}`:b.checkCompleted?(b.missingCount?`${b.missingCount} files need backup${b.hasEnoughSpace?'':' • Not enough free space'}`:'Everything is backed up and content-verified'):'Choose the memory card and destination on the Mac.';$('#backupFailures').textContent=b.failureMessages.join('\n')}
function changeFolder(path){if((state.photos.length||state.rawScanCompleted)&&!confirm('Switch folders? Current scan and photo review results will be cleared.'))return;api('/api/select-folder',{path});$('#folderSheet').hidden=true;$('#folderSearch').value=''}
function renderFolders(){const query=($('#folderSearch').value||'').toLocaleLowerCase(),folders=(state.folders||[]).filter(f=>f.name.toLocaleLowerCase().includes(query));$('#folderList').innerHTML=folders.length?folders.map(f=>`<button data-path="${esc(f.path)}">📁 ${esc(f.name)}</button>`).join(''):'<div class="empty">No matching subfolders.</div>';document.querySelectorAll('#folderList button').forEach(button=>button.onclick=()=>changeFolder(button.dataset.path));const busy=state.analyzing||state.browsing||state.rawScanning||state.rawCleaning;$('#upFolder').disabled=!state.canGoUp||busy;$('#browseFolders').disabled=busy||!(state.folders||[]).length}
function render(){renderReview();renderRaw();renderBackup();renderFolders()}
function setTab(tab){activeTab=tab;$('#reviewPanel').hidden=tab!=='review';$('#rawPanel').hidden=tab!=='raw';$('#backupPanel').hidden=tab!=='backup';$('#actions').hidden=tab!=='review';$('#rawActions').hidden=tab!=='raw';$('#reviewTab').classList.toggle('active',tab==='review');$('#rawTab').classList.toggle('active',tab==='raw');$('#backupTab').classList.toggle('active',tab==='backup')}
function bindCards(){document.querySelectorAll('.card').forEach((card,i)=>{card.querySelector('.check').onchange=e=>{e.stopPropagation();e.target.checked?selected.add(card.dataset.id):selected.delete(card.dataset.id);card.classList.toggle('selected',e.target.checked);updateSelection()};card.querySelector('img').onclick=()=>openViewer(i)})}
function bindRawCards(){document.querySelectorAll('.rawRow').forEach((card,i)=>{card.querySelector('.rawCheck').onchange=e=>{e.stopPropagation();e.target.checked?selectedRaw.add(card.dataset.id):selectedRaw.delete(card.dataset.id);card.classList.toggle('selected',e.target.checked);updateRawSelection()};card.querySelector('img').onclick=()=>openRawViewer(i)})}
function updateSelection(){$('#count').textContent=`${selected.size} selected`;$('#trash').disabled=!selected.size;$('#trash').textContent=state&&state.dryRun?'Review Dry Run':'Move to Trash'}
function updateRawSelection(){$('#rawCount').textContent=`${selectedRaw.size} RAW selected`;$('#trashRaw').disabled=!selectedRaw.size||state.rawCleaning||state.rawScanning||state.analyzing;$('#trashRaw').textContent=state&&state.dryRun?'Review RAW Dry Run':'Move RAW to Trash'}
function mediaURL(item,kind){return`/image?kind=${kind}&id=${encodeURIComponent(item.id)}`}
function preloadAround(items,index,isRaw){[-2,-1,1,2].forEach(d=>{const item=items[index+d];if(item)new Image().src=mediaURL(item,isRaw?'rawPreview':'preview')})}
function applyZoom(){const limit=140*(zoomScale-1);zoomX=Math.max(-limit,Math.min(limit,zoomX));zoomY=Math.max(-limit,Math.min(limit,zoomY));$('#previewCanvas').style.transform=`translate3d(${zoomX}px,${zoomY}px,0) scale(${zoomScale})`}
function resetZoom(){zoomScale=1;zoomX=zoomY=0;applyZoom()}
function touchDistance(touches){return Math.hypot(touches[0].clientX-touches[1].clientX,touches[0].clientY-touches[1].clientY)}
function loadPreview(item,isRaw){const token=++viewerLoadToken,lowURL=mediaURL(item,isRaw?'rawThumb':'thumb'),fullURL=mediaURL(item,isRaw?'rawPreview':'preview'),low=new Image(),full=new Image();let fullReady=false;low.onload=()=>{if(token!==viewerLoadToken||fullReady)return;$('#previewLow').src=lowURL;$('#previewLow').style.opacity=1;$('#preview').style.opacity=0};full.onload=()=>{if(token!==viewerLoadToken)return;fullReady=true;$('#preview').src=fullURL;$('#preview').style.opacity=1;$('#previewLow').style.opacity=0};low.src=lowURL;full.src=fullURL}
function selectViewer(i,isRaw,center=false){const items=isRaw?rawShown:shown,p=items[i];if(!p)return;const changed=viewerMode!==(isRaw?'raw':'photo')||(isRaw?rawCurrent:current)!==i;viewerMode=isRaw?'raw':'photo';isRaw?rawCurrent=i:current=i;if(changed)resetZoom();$('#viewerUndo').hidden=isRaw;$('#viewerName').textContent=isRaw?`${p.name} • ${formatBytes(p.byteCount)}`:p.name;$('#viewerTrash').textContent=state.dryRun?(isRaw?'Review RAW Dry Run':'Review Dry Run'):(isRaw?'Move RAW to Trash':'Move to Trash');document.querySelectorAll('#filmstrip button').forEach((button,n)=>button.classList.toggle('active',n===i));const thumb=$('#filmstrip button.active img');if(thumb?.complete&&thumb.naturalWidth){$('#previewLow').src=thumb.currentSrc||thumb.src;$('#previewLow').style.opacity=1;$('#preview').style.opacity=0}if(center)$('#filmstrip button.active')?.scrollIntoView({behavior:'smooth',inline:'center',block:'nearest'});loadPreview(p,isRaw);preloadAround(items,i,isRaw)}
function renderFilmstrip(items,index,isRaw){const key=(isRaw?'raw|':'photo|')+items.map(item=>item.id).join(',');if(key!==filmstripKey){filmstripKey=key;const kind=isRaw?'rawThumb':'thumb',strip=$('#filmstrip');strip.innerHTML=items.map((item,i)=>`<button data-index="${i}" aria-label="${esc(item.name)}"><img loading="lazy" src="${mediaURL(item,kind)}"></button>`).join('');strip.querySelectorAll('button').forEach(button=>button.onclick=()=>selectViewer(+button.dataset.index,isRaw,true));strip.onscroll=()=>{cancelAnimationFrame(filmstripFrame);filmstripFrame=requestAnimationFrame(()=>{const center=strip.scrollLeft+strip.clientWidth/2,buttons=[...strip.querySelectorAll('button')];if(!buttons.length)return;const nearest=buttons.reduce((best,button)=>Math.abs(button.offsetLeft+button.offsetWidth/2-center)<Math.abs(best.offsetLeft+best.offsetWidth/2-center)?button:best);const i=+nearest.dataset.index;if(i!==(isRaw?rawCurrent:current))selectViewer(i,isRaw,false)})}}}
function openViewer(i){$('#viewer').classList.add('open');renderFilmstrip(shown,i,false);selectViewer(i,false,false);requestAnimationFrame(()=>$('#filmstrip button.active')?.scrollIntoView({behavior:'auto',inline:'center',block:'nearest'}))}
function openRawViewer(i){$('#viewer').classList.add('open');renderFilmstrip(rawShown,i,true);selectViewer(i,true,false);requestAnimationFrame(()=>$('#filmstrip button.active')?.scrollIntoView({behavior:'auto',inline:'center',block:'nearest'}))}
function move(d){const isRaw=viewerMode==='raw',items=isRaw?rawShown:shown,index=isRaw?rawCurrent:current;if(!items.length)return;selectViewer((index+d+items.length)%items.length,isRaw,true)}
async function refresh(force=false){try{const r=await fetch('/api/state',{cache:'no-store'});if(r.status===401){location.reload();return}state=await r.json();const b=state.backup,busy=state.analyzing||state.browsing||state.rawScanning||state.rawCleaning||b.checking||b.copying;$('#folder').textContent=state.selectedRelativePath||state.rootFolderName||state.folderName||'Select folder on Mac';$('#dry').checked=state.dryRun;$('#undo').disabled=!state.canUndo;$('#viewerUndo').disabled=!state.canUndo;$('#browse').disabled=busy||!state.folderName;$('#analyze').disabled=busy||!state.folderName;$('#scanRaw').disabled=busy||!state.folderName;$('#cancel').hidden=!state.rawScanning&&!state.rawCleaning&&!state.browsing&&!state.analyzing;$('#photoStat').textContent=($('#filter').value==='browse'?(state.browsePhotos||[]):state.photos).length.toLocaleString();$('#rawStat').textContent=(state.rawFiles||[]).length.toLocaleString();$('#status').textContent=b.copying?'Backing up and verifying':b.checking?'Checking camera card backup':state.rawCleaning?'Cleaning selected RAW files':state.rawScanning?`Scanning RAW • ${state.rawInspectedCount.toLocaleString()} files`:state.browsing?`Indexing photos • ${state.browseInspectedCount.toLocaleString()} files`:state.analyzing?`Analyzing photos • ${state.analyzedCount.toLocaleString()}`:'Connected securely to Mac';$('#rawStatus').textContent=state.rawCleaning?'Moving selected CR3/XMP files to macOS Trash…':state.rawCleanupMessage|| (state.rawScanning?`${state.rawInspectedCount.toLocaleString()} files checked • ${state.rawCurrentFolder}`:state.rawScanCompleted?`${state.rawInspectedCount.toLocaleString()} checked • ${(state.rawFiles||[]).length} orphaned • ${formatBytes(state.rawTotalBytes)}`:'Ready to scan the selected folder');const sig=(state.selectedRelativePath||'root')+'|'+(state.folders||[]).map(f=>f.path).join(',')+'|'+$('#filter').value+'|'+state.photos.map(p=>p.id+':'+p.issues.join(',')).join('|')+'|'+(state.browsePhotos||[]).map(p=>p.id).join('|')+'|'+state.browsing+'|'+(state.rawFiles||[]).map(f=>f.id).join('|')+'|'+state.dryRun+'|'+state.rawCleaning+'|'+(state.rawCleanupMessage||'')+'|'+JSON.stringify(b);if(force||sig!==lastSignature){lastSignature=sig;render()}else{updateSelection();updateRawSelection()}}catch(e){$('#status').textContent='Mac connection unavailable'}}
async function trashCurrent(){const p=shown[current];if(!p)return;const nextID=shown.length>1?shown[(current+1)%shown.length].id:null;if(!confirm(`${state.dryRun?'Dry Run: review':'Move to Trash'} ${p.name}?`))return;await api('/api/trash',{ids:[p.id]});if(nextID){const i=shown.findIndex(photo=>photo.id===nextID);if(i>=0)openViewer(i)}else if(!state.dryRun)$('#viewer').classList.remove('open')}
async function trashRawCurrent(){const p=rawShown[rawCurrent];if(!p)return;const nextID=rawShown.length>1?rawShown[(rawCurrent+1)%rawShown.length].id:null;const question=`${state.dryRun?'Dry Run: review':'Move to Trash'} 1 CR3${p.xmpCount?' + '+p.xmpCount+' XMP':''} (${formatBytes(p.byteCount)})? JPG files will not be changed.`;if(!confirm(question))return;await api('/api/trash-raw',{ids:[p.id]});if(nextID){const i=rawShown.findIndex(file=>file.id===nextID);if(i>=0)openRawViewer(i)}else if(!state.dryRun)$('#viewer').classList.remove('open')}
function confirmRawBatch(){const files=rawShown.filter(f=>selectedRaw.has(f.id)),xmp=files.reduce((n,f)=>n+f.xmpCount,0),bytes=files.reduce((n,f)=>n+f.byteCount,0);if(!files.length)return;const question=`${state.dryRun?'Dry Run: review':'Move to Trash'} ${files.length} CR3${xmp?' + '+xmp+' XMP':''} (${formatBytes(bytes)})? JPG files will not be changed.`;if(confirm(question))api('/api/trash-raw',{ids:files.map(f=>f.id)})}
function confirmBackup(){const b=state.backup;if(!b.missingCount||!b.hasEnoughSpace)return;const question=`Back up ${b.missingCount} files (${formatBytes(b.requiredBytes)}) to ${b.destinationPath}? Every file will be SHA-256 verified.`;if(confirm(question))api('/api/start-backup')}
function handleKeyboard(e){const tag=e.target?.tagName;if(['INPUT','SELECT','TEXTAREA'].includes(tag)||e.target?.isContentEditable)return;if(e.key==='Escape'){$('.close').click();$('#folderSheet').hidden=true;return}if(!$('#viewer').classList.contains('open'))return;if(e.key==='ArrowLeft'||e.key==='ArrowRight'){e.preventDefault();move(e.key==='ArrowLeft'?-1:1);return}if((e.key==='Delete'||e.key==='Backspace')&&!e.repeat){e.preventDefault();viewerMode==='raw'?trashRawCurrent():trashCurrent()}}
$('#previewStage').ontouchstart=e=>{if(e.touches.length===2){wasPinching=true;pinchStart=touchDistance(e.touches);pinchScale=zoomScale;panStart=null}else if(e.touches.length===1&&zoomScale>1){panStart={x:e.touches[0].clientX,y:e.touches[0].clientY,ox:zoomX,oy:zoomY}}};$('#previewStage').ontouchmove=e=>{if(e.touches.length===2&&pinchStart){e.preventDefault();zoomScale=Math.max(1,Math.min(5,pinchScale*touchDistance(e.touches)/pinchStart));if(zoomScale===1)zoomX=zoomY=0;applyZoom()}else if(e.touches.length===1&&panStart&&zoomScale>1){e.preventDefault();zoomX=panStart.ox+e.touches[0].clientX-panStart.x;zoomY=panStart.oy+e.touches[0].clientY-panStart.y;applyZoom()}};$('#previewStage').ontouchend=()=>{pinchStart=0;panStart=null;if(zoomScale<1.03)resetZoom();setTimeout(()=>wasPinching=false,0)};
$('#reviewTab').onclick=()=>setTab('review');$('#rawTab').onclick=()=>setTab('raw');$('#backupTab').onclick=()=>setTab('backup');$('#upFolder').onclick=()=>{const parts=(state.selectedRelativePath||'').split('/').filter(Boolean);parts.pop();changeFolder(parts.join('/'))};$('#browseFolders').onclick=()=>{$('#folderSheet').hidden=false;$('#folderSearch').focus()};$('#closeFolders').onclick=()=>{$('#folderSheet').hidden=true;$('#folderSearch').value='';renderFolders()};$('#folderSearch').oninput=renderFolders;$('#browse').onclick=()=>{$('#filter').value='browse';renderLimit=80;api('/api/browse')};$('#filter').onchange=()=>{renderLimit=80;lastSignature='';renderReview()};$('#dry').onchange=e=>api('/api/dry-run',{value:e.target.checked});$('#scanRaw').onclick=()=>api('/api/scan-raw');$('#analyze').onclick=()=>api('/api/analyze');$('#cancel').onclick=()=>api('/api/cancel');$('#checkBackup').onclick=()=>api('/api/check-backup');$('#startBackup').onclick=confirmBackup;$('#cancelBackup').onclick=()=>api('/api/cancel');$('#undo').onclick=()=>api('/api/undo');$('#trash').onclick=()=>{if(confirm(`${state.dryRun?'Dry Run: review':'Move to Trash'} ${selected.size} selected photo(s)?`))api('/api/trash',{ids:[...selected]})};$('#trashRaw').onclick=confirmRawBatch;$('.close').onclick=()=>$('#viewer').classList.remove('open');$('.prev').onclick=()=>move(-1);$('.next').onclick=()=>move(1);$('#viewerKeep').onclick=()=>move(1);$('#viewerUndo').onclick=()=>api('/api/undo');$('#viewerTrash').onclick=()=>viewerMode==='raw'?trashRawCurrent():trashCurrent();document.onkeydown=e=>{if(e.key==='Escape'){$('.close').click();$('#folderSheet').hidden=true}if($('#viewer').classList.contains('open')&&e.key==='ArrowLeft')move(-1);if($('#viewer').classList.contains('open')&&e.key==='ArrowRight')move(1)};let touchX=0;$('#viewer').ontouchstart=e=>{if(!e.target.closest('#filmstrip'))touchX=e.touches[0].clientX};$('#viewer').ontouchend=e=>{if(e.target.closest('#filmstrip')||wasPinching||zoomScale>1)return;const d=e.changedTouches[0].clientX-touchX;if(Math.abs(d)>45)move(d>0?-1:1)};setTab('review');refresh(true);setInterval(refresh,1500);
document.onkeydown=handleKeyboard;
</script></body></html>
"""#
}
