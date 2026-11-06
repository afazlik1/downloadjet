import SwiftUI
import AppKit
import DownloadCore

@MainActor final class DownloadStore: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var message: String?
    @Published var queueRunning = true
    @Published var speeds: [UUID: Double] = [:]
    @Published private(set) var totalSpeed: Double = 0
    @Published private(set) var speedHistory: [DownloadSpeedSample] = []
    @Published var connections = 4 { didSet { savePreferences() } }
    @Published var maxRetries = 3 { didSet { savePreferences() } }
    @Published var hostRules: [HostConnectionRule] = [] { didSet { savePreferences() } }
    @Published var recoveryMessages: [UUID: String] = [:]
    @Published var phases: [UUID: TransferPhase] = [:]
    private struct Preferences: Codable { var connections: Int; var maxRetries: Int; var hostRules: [HostConnectionRule] }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private let networkBytes = ReceivedByteCounter()
    private var speedMeter = DownloadSpeedHistory(now: ProcessInfo.processInfo.systemUptime)
    private var timer: Timer?
    private var storageReady = false
    let support: URL
    var defaultDirectory: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    init(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], automaticallySchedule: Bool = true) {
        support = AppStorage.directory(in: applicationSupport)
        speedHistory = speedMeter.samples
        do {
            try AppStorage.prepare(in: applicationSupport)
            let settings = support.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: settings.path) {
                let saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: settings))
                connections = min(8, max(1, saved.connections)); maxRetries = min(5, max(0, saved.maxRetries)); hostRules = saved.hostRules
            }
            let file = support.appendingPathComponent("queue.json")
            if FileManager.default.fileExists(atPath: file.path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: file))
                for i in items.indices where items[i].status == .downloading { items[i].status = .paused }
            }
            storageReady = true
        } catch { message = "Could not load saved queue: \(error.localizedDescription)" }
        if automaticallySchedule {
            let timer = Timer(timeInterval: DownloadSpeedHistory.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleSpeed(); self?.pump() }
            }
            timer.tolerance = 0.025
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
    func sampleSpeed() {
        for (id, bytes) in networkBytes.take() { speedMeter.record(bytes, for: id) }
        speedMeter.sample(at: ProcessInfo.processInfo.systemUptime)
        speeds = speedMeter.speeds
        totalSpeed = speedMeter.totalSpeed
        speedHistory = speedMeter.samples
    }
    private func savePreferences() {
        guard storageReady else { return }
        do { try JSONEncoder().encode(Preferences(connections: connections, maxRetries: maxRetries, hostRules: hostRules)).write(to: support.appendingPathComponent("preferences.json"), options: .atomic) }
        catch { message = "Could not save settings: \(error.localizedDescription)" }
    }
    func setHostRule(host: String, connections: Int) throws {
        let rule = try HostConnectionRule(host: host, connections: connections)
        hostRules = (hostRules.filter { $0.host != rule.host } + [rule]).sorted { $0.host < $1.host }
    }
    func save() {
        guard storageReady else { return }
        do { try JSONEncoder().encode(items).write(to: support.appendingPathComponent("queue.json"), options: .atomic) }
        catch { message = "Could not save queue: \(error.localizedDescription)" }
    }
    func add(text: String, directory: URL, scheduled: Date?, downloadLater: Bool = false) throws {
        guard storageReady else { throw StorageError.unavailable }
        let urls = try DownloadItem.parseURLs(text)
        for url in urls {
            var item = DownloadItem(url: url, directory: directory, scheduled: downloadLater ? nil : scheduled)
            if downloadLater { item.status = .waiting }
            let base = item.destination.deletingPathExtension().lastPathComponent
            let ext = item.destination.pathExtension
            var number = 2
            while FileManager.default.fileExists(atPath: item.destination.path) || items.contains(where: { $0.destination == item.destination }) {
                item.filename = "\(base) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"); number += 1
            }
            items.append(item)
        }
        save(); pump()
    }
    func pump() {
        let now = Date()
        guard storageReady, queueRunning else { return }
        for item in items where tasks.count < 2 && item.status == .queued && (item.scheduled == nil || item.scheduled! <= now) { start(item.id) }
    }
    func start(_ id: UUID) {
        guard storageReady, tasks[id] == nil, let index = items.firstIndex(where: { $0.id == id }), items[index].status != .completed else { return }
        items[index].status = .downloading; items[index].error = nil; items[index].scheduled = nil
        let item = items[index], token = UUID()
        let connections = HostConnectionRule.resolve(url: item.url, defaultConnections: connections, rules: hostRules)
        let retryPolicy = RetryPolicy(maxRetries: maxRetries)
        tokens[id] = token
        let networkBytes = networkBytes
        let cache = support.appendingPathComponent("Parts").appendingPathComponent(id.uuidString)
        tasks[id] = Task {
            do {
                try await Transfer.run(item: item, cache: cache, connections: connections, phase: { [self] phase in
                    await setPhase(id, token: token, phase: phase)
                }, retryPolicy: retryPolicy, receivedBytes: { count in
                    networkBytes.record(count, for: id)
                }, retrying: { [self] attempt, delay in
                    await reportRecovery(id, token: token, attempt: attempt, delay: delay)
                }, progress: { [self] received, total in
                    await update(id, token: token, received: received, total: total)
                })
                if tokens[id] == token, let i = items.firstIndex(where: { $0.id == id }) { items[i].status = .completed }
            } catch {
                if tokens[id] == token, let i = items.firstIndex(where: { $0.id == id }) {
                    if items[i].status == .downloading { items[i].status = .failed; items[i].error = error.localizedDescription }
                }
            }
            tasks[id] = nil; tokens[id] = nil; speeds[id] = nil; recoveryMessages[id] = nil; phases[id] = nil
            save(); pump()
        }
        save()
    }
    private func setPhase(_ id: UUID, token: UUID, phase: TransferPhase) {
        guard tokens[id] == token, items.first(where: { $0.id == id })?.status == .downloading else { return }
        phases[id] = phase
        if phase == .assembling { speeds[id] = nil; recoveryMessages[id] = nil }
    }
    private func reportRecovery(_ id: UUID, token: UUID, attempt: Int, delay: TimeInterval) {
        guard tokens[id] == token, items.first(where: { $0.id == id })?.status == .downloading else { return }
        recoveryMessages[id] = "Retry \(attempt) in \(Int(ceil(delay)))s · temporary connection or server problem"
        speeds[id] = nil
    }
    private func update(_ id: UUID, token: UUID, received: Int64, total: Int64) {
        guard tokens[id] == token, let i = items.firstIndex(where: { $0.id == id }), items[i].status == .downloading else { return }
        if received > items[i].received { recoveryMessages[id] = nil }
        items[i].received = received; items[i].total = total
    }
    func pause(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = .paused; tasks[id]?.cancel(); speeds[id] = nil; recoveryMessages[id] = nil; phases[id] = nil; save()
    }
    func resume(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), tasks[id] == nil else { return }
        items[i].status = .queued; items[i].scheduled = nil; queueRunning = true; save(); pump()
    }
    func pauseAll() { queueRunning = false; for item in items where item.status == .downloading || item.status == .queued { pause(item.id) } }
    func resumeAll() {
        for i in items.indices where items[i].status == .paused || items[i].status == .failed { items[i].status = .queued }
        queueRunning = true; save(); pump()
    }
    func remove(_ id: UUID) {
        guard tasks[id] == nil else { pause(id); return }
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Parts").appendingPathComponent(id.uuidString))
        save()
    }
    func shutdown() { queueRunning = false; for id in Array(tasks.keys) { pause(id) }; save() }
}
// Delegate callbacks add bytes without publishing UI updates for every packet.
private final class ReceivedByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: Int64] = [:]
    func record(_ bytes: Int64, for id: UUID) {
        guard bytes > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        pending[id, default: 0] += bytes
    }
    func take() -> [UUID: Int64] {
        lock.lock(); defer { lock.unlock() }
        let result = pending
        pending.removeAll(keepingCapacity: true)
        return result
    }
}
private enum StorageError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Saved download data is unavailable. Resolve the startup error and reopen DownloadJet." }
}
func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
