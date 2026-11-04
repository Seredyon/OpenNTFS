import SwiftUI
import AppKit
import Foundation

struct Activity: Equatable {
    var title: String
    var detail: String = ""
    var fraction: Double?
    var cancellable: Bool
    var cancelling = false
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let text: String
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Why the check sheet is shown.
enum CheckReason { case manual, dirty, markedDuringWrite }

enum SheetKind: Identifiable {
    case check(Target, CheckReason)
    case checkResult(Target, CheckReport)
    case newFolder
    case rename(Entry)
    case delete([Entry])
    case info(Entry)
    case format(Target)
    case repair([Entry]?)
    var id: String {
        switch self {
        case .check(let t, _): return "check:" + t.id
        case .checkResult(let t, let r): return "checkResult:" + t.id + ":" + r.id.uuidString
        case .newFolder: return "newFolder"
        case .rename(let e): return "rename:" + e.id
        case .delete(let list): return "delete:" + list.map(\.id).joined(separator: "|")
        case .info(let e): return "info:" + e.id
        case .format(let t): return "format:" + t.id
        case .repair(let list): return "repair:" + (list?.map(\.id).joined(separator: "|") ?? "*")
        }
    }
}

/// Shared between the UI and the background operation: progress throttling and cancellation.
final class OperationContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast
    private let sink: (String?, Double?) -> Void

    init(sink: @escaping (String?, Double?) -> Void) { self.sink = sink }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); WorkerConnection.shared.cancelCurrent() }
    func check() throws { if isCancelled { throw CancelledFailure() } }

    func report(_ detail: String?, _ fraction: Double?, force: Bool = false) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.08 else { lock.unlock(); return }
        lastReport = now
        lock.unlock()
        DispatchQueue.main.async { self.sink(detail, fraction) }
    }
}

/// One planned worker operation: arguments plus the bytes it moves (for progress) and a label.
struct PlannedOp {
    let op: String
    let args: [String]
    let bytes: UInt64
    let label: String
}

/// Executes planned operations in batches (one mounted session each, group-committed writes).
/// Returns the number of operations completed; on failure throws `BatchFailure` with the global count.
func executePlanned(_ ops: [PlannedOp], target t: Target, ctx: OperationContext, chunk: Int = 800) throws -> Int {
    let overhead: UInt64 = 64 * 1024
    let total = ops.reduce(UInt64(0)) { $0 + $1.bytes + overhead }
    var doneWeight: UInt64 = 0, completed = 0
    var start = 0
    while start < ops.count {
        try ctx.check()
        let slice = Array(ops[start..<min(start + chunk, ops.count)])
        let base = doneWeight
        ctx.report(slice[0].label, total > 0 ? Double(base) / Double(total) : nil, force: true)
        do {
            try Worker.batch(t, slice.map { ($0.op, $0.args) }) { bytes, item in
                let index = min(max(item ?? 0, 0), slice.count - 1)
                let w = base + bytes + UInt64(index) * overhead
                ctx.report(slice[index].label, total > 0 ? min(Double(w) / Double(total), 1) : nil)
            }
        } catch let failure as BatchFailure {
            throw BatchFailure(completed: start + failure.completed, cancelled: failure.cancelled, message: failure.message)
        }
        doneWeight = base + slice.reduce(UInt64(0)) { $0 + $1.bytes + overhead }
        completed = start + slice.count
        start += slice.count
    }
    return completed
}

@MainActor final class BrowserModel: ObservableObject {
    @Published var targets: [Target] = []
    @Published private(set) var targetID: String?
    @Published private(set) var opened = false
    @Published private(set) var path = "/"
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var visible: [Entry] = []
    @Published var selection: Set<Entry.ID> = []
    @Published var search = "" { didSet { if search != oldValue { refilter() } } }
    @Published var sortOrder: [KeyPathComparator<Entry>] = [KeyPathComparator(\Entry.name, comparator: .localizedStandard)] {
        didSet { refilter() }
    }
    @Published private(set) var activity: Activity?
    @Published private(set) var scanning = false
    @Published var alert: AlertItem?
    @Published var sheet: SheetKind?
    @Published var toast: Toast?
    @Published var dropTargeted = false
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []

    let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "local.openntfs.operations", qos: .userInitiated)
    private var context: OperationContext?
    private var deviceRefreshPending = false
    private var toastTask: DispatchWorkItem?

    var target: Target? { targets.first { $0.id == targetID } }
    private struct PreviewCopy { let size: UInt64; let modified: UInt64; let url: URL }
    private var previewCopies: [String: PreviewCopy] = [:]

    var busy: Bool { activity != nil }
    var canBrowse: Bool { opened && target != nil && !busy }
    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }
    var folderName: String { path == "/" ? (target?.name ?? "") : (path as NSString).lastPathComponent }
    var hiddenCount: Int { settings.showHiddenItems ? 0 : entries.filter { $0.isHidden || $0.isSystem }.count }

    // MARK: Activity

    func run<T>(_ title: String, cancellable: Bool = false, work: @escaping (OperationContext) throws -> T,
                done: @escaping (Result<T, Error>) -> Void) {
        guard activity == nil else { return }
        let ctx = OperationContext { [weak self] detail, fraction in
            guard let self = self, var a = self.activity else { return }
            if let detail = detail { a.detail = detail }
            a.fraction = fraction
            self.activity = a
        }
        context = ctx
        withAnimation(.easeOut(duration: 0.18)) { activity = Activity(title: title, cancellable: cancellable) }
        queue.async {
            let result = Result { try work(ctx) }
            DispatchQueue.main.async {
                self.context = nil
                withAnimation(.easeInOut(duration: 0.22)) { self.activity = nil }
                done(result)
                if let t = self.target, VolumeAlerts.consume(t.id) {
                    self.alert = nil
                    self.sheet = .check(t, .markedDuringWrite)
                }
                if self.deviceRefreshPending { self.deviceRefreshPending = false; self.refreshDevices() }
            }
        }
    }

    func cancelActivity() {
        guard let ctx = context, var a = activity, a.cancellable else { return }
        a.cancelling = true; a.detail = L("Cancelling…"); activity = a
        ctx.cancel()
    }

    func show(_ error: Error, title: String? = nil) {
        if error is CancelledFailure { showToast("xmark.circle", L("Cancelled")); return }
        if error is VolumeNeedsCheck, let t = target { sheet = .check(t, .dirty); return }
        alert = AlertItem(title: title ?? L("The operation could not be completed"), message: error.localizedDescription)
    }

    func showToast(_ symbol: String, _ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = Toast(symbol: symbol, text: text) }
        let task = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil } }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: task)
    }

    // MARK: Devices and images

    func refreshDevices(userInitiated: Bool = false) {
        guard !scanning else { return }
        if busy { deviceRefreshPending = true; return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Target.discover() }
            DispatchQueue.main.async {
                self.scanning = false
                switch result {
                case .success(let found): self.apply(found, userInitiated: userInitiated)
                case .failure(let error): if userInitiated { self.show(error) }
                }
            }
        }
    }

    private func apply(_ found: [Target], userInitiated: Bool) {
        if busy { deviceRefreshPending = true; return }
        let previous = target
        withAnimation(.easeInOut(duration: 0.2)) { targets = targets.filter(\.isImage) + found }
        if let current = previous, !current.isImage {
            if let match = found.first(where: current.sameDevice) {
                targetID = match.id
            } else {
                closeBrowser(); targetID = nil
                if userInitiated == false { showToast("externaldrive.badge.xmark", L("“%@” was disconnected.", current.name)) }
            }
        }
        if userInitiated {
            showToast("arrow.clockwise", found.isEmpty ? L("No NTFS partitions on external drives") : LP(found.count, "%ld NTFS partition found", "%ld NTFS partitions found"))
        }
    }

    func choose(_ id: String?) {
        guard !busy, id != targetID else { return }
        closeBrowser()
        withAnimation(.easeInOut(duration: 0.2)) { targetID = id }
    }

    private func closeBrowser() {
        discardPreviewCopies()
        MountGuard.shared.release()
        opened = false; entries = []; visible = []; selection = []; path = "/"; search = ""
        backStack = []; forwardStack = []
    }

    func openImagePanel() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L("Open NTFS Image"); panel.prompt = L("Open")
        panel.message = L("Choose an image of the NTFS partition itself (without a partition table).")
        if panel.runModal() == .OK, let url = panel.url { attachImage(url) }
    }

    func attachImage(_ url: URL) {
        do {
            let t = try Target.image(url)
            if !targets.contains(where: { $0.id == t.id }) { withAnimation { targets.append(t) } }
            choose(t.id); openVolume()
        } catch { show(error) }
    }

    func removeImage(_ t: Target) {
        guard t.isImage, !busy else { return }
        if targetID == t.id { closeBrowser(); targetID = nil }
        withAnimation { targets.removeAll { $0.id == t.id } }
    }

    func openVolume() {
        guard target != nil else { return }
        go(to: "/", history: false, resetHistory: true)
    }

    func mountInFinder() {
        guard let t = target, !t.isImage else { return }
        MountGuard.shared.release()
        run(L("Returning the volume to Finder…"), work: { _ in
            _ = try Worker.invoke("inspect", target: t, arguments: [])
            _ = try Worker.invoke("release", target: t, arguments: [])
            let r = try Runner.run("/usr/sbin/diskutil", ["mount", t.id])
            guard r.status == 0 else {
                throw AppFailure(message: String(data: r.error, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? L("Could not mount the volume."))
            }
        }) { result in
            switch result {
            case .success:
                self.closeBrowser()
                self.showToast("checkmark.circle", L("The volume is available in Finder (read-only). Open it here again to write."))
            case .failure(let error): self.show(error)
            }
        }
    }

    /// Releases the drive, unmounts every partition and powers it down so it can be unplugged.
    func eject() {
        guard let t = target, !t.isImage, let disk = t.parentDisk else { return }
        MountGuard.shared.release()
        run(L("Ejecting “%@”…", t.name), work: { _ in
            _ = try Worker.invoke("release", target: t, arguments: [])
            let r = try Runner.run("/usr/sbin/diskutil", ["eject", disk])
            guard r.status == 0 else {
                throw AppFailure(message: L("Could not eject the drive. Close any app that is using it and try again."))
            }
        }) { result in
            switch result {
            case .success:
                self.closeBrowser(); self.targetID = nil
                self.showToast("eject", L("“%@” can be safely disconnected.", t.name))
                self.refreshDevices()
            case .failure(let error): self.show(error)
            }
        }
    }

    /// Checks the volume with the engine's NTFS checker. `verify` changes nothing; `safe` clears the
    /// "needs check" mark only if no errors are found; `repair` fixes the errors it finds.
    func checkVolume(_ mode: CheckReport.Mode, target chosen: Target? = nil) {
        guard let t = chosen ?? target, t.isNTFS, !busy else { return }
        let title: String
        switch mode {
        case .verify: title = L("Checking “%@”…", t.name)
        case .safe: title = L("Clearing the check mark on “%@”…", t.name)
        case .repair: title = L("Repairing “%@”…", t.name)
        }
        // Keep macOS from mounting the volume while the checker works on it.
        if !t.isImage { MountGuard.shared.protect(t.id) }
        run(title, work: { ctx in
            try Worker.check(t, mode: mode) { percent, stage in
                ctx.report(L("Stage %@ · %@%%", String((stage ?? 0) + 1), String(percent)), Double(min(percent, 100)) / 100)
            }
        }) { result in
            if !self.opened && !t.isImage { MountGuard.shared.release() }
            switch result {
            case .success(let report):
                if mode != .verify && report.writable && self.opened && self.targetID == t.id { self.reload() }
                // Let the previous sheet finish closing before the result appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.sheet = .checkResult(t, report) }
            case .failure(let error): self.show(error)
            }
        }
    }

    func format(_ t: Target, label: String) {
        run(L("Formatting “%@”…", t.name), work: { _ in try Worker.invoke("format", target: t, arguments: [label], format: true) }) { result in
            switch result {
            case .success:
                self.closeBrowser()
                if t.isImage, let i = self.targets.firstIndex(where: { $0.id == t.id }) { self.targets[i].fileSystem = "ntfs" }
                self.showToast("checkmark.circle", L("Formatting finished."))
                if !t.isImage { self.refreshDevices() }
            case .failure(let error): self.show(error)
            }
        }
    }

    // MARK: Navigation

    func go(to destination: String, history: Bool = true, resetHistory: Bool = false, select: String? = nil) {
        guard let t = target, !busy else { return }
        let origin = path, wasOpened = opened
        run(opened ? L("Reading folder…") : L("Opening “%@”…", t.name), work: { _ in try Worker.list(t, destination) }) { result in
            switch result {
            case .success(let list):
                if resetHistory { self.backStack = []; self.forwardStack = [] }
                else if history && wasOpened && origin != destination { self.backStack.append(origin); self.forwardStack = [] }
                if destination != origin || resetHistory { self.search = "" }
                self.path = destination
                self.entries = list
                withAnimation(.easeInOut(duration: 0.15)) { self.opened = true }
                if !t.isImage { MountGuard.shared.protect(t.id) }
                self.refilter()
                if let name = select { self.selection = Set(list.filter { $0.name == name }.map(\.id)) }
                else { self.selection = self.selection.intersection(Set(list.map(\.id))) }
            case .failure(let error): self.show(error, title: wasOpened ? nil : L("Could not open the volume"))
            }
        }
    }

    func reload(select: String? = nil) { if opened { go(to: path, history: false, select: select) } }
    func back() { guard let previous = backStack.last, canBrowse else { return }; backStack.removeLast(); forwardStack.append(path); go(to: previous, history: false) }
    func forward() { guard let next = forwardStack.last, canBrowse else { return }; forwardStack.removeLast(); backStack.append(path); go(to: next, history: false) }
    func up() { guard path != "/", canBrowse else { return }; go(to: NTFSPath.parent(path), select: (path as NSString).lastPathComponent) }
    func enter(_ entry: Entry) { if entry.isFolder { go(to: NTFSPath.join(path, entry.name)) } }

    func refilter() {
        var list = entries
        if !settings.showHiddenItems { list = list.filter { !$0.isHidden && !$0.isSystem } }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        list.sort(using: sortOrder)
        let folders = list.filter(\.directory), files = list.filter { !$0.directory }
        visible = folders + files
    }

    // MARK: Primary actions

    func primaryAction(_ ids: Set<Entry.ID>) {
        let chosen = entries.filter { ids.contains($0.id) }
        guard let first = chosen.first else { return }
        if chosen.count == 1, first.isFolder { enter(first); return }
        let files = chosen.filter(\.isRegularFile)
        guard !files.isEmpty else { return }
        switch settings.doubleClickAction {
        case .menu: DispatchQueue.main.async { FileActionMenu.show(for: files, model: self) }
        case .open: openWithDefaultApp(files)
        case .quickLook: quickLook(files)
        }
    }

    func openSelection() {
        let chosen = selectedEntries
        if chosen.count == 1, chosen[0].isFolder { enter(chosen[0]) }
        else if !chosen.filter(\.isRegularFile).isEmpty { openWithDefaultApp(chosen.filter(\.isRegularFile)) }
    }

    // MARK: Import

    func importPanel() {
        guard canBrowse else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.title = L("Copy to “%@”", folderName); panel.prompt = L("Copy")
        panel.message = L("Files and folders are copied to the NTFS volume. Existing items are never replaced.")
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL], into destination: String? = nil) {
        guard let t = target, canBrowse, !urls.isEmpty else { return }
        let folder = destination ?? path
        let taken = Set((folder == path ? entries : []).map { $0.name.lowercased() })
        let skipMetadata = settings.skipMacMetadata
        let needsListing = folder != path
        run(L("Copying to “%@”…", destination.map { ($0 as NSString).lastPathComponent } ?? folderName), cancellable: true, work: { ctx -> (Int, Int, Int) in
            var existing = taken
            if needsListing { existing = Set(try Worker.list(t, folder).map { $0.name.lowercased() }) }
            // Plan the whole copy first: folders (parents before children), then files, so the
            // worker can group-commit consecutive files and progress reflects real bytes.
            var folders: [PlannedOp] = [], files: [PlannedOp] = []
            var renamed = 0, skipped = 0
            let fm = FileManager.default
            func add(_ url: URL, remoteFolder: String, siblings: inout Set<String>) throws {
                try ctx.check()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                let original = url.lastPathComponent
                if values.isSymbolicLink == true { skipped += 1; return }
                if skipMetadata && NameRules.isMacMetadata(original) { skipped += 1; return }
                var name = NameRules.windowsSafe(original)
                if name != original.precomposedStringWithCanonicalMapping { renamed += 1 }
                name = NameRules.unique(name, taken: siblings)
                siblings.insert(name.lowercased())
                let remote = NTFSPath.join(remoteFolder, name)
                if values.isDirectory == true {
                    folders.append(PlannedOp(op: "mkdir", args: [remote], bytes: 0, label: name))
                    var children = Set<String>()
                    let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
                    for child in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                        try add(child, remoteFolder: remote, siblings: &children)
                    }
                } else if values.isRegularFile == true {
                    files.append(PlannedOp(op: "put", args: [url.path, remote], bytes: UInt64(values.fileSize ?? 0), label: original))
                } else { skipped += 1 }
            }
            for url in urls { try add(url, remoteFolder: folder, siblings: &existing) }
            let labelled = files.enumerated().map { i, f in
                PlannedOp(op: f.op, args: f.args, bytes: f.bytes, label: L("%@ of %@ - %@", String(i + 1), String(files.count), f.label))
            }
            do { _ = try executePlanned(folders + labelled, target: t, ctx: ctx) }
            catch let failure as BatchFailure {
                if failure.cancelled { throw CancelledFailure() }
                let copied = max(0, failure.completed - folders.count)
                throw AppFailure(message: L("Copied %@ of %@.", String(copied), String(files.count)) + "\n" + failure.message)
            }
            return (files.count, renamed, skipped)
        }) { result in
            switch result {
            case .success(let (copied, renamed, skipped)):
                var text = LP(copied, "Copied %ld file", "Copied %ld files")
                if renamed > 0 { text += " · " + LP(renamed, "%ld renamed for Windows", "%ld renamed for Windows") }
                if skipped > 0 { text += " · " + LP(skipped, "%ld skipped", "%ld skipped") }
                self.showToast("checkmark.circle", text)
            case .failure(let error): self.show(error)
            }
            self.reload()
        }
    }

    // MARK: Export

    func exportSelectionPanel() {
        let chosen = selectedEntries.filter { !$0.isLink }
        guard canBrowse, !chosen.isEmpty else { return }
        if chosen.count == 1, chosen[0].isRegularFile {
            let e = chosen[0]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = e.name; panel.title = L("Save to Mac"); panel.prompt = L("Save")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                // The panel already asked to replace; keep the old file in the Trash.
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { show(error); return }
            }
            export([e], to: url.deletingLastPathComponent(), names: [e.id: url.lastPathComponent])
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.title = L("Save to Mac"); panel.prompt = L("Save Here")
            panel.message = LP(chosen.count, "%ld item will be copied to the chosen folder.", "%ld items will be copied to the chosen folder.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            export(chosen, to: url)
        }
    }

    func export(_ chosen: [Entry], to directory: URL, names: [String: String] = [:], reveal: Bool = true,
                completion: (([URL]) -> Void)? = nil) {
        guard let t = target, canBrowse else { return }
        let folder = path
        run(LP(chosen.count, "Saving %ld item…", "Saving %ld items…"), cancellable: true, work: { ctx -> [URL] in
            var folders: [URL] = [], files: [PlannedOp] = [], tops: [URL] = []
            let fm = FileManager.default
            var localTaken = Set(((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).map { $0.lowercased() })
            func walk(_ remote: String, _ entry: Entry, _ local: URL) throws {
                try ctx.check()
                if entry.isFolder {
                    folders.append(local)
                    for child in try Worker.list(t, remote) where !child.isLink {
                        try walk(NTFSPath.join(remote, child.name), child, local.appendingPathComponent(child.name))
                    }
                } else if entry.isRegularFile {
                    files.append(PlannedOp(op: "get", args: [local.path, remote], bytes: entry.size, label: local.lastPathComponent))
                }
            }
            for e in chosen {
                let name = NameRules.unique(names[e.id] ?? e.name, taken: localTaken)
                localTaken.insert(name.lowercased())
                let local = directory.appendingPathComponent(name)
                tops.append(local)
                try walk(NTFSPath.join(folder, e.name), e, local)
            }
            for url in folders { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            let labelled = files.enumerated().map { i, f in
                PlannedOp(op: f.op, args: f.args, bytes: f.bytes, label: L("%@ of %@ - %@", String(i + 1), String(files.count), f.label))
            }
            do { _ = try executePlanned(labelled, target: t, ctx: ctx) }
            catch let failure as BatchFailure { if failure.cancelled { throw CancelledFailure() }; throw AppFailure(message: failure.message) }
            return tops
        }) { result in
            switch result {
            case .success(let urls):
                if let completion = completion { completion(urls); return }
                self.showToast("checkmark.circle", LP(urls.count, "Saved %ld item to the Mac", "Saved %ld items to the Mac"))
                if reveal { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            case .failure(let error): self.show(error)
            }
        }
    }

    // MARK: Open / Quick Look (temporary copies)

    func openWithDefaultApp(_ files: [Entry]) {
        let list = files.filter(\.isRegularFile)
        guard !list.isEmpty, let dir = try? TempFiles.newDirectory() else { return }
        export(list, to: dir, reveal: false) { urls in
            urls.forEach { NSWorkspace.shared.open($0) }
            self.showToast("doc.on.doc", L("Opened a copy. Changes made in other apps are not saved to the NTFS volume."))
        }
    }

    /// A file is copied once: the copy is reused until the file changes or the volume is closed.
    func quickLook(_ files: [Entry]) {
        guard let t = target else { return }
        let list = files.filter(\.isRegularFile)
        let key = { (entry: Entry) in "\(t.id)|\(entry.id)" }
        let copy = { (entry: Entry) -> URL? in
            guard let saved = self.previewCopies[key(entry)], saved.size == entry.size, saved.modified == entry.modifiedNTFS,
                  FileManager.default.fileExists(atPath: saved.url.path) else { return nil }
            return saved.url
        }
        let missing = list.filter { copy($0) == nil }
        guard !missing.isEmpty else { PreviewController.shared.show(list.compactMap(copy)); return }
        guard let dir = try? TempFiles.newDirectory() else { return }
        export(missing, to: dir, reveal: false) { urls in
            for (entry, url) in zip(missing, urls) {
                if let stale = self.previewCopies[key(entry)] {
                    try? FileManager.default.removeItem(at: stale.url)
                    _ = rmdir(stale.url.deletingLastPathComponent().path)   // fails while other copies share it
                }
                self.previewCopies[key(entry)] = PreviewCopy(size: entry.size, modified: entry.modifiedNTFS, url: url)
            }
            PreviewController.shared.show(list.compactMap(copy))
        }
    }

    private func discardPreviewCopies() {
        guard !previewCopies.isEmpty else { return }
        PreviewController.shared.close()
        Set(previewCopies.values.map { $0.url.deletingLastPathComponent() }).forEach { try? FileManager.default.removeItem(at: $0) }
        previewCopies = [:]
    }

    func toggleQuickLook() {
        if PreviewController.shared.isVisible { PreviewController.shared.close(); return }
        quickLook(selectedEntries)
    }

    // MARK: Folder and item changes

    func newFolder(named name: String) {
        guard let t = target, canBrowse else { return }
        let remote = NTFSPath.join(path, name)
        run(L("Creating folder…"), work: { _ in try Worker.invoke("mkdir", target: t, arguments: [remote]) }) { result in
            if case .failure(let error) = result { self.show(error) }
            self.reload(select: name)
        }
    }

    func suggestedFolderName() -> String {
        NameRules.unique(L("New Folder"), taken: Set(entries.map { $0.name.lowercased() }))
    }

    func rename(_ entry: Entry, to name: String) {
        guard let t = target, canBrowse, name != entry.name else { return }
        let from = NTFSPath.join(path, entry.name), to = NTFSPath.join(path, name)
        run(L("Renaming…"), work: { _ in try Worker.invoke("rename", target: t, arguments: [from, to]) }) { result in
            if case .failure(let error) = result { self.show(error) }
            self.reload(select: name)
        }
    }

    func delete(_ chosen: [Entry]) {
        guard let t = target, canBrowse, !chosen.isEmpty else { return }
        let folder = path
        run(LP(chosen.count, "Deleting %ld item…", "Deleting %ld items…"), cancellable: true, work: { ctx -> Int in
            // Depth-first plan: files and links first, then folders bottom-up.
            var steps: [(String, String)] = []
            func walk(_ remote: String, _ entry: Entry) throws {
                try ctx.check()
                if entry.isFolder {
                    for child in try Worker.list(t, remote) { try walk(NTFSPath.join(remote, child.name), child) }
                    steps.append(("rmdir", remote))
                } else if entry.isLink {
                    throw AppFailure(message: L("“%@” is a link or reparse point; OpenNTFS does not delete those.", entry.name))
                } else { steps.append(("remove", remote)) }
            }
            for e in chosen { try walk(NTFSPath.join(folder, e.name), e) }
            let ops = steps.enumerated().map { i, step in
                PlannedOp(op: step.0, args: [step.1], bytes: 0, label: L("%@ of %@ - %@", String(i + 1), String(steps.count), (step.1 as NSString).lastPathComponent))
            }
            do { return try executePlanned(ops, target: t, ctx: ctx) }
            catch let failure as BatchFailure {
                if failure.cancelled { throw CancelledFailure() }
                throw AppFailure(message: LP(failure.completed, "Deleted %ld item", "Deleted %ld items") + ".\n" + failure.message)
            }
        }) { result in
            switch result {
            case .success(let n): self.showToast("trash", LP(n, "Deleted %ld item", "Deleted %ld items"))
            case .failure(let error): self.show(error)
            }
            self.selection = []
            self.reload()
        }
    }

    /// Re-derives Windows permissions for objects that still carry the engine's default security.
    func repairWindowsAccess(_ chosen: [Entry]?) {
        guard let t = target, canBrowse else { return }
        let folder = path
        run(L("Repairing Windows access…"), cancellable: true, work: { ctx -> (Int, Int) in
            let items: [String]
            if let chosen = chosen { items = chosen.filter { !$0.isLink }.map { NTFSPath.join(folder, $0.name) } }
            else {
                items = try Worker.list(t, "/").filter { !$0.isLink && !$0.name.hasPrefix("$") && $0.name.caseInsensitiveCompare("System Volume Information") != .orderedSame }
                    .map { NTFSPath.join("/", $0.name) }
            }
            var checked = 0, fixed = 0
            for (i, remote) in items.enumerated() {
                try ctx.check()
                ctx.report((remote as NSString).lastPathComponent, Double(i) / Double(max(items.count, 1)), force: true)
                let o = Worker.object(try Worker.invoke("fixsec", target: t, arguments: [remote]))
                checked += (o["checked"] as? Int) ?? 0; fixed += (o["fixed"] as? Int) ?? 0
            }
            return (checked, fixed)
        }) { result in
            switch result {
            case .success(let (checked, fixed)):
                self.alert = AlertItem(title: L("Windows access checked"),
                                       message: LP(checked, "Checked %ld item.", "Checked %ld items.") + " " + LP(fixed, "Repaired %ld item.", "Repaired %ld items.")
                                       + (fixed == 0 ? " " + L("Nothing needed repair.") : ""))
            case .failure(let error): self.show(error)
            }
        }
    }

    func copyNames(_ chosen: [Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chosen.map(\.name).joined(separator: "\n"), forType: .string)
        showToast("doc.on.clipboard", LP(chosen.count, "Copied %ld name", "Copied %ld names"))
    }
}
