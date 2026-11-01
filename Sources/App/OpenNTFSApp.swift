import SwiftUI
import AppKit
import Quartz

@MainActor enum AppState {
    static weak var model: BrowserModel?
    static var didStart = false
}

// MARK: - Quick Look

final class PreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = PreviewController()
    private(set) var items: [URL] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = urls
        if panel.dataSource == nil { panel.dataSource = self; panel.delegate = self }
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { if isVisible { QLPreviewPanel.shared().orderOut(nil) } }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] as NSURL }
}

// MARK: - Application delegate

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Localizer.prepareAtLaunch()
        TempFiles.cleanAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Space toggles Quick Look and Return opens the selection while the file list has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty, NSApp.keyWindow?.firstResponder is NSTableView,
                  let model = MainActor.assumeIsolated({ AppState.model }) else { return event }
            switch event.keyCode {
            case 49: MainActor.assumeIsolated { model.toggleQuickLook() }; return nil
            case 36, 76: MainActor.assumeIsolated { model.openSelection() }; return nil
            default: return event
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkerConnection.shared.close()
        TempFiles.cleanAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { AppState.model?.busy != true }
    }
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ AppState.model?.busy == true }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Wait for the operation to finish")
        alert.informativeText = L("OpenNTFS is writing to the NTFS volume. Quitting now could interrupt the write.")
        alert.addButton(withTitle: L("Keep Working"))
        alert.runModal()
        return .terminateCancel
    }

    // Quick Look panel controller (the app delegate is part of the responder chain).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = PreviewController.shared; panel.delegate = PreviewController.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

// MARK: - App

/// Entry point: the interface language must be in place before AppKit loads any localized
/// resources, otherwise system menus would follow the macOS language instead of the app setting.
@main enum Launcher {
    static func main() {
        Localizer.prepareAtLaunch()
        OpenNTFSApp.main()
    }
}

struct OpenNTFSApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = BrowserModel()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("OpenNTFS", id: "main") {
            RootView(model: model, settings: settings)
                .onAppear {
                    AppState.model = model
                    guard !AppState.didStart else { return }
                    AppState.didStart = true
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--image"), args.indices.contains(i + 1) {
                        model.refreshDevices()
                        model.attachImage(URL(fileURLWithPath: args[i + 1]))
                    } else {
                        model.refreshDevices()
                    }
                }
        }
        .defaultSize(width: 1180, height: 740)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model, settings: settings) }

        Settings {
            SettingsView(model: model, settings: settings)
        }
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About OpenNTFS")) { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button(L("New Folder")) { model.sheet = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.canBrowse)
            Button(L("Open Disk Image…"), action: model.openImagePanel)
                .keyboardShortcut("o").disabled(model.busy)
            Divider()
            Button(L("Add Files…"), action: model.importPanel)
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!model.canBrowse)
            Button(L("Save to Mac…"), action: model.exportSelectionPanel)
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canBrowse || model.selection.isEmpty)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("Open")) { model.openSelection() }
                .keyboardShortcut(.downArrow).disabled(!model.canBrowse || model.selection.isEmpty)
            Button(L("Quick Look")) { model.toggleQuickLook() }
                .keyboardShortcut("y").disabled(!model.canBrowse || model.selectedEntries.filter(\.isRegularFile).isEmpty)
            Button(L("Get Info")) { if let e = model.selectedEntries.first { model.sheet = .info(e) } }
                .keyboardShortcut("i").disabled(model.selectedEntries.count != 1)
            Button(L("Rename…")) { if let e = model.selectedEntries.first { model.sheet = .rename(e) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.canBrowse || model.selectedEntries.count != 1)
            Divider()
            Button(L("Delete…")) { model.sheet = .delete(model.selectedEntries) }
                .keyboardShortcut(.delete, modifiers: .command).disabled(!model.canBrowse || model.selection.isEmpty)
        }
        CommandMenu(L("Go")) {
            Button(L("Back"), action: model.back).keyboardShortcut("[").disabled(model.backStack.isEmpty || !model.canBrowse)
            Button(L("Forward"), action: model.forward).keyboardShortcut("]").disabled(model.forwardStack.isEmpty || !model.canBrowse)
            Button(L("Enclosing Folder"), action: model.up).keyboardShortcut(.upArrow).disabled(model.path == "/" || !model.canBrowse)
            Button(L("Volume Root")) { model.go(to: "/") }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.canBrowse)
            Divider()
            Button(L("Refresh")) { model.reload() }.keyboardShortcut("r").disabled(!model.canBrowse)
        }
        CommandMenu(L("Volume")) {
            Button(L("Open Volume"), action: model.openVolume).disabled(model.target?.isNTFS != true || model.busy)
            Button(L("Show in Finder"), action: model.mountInFinder).disabled(model.target == nil || model.target?.isImage == true || model.busy)
            Button(L("Eject"), action: model.eject).keyboardShortcut("e").disabled(model.target == nil || model.target?.isImage == true || model.busy)
            Button(L("Refresh Drives")) { model.refreshDevices(userInitiated: true) }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(model.busy)
            Divider()
            Button(L("Repair Windows Access for Entire Volume…")) { model.sheet = .repair(nil) }.disabled(!model.canBrowse)
            Divider()
            Button(L("Format as NTFS…")) { if let t = model.target { model.sheet = .format(t) } }.disabled(model.target == nil || model.busy)
        }
        CommandGroup(replacing: .help) {
            Button(L("OpenNTFS Help")) { AboutPanel.showHelp() }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            Form {
                Picker(L("Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.language != Localizer.launchLanguage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Menus provided by macOS switch after OpenNTFS restarts.")).font(.callout).foregroundStyle(.secondary)
                        Button(L("Restart Now")) { Relauncher.relaunch() }.disabled(model.busy)
                    }
                }
            }
            .padding(20)
            .tabItem { Label(L("General"), systemImage: "gearshape") }

            Form {
                Toggle(L("Show hidden and system items"), isOn: $settings.showHiddenItems)
                Picker(L("Double-clicking a file"), selection: $settings.doubleClickAction) {
                    ForEach(DoubleClickAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Skip macOS metadata files when copying (.DS_Store, ._*)"), isOn: $settings.skipMacMetadata)
                Text(L("Names that Windows does not allow are adjusted automatically when copying (for example, “:” becomes “_”)."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .tabItem { Label(L("Files"), systemImage: "folder") }
        }
        .frame(width: 520)
        .id(settings.language)
    }
}

enum Relauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - About / Help

enum AboutPanel {
    static func show() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let credits = NSAttributedString(
            string: L("NTFS file manager for Macs with Apple silicon. No system driver or background service is installed.\n\nExperimental build - keep a backup of valuable data."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenNTFS",
            .applicationVersion: version,
            .credits: credits,
        ])
    }

    static func showHelp() {
        let alert = NSAlert()
        alert.messageText = L("OpenNTFS Help")
        alert.informativeText = L("• Select a drive in the sidebar and click “Open Volume”.\n• Double-click a folder to open it; double-click a file for actions.\n• Drag files from Finder into the window to copy them.\n• Space - Quick Look, Return - open, ⌘⌫ - delete, ⌘[ / ⌘] - back / forward.\n• “Show in Finder” gives the drive back to macOS (read-only in Finder); “Eject” (⌘E) prepares it for unplugging.\n• If Windows cannot open files written by an earlier build, use Volume › Repair Windows Access.")
        alert.runModal()
    }
}
