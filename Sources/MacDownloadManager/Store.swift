import SwiftUI
import AppKit
import DownloadCore

@MainActor final class DownloadStore: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var message: String?
    @Published var queueRunning = true
    @Published var speeds: [UUID: Double] = [:]
    @Published var connections = 4 { didSet { savePreferences() } }
    @Published var maxRetries = 3 { didSet { savePreferences() } }
    @Published var hostRules: [HostConnectionRule] = [] { didSet { savePreferences() } }
    @Published var recoveryMessages: [UUID: String] = [:]
    @Published var phases: [UUID: TransferPhase] = [:]
    private struct Preferences: Codable { var connections: Int; var maxRetries: Int; var hostRules: [HostConnectionRule] }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var timer: Timer?
    let support: URL
    var defaultDirectory: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    init() {
        // Retain the existing storage folder so the display-name change preserves saved state.
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Current")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
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
        } catch { message = "Could not load saved queue: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.pump() } }
    }
    private func savePreferences() {
        do { try JSONEncoder().encode(Preferences(connections: connections, maxRetries: maxRetries, hostRules: hostRules)).write(to: support.appendingPathComponent("preferences.json"), options: .atomic) }
        catch { message = "Could not save settings: \(error.localizedDescription)" }
    }
    func setHostRule(host: String, connections: Int) throws {
        let rule = try HostConnectionRule(host: host, connections: connections)
        hostRules = (hostRules.filter { $0.host != rule.host } + [rule]).sorted { $0.host < $1.host }
    }
    func save() {
        do { try JSONEncoder().encode(items).write(to: support.appendingPathComponent("queue.json"), options: .atomic) }
        catch { message = "Could not save queue: \(error.localizedDescription)" }
    }
    func add(text: String, directory: URL, scheduled: Date?) throws {
        let urls = try DownloadItem.parseURLs(text)
        for url in urls {
            var item = DownloadItem(url: url, directory: directory, scheduled: scheduled)
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
        for (id, sample) in samples where now.timeIntervalSince(sample.0) >= 2 { speeds[id] = nil }
        guard queueRunning else { return }
        for item in items where tasks.count < 2 && item.status == .queued && (item.scheduled == nil || item.scheduled! <= Date()) { start(item.id) }
    }
    func start(_ id: UUID) {
        guard tasks[id] == nil, let index = items.firstIndex(where: { $0.id == id }), items[index].status != .completed else { return }
        items[index].status = .downloading; items[index].error = nil; items[index].scheduled = nil
        let item = items[index], token = UUID()
        let connections = HostConnectionRule.resolve(url: item.url, defaultConnections: connections, rules: hostRules)
        let retryPolicy = RetryPolicy(maxRetries: maxRetries)
        tokens[id] = token; samples[id] = nil
        let cache = support.appendingPathComponent("Parts").appendingPathComponent(id.uuidString)
        tasks[id] = Task {
            do {
                try await Transfer.run(item: item, cache: cache, connections: connections, phase: { [self] phase in
                    await setPhase(id, token: token, phase: phase)
                }, retryPolicy: retryPolicy, retrying: { [self] attempt, delay in
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
        if phase == .assembling { speeds[id] = nil; samples[id] = nil; recoveryMessages[id] = nil }
    }
    private func reportRecovery(_ id: UUID, token: UUID, attempt: Int, delay: TimeInterval) {
        guard tokens[id] == token, items.first(where: { $0.id == id })?.status == .downloading else { return }
        recoveryMessages[id] = "Retry \(attempt) in \(Int(ceil(delay)))s · temporary connection or server problem"
        speeds[id] = nil; samples[id] = nil
    }
    private func update(_ id: UUID, token: UUID, received: Int64, total: Int64) {
        guard tokens[id] == token, let i = items.firstIndex(where: { $0.id == id }), items[i].status == .downloading else { return }
        if received > items[i].received { recoveryMessages[id] = nil }
        items[i].received = received; items[i].total = total
        guard phases[id] != .assembling else { return }
        let now = Date()
        if let (time, bytes) = samples[id], now.timeIntervalSince(time) >= 0.5 {
            speeds[id] = max(0, Double(received - bytes) / now.timeIntervalSince(time)); samples[id] = (now, received)
        } else if samples[id] == nil { samples[id] = (now, received) }
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
func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
