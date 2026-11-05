import Foundation
import CryptoKit
import DownloadCore

func runPerformanceBenchmark() async throws {
    let suite = DownloadCoreTests()
    try suite.setUpWithError(benchmark: true)
    defer { try? suite.tearDownWithError() }
    var rows: [[String: Any]] = []
    for kind in ["large", "small"] {
        let size = kind == "large" ? 64 * 1024 * 1024 : 2 * 1024 * 1024
        var expected = Data(capacity: size)
        let pattern = Data((0..<256).map { UInt8($0) })
        for _ in 0..<(size / 256) { expected.append(pattern) }
        let expectedHash = SHA256.hash(data: expected)
        for iteration in 0..<3 {
            let item = suite.item("benchmark/\(kind)-\(iteration)")
            let start = ProcessInfo.processInfo.systemUptime
            try await Transfer.run(item: item, cache: suite.root.appendingPathComponent("cache"), connections: 4) { _, _ in }
            let duration = ProcessInfo.processInfo.systemUptime - start
            let received = try Data(contentsOf: item.destination)
            precondition(SHA256.hash(data: received) == expectedHash, "Benchmark file integrity failed")
            let log = try String(contentsOf: suite.root.appendingPathComponent("requests.log"), encoding: .utf8)
            let requests = log.split(separator: "\n").filter { $0.contains("/benchmark/\(kind)-\(iteration) ") }
            let sockets = Set(requests.compactMap { $0.components(separatedBy: "connection=").last })
            rows.append(["tcp_connections": sockets.count, "http_requests": requests.count, "scenario": kind, "iteration": iteration, "bytes": size, "seconds": duration, "MiB_per_second": Double(size) / 1048576 / duration])
        }
    }
    print(String(data: try JSONSerialization.data(withJSONObject: ["environment": "Loopback HTTP/1.1, 80 ms per new TCP connection; 64 MiB at 128 MiB/s or 2 MiB at 8 MiB/s per connection; 4 requested workers; 3 runs each; SHA-256 verified", "results": rows], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
}

extension DownloadCoreTests {
    var tailExpected: Data {
        var data = Data(capacity: 9 * 1024 * 1024)
        for index in 0..<144 {
            let block = Data(SHA256.hash(data: Data(String(index).utf8)))
            for _ in 0..<2048 { data.append(block) }
        }
        return data
    }
}
func runTailBenchmark() async throws {
    let suite = DownloadCoreTests()
    try suite.setUpWithError()
    defer { try? suite.tearDownWithError() }
    let item = suite.item("tail-straggler")
    let started = ProcessInfo.processInfo.systemUptime
    try await Transfer.run(item: item, cache: suite.root.appendingPathComponent("cache"), connections: 4) { _, _ in }
    let seconds = ProcessInfo.processInfo.systemUptime - started
    let output = try Data(contentsOf: item.destination)
    precondition(SHA256.hash(data: output) == SHA256.hash(data: suite.tailExpected))
    let log = try String(contentsOf: suite.root.appendingPathComponent("requests.log"), encoding: .utf8)
    print(String(data: try JSONSerialization.data(withJSONObject: ["scenario": "9 MiB file; first request for final range dribbles 64 KiB every 180 ms; other requests unthrottled", "seconds": seconds, "sha256_verified": true, "requests": log.split(separator: "\n").map(String.init)], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
}
