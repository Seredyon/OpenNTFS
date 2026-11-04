import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        // The language id is applied inside the columns: recreating the split view itself would
        // drop its sidebar toggle and selection state.
        NavigationSplitView {
            SidebarView(model: model)
                .id(settings.language)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            DetailView(model: model)
                .id(settings.language)
        }
        .frame(minWidth: 920, minHeight: 580)
        .sheet(item: $model.sheet) { kind in SheetHost(model: model, kind: kind) }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text(L("OK"))))
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.refreshDevices() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.refreshDevices() }
        .onChange(of: model.busy) { busy in NSApp.windows.forEach { $0.standardWindowButton(.closeButton)?.isEnabled = !busy } }
        .onChange(of: settings.showHiddenItems) { _ in model.refilter() }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: BrowserModel

    private var selection: Binding<String?> {
        Binding(get: { model.targetID }, set: { model.choose($0) })
    }

    var body: some View {
        List(selection: selection) {
            Section(L("External Drives")) {
                let volumes = model.targets.filter { !$0.isImage }
                if volumes.isEmpty {
                    Label(model.scanning ? L("Searching…") : L("No NTFS drives connected"), systemImage: model.scanning ? "hourglass" : "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary).font(.callout)
                        .nonSelectable()
                }
                ForEach(volumes) { t in TargetRow(model: model, target: t).tag(t.id) }
            }
            let images = model.targets.filter(\.isImage)
            if !images.isEmpty {
                Section(L("Disk Images")) {
                    ForEach(images) { t in TargetRow(model: model, target: t).tag(t.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.busy)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Button { model.refreshDevices(userInitiated: true) } label: {
                        if model.scanning { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .help(L("Refresh the list of external drives"))
                    Button(action: model.openImagePanel) { Label(L("Open Image…"), systemImage: "plus") }
                        .help(L("Open an NTFS partition image file"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .disabled(model.busy)
            }
            .background(.bar)
        }
    }
}

private extension View {
    @ViewBuilder func nonSelectable() -> some View {
        if #available(macOS 14.0, *) { self.selectionDisabled(true) } else { self }
    }
}

struct TargetRow: View {
    @ObservedObject var model: BrowserModel
    let target: Target

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: target.symbol)
                .font(.system(size: 18))
                .foregroundStyle(target.isNTFS ? Color.accentColor : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).lineLimit(1)
                Text(target.isImage ? target.sizeText : target.fileSystemText + " · " + target.sizeText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.targetID == target.id && model.opened {
                Circle().fill(.green).frame(width: 7, height: 7).help(L("Open in OpenNTFS"))
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(L("Open Volume")) { model.choose(target.id); model.openVolume() }.disabled(!target.isNTFS)
            Button(L("Check Volume…")) { model.choose(target.id); model.sheet = .check(target, .manual) }.disabled(!target.isNTFS || model.busy)
            if !target.isImage {
                Button(L("Show in Finder")) { model.choose(target.id); model.mountInFinder() }
                Button(L("Eject")) { model.choose(target.id); model.eject() }
            } else {
                Button(L("Remove from List")) { model.removeImage(target) }
            }
            Divider()
            Button(L("Format as NTFS…"), role: .destructive) { model.choose(target.id); model.sheet = .format(target) }
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let t = model.target {
                    if model.opened { BrowserView(model: model) }
                    else { VolumeOverview(model: model, target: t) }
                } else {
                    WelcomeView(model: model)
                }
            }
            .transition(.opacity)
            VStack(spacing: 10) {
                if let toast = model.toast { ToastView(toast: toast).transition(.move(edge: .bottom).combined(with: .opacity)) }
                if let activity = model.activity {
                    ActivityPanel(activity: activity, cancel: model.cancelActivity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, model.opened ? 40 : 18)
            .padding(.horizontal, 24)
        }
        .navigationTitle(model.target?.name ?? "OpenNTFS")
        .navigationSubtitle(model.opened ? model.path : (model.target?.detail ?? L("NTFS for your Mac")))
        .toolbar { BrowserToolbar(model: model) }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        CenteredScroll {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 128, height: 128)
            VStack(spacing: 6) {
                Text(L("Welcome to OpenNTFS")).font(.largeTitle.weight(.semibold))
                Text(L("Read and write NTFS drives on your Mac - no drivers or system extensions required."))
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                StepRow(number: 1, text: L("Connect an NTFS drive: USB flash drive, external disk or SD card."))
                StepRow(number: 2, text: L("Select it in the sidebar."))
                StepRow(number: 3, text: L("Click “Open Volume” and confirm access when macOS asks."))
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            HStack(spacing: 12) {
                Button { model.refreshDevices(userInitiated: true) } label: { Label(L("Find Drives"), systemImage: "arrow.clockwise") }
                    .controlSize(.large)
                Button(action: model.openImagePanel) { Label(L("Open Disk Image…"), systemImage: "opticaldiscdrive") }
                    .controlSize(.large)
            }
            .disabled(model.busy)
        }
        .padding(40)
        }
    }
}

/// Scrolls when the window is small but never lets its content dictate the window size
/// (a tall minimum height would push the sidebar out of view inside NavigationSplitView).
struct CenteredScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

struct StepRow: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}

struct VolumeOverview: View {
    @ObservedObject var model: BrowserModel
    let target: Target

    var body: some View {
        CenteredScroll {
        VStack(spacing: 20) {
            Image(systemName: target.isImage ? "opticaldiscdrive.fill" : target.symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(target.isNTFS ? Color.accentColor : Color.orange)
                .padding(.bottom, 4)
            VStack(spacing: 6) {
                Text(target.name).font(.title.weight(.semibold))
                Text(target.detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if target.isNTFS {
                Button { model.openVolume() } label: {
                    Label(L("Open Volume"), systemImage: "folder").frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
            } else {
                Label(L("This partition is not recognized as NTFS. You can format it from the context menu."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 10) {
                if target.isImage {
                    InfoLine(symbol: "doc", text: L("Changes are written directly into the image file."))
                } else {
                    InfoLine(symbol: "lock.shield", text: L("macOS asks once for access to this drive; it lasts until you quit or return the drive to Finder."))
                    InfoLine(symbol: "eject", text: L("While open here, the volume is temporarily unmounted from Finder. Use “Show in Finder” to give it back."))
                }
                InfoLine(symbol: "exclamationmark.shield", text: L("Experimental build: keep a backup of valuable files."))
            }
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45)))
            HStack(spacing: 18) {
                if target.isNTFS {
                    Button(L("Check Volume")) { model.sheet = .check(target, .manual) }.buttonStyle(.link)
                        .help(L("Look for NTFS errors without changing anything"))
                }
                if !target.isImage {
                    Button(L("Show in Finder")) { model.mountInFinder() }.buttonStyle(.link)
                        .help(L("Give the drive back to macOS: Finder shows it read-only"))
                    Button(L("Eject")) { model.eject() }.buttonStyle(.link)
                        .help(L("Eject the whole drive so it can be unplugged"))
                }
            }
            .disabled(model.busy)
        }
        .padding(40)
        }
    }
}

struct InfoLine: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            Text(text).lineLimit(4)
        }
    }
}

// MARK: - Toolbar

struct BrowserToolbar: ToolbarContent {
    @ObservedObject var model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.back) { Image(systemName: "chevron.left") }
                .help(L("Back")).disabled(model.backStack.isEmpty || !model.canBrowse)
            Button(action: model.forward) { Image(systemName: "chevron.right") }
                .help(L("Forward")).disabled(model.forwardStack.isEmpty || !model.canBrowse)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.opened {
                Button(action: model.importPanel) { Label(L("Add Files"), systemImage: "plus.square.on.square") }
                    .help(L("Copy files and folders from the Mac to this folder")).disabled(!model.canBrowse)
                Button { model.sheet = .newFolder } label: { Label(L("New Folder"), systemImage: "folder.badge.plus") }
                    .help(L("New Folder")).disabled(!model.canBrowse)
                Button(action: model.exportSelectionPanel) { Label(L("Save to Mac"), systemImage: "square.and.arrow.down") }
                    .help(L("Save the selected items to the Mac")).disabled(!model.canBrowse || model.selectedEntries.filter { !$0.isLink }.isEmpty)
                Button(role: .destructive) { model.sheet = .delete(model.selectedEntries) } label: { Label(L("Delete"), systemImage: "trash") }
                    .help(L("Delete the selected items")).disabled(!model.canBrowse || model.selection.isEmpty)
                Menu {
                    MoreMenuItems(model: model)
                } label: { Label(L("More"), systemImage: "ellipsis.circle") }
                    .help(L("More actions"))
            } else if let t = model.target {
                Menu {
                    if t.isNTFS {
                        Button(L("Open Volume"), action: model.openVolume)
                        Button(L("Check Volume…")) { model.sheet = .check(t, .manual) }
                    }
                    if !t.isImage { Button(L("Show in Finder"), action: model.mountInFinder); Button(L("Eject"), action: model.eject) }
                    Divider()
                    Button(L("Format as NTFS…"), role: .destructive) { model.sheet = .format(t) }
                } label: { Label(L("More"), systemImage: "ellipsis.circle") }
                    .disabled(model.busy)
            }
        }
    }
}

struct MoreMenuItems: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        let selected = model.selectedEntries
        Button(L("Rename…")) { if let e = selected.first { model.sheet = .rename(e) } }.disabled(selected.count != 1 || !model.canBrowse)
        Button(L("Get Info")) { if let e = selected.first { model.sheet = .info(e) } }.disabled(selected.count != 1)
        Button(L("Quick Look")) { model.quickLook(selected) }.disabled(selected.filter(\.isRegularFile).isEmpty || !model.canBrowse)
        Divider()
        Button(L("Repair Windows Access for Selection…")) { model.sheet = .repair(selected) }.disabled(selected.isEmpty || !model.canBrowse)
        Button(L("Repair Windows Access for Entire Volume…")) { model.sheet = .repair(nil) }.disabled(!model.canBrowse)
        Button(L("Check Volume…")) { if let t = model.target { model.sheet = .check(t, .manual) } }.disabled(model.busy)
        Divider()
        Button(L("Refresh")) { model.reload() }.disabled(!model.canBrowse)
        if let t = model.target, !t.isImage {
            Button(L("Show in Finder"), action: model.mountInFinder).disabled(model.busy)
            Button(L("Eject"), action: model.eject).disabled(model.busy)
        }
        if let t = model.target {
            Divider()
            Button(L("Format as NTFS…"), role: .destructive) { model.sheet = .format(t) }.disabled(model.busy)
        }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            Divider()
            ZStack {
                FileTable(model: model)
                if model.visible.isEmpty && !model.busy && !model.dropTargeted {
                    EmptyFolderView(model: model).allowsHitTesting(false)
                }
                if model.dropTargeted { DropOverlay(folder: model.folderName) }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
                guard model.canBrowse else { return false }
                loadURLs(providers) { urls in model.importURLs(urls) }
                return true
            }
            StatusBar(model: model)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text(L("Search in Folder")))
    }

    private func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup(), lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url = url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { completion(urls) } }
    }
}

struct PathBar: View {
    @ObservedObject var model: BrowserModel

    // Crumbs must stay outside a ScrollView: on macOS it takes their clicks. Long names shorten,
    // and deep paths fold the middle into one crumb that opens the last hidden folder.
    private let lastShown = 4

    var body: some View {
        let parts = NTFSPath.components(model.path)
        let hidden = max(0, parts.count - lastShown)
        HStack(spacing: 2) {
            crumb(title: model.target?.name ?? "/", symbol: model.target?.isImage == true ? "opticaldiscdrive" : "externaldrive", path: "/", current: parts.isEmpty)
            if hidden > 0 {
                separator
                crumb(title: "…", symbol: "folder", path: "/" + parts[0..<hidden].joined(separator: "/"), current: false)
            }
            ForEach(Array(parts.enumerated().dropFirst(hidden)), id: \.offset) { index, part in
                separator
                crumb(title: part, symbol: "folder", path: "/" + parts[0...index].joined(separator: "/"), current: index == parts.count - 1)
                    .layoutPriority(index == parts.count - 1 ? 1 : 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).font(.system(size: 13))
    }

    /// One long name must not push the other folders out of the bar; the tooltip keeps the full path.
    private func short(_ name: String) -> String {
        name.count <= 36 ? name : name.prefix(24) + "…" + name.suffix(11)
    }

    private func crumb(title: String, symbol: String, path: String, current: Bool) -> some View {
        Button { if !current { model.go(to: path) } } label: {
            Label(short(title), systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .lineLimit(1).truncationMode(.middle)
                .font(.callout.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? .primary : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.accentColor.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .help(path)
    }
}

struct FileTable: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(L("Name"), value: \Entry.name, comparator: .localizedStandard) { entry in
                NameCell(entry: entry)
            }
            .width(min: 200, ideal: 320)
            TableColumn(L("Date Modified"), value: \Entry.date) { entry in
                Text(entry.dateLabel).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn(L("Size"), value: \Entry.size) { entry in
                Text(entry.sizeLabel).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80)
            TableColumn(L("Kind"), value: \Entry.kind) { entry in
                Text(entry.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            EntryContextMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.primaryAction(ids)
        }
    }
}

struct NameCell: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: KindCache.icon(for: entry)).resizable().interpolation(.high).frame(width: 18, height: 18)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            if entry.isLink { Image(systemName: "arrow.turn.up.right").font(.caption).foregroundStyle(.secondary) }
        }
        .opacity(entry.isHidden || entry.isSystem ? 0.55 : 1)
    }
}

struct EmptyFolderView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(model.search.isEmpty ? L("This folder is empty") : L("No items match “%@”", model.search)).font(.title3).foregroundStyle(.secondary)
            if model.search.isEmpty {
                Text(L("Drag files here or click “Add Files”.")).foregroundStyle(.tertiary)
                if model.hiddenCount > 0 { Text(LP(model.hiddenCount, "%ld hidden item", "%ld hidden items")).font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct DropOverlay: View {
    let folder: String
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40))
                    Text(L("Drop to copy into “%@”", folder)).font(.title3.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
            )
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

struct StatusBar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let t = model.target {
                Label(t.isImage ? L("Disk image") + " · " + t.sizeText : t.id + " · " + t.fileSystemText + " · " + t.sizeText,
                      systemImage: t.isImage ? "opticaldiscdrive" : "externaldrive")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).frame(height: 28)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private var summary: String {
        let selected = model.selectedEntries
        if selected.isEmpty {
            var text = LP(model.visible.count, "%ld item", "%ld items")
            if model.hiddenCount > 0 { text += " · " + LP(model.hiddenCount, "%ld hidden", "%ld hidden") }
            return text
        }
        let bytes = selected.filter { !$0.directory }.reduce(UInt64(0)) { $0 + $1.size }
        var text = L("%@ of %@ selected", String(selected.count), String(model.visible.count))
        if bytes > 0 { text += " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
        return text
    }
}

struct ActivityPanel: View {
    let activity: Activity
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let fraction = activity.fraction {
                ProgressView(value: min(max(fraction, 0), 1)).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !activity.detail.isEmpty { Text(activity.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let fraction = activity.fraction {
                    ProgressView(value: min(max(fraction, 0), 1)).progressViewStyle(.linear).frame(minWidth: 240)
                        .animation(.linear(duration: 0.15), value: fraction)
                }
            }
            Spacer(minLength: 8)
            if let fraction = activity.fraction { Text(fraction, format: .percent.precision(.fractionLength(0))).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            if activity.cancellable {
                Button(L("Cancel"), action: cancel).disabled(activity.cancelling).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(Color.accentColor)
            Text(toast.text).font(.callout).lineLimit(3)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
