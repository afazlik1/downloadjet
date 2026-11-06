import Foundation

// One session per file keeps HTTP/1.1 connections and HTTP/2 multiplexing available
// across HEAD, range requests, and retries. Delegate callbacks are routed by task ID.
private final class TransferSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private(set) var session: URLSession!
    init(connections: Int) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86400
        config.httpMaximumConnectionsPerHost = min(8, max(1, connections))
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func task(for request: URLRequest, receiver: Request) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: request)
        lock.lock(); requests[task.taskIdentifier] = receiver; lock.unlock()
        return task
    }
    private func receiver(for task: URLSessionTask, removing: Bool = false) -> Request? {
        lock.lock(); defer { lock.unlock() }
        return removing ? requests.removeValue(forKey: task.taskIdentifier) : requests[task.taskIdentifier]
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        receiver(for: downloadTask)?.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        receiver(for: downloadTask)?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        receiver(for: task, removing: true)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}

// Each request writes through URLSession's temporary download file; large files stay off the heap.
private final class Request: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var result: (URL, HTTPURLResponse)?
    private var moveError: Error?
    private var lastProgress: TimeInterval = 0
    private let output: URL
    private let progress: @Sendable (Int64) -> Void
    private let receivedBytes: @Sendable (Int64) -> Void
    init(output: URL, receivedBytes: @escaping @Sendable (Int64) -> Void, progress: @escaping @Sendable (Int64) -> Void) {
        self.output = output; self.receivedBytes = receivedBytes; self.progress = progress
    }
    func run(_ request: URLRequest, pool: TransferSession) async throws -> (URL, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let task = pool.task(for: request, receiver: self); self.task = task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        receivedBytes(bytesWritten)
        if now - lastProgress >= 0.1 || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite) {
            lastProgress = now; progress(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else { moveError = DownloadError.invalidResponse; return }
        do { try FileManager.default.moveItem(at: location, to: output); result = (output, response) } catch { moveError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError { continuation?.resume(throwing: error) }
        else if let result { continuation?.resume(returning: result) }
        else { continuation?.resume(throwing: DownloadError.invalidResponse) }
        continuation = nil
    }
}

private struct Manifest: Codable, Equatable {
    var url: URL
    var length: Int64
    var validator: String?
    var chunkSize: Int64
}
private actor ProgressCounter {
    var values: [Int: Int64] = [:]
    let total: Int64
    let callback: @Sendable (Int64, Int64) async -> Void
    init(total: Int64, callback: @escaping @Sendable (Int64, Int64) async -> Void) { self.total = total; self.callback = callback }
    private var received: Int64 = 0
    private var lastReport: TimeInterval = 0
    func update(_ index: Int, _ count: Int64) async {
        let previous = values[index] ?? 0
        let current = max(previous, count)
        values[index] = current; received += current - previous
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport >= 0.1 || received == total {
            lastReport = now; await callback(received, total)
        }
    }
}
private actor TailEligibility {
    private var receiving: Set<UUID> = []
    private var retried: Set<UUID> = []
    func recordProgress(_ id: UUID) { receiving.insert(id) }
    func recordRetry(_ id: UUID) { retried.insert(id) }
    // Never use a hedge to bypass a retry budget or a server's Retry-After backoff.
    func eligible(_ id: UUID) -> Bool { receiving.contains(id) && !retried.contains(id) }
}
private enum RangeEvent: Sendable {
    case tick
    case finished(UUID, Result<URL, Error>)
}
private struct RunningRange {
    let index: Int
    let started: TimeInterval
    let task: Task<RangeEvent, Never>
}

public enum Transfer {
    private static func download(_ request: URLRequest, output: URL, pool: TransferSession, policy: RetryPolicy, receivedBytes: @escaping @Sendable (Int64) -> Void, retrying: @escaping @Sendable (Int, TimeInterval) async -> Void, progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        try await policy.perform(retrying: retrying) {
            // Every attempt starts with a fresh temporary file; completed chunks stay intact.
            try? FileManager.default.removeItem(at: output)
            do {
                let result = try await Request(output: output, receivedBytes: receivedBytes, progress: progress).run(request, pool: pool)
                guard (200..<300).contains(result.1.statusCode) else {
                    throw HTTPStatusError(status: result.1.statusCode, retryAfter: result.1.value(forHTTPHeaderField: "Retry-After"))
                }
                return result
            } catch { try? FileManager.default.removeItem(at: output); throw error }
        }
    }
    private static func downloadRanges(item: DownloadItem, cache: URL, ranges: [ClosedRange<Int64>], pending: [Int], pool: TransferSession, connections: Int, validator: String?, length: Int64, counter: ProgressCounter, retryPolicy: RetryPolicy, tailRecovery: TailRecoveryPolicy, receivedBytes: @escaping @Sendable (Int64) -> Void, phase: @escaping @Sendable (TransferPhase) async -> Void, retrying: @escaping @Sendable (Int, TimeInterval) async -> Void) async throws {
        let fm = FileManager.default
        let workers = min(8, max(1, connections))
        let eligibility = TailEligibility()
        var stagingFiles: [URL] = []
        // The task group drains every attempt before this defer runs, including cancelled losers.
        defer { for file in stagingFiles { try? fm.removeItem(at: file) } }
        try await withThrowingTaskGroup(of: RangeEvent.self) { group in
            var active: [UUID: RunningRange] = [:]
            var completed: Set<Int> = []
            var hedged: Set<Int> = []
            var next = 0
            var ticking = false
            defer {
                for attempt in active.values { attempt.task.cancel() }
                group.cancelAll()
            }
            func enqueue(_ index: Int) {
                let id = UUID(), range = ranges[index]
                let staging = cache.appendingPathComponent(id.uuidString)
                stagingFiles.append(staging)
                let job = Task<RangeEvent, Never> {
                    do {
                        try Task.checkCancellation()
                        var request = URLRequest(url: item.url)
                        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                        request.setValue(validator, forHTTPHeaderField: "If-Range")
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        let (file, response) = try await download(request, output: staging, pool: pool, policy: retryPolicy, receivedBytes: receivedBytes, retrying: { count, delay in
                            await eligibility.recordRetry(id)
                            await retrying(count, delay)
                        }) { bytes in
                            Task {
                                await eligibility.recordProgress(id)
                                await counter.update(index, min(bytes, range.upperBound - range.lowerBound + 1))
                            }
                        }
                        guard response.statusCode == 206,
                              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound)/\(length)",
                              (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == range.upperBound - range.lowerBound + 1 else { throw DownloadError.invalidResponse }
                        try Task.checkCancellation()
                        return .finished(id, .success(file))
                    } catch { return .finished(id, .failure(error)) }
                }
                active[id] = RunningRange(index: index, started: ProcessInfo.processInfo.systemUptime, task: job)
                // Forward structured cancellation to the separately cancellable attempt.
                group.addTask {
                    await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                }
            }
            while next < pending.count && active.count < workers { enqueue(pending[next]); next += 1 }
            while !active.isEmpty {
                try Task.checkCancellation()
                if tailRecovery.enabled && workers > 1 && next == pending.count && active.count < workers {
                    let now = ProcessInfo.processInfo.systemUptime
                    let candidates = active.sorted { $0.value.started < $1.value.started }
                    for (id, attempt) in candidates where active.count < workers && !completed.contains(attempt.index) && !hedged.contains(attempt.index) && now - attempt.started >= tailRecovery.gracePeriod {
                        if await eligibility.eligible(id) {
                            hedged.insert(attempt.index)
                            enqueue(attempt.index) // At most one backup for a range, using an idle slot.
                            await phase(.recoveringSlowRange)
                        }
                    }
                    if !ticking && active.values.contains(where: { !hedged.contains($0.index) && !completed.contains($0.index) }) {
                        ticking = true
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(min(0.25, tailRecovery.gracePeriod / 2) * 1_000_000_000))
                            return .tick
                        }
                    }
                }
                guard let event = try await group.next() else { break }
                try Task.checkCancellation()
                switch event {
                case .tick: ticking = false
                case let .finished(id, result):
                    guard let attempt = active.removeValue(forKey: id) else { continue }
                    if completed.contains(attempt.index) { continue }
                    switch result {
                    case .success(let file):
                        try fm.moveItem(at: file, to: cache.appendingPathComponent("\(attempt.index).part"))
                        completed.insert(attempt.index)
                        for peer in active.values where peer.index == attempt.index { peer.task.cancel() }
                        let range = ranges[attempt.index]
                        await counter.update(attempt.index, range.upperBound - range.lowerBound + 1)
                    case .failure(let error):
                        let hasPeer = active.values.contains { $0.index == attempt.index }
                        let transient = RetryPolicy(maxRetries: 1).delay(for: error, retry: 1) != nil
                        if !hasPeer || !transient { throw error }
                    }
                    while next < pending.count && active.count < workers { enqueue(pending[next]); next += 1 }
                }
            }
        }
    }
    // Enough ranges to fill the requested workers, with bounded request/disk overhead.
    public static func chunkSize(length: Int64, connections: Int) -> Int64 {
        let workers = Int64(min(8, max(1, connections)))
        let target = length > 0 ? (length - 1) / workers + 1 : 0
        let alignment: Int64 = 64 * 1024
        let bounded = min(4 * 1024 * 1024, max(256 * 1024, target))
        return ((bounded + alignment - 1) / alignment) * alignment
    }
    public static func ranges(length: Int64, chunkSize: Int64) -> [ClosedRange<Int64>] {
        guard length > 0, chunkSize > 0 else { return [] }
        return stride(from: Int64(0), to: length, by: Int(chunkSize)).map { $0...min(length - 1, $0 + chunkSize - 1) }
    }
    public static func run(item: DownloadItem, cache: URL, connections: Int = 4, tailRecovery: TailRecoveryPolicy = TailRecoveryPolicy(), phase: @escaping @Sendable (TransferPhase) async -> Void = { _ in }, retryPolicy: RetryPolicy = RetryPolicy(), receivedBytes: @escaping @Sendable (Int64) -> Void = { _ in }, retrying: @escaping @Sendable (Int, TimeInterval) async -> Void = { _, _ in }, progress: @escaping @Sendable (Int64, Int64) async -> Void) async throws {
        let fm = FileManager.default
        await phase(.downloading)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: item.directory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: item.destination.path) else { throw DownloadError.destinationExists }
        var head = URLRequest(url: item.url); head.httpMethod = "HEAD"; head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let pool = TransferSession(connections: connections)
        defer { pool.session.invalidateAndCancel() }
        let metadataRequest = head
        let http = try await retryPolicy.perform(retrying: retrying) {
            let (_, response) = try await pool.session.data(for: metadataRequest)
            guard let http = response as? HTTPURLResponse else { throw DownloadError.invalidResponse }
            if [408, 429, 500, 502, 503, 504].contains(http.statusCode) {
                throw HTTPStatusError(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            return http
        }
        // HEAD may be unsupported. In that case use the ordinary streaming download path.
        let length = (200..<300).contains(http.statusCode) ? http.expectedContentLength : -1
        let etag = http.value(forHTTPHeaderField: "ETag")
        let validator = (etag?.hasPrefix("W/") == false ? etag : nil) ?? http.value(forHTTPHeaderField: "Last-Modified")
        let ranged = length > 0 && http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" && validator != nil
        if ranged {
            let manifestURL = cache.appendingPathComponent("manifest.json")
            let previous = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            var manifest = Manifest(url: item.url, length: length, validator: validator, chunkSize: chunkSize(length: length, connections: connections))
            // Retain the old layout for compatible resumed downloads, including 0.2's 4 MiB parts.
            if let previous, previous.url == item.url, previous.length == length, previous.validator == validator,
               previous.chunkSize >= 256 * 1024, previous.chunkSize <= 4 * 1024 * 1024 {
                manifest = previous
            }
            if previous != manifest {
                try fm.removeItem(at: cache); try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            let ranges = ranges(length: length, chunkSize: manifest.chunkSize)
            let counter = ProgressCounter(total: length, callback: progress)
            var pending: [Int] = []
            for (index, range) in ranges.enumerated() {
                let path = cache.appendingPathComponent("\(index).part")
                let size = (try? fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value
                if size == range.upperBound - range.lowerBound + 1 { await counter.update(index, size!) }
                else { try? fm.removeItem(at: path); pending.append(index) }
            }
            try await downloadRanges(item: item, cache: cache, ranges: ranges, pending: pending, pool: pool, connections: connections, validator: validator, length: length, counter: counter, retryPolicy: retryPolicy, tailRecovery: tailRecovery, receivedBytes: receivedBytes, phase: phase, retrying: retrying)
            try Task.checkCancellation()
            await phase(.assembling)
            let assembled = item.directory.appendingPathComponent(".downloadjet-\(item.id).tmp")
            defer { try? fm.removeItem(at: assembled) }
            fm.createFile(atPath: assembled.path, contents: nil)
            let output = try FileHandle(forWritingTo: assembled)
            do {
                for index in ranges.indices {
                    try Task.checkCancellation()
                    let input = try FileHandle(forReadingFrom: cache.appendingPathComponent("\(index).part"))
                    do { while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }; try input.close() }
                    catch { try? input.close(); throw error }
                }
                try output.synchronize(); try output.close()
            } catch { try? output.close(); throw error }
            try fm.moveItem(at: assembled, to: item.destination)
        } else {
            let staging = item.directory.appendingPathComponent(".downloadjet-\(item.id).tmp")
            try? fm.removeItem(at: staging)
            defer { try? fm.removeItem(at: staging) }
            let (file, response) = try await download(URLRequest(url: item.url), output: staging, pool: pool, policy: retryPolicy, receivedBytes: receivedBytes, retrying: retrying) { bytes in Task { await progress(bytes, max(0, length)) } }
            guard (200..<300).contains(response.statusCode), response.statusCode != 206 else { throw DownloadError.invalidResponse }
            try Task.checkCancellation()
            try fm.moveItem(at: file, to: item.destination)
        }
        try? fm.removeItem(at: cache)
        let size = (try? fm.attributesOfItem(atPath: item.destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        await progress(size, size)
    }
}
