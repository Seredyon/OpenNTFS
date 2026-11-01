import Foundation
import AppKit
import Darwin
import IOKit
import UniformTypeIdentifiers

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A batch stopped early; `completed` operations (in order) were fully applied.
struct BatchFailure: LocalizedError {
    let completed: Int
    let cancelled: Bool
    let message: String
    var errorDescription: String? { cancelled ? L("The operation was cancelled.") : message }
}

struct CancelledFailure: LocalizedError {
    var errorDescription: String? { L("The operation was cancelled.") }
}

struct CommandResult { let status: Int32; let output: Data; let error: Data }

enum Runner {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> CommandResult {
        let p = Process(), out = Pipe(), err = Pipe(), feed = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = out; p.standardError = err; p.standardInput = input == nil ? FileHandle.nullDevice : feed
        var environment = ProcessInfo.processInfo.environment
        // Child tools inherit the app's external storage directory for temporary files.
        environment["TMPDIR"] = TempFiles.childTemporary.path
        p.environment = environment
        try p.run()
        let group = DispatchGroup(), lock = NSLock()
        var stdout = Data(), stderr = Data()
        group.enter(); DispatchQueue.global().async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); stdout = data; lock.unlock(); group.leave()
        }
        group.enter(); DispatchQueue.global().async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); stderr = data; lock.unlock(); group.leave()
        }
        if let input = input { try feed.fileHandleForWriting.write(contentsOf: input); try feed.fileHandleForWriting.close() }
        p.waitUntilExit(); group.wait()
        return CommandResult(status: p.terminationStatus, output: stdout, error: stderr)
    }

    static func diskInfo(_ device: String) throws -> [String: Any] {
        let r = try run("/usr/sbin/diskutil", ["info", "-plist", device])
        guard r.status == 0, let d = try PropertyListSerialization.propertyList(from: r.output, format: nil) as? [String: Any] else {
            throw AppFailure(message: L("Could not read disk information."))
        }
        return d
    }

    static func registryID(_ device: String) throws -> UInt64 {
        let service = device.withCString { IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, $0)) }
        guard service != 0 else { throw AppFailure(message: L("The drive has been disconnected.")) }
        defer { IOObjectRelease(service) }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS, identifier != 0 else {
            throw AppFailure(message: L("Could not identify the connected drive."))
        }
        return identifier
    }
}

// MARK: - Targets (USB partitions and image files)

struct Target: Identifiable {
    var id: String
    var name: String
    var size: Int64
    var fileSystem: String
    var metadata: [String: Any]

    var isImage: Bool { metadata["kind"] as? String == "image" }
    var isNTFS: Bool { fileSystem.lowercased().contains("ntfs") }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var fileSystemText: String { isNTFS ? "NTFS" : (fileSystem.isEmpty ? L("Unknown file system") : fileSystem.uppercased()) }
    var symbol: String {
        if isImage { return "opticaldiscdrive" }
        return (metadata["bus"] as? String) == "Secure Digital" ? "sdcard.fill" : "externaldrive.fill"
    }
    var parentDisk: String? { metadata["parent"] as? String }
    var detail: String {
        isImage ? L("NTFS image") + " · " + sizeText : fileSystemText + " · " + sizeText + " · " + id
    }
    var sameDevice: (Target) -> Bool {
        { other in
            other.id == self.id
                && (other.metadata["identity"] as? String) == (self.metadata["identity"] as? String)
                && (other.metadata["registryID"] as? NSNumber) == (self.metadata["registryID"] as? NSNumber)
        }
    }

    static func image(_ url: URL) throws -> Target {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
            throw AppFailure(message: L("Choose a regular NTFS image file."))
        }
        return Target(id: url.path, name: url.lastPathComponent, size: Int64(resource.fileSize ?? 0), fileSystem: "ntfs",
                      metadata: ["kind": "image", "path": url.path])
    }

    /// External drives on any bus (USB, Thunderbolt, SATA/PCIe enclosures) and removable cards in a
    /// built-in SD reader. Internal fixed disks are never listed. Mirrors `supportedParent` in the worker.
    static func supportedParent(_ p: [String: Any]) -> Bool {
        guard p["WholeDisk"] as? Bool == true, p["VirtualOrPhysical"] as? String == "Physical" else { return false }
        if p["Internal"] as? Bool == false { return true }
        return p["BusProtocol"] as? String == "Secure Digital" && p["RemovableMedia"] as? Bool == true
    }

    static func discover() throws -> [Target] {
        let r = try Runner.run("/usr/sbin/diskutil", ["list", "-plist", "physical"])
        guard r.status == 0, let all = try PropertyListSerialization.propertyList(from: r.output, format: nil) as? [String: Any] else {
            throw AppFailure(message: L("Could not get the list of external drives."))
        }
        var targets: [Target] = []
        for disk in all["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            // One unreadable or vanishing disk must not hide the others.
            guard let parentID = disk["DeviceIdentifier"] as? String, let parent = try? Runner.diskInfo(parentID),
                  supportedParent(parent),
                  let tree = parent["DeviceTreePath"] as? String, let parentSize = parent["IOKitSize"] as? NSNumber else { continue }
            for partition in disk["Partitions"] as? [[String: Any]] ?? [] {
                guard let device = partition["DeviceIdentifier"] as? String, let info = try? Runner.diskInfo(device) else { continue }
                guard info["Internal"] as? Bool == parent["Internal"] as? Bool, info["WholeDisk"] as? Bool == false, info["WritableMedia"] as? Bool == true,
                      ["Microsoft Basic Data", "Windows_NTFS"].contains(info["Content"] as? String ?? ""),
                      let size = info["IOKitSize"] as? NSNumber, size.int64Value >= 16 * 1024 * 1024,
                      let offset = info["PartitionMapPartitionOffset"] as? NSNumber else { continue }
                guard let registry = try? Runner.registryID(device) else { continue }
                let identity = info["DiskUUID"] as? String ?? "ioreg:\(registry)"
                let fs = (info["FilesystemType"] as? String) ?? (info["FilesystemName"] as? String) ?? ""
                let name = (info["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("NTFS Partition")
                targets.append(Target(id: device, name: name, size: size.int64Value, fileSystem: fs, metadata: [
                    "kind": "volume", "device": device, "parent": parentID, "identity": identity,
                    "registryID": NSNumber(value: registry), "size": size, "offset": offset, "parentSize": parentSize, "tree": tree,
                    "bus": parent["BusProtocol"] as? String ?? "",
                ]))
            }
        }
        return targets
    }
}

// MARK: - Directory entries

struct Entry: Identifiable, Hashable, Decodable {
    let fileID: UInt64
    let name: String
    let size: UInt64
    let directory: Bool
    let attributes: UInt32
    let modifiedNTFS: UInt64
    let id: String
    let date: Date
    let fileExtension: String

    enum CodingKeys: String, CodingKey { case fileID, name, size, directory, attributes, modifiedNTFS }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try c.decode(UInt64.self, forKey: .fileID)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(UInt64.self, forKey: .size)
        directory = try c.decode(Bool.self, forKey: .directory)
        attributes = try c.decode(UInt32.self, forKey: .attributes)
        modifiedNTFS = try c.decode(UInt64.self, forKey: .modifiedNTFS)
        id = "\(fileID):\(name)"
        date = Date(timeIntervalSince1970: Double(modifiedNTFS) / 10_000_000 - 11_644_473_600)
        fileExtension = directory ? "" : (name as NSString).pathExtension.lowercased()
    }

    var isLink: Bool { attributes & 0x400 != 0 }
    var isHidden: Bool { attributes & 0x2 != 0 }
    var isSystem: Bool { attributes & 0x4 != 0 }
    var isReadOnly: Bool { attributes & 0x1 != 0 }
    var isFolder: Bool { directory && !isLink }
    var isRegularFile: Bool { !directory && !isLink }
    var sizeLabel: String { directory ? "-" : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file) }
    var dateLabel: String { Formatters.date(date) }
    var kind: String { KindCache.kind(for: self) }

    var attributeNames: [String] {
        var names: [String] = []
        let map: [(UInt32, String)] = [(0x1, LK("Read-only")), (0x2, LK("Hidden")), (0x4, LK("System")), (0x20, LK("Archive")),
                                       (0x200, LK("Sparse")), (0x400, LK("Reparse point")), (0x800, LK("Compressed")), (0x4000, LK("Encrypted"))]
        for (bit, name) in map where attributes & bit != 0 { names.append(L(name)) }
        return names
    }

    static func == (a: Entry, b: Entry) -> Bool { a.id == b.id && a.size == b.size && a.modifiedNTFS == b.modifiedNTFS }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum Formatters {
    private static var cache: [AppLanguage: DateFormatter] = [:]
    static func date(_ date: Date) -> String {
        let language = Localizer.language
        let formatter = cache[language] ?? {
            let f = DateFormatter(); f.locale = language.locale; f.dateStyle = .medium; f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            cache[language] = f; return f
        }()
        return formatter.string(from: date)
    }
}

/// Finder icons and kind names, cached by file extension.
enum KindCache {
    private static var kinds: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func kind(for entry: Entry) -> String {
        if entry.isLink { return L("Link") }
        if entry.directory { return L("Folder") }
        let key = Localizer.language.rawValue + ":" + entry.fileExtension
        if let cached = kinds[key] { return cached }
        let value: String
        if entry.fileExtension.isEmpty { value = L("Document") }
        else if let type = UTType(filenameExtension: entry.fileExtension), let description = type.localizedDescription, !type.isDynamic {
            value = description.prefix(1).uppercased() + description.dropFirst()
        } else { value = L("%@ file", entry.fileExtension.uppercased()) }
        kinds[key] = value
        return value
    }

    static func icon(for entry: Entry) -> NSImage {
        let key = entry.isLink ? "#link" : entry.directory ? "#folder" : entry.fileExtension
        if let cached = icons[key] { return cached }
        let image: NSImage
        if entry.isLink { image = NSWorkspace.shared.icon(for: .aliasFile) }
        else if entry.directory { image = NSWorkspace.shared.icon(for: .folder) }
        else { image = NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.fileExtension) ?? .data) }
        image.size = NSSize(width: 32, height: 32)
        icons[key] = image
        return image
    }
}

// MARK: - Worker process

/// One long-lived `NTFSWorker serve` child exchanging NDJSON over anonymous pipes.
/// Long transfers interleave `{"progress": bytes}` lines before the final response line.
final class WorkerConnection {
    static let shared = WorkerConnection()
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private let pidLock = NSLock()
    private var activePID: pid_t = 0

    func request(_ data: Data, executable: URL, progress: ((UInt64, Int?) -> Void)?) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning != true {
            let p = Process(), feed = Pipe(), result = Pipe()
            p.executableURL = executable; p.arguments = ["serve"]
            p.standardInput = feed; p.standardOutput = result; p.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = TempFiles.childTemporary.path
            p.environment = environment
            try p.run()
            process = p; input = feed.fileHandleForWriting; output = result.fileHandleForReading; pending = Data()
        }
        guard let input = input, let output = output, let process = process else {
            throw AppFailure(message: L("Could not start the NTFS module."))
        }
        pidLock.lock(); activePID = process.processIdentifier; pidLock.unlock()
        defer { pidLock.lock(); activePID = 0; pidLock.unlock() }
        var line = data; line.append(10)
        try input.write(contentsOf: line)
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let message = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                   object["ok"] == nil, object["error"] == nil, let bytes = object["progress"] as? NSNumber {
                    progress?(bytes.uint64Value, (object["item"] as? NSNumber)?.intValue)
                    continue
                }
                return message
            }
            guard pending.count < 64 * 1024 * 1024 else { throw AppFailure(message: L("The NTFS module returned too much data.")) }
            let next = output.availableData
            guard !next.isEmpty else {
                process.waitUntilExit()
                let status = process.terminationStatus
                self.input = nil; self.output = nil; self.process = nil; pending = Data()
                throw AppFailure(message: L("The NTFS module stopped (%@). Open the volume again.", String(status)))
            }
            pending.append(next)
        }
    }

    /// Asks the worker to stop the current transfer at the next 1 MiB boundary.
    func cancelCurrent() {
        pidLock.lock(); let pid = activePID; pidLock.unlock()
        if pid > 0 { kill(pid, SIGUSR1) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? input?.close(); input = nil; output = nil; process = nil; pending = Data()
    }
}

enum Worker {
    static func invoke(_ action: String, target: Target, arguments: [String], format: Bool = false,
                       operations: [[String: Any]]? = nil, progress: ((UInt64, Int?) -> Void)? = nil) throws -> Data {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("NTFSWorker") else {
            throw AppFailure(message: L("The NTFSWorker module is missing from the application."))
        }
        var metadata = target.metadata
        if format { metadata["formatConfirmation"] = metadata[target.isImage ? "path" : "identity"] }
        var request: [String: Any] = ["action": action, "target": metadata, "arguments": arguments, "uid": getuid()]
        if progress != nil { request["progress"] = true }
        if let operations = operations { request["operations"] = operations }
        let data = try JSONSerialization.data(withJSONObject: request)
        let output = try WorkerConnection.shared.request(data, executable: executable, progress: progress)
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw AppFailure(message: L("The NTFS module returned an invalid response."))
        }
        if let error = object["error"] as? String {
            let completed = (object["completed"] as? NSNumber)?.intValue
            let cancelled = error == "Operation cancelled" || error.contains("-128")
            if let completed = completed { throw BatchFailure(completed: completed, cancelled: cancelled, message: ErrorText.localize(error)) }
            if cancelled { throw CancelledFailure() }
            throw AppFailure(message: ErrorText.localize(error))
        }
        return output
    }

    /// Runs many operations in one mounted session (see runBatch in the worker). Progress reports
    /// bytes across the batch and the index of the operation in progress.
    static func batch(_ target: Target, _ operations: [(String, [String])], progress: ((UInt64, Int?) -> Void)? = nil) throws {
        let ops: [[String: Any]] = operations.map { ["op": $0.0, "args": $0.1] }
        _ = try invoke("batch", target: target, arguments: [], operations: ops, progress: progress)
    }

    static func list(_ target: Target, _ path: String) throws -> [Entry] {
        struct Listing: Decodable { let entries: [Entry] }
        return try JSONDecoder().decode(Listing.self, from: invoke("ls", target: target, arguments: [path])).entries
    }

    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Paths and names

enum NTFSPath {
    static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }
    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
    static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
}

enum NameRules {
    private static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    private static let reserved: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf16.count <= 255 && name != "." && name != ".." && !name.hasSuffix(".") && !name.hasSuffix(" ")
            && name.rangeOfCharacter(from: forbidden) == nil
    }

    /// Converts a Mac file name into one Windows accepts: NFC, no forbidden characters,
    /// no trailing dots/spaces, no reserved device names, at most 255 UTF-16 units.
    static func windowsSafe(_ original: String) -> String {
        var name = original.precomposedStringWithCanonicalMapping
        name = String(name.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        if let last = name.last, last == "." || last == " " { name.removeLast(); name.append("_") }
        if name.isEmpty || name == "." || name == ".." { name = "_" }
        let stem = (name as NSString).deletingPathExtension.uppercased()
        if reserved.contains(stem) { name = "_" + name }
        if name.utf16.count > 255 {
            let ext = (name as NSString).pathExtension
            var stemPart = (name as NSString).deletingPathExtension
            let limit = 255 - (ext.isEmpty ? 0 : ext.utf16.count + 1)
            while stemPart.utf16.count > limit { stemPart.removeLast() }
            name = ext.isEmpty ? stemPart : stemPart + "." + ext
        }
        return name
    }

    /// "Name 2.ext", "Name 3.ext"… avoiding `taken` (compared case-insensitively, like Windows).
    static func unique(_ name: String, taken: Set<String>) -> String {
        if !taken.contains(name.lowercased()) { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for i in 2...10_000 {
            let candidate = ext.isEmpty || stem.isEmpty ? "\(name) \(i)" : "\(stem) \(i).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return name + " " + UUID().uuidString.prefix(8)
    }

    static func isMacMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".Spotlight-V100" || name == ".fseventsd"
            || name == ".Trashes" || name == ".TemporaryItems" || name == "Icon\r" || name == ".localized"
    }
}

// MARK: - Temporary copies for Open / Quick Look

enum TempFiles {
    private static var bundleTemporary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Temporary") }

    /// A portable copy started from an external volume keeps its temporary files on that volume;
    /// an installed copy (startup volume, e.g. /Applications) uses the normal per-user temporary
    /// folder so its signed bundle is never modified.
    private static var portable: Bool {
        let bundleVolume = (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let rootVolume = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        return bundleVolume != nil && rootVolume != nil && bundleVolume != rootVolume
            && FileManager.default.isWritableFile(atPath: bundleTemporary.path)
    }

    /// TMPDIR for child processes.
    static var childTemporary: URL { portable ? bundleTemporary : FileManager.default.temporaryDirectory }

    static var previewRoot: URL {
        portable ? bundleTemporary.appendingPathComponent("Preview") : FileManager.default.temporaryDirectory.appendingPathComponent("OpenNTFS-Preview")
    }

    static func newDirectory() throws -> URL {
        let url = previewRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func cleanAll() { try? FileManager.default.removeItem(at: previewRoot) }
}
