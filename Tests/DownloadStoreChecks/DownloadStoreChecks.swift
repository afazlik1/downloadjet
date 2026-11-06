import Foundation
import DownloadCore

// Compile alongside the app's real store so these checks exercise its scheduler,
// persistence, and manual actions without touching the user's Application Support.
@main struct DownloadStoreChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let log = root.appendingPathComponent("requests.log")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DownloadCoreChecks/server.py")
        server.arguments = ["python3", fixture.path, log.path]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: "http://127.0.0.1:\(port)"), !port.isEmpty else { fatalError("Fixture did not start") }
        let applicationSupport = root.appendingPathComponent("Application Support")
        let output = root.appendingPathComponent("output")
        let store = DownloadStore(applicationSupport: applicationSupport, automaticallySchedule: false)
        precondition(store.message == nil)
        try store.add(text: "\(base)/small\n\(base)/range", directory: output, scheduled: Date().addingTimeInterval(3600), downloadLater: true)
        precondition(store.items.count == 2 && store.items.allSatisfy { $0.status == .waiting && $0.scheduled == nil })
        for _ in 0..<3 { store.pump() }
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(!fm.fileExists(atPath: log.path) && !fm.fileExists(atPath: output.path), "Download Later made a network request or started writing a file")
        print("PASS Download Later saves a batch without HEAD/GET requests or output files")

        store.shutdown()
        let restored = DownloadStore(applicationSupport: applicationSupport, automaticallySchedule: false)
        precondition(restored.message == nil && restored.items.map(\.id) == store.items.map(\.id))
        restored.pump(); restored.pauseAll(); restored.resumeAll(); restored.pump()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(restored.items.allSatisfy { $0.status == .waiting && $0.scheduled == nil })
        precondition(!fm.fileExists(atPath: log.path), "A saved download started after relaunch or Resume All")
        print("PASS saved downloads stay stopped across relaunch, Pause All, and Resume All")

        let first = restored.items[0]
        restored.resume(first.id)
        let deadline = Date().addingTimeInterval(15)
        while restored.items[0].status == .downloading && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(restored.items[0].status == .completed, "Explicit Start Download did not complete")
        let expected = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 256) })
        let downloaded = try Data(contentsOf: first.destination)
        precondition(downloaded == expected, "Started file differs from fixture bytes")
        precondition(restored.items[1].status == .waiting && !fm.fileExists(atPath: restored.items[1].destination.path))
        let requests = try String(contentsOf: log, encoding: .utf8)
        precondition(!requests.contains("/range"), "Starting one download started another saved link")
        print("PASS Start Download completes only the selected saved item with exact file bytes")

        restored.sampleSpeed()
        precondition(restored.totalSpeed > 0 && restored.speedHistory.last?.bytesPerSecond == restored.totalSpeed)
        precondition(restored.speeds[first.id] == restored.totalSpeed)
        let peak = restored.totalSpeed
        try await Task.sleep(nanoseconds: 550_000_000)
        restored.sampleSpeed()
        precondition(restored.totalSpeed == 0 && restored.speeds.isEmpty)
        precondition(restored.speedHistory.contains { $0.bytesPerSecond == peak })
        precondition(restored.speedHistory.count <= 61)
        print("PASS live network speed updates from received bytes and drops to zero while idle")

        restored.remove(restored.items[1].id)
        restored.shutdown()
        let final = DownloadStore(applicationSupport: applicationSupport, automaticallySchedule: false)
        precondition(final.items.count == 1 && final.items[0].status == .completed)
        final.shutdown()
        print("PASS removing a saved link persists without starting it")
        print("All 5 download-store checks passed.")
    }
}
