import Foundation

/// A small HTTP/1.1 subset for the peer API: one request at a time per connection, `Content-Length` bodies only.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    /// Header names in lowercase.
    var headers: [String: String]
    var body: Data

    var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var keepAlive: Bool {
        headers["connection"]?.lowercased() != "close"
    }

    enum ParseError: Error {
        case malformed, tooLarge
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    /// Takes one complete request from the front of `buffer`. Returns nil when more bytes are necessary.
    static func parse(_ buffer: inout Data) throws -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeaderBytes { throw ParseError.tooLarge }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { throw ParseError.malformed }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { throw ParseError.malformed }
        guard length <= maxBodyBytes else { throw ParseError.tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<bodyStart + length])
        buffer.removeSubrange(buffer.startIndex..<bodyStart + length)

        let target = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return HTTPRequest(method: String(requestLine[0]), path: target?.path ?? String(requestLine[1]),
                           query: query, headers: headers, body: body)
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// A part of a file to send after the head, in chunks, instead of `body`.
    var file: (url: URL, offset: UInt64, length: UInt64)?

    /// A whole file, or one byte range of it (`Range: bytes=a-b`) for video seeking.
    static func file(_ url: URL, mime: String, range: String?) -> HTTPResponse {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) ?? 0
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes"]
        let bounds = range?.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        guard let bounds, bounds.count == 2, bounds[0] == "bytes", bounds[1].contains("-") else {
            return HTTPResponse(status: 200, headers: headers, file: (url, 0, size))
        }
        let parts = bounds[1].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let from = UInt64(parts[0]), to = parts.count > 1 ? UInt64(parts[1]) : nil
        let start = from ?? (size - min(to ?? 0, size))
        let end = from == nil ? size - 1 : min(to ?? size - 1, size - 1)
        guard size > 0, start <= end else {
            return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"])
        }
        headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        return HTTPResponse(status: 206, headers: headers, file: (url, start, end - start + 1))
    }

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
    }

    /// The error shape of the peer API: `{"error": "<code>", "message": "<text for logs>"}`.
    static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(status, ["error": code, "message": message])
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(file?.length ?? UInt64(body.count))
        all["Connection"] = keepAlive ? "keep-alive" : "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + (file == nil ? body : Data())
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 416: "Range Not Satisfiable"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}
