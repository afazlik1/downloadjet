import Foundation

public enum AppStorage {
    public static func directory(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("DownloadJet", isDirectory: true)
    }

    /// Move the complete legacy store on the same volume before creating new state.
    /// An existing DownloadJet store is authoritative; never merge or overwrite it.
    @discardableResult
    public static func prepare(in applicationSupport: URL) throws -> URL {
        let fm = FileManager.default
        let destination = directory(in: applicationSupport)
        let legacy = applicationSupport.appendingPathComponent("Current", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
        } else if fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileReadCorruptFile) }
            // A failed rename leaves the legacy store intact and propagates the error.
            try fm.moveItem(at: legacy, to: destination)
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        return destination
    }
}
