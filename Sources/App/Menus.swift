import SwiftUI
import AppKit

/// Right-click menu for table rows (or empty space when `ids` is empty).
struct EntryContextMenu: View {
    @ObservedObject var model: BrowserModel
    let ids: Set<Entry.ID>

    var body: some View {
        let chosen = model.entries.filter { ids.contains($0.id) }
        let files = chosen.filter(\.isRegularFile)
        if chosen.isEmpty {
            Button(L("New Folder")) { model.sheet = .newFolder }.disabled(!model.canBrowse)
            Button(L("Add Files…"), action: model.importPanel).disabled(!model.canBrowse)
            Divider()
            Button(L("Refresh")) { model.reload() }.disabled(!model.canBrowse)
        } else {
            if chosen.count == 1, chosen[0].isFolder {
                Button(L("Open")) { model.enter(chosen[0]) }.disabled(!model.canBrowse)
            } else if !files.isEmpty {
                Button(L("Open")) { model.openWithDefaultApp(files) }.disabled(!model.canBrowse)
                Button(L("Quick Look")) { model.quickLook(files) }.disabled(!model.canBrowse)
            }
            Button(chosen.count == 1 ? L("Save to Mac…") : LP(chosen.count, "Save %ld Item to Mac…", "Save %ld Items to Mac…")) {
                model.selection = ids; model.exportSelectionPanel()
            }
            .disabled(!model.canBrowse || chosen.allSatisfy(\.isLink))
            Divider()
            if chosen.count == 1 {
                Button(L("Rename…")) { model.sheet = .rename(chosen[0]) }.disabled(!model.canBrowse)
                Button(L("Get Info")) { model.sheet = .info(chosen[0]) }
            }
            Button(chosen.count == 1 ? L("Copy Name") : L("Copy Names")) { model.copyNames(chosen) }
            Button(L("Repair Windows Access…")) { model.sheet = .repair(chosen) }.disabled(!model.canBrowse)
            Divider()
            Button(chosen.count == 1 ? L("Delete…") : LP(chosen.count, "Delete %ld Item…", "Delete %ld Items…"), role: .destructive) {
                model.sheet = .delete(chosen)
            }
            .disabled(!model.canBrowse)
        }
    }
}

/// The pop-up menu shown at the pointer when a file is double-clicked.
enum FileActionMenu {
    private final class Item: NSMenuItem {
        private let handler: () -> Void
        init(_ title: String, symbol: String, enabled: Bool = true, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            isEnabled = enabled
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        @objc private func fire() { handler() }
    }

    @MainActor static func show(for files: [Entry], model: BrowserModel) {
        guard let window = NSApp.keyWindow, let view = window.contentView, let first = files.first else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: files.count == 1 ? first.name : LP(files.count, "%ld file", "%ld files"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.image = files.count == 1 ? {
            let icon = KindCache.icon(for: first).copy() as! NSImage; icon.size = NSSize(width: 16, height: 16); return icon
        }() : NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(Item(L("Open"), symbol: "arrow.up.forward.app") { model.openWithDefaultApp(files) })
        menu.addItem(Item(L("Quick Look"), symbol: "eye") { model.quickLook(files) })
        menu.addItem(Item(files.count == 1 ? L("Save to Mac…") : LP(files.count, "Save %ld Item to Mac…", "Save %ld Items to Mac…"), symbol: "square.and.arrow.down") {
            model.selection = Set(files.map(\.id)); model.exportSelectionPanel()
        })
        menu.addItem(.separator())
        if files.count == 1 {
            menu.addItem(Item(L("Rename…"), symbol: "pencil") { model.sheet = .rename(first) })
            menu.addItem(Item(L("Get Info"), symbol: "info.circle") { model.sheet = .info(first) })
        }
        menu.addItem(Item(files.count == 1 ? L("Copy Name") : L("Copy Names"), symbol: "doc.on.clipboard") { model.copyNames(files) })
        menu.addItem(Item(L("Repair Windows Access…"), symbol: "checkmark.shield") { model.sheet = .repair(files) })
        menu.addItem(.separator())
        menu.addItem(Item(files.count == 1 ? L("Delete…") : LP(files.count, "Delete %ld Item…", "Delete %ld Items…"), symbol: "trash") { model.sheet = .delete(files) })
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

// MARK: - Sheets

struct SheetHost: View {
    @ObservedObject var model: BrowserModel
    let kind: SheetKind

    var body: some View {
        switch kind {
        case .newFolder: NameSheet(model: model, title: L("New Folder"), initial: model.suggestedFolderName(), action: L("Create")) { model.newFolder(named: $0) }
        case .rename(let e): NameSheet(model: model, title: L("Rename"), initial: e.name, action: L("Rename"), original: e.name) { model.rename(e, to: $0) }
        case .delete(let list): DeleteSheet(model: model, entries: list)
        case .info(let e): InfoSheet(model: model, entry: e)
        case .format(let t): FormatSheet(model: model, target: t)
        case .repair(let list): RepairSheet(model: model, entries: list)
        case .check(let t, let reason): CheckSheet(model: model, target: t, reason: reason)
        case .checkResult(let t, let report): CheckResultSheet(model: model, target: t, report: report)
        }
    }
}

struct SheetFrame<Content: View, Buttons: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint).frame(width: 34)
                Text(title).font(.title2.weight(.semibold))
            }
            content
            HStack { Spacer(); buttons }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct NameSheet: View {
    @ObservedObject var model: BrowserModel
    let title: String
    let initial: String
    let action: String
    var original: String? = nil
    let commit: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        let n = name
        if n.isEmpty { return nil }
        if !NameRules.isValid(n) { return L("Windows does not allow \\ / : * ? \" < > | or a trailing dot or space.") }
        if n.caseInsensitiveCompare(original ?? "\u{0}") != .orderedSame,
           model.entries.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return L("An item with this name already exists.")
        }
        return nil
    }
    private var canCommit: Bool { !name.isEmpty && problem == nil && name != original }

    var body: some View {
        SheetFrame(symbol: original == nil ? "folder.badge.plus" : "pencil", tint: .accentColor, title: title) {
            TextField(L("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canCommit { dismiss(); commit(name) } }
            Text(problem ?? " ").font(.caption).foregroundStyle(.red)
        } buttons: {
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(action) { dismiss(); commit(name) }.keyboardShortcut(.defaultAction).disabled(!canCommit)
        }
        .onAppear { name = initial }
    }
}

struct DeleteSheet: View {
    @ObservedObject var model: BrowserModel
    let entries: [Entry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let folders = entries.filter(\.isFolder).count
        SheetFrame(symbol: "trash", tint: .red, title: entries.count == 1 ? L("Delete “%@”?", entries[0].name) : LP(entries.count, "Delete %ld item?", "Delete %ld items?")) {
            Text(L("NTFS volumes have no Trash on the Mac - deleted items cannot be restored."))
            if folders > 0 { Label(L("Folders are deleted together with everything inside them."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if entries.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries.prefix(50)) { e in
                            HStack { Image(nsImage: KindCache.icon(for: e)).resizable().frame(width: 16, height: 16); Text(e.name).lineLimit(1) }
                        }
                        if entries.count > 50 { Text(LP(entries.count - 50, "and %ld more", "and %ld more")).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
        } buttons: {
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Delete"), role: .destructive) { dismiss(); model.delete(entries) }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.red)
        }
    }
}

struct InfoSheet: View {
    @ObservedObject var model: BrowserModel
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: KindCache.icon(for: entry)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    Text(entry.kind).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                row(L("Size"), entry.directory ? "-" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file) + " (" + entry.size.formatted(.number.locale(Localizer.language.locale)) + " " + L("bytes") + ")")
                row(L("Where"), (model.target?.name ?? "") + ":" + model.path)
                row(L("Modified"), entry.date.formatted(Date.FormatStyle(date: .complete, time: .standard).locale(Localizer.language.locale)))
                row(L("Attributes"), entry.attributeNames.isEmpty ? "-" : entry.attributeNames.joined(separator: ", "))
                row(L("NTFS file ID"), String(entry.fileID))
            }
            HStack { Spacer(); Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 480)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FormatSheet: View {
    @ObservedObject var model: BrowserModel
    let target: Target
    @State private var label = "OPENNTFS"
    @State private var confirmation = ""
    @Environment(\.dismiss) private var dismiss

    private var labelValid: Bool { NameRules.isValid(label) && label.utf16.count <= 32 }

    var body: some View {
        SheetFrame(symbol: "exclamationmark.triangle.fill", tint: .red, title: L("Format as NTFS")) {
            Text(L("All data on this partition will be erased.")).foregroundStyle(.red).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).fontWeight(.medium)
                Text(target.detail).font(.callout).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            TextField(L("New volume name"), text: $label).textFieldStyle(.roundedBorder)
            if !labelValid { Text(L("Use 1-32 characters without \\ / : * ? \" < > |.")).font(.caption).foregroundStyle(.red) }
            Text(L("To confirm, type the current name exactly: %@", target.name)).font(.callout)
            TextField(L("Confirmation"), text: $confirmation).textFieldStyle(.roundedBorder)
            if !target.isImage {
                Text(L("Formatting has been verified on disk images only, not on physical drives.")).font(.caption).foregroundStyle(.secondary)
            }
        } buttons: {
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Erase and Format"), role: .destructive) { dismiss(); model.format(target, label: label) }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(confirmation != target.name || !labelValid)
        }
    }
}

struct RepairSheet: View {
    @ObservedObject var model: BrowserModel
    let entries: [Entry]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(symbol: "checkmark.shield", tint: .accentColor, title: L("Repair Windows Access")) {
            Text(L("Files written by earlier OpenNTFS builds could carry non-standard NTFS permissions, which can make Windows fail to open them (for example, error 0xc0000142)."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("This replaces only those default permissions with the ones Windows itself would assign, inherited from the parent folder. File contents and permissions set on Windows are not changed."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(entries.map { LP($0.count, "Applies to %ld selected item (folders include their contents).", "Applies to %ld selected items (folders include their contents).") }
                  ?? L("Applies to every file and folder on the volume."), systemImage: "info.circle")
                .font(.callout)
        } buttons: {
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Repair")) { dismiss(); model.repairWindowsAccess(entries) }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Volume check

struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
    }
}

struct CheckSheet: View {
    @ObservedObject var model: BrowserModel
    let target: Target
    let reason: CheckReason
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(symbol: "stethoscope", tint: reason == .manual ? .accentColor : .orange, title: L("Check “%@”", target.name)) {
            switch reason {
            case .dirty:
                Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        text: L("This volume is marked as needing a check, so OpenNTFS does not write to it. You can still open and read it."))
                Text(L("Windows and other NTFS drivers set this mark when a drive is unplugged without ejecting, when the computer loses power or shuts down abruptly, or when a problem is detected."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .markedDuringWrite:
                Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        text: L("While writing, the NTFS engine found an inconsistency on this volume and marked it as needing a check. OpenNTFS will not write to it until it has been checked."))
            case .manual:
                EmptyView()
            }
            if reason == .manual {
                Text(L("The check reads the NTFS structures of the whole volume and does not change anything on the drive. It uses the checker built into the NTFS engine. Large drives can take several minutes."))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Check and Clear Mark reads the whole volume once and removes the mark only if no errors are found. It repairs nothing; if there are errors, the volume stays as it is. Large drives can take several minutes."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            if reason == .manual {
                Button(L("Check")) { dismiss(); model.checkVolume(.verify, target: target) }.keyboardShortcut(.defaultAction)
            } else {
                Button(L("Check Only")) { dismiss(); model.checkVolume(.verify, target: target) }
                Button(L("Check and Clear Mark")) { dismiss(); model.checkVolume(.safe, target: target) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct CheckResultSheet: View {
    @ObservedObject var model: BrowserModel
    let target: Target
    let report: CheckReport
    @State private var confirmRepair = false
    @State private var showReport = false
    @Environment(\.dismiss) private var dismiss

    private enum Look { case good, attention, bad }

    private var offerClear: Bool { report.mode == .verify && report.noErrors && !report.writable }
    private var offerRepair: Bool { report.outcome == .errors }

    private var look: Look {
        if report.outcome == .errors || report.outcome == .unsupported || report.outcome == .unknown { return .bad }
        return report.writable ? .good : .attention
    }

    private var title: String {
        switch report.outcome {
        case .errors: return L("Errors were found")
        case .repaired: return L("Volume repaired")
        case .unsupported: return L("The volume cannot be checked")
        case .unknown: return L("Check finished")
        case .clean, .minor, .journal:
            if report.mode != .verify && report.writable { return L("Ready for writing") }
            return report.outcome == .journal ? L("Unfinished changes in the journal") : L("No errors found")
        }
    }

    private var message: String {
        let name = target.name
        switch report.outcome {
        case .errors:
            if report.mode == .safe { return L("The check found errors on “%@”, so the mark was kept and nothing was changed.", name) }
            if report.mode == .repair { return L("Some errors on “%@” could not be repaired. Connect the drive to a Windows PC and run chkdsk X: /f (X is the drive letter).", name) }
            return L("The checker found damaged NTFS structures on “%@” (see the report). The most reliable fix is chkdsk on Windows: connect the drive and run chkdsk X: /f (X is the drive letter). You can also repair the volume here.", name)
        case .repaired:
            return report.writable ? L("The NTFS engine repaired the errors it found. You can write to “%@” again.", name)
                                   : L("The NTFS engine repaired the errors it found, but the volume is still marked. Check it on Windows with chkdsk.")
        case .unsupported:
            return L("This volume uses NTFS features the checker does not support. Check it on Windows with chkdsk.")
        case .unknown:
            return L("The checker finished with an unexpected result. See the report.")
        case .clean, .minor, .journal:
            switch report.mode {
            case .verify:
                if report.writable {
                    return report.outcome == .minor ? L("The NTFS structures of “%@” are consistent. The checker noted minor issues that need no repair.", name)
                                                    : L("The NTFS structures of “%@” are consistent.", name)
                }
                if report.outcome == .journal {
                    return L("The NTFS journal contains changes that Windows did not finish. OpenNTFS can complete them, as Windows would on its next start, and clear the mark if the volume is then free of errors.")
                }
                return L("The volume is only marked as needing a check. To allow writing, OpenNTFS checks it once more and clears the mark only if there are still no errors. Nothing else is changed.")
            case .safe, .repair:
                return report.writable ? L("No errors were found and the mark was cleared. You can write to “%@” again.", name)
                                       : L("No errors were found, but the mark could not be cleared. Check the drive on Windows with chkdsk.")
            }
        }
    }

    var body: some View {
        SheetFrame(symbol: look == .good ? "checkmark.seal.fill" : look == .attention ? "exclamationmark.triangle.fill" : "xmark.octagon.fill",
                   tint: look == .good ? .green : look == .attention ? .orange : .red, title: title) {
            Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if confirmRepair {
                Callout(symbol: "exclamationmark.triangle.fill", tint: .red,
                        text: L("Repair rewrites NTFS metadata. Damaged entries can be removed and lost files are moved into a recovery folder. Back up important files first, for example with Save to Mac."))
            }
            if !report.log.isEmpty {
                DisclosureGroup(L("Checker report"), isExpanded: $showReport) {
                    ScrollView {
                        Text(report.log.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                    HStack {
                        Spacer()
                        Button(L("Copy Report")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.log, forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        } buttons: {
            if confirmRepair {
                Button(L("Cancel")) { confirmRepair = false }.keyboardShortcut(.cancelAction)
                Button(L("Repair Volume"), role: .destructive) { dismiss(); model.checkVolume(.repair, target: target) }
                    .buttonStyle(.borderedProminent).tint(.red)
            } else if offerClear {
                Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Clear Mark")) { dismiss(); model.checkVolume(.safe, target: target) }.keyboardShortcut(.defaultAction)
            } else if offerRepair && report.mode != .repair {
                Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Repair…"), role: .destructive) { withAnimation { confirmRepair = true } }
            } else {
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
