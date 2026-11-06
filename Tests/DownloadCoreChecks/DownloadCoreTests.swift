import Foundation
import DownloadCore

final class DownloadCoreTests {
    var server: Process!
    var root: URL!
    var base: URL!
    func setUpWithError(benchmark: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("server.py").path, root.appendingPathComponent("requests.log").path]
        if benchmark { var environment = ProcessInfo.processInfo.environment; environment["DOWNLOADJET_BENCHMARK"] = "1"; server.environment = environment }
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        let data = pipe.fileHandleForReading.availableData
        let port = try XCTUnwrap(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    }
    func tearDownWithError() throws { server?.terminate(); try? FileManager.default.removeItem(at: root) }
    var expected: Data { Data((0..<(9 * 1024 * 1024)).map { UInt8($0 % 256) }) }
    func item(_ path: String) -> DownloadItem { DownloadItem(url: base.appendingPathComponent(path), directory: root.appendingPathComponent("output")) }
    func testFreshStorage() throws {
        let applicationSupport = root.appendingPathComponent("Application Support")
        let directory = try AppStorage.prepare(in: applicationSupport)
        XCTAssertEqual(directory.lastPathComponent, "DownloadJet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try AppStorage.prepare(in: applicationSupport), directory)
    }
    func testStorageMigrationAndResume() async throws {
        let applicationSupport = root.appendingPathComponent("Application Support")
        let legacy = applicationSupport.appendingPathComponent("Current")
        var item = item("range"); item.status = .paused
        let parts = legacy.appendingPathComponent("Parts").appendingPathComponent(item.id.uuidString)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let queue = try JSONEncoder().encode([item])
        let preferences = Data(#"{"connections":8,"maxRetries":5,"hostRules":[]}"#.utf8)
        try queue.write(to: legacy.appendingPathComponent("queue.json"))
        try preferences.write(to: legacy.appendingPathComponent("preferences.json"))
        let manifest: [String: Any] = ["url": item.url.absoluteString, "length": expected.count, "validator": "\"version-1\"", "chunkSize": 4 * 1024 * 1024]
        try JSONSerialization.data(withJSONObject: manifest).write(to: parts.appendingPathComponent("manifest.json"))
        try expected.prefix(4 * 1024 * 1024).write(to: parts.appendingPathComponent("0.part"))

        let directory = try AppStorage.prepare(in: applicationSupport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("queue.json")), queue)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preferences.json")), preferences)
        let restored = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: directory.appendingPathComponent("queue.json")))
        XCTAssertEqual(restored.first?.id, item.id)
        XCTAssertEqual(restored.first?.status, .paused)
        XCTAssertEqual(restored.first?.directory, item.directory)
        XCTAssertEqual(try AppStorage.prepare(in: applicationSupport), directory)
        let cache = directory.appendingPathComponent("Parts").appendingPathComponent(item.id.uuidString)
        try await Transfer.run(item: item, cache: cache) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: item.destination), expected)
        let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("bytes=0-4194303"))
    }
    func testExistingStorageIsNotOverwritten() throws {
        let legacy = root.appendingPathComponent("Current")
        let destination = AppStorage.directory(in: root)
        for directory in [legacy, destination] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("older queue".utf8).write(to: legacy.appendingPathComponent("queue.json"))
        try Data("new queue".utf8).write(to: destination.appendingPathComponent("queue.json"))
        try Data("legacy only".utf8).write(to: legacy.appendingPathComponent("preferences.json"))
        XCTAssertEqual(try AppStorage.prepare(in: root), destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("queue.json"), encoding: .utf8), "new queue")
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("queue.json"), encoding: .utf8), "older queue")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("preferences.json").path))
    }
    func testBlockedStorageMigrationRetainsData() throws {
        let legacy = root.appendingPathComponent("Current")
        let destination = AppStorage.directory(in: root)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("keep queue".utf8).write(to: legacy.appendingPathComponent("queue.json"))
        try Data("blocking file".utf8).write(to: destination)
        XCTAssertThrowsError(try AppStorage.prepare(in: root))
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("queue.json"), encoding: .utf8), "keep queue")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "blocking file")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.removeItem(at: legacy)
        try Data("invalid store".utf8).write(to: legacy)
        XCTAssertThrowsError(try AppStorage.prepare(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "invalid store")
    }
    func testSpeedHistory() {
        let first = UUID(), second = UUID()
        var history = DownloadSpeedHistory(now: 0)
        XCTAssertEqual(history.samples.count, 151)
        XCTAssertEqual(history.samples.first?.time, -30)
        history.record(1024, for: first); history.record(2048, for: second)
        history.record(-100, for: first)
        history.sample(at: 0.2)
        XCTAssertEqual(history.totalSpeed, 15360)
        XCTAssertEqual(history.speeds[first], 5120)
        XCTAssertEqual(history.speeds[second], 10240)
        history.sample(at: 0.4)
        XCTAssertEqual(history.totalSpeed, 0)
        XCTAssertTrue(history.speeds.isEmpty)
        XCTAssertTrue(history.samples.contains { $0.bytesPerSecond == 15360 })
        history.record(1024, for: first)
        history.sample(at: 1.4) // Delayed timers use real elapsed time, not a fixed divisor.
        XCTAssertTrue(abs(history.totalSpeed - 1024) < 0.001)
        for tick in 8...185 { history.sample(at: Double(tick) / 5) }
        XCTAssertEqual(history.samples.count, 151)
        XCTAssertEqual(history.samples.first?.time, 7)
        XCTAssertEqual(history.samples.last?.time, 37)
        XCTAssertTrue(history.samples.allSatisfy { $0.bytesPerSecond == 0 })
        history.sample(at: 200) // A long idle gap expires all old measurements.
        XCTAssertTrue(history.samples.allSatisfy { $0.time >= 170 })
        history.record(1000, for: first)
        history.sample(at: 199); history.sample(at: 200)
        history.sample(at: 200.2)
        XCTAssertTrue(abs(history.totalSpeed - 5000) < 0.001)
    }
    func testRangeBoundaries() {
        XCTAssertEqual(Transfer.ranges(length: 10, chunkSize: 4), [0...3, 4...7, 8...9])
        XCTAssertTrue(Transfer.ranges(length: 0, chunkSize: 4).isEmpty)
    }
    func testURLValidationAndFilenames() throws {
        XCTAssertEqual(try DownloadItem.parseURLs("https://example.com/a\nhttp://example.com/b").count, 2)
        for text in ["file:///etc/passwd", "https://user:pass@example.com", "", "a string"] { XCTAssertThrowsError(try DownloadItem.parseURLs(text)) }
        XCTAssertEqual(DownloadItem.safeFilename("../file:bad"), ".._file_bad")
        XCTAssertEqual(DownloadItem.safeFilename(".."), "download")
    }
    func testParallelDownloadIsByteExact() async throws {
        let item = item("range")
        let network = NetworkByteCounter()
        try await Transfer.run(item: item, cache: root.appendingPathComponent("cache"), receivedBytes: { network.add($0) }) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: item.destination), expected)
        XCTAssertEqual(network.total, Int64(expected.count))
    }
    func testOrdinaryAndUnsupportedHEADDownloads() async throws {
        for path in ["plain", "nohead"] {
            let item = item(path)
            let network = NetworkByteCounter()
            try await Transfer.run(item: item, cache: root.appendingPathComponent(path), receivedBytes: { network.add($0) }) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: item.destination), expected)
            XCTAssertEqual(network.total, Int64(expected.count))
        }
    }
    func testInvalidRangeDoesNotPublishFile() async throws {
        let item = item("bad")
        do { try await Transfer.run(item: item, cache: root.appendingPathComponent("cache")) { _, _ in }; XCTFail("Expected rejection") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
    }
    func testDestinationIsNeverOverwritten() async throws {
        let item = item("range")
        try FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: item.destination)
        do { try await Transfer.run(item: item, cache: root.appendingPathComponent("cache")) { _, _ in }; XCTFail("Expected collision") } catch {}
        XCTAssertEqual(try String(contentsOf: item.destination, encoding: .utf8), "keep me")
    }
    func testResumeFromCompletedChunk() async throws {
        let item = item("range"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["url": item.url.absoluteString, "length": 9 * 1024 * 1024, "validator": "\"version-1\"", "chunkSize": 4 * 1024 * 1024]
        try JSONSerialization.data(withJSONObject: manifest).write(to: cache.appendingPathComponent("manifest.json"))
        try expected.prefix(4 * 1024 * 1024).write(to: cache.appendingPathComponent("0.part"))
        let network = NetworkByteCounter()
        try await Transfer.run(item: item, cache: cache, receivedBytes: { network.add($0) }) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: item.destination), expected)
        XCTAssertEqual(network.total, Int64(expected.count - 4 * 1024 * 1024))
        let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("bytes=0-4194303"))
    }
    func testChangedValidatorDiscardsCachedChunks() async throws {
        let item = item("range"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["url": item.url.absoluteString, "length": 9 * 1024 * 1024, "validator": "old-version", "chunkSize": 4 * 1024 * 1024]
        try JSONSerialization.data(withJSONObject: manifest).write(to: cache.appendingPathComponent("manifest.json"))
        try Data(repeating: 42, count: 4 * 1024 * 1024).write(to: cache.appendingPathComponent("0.part"))
        try await Transfer.run(item: item, cache: cache) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: item.destination), expected)
        let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("bytes=0-"))
    }
    func testHTTPFailureDoesNotPublishFile() async throws {
        let item = item("missing")
        do { try await Transfer.run(item: item, cache: root.appendingPathComponent("cache")) { _, _ in }; XCTFail("Expected HTTP error") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
    }
    func testRecoveryPolicy() throws {
        let policy = RetryPolicy(maxRetries: 3, baseDelay: 1, maxDelay: 300)
        XCTAssertEqual(policy.delay(for: HTTPStatusError(status: 503), retry: 1), 1)
        XCTAssertEqual(policy.delay(for: URLError(.timedOut), retry: 3), 4)
        XCTAssertEqual(policy.delay(for: HTTPStatusError(status: 429, retryAfter: "12"), retry: 1), 12)
        XCTAssertEqual(policy.delay(for: HTTPStatusError(status: 503, retryAfter: "9999"), retry: 1), 300)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(policy.delay(for: HTTPStatusError(status: 503, retryAfter: "Thu, 01 Jan 1970 00:01:00 GMT"), retry: 1, now: now), 60)
        XCTAssertTrue(policy.delay(for: HTTPStatusError(status: 404), retry: 1) == nil)
        XCTAssertTrue(policy.delay(for: URLError(.cancelled), retry: 1) == nil)
        XCTAssertTrue(policy.delay(for: URLError(.serverCertificateUntrusted), retry: 1) == nil)
        XCTAssertTrue(policy.delay(for: URLError(.timedOut), retry: 4) == nil)
    }
    func testHostConnectionRules() throws {
        let rule = try HostConnectionRule(host: " DOWNLOADS.Example.com ", connections: 2)
        XCTAssertEqual(HostConnectionRule.resolve(url: URL(string: "https://downloads.example.com/a")!, defaultConnections: 8, rules: [rule]), 2)
        XCTAssertEqual(HostConnectionRule.resolve(url: URL(string: "https://other.example.com/a")!, defaultConnections: 8, rules: [rule]), 8)
        XCTAssertEqual(HostConnectionRule.resolve(url: URL(string: "https://sub.downloads.example.com/a")!, defaultConnections: 4, rules: [rule]), 4)
        for host in ["https://example.com", "example.com/path", "example.com:443", "", "user@example.com"] { XCTAssertThrowsError(try HostConnectionRule(host: host, connections: 2)) }
    }
    func testTemporaryFailuresRecover() async throws {
        for path in ["retry", "retry-chunks"] {
            let item = item(path)
            try await Transfer.run(item: item, cache: root.appendingPathComponent(path), retryPolicy: RetryPolicy(maxRetries: 3, baseDelay: 0.01, maxDelay: 0.02)) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: item.destination), expected)
        }
    }
    func testRetryBudgetAndCancellation() async throws {
        let item = item("alwaysbusy")
        do {
            try await Transfer.run(item: item, cache: root.appendingPathComponent("cache"), retryPolicy: RetryPolicy(maxRetries: 2, baseDelay: 0.01, maxDelay: 0.02)) { _, _ in }
            XCTFail("Expected exhausted retry budget")
        } catch { XCTAssertEqual((error as? HTTPStatusError)?.status, 503) }
        let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "/alwaysbusy full").count - 1, 3)
        let cancelling = self.item("cancel-retry")
        let task = Task {
            try await Transfer.run(item: cancelling, cache: root.appendingPathComponent("cancel"), retryPolicy: RetryPolicy(baseDelay: 10)) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Expected immediate cancellation") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelling.destination.path))
    }
    func testAdaptiveRangesAndSmallFiles() async throws {
        XCTAssertEqual(Transfer.chunkSize(length: 2 * 1024 * 1024, connections: 4), 512 * 1024)
        XCTAssertEqual(Transfer.chunkSize(length: 64 * 1024 * 1024, connections: 4), 4 * 1024 * 1024)
        XCTAssertEqual(Transfer.chunkSize(length: 1, connections: 8), 256 * 1024)
        XCTAssertTrue(Transfer.chunkSize(length: Int64.max, connections: 8) <= 4 * 1024 * 1024)
        let item = item("small")
        try await Transfer.run(item: item, cache: root.appendingPathComponent("small-cache"), connections: 4) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: item.destination), Data(expected.prefix(2 * 1024 * 1024)))
        let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").filter { $0.hasPrefix("/small bytes=") }.count, 4)
    }
    func testConnectionLimitsAndReuse() async throws {
        for workers in [1, 2, 4, 8] {
            let item = item("workers-\(workers)")
            try await Transfer.run(item: item, cache: root.appendingPathComponent("workers-cache"), connections: workers) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: item.destination), expected)
            let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
            let rows = log.split(separator: "\n").filter { $0.hasPrefix("/workers-\(workers) bytes=") }
            let active = rows.compactMap { row -> Int? in
                guard let suffix = row.components(separatedBy: "active=").last else { return nil }
                return Int(suffix.components(separatedBy: " ")[0])
            }
            XCTAssertTrue((active.max() ?? 0) <= workers)
            XCTAssertTrue((active.max() ?? 0) >= min(2, workers))
            if workers == 1 {
                let ports = Set(rows.compactMap { $0.components(separatedBy: "connection=").last })
                XCTAssertTrue(rows.count >= 3)
                XCTAssertEqual(ports.count, 1) // Multiple ranges reused the same TCP socket.
            }
        }
    }
    func testSlowTailRecoveryAndProgress() async throws {
        let item = item("tail-straggler"), recorder = TransferRecorder()
        let start = ProcessInfo.processInfo.systemUptime
        try await Transfer.run(item: item, cache: root.appendingPathComponent("cache"), connections: 4, tailRecovery: TailRecoveryPolicy(gracePeriod: 0.1), phase: { await recorder.phase($0) }) { received, total in await recorder.progress(received, total) }
        XCTAssertTrue(ProcessInfo.processInfo.systemUptime - start < 2)
        XCTAssertEqual(try Data(contentsOf: item.destination), tailExpected)
        let events = await recorder.snapshot()
        XCTAssertTrue(events.phases.contains(.recoveringSlowRange))
        XCTAssertEqual(events.phases.last, .assembling)
        XCTAssertTrue(events.progress.allSatisfy { $0.0 <= $0.1 })
        XCTAssertEqual(events.progress.last?.0, Int64(tailExpected.count))
        let rows = try requestRows("tail-straggler")
        let final = rows.filter { $0.contains("-9437183 ") }
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(rows.allSatisfy { activeCount($0) <= 4 })
    }
    func testResumedTailRecovery() async throws {
        let item = item("tail-resumed"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["url": item.url.absoluteString, "length": 9 * 1024 * 1024, "validator": "\"version-1\"", "chunkSize": 4 * 1024 * 1024]
        try JSONSerialization.data(withJSONObject: manifest).write(to: cache.appendingPathComponent("manifest.json"))
        let source = tailExpected
        try source.prefix(4 * 1024 * 1024).write(to: cache.appendingPathComponent("0.part"))
        try source.subdata(in: (4 * 1024 * 1024)..<(8 * 1024 * 1024)).write(to: cache.appendingPathComponent("1.part"))
        try await Transfer.run(item: item, cache: cache, connections: 2, tailRecovery: TailRecoveryPolicy(gracePeriod: 0.1)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: item.destination), source)
        let rows = try requestRows("tail-resumed")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.contains("bytes=8388608-9437183") && activeCount($0) <= 2 })
    }
    func testTailCancellationAndCleanup() async throws {
        let item = item("tail-cancel"), cache = root.appendingPathComponent("cache")
        let (events, continuation) = AsyncStream<TransferPhase>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            try await Transfer.run(item: item, cache: cache, connections: 4, tailRecovery: TailRecoveryPolicy(gracePeriod: 0.1), phase: { continuation.yield($0) }) { _, _ in }
        }
        for await phase in events {
            if phase == .recoveringSlowRange { task.cancel(); break }
        }
        let start = ProcessInfo.processInfo.systemUptime
        do { try await task.value; XCTFail("Expected cancellation of both copies") } catch {}
        XCTAssertTrue(ProcessInfo.processInfo.systemUptime - start < 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
        let retained = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        XCTAssertTrue(retained.allSatisfy { $0.pathExtension == "part" || $0.lastPathComponent == "manifest.json" })
        XCTAssertTrue(retained.contains { $0.pathExtension == "part" })
    }
    func testInvalidTailBackupRejected() async throws {
        let item = item("tail-invalid-backup"), cache = root.appendingPathComponent("cache")
        do {
            try await Transfer.run(item: item, cache: cache, connections: 4, tailRecovery: TailRecoveryPolicy(gracePeriod: 0.1)) { _, _ in }
            XCTFail("Malformed backup must not be accepted")
        } catch { XCTAssertTrue(error is DownloadError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
        let retained = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        XCTAssertTrue(retained.allSatisfy { $0.pathExtension == "part" || $0.lastPathComponent == "manifest.json" })
    }
    func testSingleConnectionAndRetryAfterRespected() async throws {
        let serial = item("tail-serial")
        try await Transfer.run(item: serial, cache: root.appendingPathComponent("serial"), connections: 1, tailRecovery: TailRecoveryPolicy(gracePeriod: 0.05)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: serial.destination), tailExpected)
        let rows = try requestRows("tail-serial")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { activeCount($0) == 1 })
        let limited = item("tail-backoff"), recorder = TransferRecorder()
        let start = ProcessInfo.processInfo.systemUptime
        try await Transfer.run(item: limited, cache: root.appendingPathComponent("backoff"), connections: 4, tailRecovery: TailRecoveryPolicy(gracePeriod: 0.05), phase: { await recorder.phase($0) }) { _, _ in }
        XCTAssertTrue(ProcessInfo.processInfo.systemUptime - start >= 1)
        XCTAssertEqual(try Data(contentsOf: limited.destination), tailExpected)
        let limitedRows = try requestRows("tail-backoff").filter { $0.contains("-9437183 ") }
        XCTAssertEqual(limitedRows.count, 2) // One 503 and its allowed retry, no speculative copy.
        let events = await recorder.snapshot()
        XCTAssertFalse(events.phases.contains(.recoveringSlowRange))
    }
    private func requestRows(_ path: String) throws -> [String] {
        let log = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        return log.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/\(path) bytes=") }
    }
    private func activeCount(_ row: String) -> Int {
        Int(row.components(separatedBy: "active=").last?.components(separatedBy: " ").first ?? "0") ?? 0
    }
    func testCancellationDoesNotPublishFile() async throws {
        let item = item("slow"), cache = root.appendingPathComponent("cache")
        let task = Task { try await Transfer.run(item: item, cache: cache) { _, _ in } }
        try await Task.sleep(nanoseconds: 120_000_000); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
    }
}

private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Equality check failed") }
private func XCTAssertTrue(_ value: Bool) { precondition(value, "Expected true") }
private func XCTAssertFalse(_ value: Bool) { precondition(!value, "Expected false") }
private func XCTFail(_ message: String) { fatalError(message) }
private func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw DownloadError.invalidResponse }; return value }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) { do { _ = try expression(); fatalError("Expected error") } catch {} }
@main struct CoreChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--tail-benchmark") { try await runTailBenchmark(); return }
        if CommandLine.arguments.contains("--benchmark") { try await runPerformanceBenchmark(); return }
        let suite = DownloadCoreTests()
        try suite.setUpWithError()
        defer { try? suite.tearDownWithError() }
        suite.testRangeBoundaries(); print("PASS range boundaries")
        suite.testSpeedHistory(); print("PASS 200-millisecond speed sampling, aggregation, idle decay, and 30-second history")
        try suite.testURLValidationAndFilenames(); print("PASS URL and filename validation")
        try await suite.testParallelDownloadIsByteExact(); print("PASS parallel byte integrity")
        // Give each test a fresh destination/cache while retaining the fixture server.
        func reset() throws {
            try FileManager.default.removeItem(at: suite.root)
            try FileManager.default.createDirectory(at: suite.root, withIntermediateDirectories: true)
        }
        try reset(); try suite.testFreshStorage(); print("PASS fresh DownloadJet storage and repeated startup")
        try reset(); try await suite.testStorageMigrationAndResume(); print("PASS storage migration preserves queue, settings, and resumable chunks")
        try reset(); try suite.testExistingStorageIsNotOverwritten(); print("PASS existing DownloadJet data is never merged or overwritten")
        try reset(); try suite.testBlockedStorageMigrationRetainsData(); print("PASS blocked storage migration retains original data")
        try reset(); try await suite.testOrdinaryAndUnsupportedHEADDownloads(); print("PASS fallback and unsupported HEAD")
        try reset(); try await suite.testInvalidRangeDoesNotPublishFile(); print("PASS malformed range rejected")
        try reset(); try await suite.testDestinationIsNeverOverwritten(); print("PASS destination collision")
        try reset(); try await suite.testResumeFromCompletedChunk(); print("PASS saved chunk resume")
        try reset(); try await suite.testCancellationDoesNotPublishFile(); print("PASS cancellation")
        try reset(); try await suite.testChangedValidatorDiscardsCachedChunks(); print("PASS changed validator invalidates chunks")
        try reset(); try await suite.testHTTPFailureDoesNotPublishFile(); print("PASS HTTP failure")
        try suite.testRecoveryPolicy(); print("PASS retry policy, Retry-After, and permanent failures")
        try suite.testHostConnectionRules(); print("PASS exact-host connection rules")
        try reset(); try await suite.testTemporaryFailuresRecover(); print("PASS automatic recovery for files and chunks")
        try reset(); try await suite.testRetryBudgetAndCancellation(); print("PASS retry budget and cancellation during backoff")
        try reset(); try await suite.testAdaptiveRangesAndSmallFiles(); print("PASS adaptive ranges and small-file integrity")
        try reset(); try await suite.testConnectionLimitsAndReuse(); print("PASS 1/2/4/8 worker limits and TCP connection reuse")
        try reset(); try await suite.testSlowTailRecoveryAndProgress(); print("PASS slow-tail rescue, bounded progress, and losing-copy cancellation")
        try reset(); try await suite.testResumedTailRecovery(); print("PASS rescue of a resumed tail without redownloading saved chunks")
        try reset(); try await suite.testTailCancellationAndCleanup(); print("PASS cancellation and cleanup of both tail attempts")
        try reset(); try await suite.testInvalidTailBackupRejected(); print("PASS malformed tail backup rejection")
        try reset(); try await suite.testSingleConnectionAndRetryAfterRespected(); print("PASS single-connection limits and Retry-After during tail recovery")
        print("All 26 checks passed.")
    }
}

private actor TransferRecorder {
    var phases: [TransferPhase] = []
    var progress: [(Int64, Int64)] = []
    func phase(_ value: TransferPhase) { phases.append(value) }
    func progress(_ received: Int64, _ total: Int64) { progress.append((received, total)) }
    func snapshot() -> (phases: [TransferPhase], progress: [(Int64, Int64)]) { (phases, progress) }
}

private final class NetworkByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func add(_ count: Int64) { lock.lock(); bytes += count; lock.unlock() }
    var total: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
}
