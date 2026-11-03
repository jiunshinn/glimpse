import Foundation
import Combine
import UniformTypeIdentifiers

/// A phone that paired with this Mac. The phone proves itself with its certificate fingerprint.
struct PairedDevice: Codable, Identifiable, Equatable {
    var id: String { String(fingerprint.prefix(16)) }
    var fingerprint: String
    var name: String
    var platform: String
    var pairedAt: Date
    var lastSeen: Date?
}

/// A pairing window: one code, valid for a short time and for one phone.
struct PairingOffer: Equatable {
    var code: String
    var url: URL
    var expires: Date
    var failedAttempts = 0
}

/// Owns the peer server, the pairing flow and the paired devices (phase 0 of docs/android-companion).
@MainActor
final class PeerService: ObservableObject {
    static let shared = PeerService()

    static let protocolVersions = [1]
    static let pairingLifetime: TimeInterval = 120
    static let maxFailedAttempts = 5

    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var offer: PairingOffer?
    @Published private(set) var serverState: PeerServer.State?
    /// The device that paired during the current pairing window.
    @Published private(set) var justPaired: PairedDevice?
    @Published private(set) var problem: String?

    let macName = Host.current().localizedName ?? "Mac"
    private let directory: URL
    /// Where the peer identity, the paired devices and the shared folders are stored.
    var storageDirectory: URL { directory }
    private var storedIdentity: PeerIdentity?
    private var server: PeerServer?

    private init() {
        directory = Self.defaultDirectory()
        load()
    }

    var deviceID: String? { identity?.deviceID }

    /// The port of the peer server while it runs.
    var listeningPort: UInt16? {
        if case .ready(let port) = serverState { return port }
        return nil
    }

    /// The Mac's TLS identity. The Mac also shows it as a client when it connects to a phone.
    var identity: PeerIdentity? {
        if storedIdentity == nil { storedIdentity = try? PeerIdentity.loadOrCreate(in: directory) }
        return storedIdentity
    }

    /// Starts the server at launch when a phone is paired, so the phone can reconnect.
    func startIfPaired() {
        if !devices.isEmpty { startServer() }
    }

    func beginPairing() {
        isPairingWindowOpen = true
        justPaired = nil
        startServer()
        makeOffer()
    }

    func endPairing() {
        isPairingWindowOpen = false
        offer = nil
        if devices.isEmpty { stopServer() }
    }

    /// A new code, for example after the old one expired.
    func makeOffer() {
        guard let identity, case .ready(let port) = serverState else {
            offer = nil
            return
        }
        guard let host = LocalAddress.primaryIPv4() else {
            offer = nil
            problem = "Connect this Mac to a Wi-Fi or Ethernet network."
            return
        }
        problem = nil
        let code = Data.random(count: 16).base64URLEncoded
        var components = URLComponents()
        components.scheme = "glimpse"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: identity.fingerprint),
            URLQueryItem(name: "code", value: code),
        ]  // Short, so the QR code stays easy to scan. The phone reads the name and versions from GET /v1/info.
        offer = PairingOffer(code: code, url: components.url!, expires: Date().addingTimeInterval(Self.pairingLifetime))
        #if DEBUG
        FileHandle.standardError.write(Data("[Peer] pairing URL: \(components.url!.absoluteString)\n".utf8))
        #endif
    }

    func unpair(_ device: PairedDevice) {
        devices.removeAll { $0.fingerprint == device.fingerprint }
        save()
        SharedFolders.shared.forget(device.fingerprint)
        DeviceLibrary.shared.reloadPhones()
        if devices.isEmpty, offer == nil { stopServer() }
    }

    // MARK: - Server

    private func startServer() {
        guard server == nil else { return }
        do {
            let identity = try PeerIdentity.loadOrCreate(in: directory)
            storedIdentity = identity
            let server = PeerServer(identity: identity) { request, client in
                await PeerService.shared.handle(request, from: client)
            }
            self.server = server
            let txt = ["id": identity.deviceID, "n": macName, "p": "mac",
                       "v": Self.protocolVersions.map(String.init).joined(separator: ",")]
            server.start(name: macName, txt: txt) { state in
                Task { @MainActor in PeerService.shared.serverChanged(state) }
            }
        } catch {
            problem = "Glimpse could not make its network key: \(error.localizedDescription)"
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        serverState = nil
    }

    private func serverChanged(_ state: PeerServer.State) {
        serverState = state
        switch state {
        case .ready:
            problem = nil
            // The pairing window waited for a port.
            if offer == nil, justPaired == nil, isPairingWindowOpen { makeOffer() }
        case .failed(let message):
            problem = "The connection service stopped: \(message)"
        case .starting:
            break
        }
    }

    /// True while the pairing window shows. It asks for an offer once the server has a port.
    private var isPairingWindowOpen = false

    // MARK: - API

    func handle(_ request: HTTPRequest, from client: PeerClient) async -> HTTPResponse {
        let device = devices.first { $0.fingerprint == client.fingerprint }
        if let device { noteSeen(device) }
        switch (request.method, request.path) {
        case ("GET", "/v1/info"):
            return .json(200, [
                "id": identity?.deviceID ?? "",
                "name": macName,
                "platform": "mac",
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                "protocol": Self.protocolVersions,
                "capabilities": ["albums"],
                "paired": device != nil,
            ])
        case ("POST", "/v1/pair"):
            return pair(request, client: client)
        case (_, "/v1/info"), (_, "/v1/pair"):
            return .error(405, "method_not_allowed", "Use GET for /v1/info and POST for /v1/pair.")
        default:
            guard device != nil else {
                return .error(401, "not_paired", "Pair this device with the Mac first.")
            }
            switch (request.method, request.path) {
            case ("POST", "/v1/hello"):
                // The phone's server listens on this port at the address of the request.
                guard let port = request.jsonBody?["port"] as? Int, (1...65535).contains(port), let host = client.host else {
                    return .error(400, "bad_request", "The body needs the port of the phone's server.")
                }
                // A hello through the USB cable comes from this Mac's own address. The cable has its own route.
                if host == "127.0.0.1" || host == "::1" { return .json(200, ["id": identity?.deviceID ?? ""]) }
                DeviceLibrary.shared.hello(fingerprint: client.fingerprint, host: host, port: port,
                                           name: request.jsonBody?["name"] as? String)
                return .json(200, ["id": identity?.deviceID ?? ""])
            default:
                return await shared(request, for: client.fingerprint)
            }
        }
    }

    /// The folders shared with phones. The file work runs off the main thread.
    private func shared(_ request: HTTPRequest, for fingerprint: String) async -> HTTPResponse {
        // Each phone sees only the folders shared with it.
        let roots = SharedFolders.shared.folders(for: fingerprint)
        let path = request.path
        guard request.method == "GET" else {
            return .error(405, "method_not_allowed", "Only GET is served for shared folders.")
        }
        return await Task.detached(priority: .userInitiated) { () -> HTTPResponse in
            if path == "/v1/albums" {
                return .json(200, ["albums": SharedLibrary.albums(roots)])
            }
            if path.hasPrefix("/v1/albums/"), path.hasSuffix("/items") {
                let id = String(path.dropFirst("/v1/albums/".count).dropLast("/items".count))
                guard let root = roots.first(where: { $0.id == id }),
                      let page = SharedLibrary.items(in: root, path: request.query["path"] ?? "") else {
                    return .error(404, "not_found", "No such shared folder.")
                }
                return .json(200, page)
            }
            if path.hasPrefix("/v1/items/"), path.hasSuffix("/thumbnail") {
                let id = String(path.dropFirst("/v1/items/".count).dropLast("/thumbnail".count))
                let size = min(max(Int(request.query["size"] ?? "") ?? 256, 32), 2048)
                guard let url = SharedLibrary.file(for: id, roots: roots), let jpeg = SharedLibrary.thumbnail(url, size: size) else {
                    return .error(404, "no_thumbnail", "No thumbnail for this item.")
                }
                return HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
            }
            if path.hasPrefix("/v1/items/"), path.hasSuffix("/content") {
                let id = String(path.dropFirst("/v1/items/".count).dropLast("/content".count))
                guard let url = SharedLibrary.file(for: id, roots: roots) else {
                    return .error(404, "not_found", "No such item.")
                }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return .file(url, mime: mime, range: request.headers["range"])
            }
            return .error(404, "not_found", "No endpoint \(request.method) \(path).")
        }.value
    }

    private func pair(_ request: HTTPRequest, client: PeerClient) -> HTTPResponse {
        guard var offer, offer.expires > Date() else {
            self.offer = nil
            return .error(403, "pairing_closed", "Open Connect Phone on the Mac and scan the new code.")
        }
        guard let body = request.jsonBody, let code = body["code"] as? String else {
            return .error(400, "bad_request", "The body needs a code.")
        }
        guard Self.constantTimeEqual(code, offer.code) else {
            offer.failedAttempts += 1
            self.offer = offer.failedAttempts >= Self.maxFailedAttempts ? nil : offer
            return .error(401, "bad_code", "The pairing code is wrong.")
        }
        let name = (body["name"] as? String).map { String($0.prefix(64)) } ?? "Phone"
        let platform = body["platform"] as? String ?? "android"
        let device = PairedDevice(fingerprint: client.fingerprint, name: name, platform: platform,
                                  pairedAt: Date(), lastSeen: Date())
        devices.removeAll { $0.fingerprint == client.fingerprint }
        devices.append(device)
        save()
        DeviceLibrary.shared.reloadPhones()
        self.offer = nil  // One code pairs one phone.
        justPaired = device
        return .json(200, ["id": identity?.deviceID ?? "", "name": macName])
    }

    private func noteSeen(_ device: PairedDevice) {
        guard let index = devices.firstIndex(of: device) else { return }
        // Write at most once a minute.
        if let last = devices[index].lastSeen, Date().timeIntervalSince(last) < 60 { return }
        devices[index].lastSeen = Date()
        save()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Storage

    private var devicesURL: URL { directory.appendingPathComponent("Devices.json") }

    private func load() {
        guard let data = try? Data(contentsOf: devicesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = (try? decoder.decode([PairedDevice].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(devices).write(to: devicesURL, options: .atomic)
    }

    private static func defaultDirectory() -> URL {
        #if DEBUG
        // Development aid: GLIMPSE_PEER_DIR=/path keeps test runs away from the real identity and devices.
        if let path = ProcessInfo.processInfo.environment["GLIMPSE_PEER_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Glimpse", isDirectory: true).appendingPathComponent("Peer", isDirectory: true)
    }
}

enum LocalAddress {
    /// The IPv4 address of the first active Wi-Fi or Ethernet interface, for the pairing QR code.
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.hasPrefix("169.254.") { continue }  // Link-local: no DHCP.
            candidates.append((name, text))
        }
        return candidates.sorted { $0.name < $1.name }.first?.address
    }
}
