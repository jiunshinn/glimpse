import Foundation
import Security

/// An error from the phone's API (`{"error": "<code>"}`) or from the network.
struct PhoneError: Error {
    var code: String
    var message: String
}

/// HTTPS client for one paired phone. TLS trusts only the phone's pinned certificate,
/// and shows the Mac's own certificate, so the phone knows which Mac asks.
final class PhoneClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let base: URL
    private let fingerprint: String
    private let identity: SecIdentity
    private var session: URLSession!
    private let lock = NSLock()
    private var retired = false

    init?(host: String, port: Int, fingerprint: String, identity: SecIdentity) {
        var components = URLComponents()
        components.scheme = "https"
        // An IPv6 literal needs brackets, and its zone ("%en0") must be escaped.
        components.percentEncodedHost = host.contains(":")
            ? "[" + host.replacingOccurrences(of: "%", with: "%25") + "]" : host
        components.port = port
        guard let base = components.url else { return nil }
        self.base = base
        self.fingerprint = fingerprint
        self.identity = identity
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Stops new requests. The requests that run now can finish; then the session closes.
    /// A session must not get a new task after it is invalidated, or Foundation raises an exception.
    func invalidate() {
        lock.withLock { retired = true }
        let session = session!
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { session.finishTasksAndInvalidate() }
    }

    func json(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await data(path, query: query)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneError(code: "bad_response", message: "The phone sent a reply that Glimpse cannot read.")
        }
        return object
    }

    func data(_ path: String, query: [String: String] = [:]) async throws -> Data {
        let (data, response) = try await perform { try await self.session.data(for: self.request(path, query: query)) }
        try check(response, data: data)
        return data
    }

    /// Downloads a file to a temporary location and returns it. The caller moves it.
    func download(_ path: String) async throws -> URL {
        let (file, response) = try await perform { try await self.session.download(for: self.request(path)) }
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let data = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            try check(response, data: data)
        }
        return file
    }

    private func request(_ path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return URLRequest(url: components.url!)
    }

    private func perform<T>(_ body: () async throws -> T) async throws -> T {
        if lock.withLock({ retired }) {
            throw PhoneError(code: "unreachable", message: "The connection to the phone changed. Try again.")
        }
        do {
            return try await body()
        } catch let error as URLError {
            let code = error.code == .serverCertificateUntrusted || error.code == .cancelled ? "wrong_phone" : "unreachable"
            throw PhoneError(code: code, message: error.localizedDescription)
        }
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, status != 200 else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw PhoneError(code: object?["error"] as? String ?? "http_\(status)",
                         message: object?["message"] as? String ?? "The phone answered with status \(status).")
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  PeerIdentity.fingerprint(ofCertificate: SecCertificateCopyData(leaf) as Data) == fingerprint
            else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
