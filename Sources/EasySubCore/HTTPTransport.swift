import Foundation

public protocol HTTPTransport: Sendable {
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let allowsInsecureASSRTFiles: Bool

    /// ASSRT's file hosts only serve signed download links over HTTP. Callers must opt in explicitly;
    /// the default transport remains HTTPS-only.
    public init(allowsInsecureASSRTFiles: Bool = false) {
        self.allowsInsecureASSRTFiles = allowsInsecureASSRTFiles
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: configuration)
    }
    public func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        try Self.validate(request.url, allowsInsecureASSRTFiles: allowsInsecureASSRTFiles)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Self.validate(response.url, allowsInsecureASSRTFiles: allowsInsecureASSRTFiles)
        guard let response = response as? HTTPURLResponse else { throw SubtitleError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw SubtitleError.http(response.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw SubtitleError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw SubtitleError.oversizedResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    static func validate(_ url: URL?, allowsInsecureASSRTFiles: Bool) throws {
        guard let url, let scheme = url.scheme?.lowercased() else { throw SubtitleError.insecureURL }
        if scheme == "https" { return }
        guard allowsInsecureASSRTFiles, scheme == "http", isASSRTFileHost(url.host) else {
            throw SubtitleError.insecureURL
        }
    }

    static func isASSRTFileHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host.range(of: #"^(?:file\d+|dl\d*)\.assrt\.net$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
}

