import Foundation

public struct HTTPStatusError: LocalizedError {
    public let status: Int
    public let retryAfter: String?
    public var errorDescription: String? { "The server returned HTTP \(status)." }
    public init(status: Int, retryAfter: String? = nil) { self.status = status; self.retryAfter = retryAfter }
}

public struct RetryPolicy: Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 300) {
        self.maxRetries = min(5, max(0, maxRetries))
        self.baseDelay = max(0.001, baseDelay)
        self.maxDelay = max(0.001, maxDelay)
    }
    public func delay(for error: Error, retry: Int, now: Date = Date()) -> TimeInterval? {
        guard retry > 0, retry <= maxRetries else { return nil }
        var serverDelay: TimeInterval = 0
        if let http = error as? HTTPStatusError {
            guard [408, 429, 500, 502, 503, 504].contains(http.status) else { return nil }
            if let value = http.retryAfter {
                if let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 { serverDelay = seconds }
                else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    serverDelay = max(0, formatter.date(from: value)?.timeIntervalSince(now) ?? 0)
                }
            }
        } else if let network = error as? URLError {
            guard [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(network.code) else { return nil }
        } else { return nil }
        return min(maxDelay, max(baseDelay * pow(2, Double(retry - 1)), serverDelay))
    }
    public func perform<T>(retrying: @escaping @Sendable (Int, TimeInterval) async -> Void = { _, _ in }, operation: () async throws -> T) async throws -> T {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                retries += 1
                guard let delay = delay(for: error, retry: retries) else { throw error }
                await retrying(retries, delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

public struct HostConnectionRule: Identifiable, Codable, Equatable, Sendable {
    public var id: String { host }
    public let host: String
    public let connections: Int
    public init(host: String, connections: Int) throws {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: "https://" + value), let parsed = url.host,
              parsed.lowercased() == value, url.port == nil, url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              [1, 2, 4, 8].contains(connections) else { throw DownloadError.invalidURL }
        self.host = value; self.connections = connections
    }
    public static func resolve(url: URL, defaultConnections: Int, rules: [Self]) -> Int {
        let host = url.host?.lowercased()
        return min(8, max(1, rules.first { $0.host == host }?.connections ?? defaultConnections))
    }
}
