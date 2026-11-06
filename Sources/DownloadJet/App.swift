import SwiftUI
import AppKit
import DownloadCore
import UniformTypeIdentifiers

// Explicit alias keeps SDKs with both State macros and the property wrapper compatible.
private typealias ViewState<Value> = SwiftUI.State<Value>

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DownloadStore?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { store?.shutdown() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct DownloadJetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = DownloadStore()
    @ViewState<Bool> private var showingAdd = false
    var body: some Scene {
        WindowGroup {
            MainView(showingAdd: $showingAdd).environmentObject(store)
                .onAppear { delegate.store = store }
                .sheet(isPresented: $showingAdd) { AddDownloadView().environmentObject(store) }
                .alert("DownloadJet", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("OK") { store.message = nil } } message: { Text(store.message ?? "") }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Add Download…") { showingAdd = true }.keyboardShortcut("n") }
        }
        Settings { DownloadSettingsView().environmentObject(store) }
    }
}
struct MainView: View {
    @EnvironmentObject var store: DownloadStore
    @Binding var showingAdd: Bool
    @ViewState<String> private var filter = "All Downloads"
    @ViewState<String> private var search = ""
    @ViewState<UUID?> private var selection = nil
    let filters = ["All Downloads", "Downloading", "Download Later", "Queued", "Paused", "Completed", "Failed"]
    let categories = ["Video", "Audio", "Archives", "Documents", "Other"]
    var visible: [DownloadItem] {
        store.items.filter { item in
            (filter == "All Downloads" || (filter == "Download Later" && item.status == .waiting) || filter.lowercased() == item.status.rawValue || filter == item.category) && (search.isEmpty || item.filename.localizedCaseInsensitiveContains(search) || item.url.host?.localizedCaseInsensitiveContains(search) == true)
        }.sorted { $0.created > $1.created }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("LIBRARY") { ForEach(filters, id: \.self) { name in Label(name, systemImage: icon(name)).tag(name) } }
                Section("FILE TYPES") { ForEach(categories, id: \.self) { name in Label(name, systemImage: icon(name)).tag(name) } }
            }
            .navigationTitle("DownloadJet")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Made for your Mac", systemImage: "desktopcomputer").font(.caption.weight(.medium))
                    Text("Your downloads. In flow.").font(.caption2).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 185, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(filter).font(.largeTitle.bold())
                        Text("\(visible.count) files · \(store.items.filter { $0.status == .downloading }.count) active transfers").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showingAdd = true } label: { Label("Add URL", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(26)
                HStack(spacing: 16) {
                    stat("TRANSFER SPEED", bytes(Int64(store.speeds.values.reduce(0, +))) + "/s", "arrow.down.circle.fill", .blue)
                    stat("COMPLETED", "\(store.items.filter { $0.status == .completed }.count) files", "checkmark.circle.fill", .green)
                    stat("IN QUEUE", "\(store.items.filter { $0.status == .queued }.count) files", "clock.fill", .orange)
                }.padding(.horizontal, 26).padding(.bottom, 22)
                Divider()
                if visible.isEmpty {
                    ContentUnavailableView { Label(search.isEmpty ? "Ready when you are" : "No matching downloads", systemImage: "arrow.down.to.line.circle") } description: { Text("Add a download URL, or paste a list of links to build your queue.") } actions: { Button("Add Download") { showingAdd = true } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(visible) { item in
                            DownloadRow(item: item).tag(item.id)
                                .contextMenu {
                                    if item.status == .downloading || item.status == .queued { Button("Pause") { store.pause(item.id) } }
                                    if item.status == .paused || item.status == .failed { Button("Resume") { store.resume(item.id) } }
                                    if item.status == .waiting { Button("Start Download") { store.resume(item.id) } }
                                    if item.status == .completed { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) } }
                                    Button("Remove from List", role: .destructive) { store.remove(item.id) }.disabled(item.status == .downloading)
                                }
                        }
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                }
                Divider()
                HStack {
                    Circle().fill(store.queueRunning ? .green : .orange).frame(width: 6, height: 6)
                    Text(store.queueRunning ? "Queue running" : "Queue paused")
                    Spacer()
                    Text("HTTP / HTTPS · Up to \(store.connections) connections per file")
                }.font(.caption).foregroundStyle(.secondary).padding(14)
            }.background(Color(nsColor: .textBackgroundColor))
            .navigationTitle("")
            .searchable(text: $search, prompt: "Search downloads")
            .toolbar {
                ToolbarItemGroup { Button { store.resumeAll() } label: { Label("Resume All", systemImage: "play.fill") }; Button { store.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") } }
            }
        }.frame(minWidth: 900, minHeight: 580).tint(.blue)
    }
    func stat(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Text(value).font(.title3.weight(.semibold)).monospacedDigit() }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    func icon(_ name: String) -> String {
        switch name {
        case "All Downloads": return "tray.full"
        case "Downloading": return "arrow.down.circle"
        case "Download Later": return "tray.and.arrow.down"
        case "Queued": return "clock"
        case "Paused": return "pause.circle"
        case "Completed": return "checkmark.circle"
        case "Failed": return "exclamationmark.circle"
        case "Video": return "film"
        case "Audio": return "music.note"
        case "Archives": return "archivebox"
        case "Documents": return "doc.text"
        default: return "square.grid.2x2"
        }
    }
}
struct DownloadRow: View {
    @EnvironmentObject var store: DownloadStore
    let item: DownloadItem
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: item.destination.pathExtension) ?? .data)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(item.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1); Spacer(); Text(store.phases[item.id]?.rawValue ?? (item.status == .waiting ? "Download Later" : item.status.rawValue.capitalized)).font(.caption).foregroundStyle(item.status == .failed ? .red : item.status == .completed ? .green : .secondary) }
                if item.status == .downloading || item.status == .paused { ProgressView(value: item.progress).tint(.blue) }
                HStack {
                    Text(item.url.host ?? "").lineLimit(1)
                    Text("·")
                    Text(item.total > 0 ? "\(bytes(item.received)) of \(bytes(item.total))" : bytes(item.received))
                    if let date = item.scheduled { Text("· \(date.formatted(date: .abbreviated, time: .shortened))") }
                    Spacer()
                    if let speed = store.speeds[item.id], speed > 0 { Text(bytes(Int64(speed)) + "/s").monospacedDigit() }
                }.font(.caption).foregroundStyle(.secondary)
                if let recovery = store.recoveryMessages[item.id] { Text(recovery).font(.caption).foregroundStyle(.orange) }
                if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            if item.status == .downloading || item.status == .queued {
                Button { store.pause(item.id) } label: { Image(systemName: "pause.fill") }.help("Pause")
            } else if item.status == .completed {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) } label: { Image(systemName: "folder") }.help("Show in Finder")
            } else if item.status == .waiting {
                Button { store.resume(item.id) } label: { Label("Start Download", systemImage: "play.fill") }.help("Start this saved download")
            } else {
                Button { store.resume(item.id) } label: { Image(systemName: "play.fill") }.help("Resume")
            }
        }.padding(.vertical, 13)
    }
}
struct AddDownloadView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @ViewState<String> private var text = ""
    @ViewState<URL?> private var directory = nil
    @ViewState<Bool> private var schedule = false
    @ViewState<Date> private var date = Date().addingTimeInterval(3600)
    @ViewState<String?> private var error = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("New download", systemImage: "arrow.down.circle.fill").font(.title2.bold())
            Text("Paste one HTTP or HTTPS link per line.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 120).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Image(systemName: "folder").foregroundStyle(.blue)
                Text((directory ?? store.defaultDirectory).path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK { directory = panel.url }
                }
            }
            Toggle("Schedule for later", isOn: $schedule)
            if schedule { DatePicker("Start at", selection: $date, in: Date()...) }
            Text("Download Later saves links without starting them or setting a time. Choose Start Download in the list when you’re ready.").font(.caption).foregroundStyle(.secondary)
            Text("Completed chunks are kept when paused. Servers without safe range support restart on resume. Scheduled downloads run while DownloadJet is open and your Mac is awake.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Paste Links") { if let value = NSPasteboard.general.string(forType: .string) { text = value } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download Later") { addDownload(later: true) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(schedule ? "Schedule" : "Download Now") { addDownload(later: false) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 540)
    }
    private func addDownload(later: Bool) {
        do {
            try store.add(text: text, directory: directory ?? store.defaultDirectory, scheduled: schedule ? date : nil, downloadLater: later)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct DownloadSettingsView: View {
    @EnvironmentObject var store: DownloadStore
    @ViewState<String> private var host = ""
    @ViewState<Int> private var limit = 2
    @ViewState<String?> private var error = nil
    var body: some View {
        Form {
            Section("Downloads") {
                Picker("Default connections per file", selection: $store.connections) {
                    ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Automatic retries per request", selection: $store.maxRetries) {
                    ForEach([0, 1, 3, 5], id: \.self) { Text($0 == 0 ? "Off" : "\($0)").tag($0) }
                }
                Text("Temporary network failures and HTTP 408, 429, 500, 502, 503, and 504 are retried with increasing delays. Server Retry-After delays are honored up to five minutes. Pause cancels recovery immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Server connection limits") {
                Text("Set connections per file for an exact hostname when a server limits parallel downloads. Rules apply to new transfers; pause and resume to apply a change. Redirected hosts use the original URL's rule.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.hostRules) { rule in
                    HStack {
                        Text(rule.host); Spacer()
                        Text("\(rule.connections) per file").foregroundStyle(.secondary)
                        Button { store.hostRules.removeAll { $0.host == rule.host } } label: { Image(systemName: "minus.circle") }.help("Remove server rule")
                    }
                }
                HStack {
                    TextField("Hostname, e.g. downloads.example.com", text: $host)
                    Picker("Connections", selection: $limit) { ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 65)
                    Button("Save Rule") {
                        do { try store.setHostRule(host: host, connections: limit); host = ""; error = nil }
                        catch { self.error = "Enter only a hostname, without a URL, path, or port." }
                    }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            Text("Up to two files download at once. Parallel requests require server byte-range support and a resource validator.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding(12).frame(width: 600, height: 500)
    }
}
