import Foundation

public enum DownloadStatus: String, Codable, Sendable { case queued, downloading, paused, completed, failed }
public struct DownloadItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var url: URL
    public var filename: String
    public var directory: URL
    public var status: DownloadStatus = .queued
    public var received: Int64 = 0
    public var total: Int64 = 0
    public var error: String?
    public var scheduled: Date?
    public var created = Date()
    public var destination: URL { directory.appendingPathComponent(filename) }
    public var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    public var category: String {
        switch destination.pathExtension.lowercased() {
        case "mp4", "mkv", "mov", "webm": return "Video"
        case "mp3", "m4a", "wav", "flac": return "Audio"
        case "zip", "rar", "7z", "gz", "dmg", "pkg": return "Archives"
        case "pdf", "docx", "txt", "epub", "csv": return "Documents"
        default: return "Other"
        }
    }
    public init(url: URL, directory: URL, filename: String? = nil, scheduled: Date? = nil) {
        self.url = url; self.directory = directory; self.scheduled = scheduled
        self.filename = Self.safeFilename(filename ?? url.lastPathComponent)
    }
    public static func safeFilename(_ value: String) -> String {
        let clean = value.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "download" : String(clean.prefix(180))
    }
    public static func parseURLs(_ text: String) throws -> [URL] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw DownloadError.invalidURL }
        return try lines.map { line in
            guard let url = URL(string: line), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw DownloadError.invalidURL }
            return url
        }
    }
}
public enum DownloadError: LocalizedError {
    case invalidURL, invalidResponse, changedResource, destinationExists
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a complete HTTP or HTTPS URL on each line. URLs with embedded credentials are not supported."
        case .invalidResponse: return "The server returned an invalid response or an unexpected byte range."
        case .changedResource: return "The file changed on the server. Resume again to restart safely."
        case .destinationExists: return "A file already exists at the destination. Choose a different name or folder."
        }
    }
}
