import Foundation
import Darwin

// C interface used by the application's worker process (Sources/NTFSWorker.mm, native build).
// Every function returns 0 on success or an errno value and fills `error` with a message.
// JSON results are allocated with strdup and released by the caller with free().

final class NativeSession {
    let storage: DescriptorStorage
    let volume: NativeNTFSVolume
    let writer: NTFSWriter?
    let wasDirty: Bool
    let journalClean: Bool
    var files = [UInt64: NTFSFileHandle]()
    var readers = [UInt64: NTFSRecord]()
    var nextHandle: UInt64 = 1

    init(descriptor: Int32, bytes: UInt64, alignment: Int, writable: Bool) throws {
        storage = DescriptorStorage(descriptor: descriptor, byteCount: bytes, writable: writable, alignment: alignment)
        volume = try NativeNTFSVolume(storage: storage)
        wasDirty = volume.dirty
        journalClean = try NTFSWriter.journalIsClean(volume)
        writer = writable ? try NTFSWriter(volume: volume, storage: storage) : nil
    }
}

private func fail(_ error: Error, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int32 {
    let message = (error as? NTFSError)?.description ?? String(describing: error)
    if let buffer, size > 0 {
        let bytes = Array(message.utf8.prefix(size - 1))
        for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
    }
    return (error as? NTFSError)?.code ?? EIO
}

private func session(_ handle: OpaquePointer) -> NativeSession {
    Unmanaged<NativeSession>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
}

private func string(_ pointer: UnsafePointer<CChar>) -> String { String(cString: pointer) }

private func json(_ object: Any) -> UnsafeMutablePointer<CChar>? {
    guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return nil }
    return strdup(text)
}

/// The entry fields the worker reports for a listing ($FILE_NAME copy from the index key).
private func entryObject(name: String, reference: UInt64, key: [UInt8]) -> [String: Any] {
    let flags = key.get32(56)
    let directory = flags & 0x10000000 != 0
    return ["name": name, "size": directory ? 0 : key.get64(48), "attributes": (flags & 0x0fffffff) | (directory ? 0x10 : 0),
            "directory": directory, "fileID": reference & 0x0000ffffffffffff, "modifiedNTFS": key.get64(16)]
}

private func listing(_ s: NativeSession, _ path: String) throws -> [[String: Any]] {
    var output = [[String: Any]]()
    if let writer = s.writer {
        for item in try writer.listing(path) where item.reference & 0x0000ffffffffffff >= 16 {
            output.append(entryObject(name: item.name, reference: item.reference, key: item.key))
        }
        return output
    }
    let directory = try s.volume.resolve(path)
    for item in try s.volume.indexItems(in: directory) where item.namespace != 2 {
        guard let entry = item.entry, entry.reference & 0x0000ffffffffffff >= 16, entry.name != "." else { continue }
        output.append(entryObject(name: entry.name, reference: entry.reference, key: item.key))
    }
    return output
}

@_cdecl("ntfs_open")
public func ntfs_open(_ descriptor: Int32, _ bytes: UInt64, _ alignment: Int32, _ writable: Int32,
                      _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> OpaquePointer? {
    do {
        let s = try NativeSession(descriptor: descriptor, bytes: bytes, alignment: Int(alignment), writable: writable != 0)
        return OpaquePointer(Unmanaged.passRetained(s).toOpaque())
    } catch { _ = fail(error, message, messageSize); return nil }
}

@_cdecl("ntfs_close")
public func ntfs_close(_ handle: OpaquePointer, _ commit: Int32, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    let unmanaged = Unmanaged<NativeSession>.fromOpaque(UnsafeRawPointer(handle))
    let s = unmanaged.takeUnretainedValue()
    defer { unmanaged.release() }
    do {
        if commit != 0 { try s.writer?.close() } else { s.writer?.abandon() }
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_flush")
public func ntfs_flush(_ handle: OpaquePointer, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    do { try session(handle).writer?.flush(); return 0 } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_was_dirty")
public func ntfs_was_dirty(_ handle: OpaquePointer) -> Int32 { session(handle).wasDirty ? 1 : 0 }

@_cdecl("ntfs_journal_clean")
public func ntfs_journal_clean(_ handle: OpaquePointer) -> Int32 { session(handle).journalClean ? 1 : 0 }

@_cdecl("ntfs_list")
public func ntfs_list(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> UnsafeMutablePointer<CChar>? {
    do { return json(try listing(session(handle), string(path))) } catch { _ = fail(error, message, messageSize); return nil }
}

/// One entry by path ("null" when it does not exist).
@_cdecl("ntfs_entry")
public func ntfs_entry(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> UnsafeMutablePointer<CChar>? {
    let s = session(handle)
    let text = string(path)
    do {
        if let writer = s.writer {
            guard let item = try writer.lookup(text) else { return strdup("null") }
            return json(entryObject(name: item.name, reference: item.reference, key: item.key))
        }
        let parts = text.split(separator: "/")
        guard let last = parts.last else { return strdup("null") }
        let parent = try s.volume.resolve("/" + parts.dropLast().joined(separator: "/"))
        guard parent.directory, let entry = try s.volume.find(String(last), in: parent) else { return strdup("null") }
        let key = try s.volume.indexItems(in: parent).first { $0.entry?.reference == entry.reference && $0.entry?.name == entry.name }?.key
        return json(entryObject(name: entry.name, reference: entry.reference, key: key ?? []))
    } catch let failure as NTFSError where failure.code == ENOENT || failure.code == ENOTDIR {
        return strdup("null")
    } catch { _ = fail(error, message, messageSize); return nil }
}

@_cdecl("ntfs_same_name")
public func ntfs_same_name(_ handle: OpaquePointer, _ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 {
    let volume = session(handle).volume
    return volume.upcase(Array(string(a).utf16)) == volume.upcase(Array(string(b).utf16)) ? 1 : 0
}

@_cdecl("ntfs_free_bytes")
public func ntfs_free_bytes(_ handle: OpaquePointer, _ bytes: UnsafeMutablePointer<UInt64>) -> Int32 {
    let s = session(handle)
    if let writer = s.writer { bytes.pointee = writer.freeClusters * UInt64(s.volume.geometry.clusterSize); return 0 }
    guard let free = try? s.volume.freeClusters() else { return EIO }
    bytes.pointee = free * UInt64(s.volume.geometry.clusterSize)
    return 0
}

@_cdecl("ntfs_create_file")
public func ntfs_create_file(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ size: UInt64, _ file: UnsafeMutablePointer<UInt64>,
                             _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    let s = session(handle)
    do {
        guard let writer = s.writer else { throw NTFSError("The volume is open read-only", code: EROFS) }
        let created = try writer.createFile(string(path), size: size)
        let id = s.nextHandle
        s.nextHandle += 1
        s.files[id] = created
        file.pointee = id
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_write_file")
public func ntfs_write_file(_ handle: OpaquePointer, _ file: UInt64, _ offset: UInt64, _ buffer: UnsafeRawPointer, _ length: Int,
                            _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    let s = session(handle)
    do {
        guard let writer = s.writer, let created = s.files[file] else { throw NTFSError("Invalid file handle", code: EBADF) }
        try writer.write(created, at: offset, bytes: [UInt8](UnsafeRawBufferPointer(start: buffer, count: length)))
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_finish_file")
public func ntfs_finish_file(_ handle: OpaquePointer, _ file: UInt64, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    let s = session(handle)
    do {
        guard let writer = s.writer, let created = s.files.removeValue(forKey: file) else { throw NTFSError("Invalid file handle", code: EBADF) }
        try writer.finish(created)
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_open_file")
public func ntfs_open_file(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ file: UnsafeMutablePointer<UInt64>, _ size: UnsafeMutablePointer<UInt64>,
                           _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    let s = session(handle)
    do {
        let text = string(path)
        let record: NTFSRecord
        if let writer = s.writer { record = try s.volume.record(reference: writer.locate(text).reference) } else { record = try s.volume.resolve(text) }
        guard !record.directory else { throw NTFSError("Is a directory", code: EISDIR) }
        if let tag = record.reparseTag { throw NTFSError(String(format: "Reparse points are not supported (tag 0x%08x)", tag), code: ENOTSUP) }
        let data = try record.attribute(NTFSType.data)
        guard !data.encrypted else { throw NTFSError("Encrypted (EFS) files can only be read on Windows", code: ENOTSUP) }
        let id = s.nextHandle
        s.nextHandle += 1
        s.readers[id] = record
        file.pointee = id
        size.pointee = data.size
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_read_file")
public func ntfs_read_file(_ handle: OpaquePointer, _ file: UInt64, _ offset: UInt64, _ buffer: UnsafeMutableRawPointer, _ length: Int,
                           _ got: UnsafeMutablePointer<Int>, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    let s = session(handle)
    do {
        guard let record = s.readers[file] else { throw NTFSError("Invalid file handle", code: EBADF) }
        let data = try s.volume.contents(of: record, at: offset, count: min(length, 8 * 1024 * 1024))
        data.withUnsafeBytes { if !data.isEmpty { buffer.copyMemory(from: $0.baseAddress!, byteCount: data.count) } }
        got.pointee = data.count
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_close_file")
public func ntfs_close_file(_ handle: OpaquePointer, _ file: UInt64) {
    let s = session(handle)
    s.readers.removeValue(forKey: file)
    s.files.removeValue(forKey: file)
}

@_cdecl("ntfs_mkdir")
public func ntfs_mkdir(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    do {
        guard let writer = session(handle).writer else { throw NTFSError("The volume is open read-only", code: EROFS) }
        try writer.createDirectory(string(path))
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_remove")
public func ntfs_remove(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ directory: Int32, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    do {
        guard let writer = session(handle).writer else { throw NTFSError("The volume is open read-only", code: EROFS) }
        try writer.remove(string(path), directory: directory != 0)
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_rename")
public func ntfs_rename(_ handle: OpaquePointer, _ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    do {
        guard let writer = session(handle).writer else { throw NTFSError("The volume is open read-only", code: EROFS) }
        try writer.rename(string(from), to: string(to))
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_repair_security")
public func ntfs_repair_security(_ handle: OpaquePointer, _ path: UnsafePointer<CChar>, _ checked: UnsafeMutablePointer<UInt32>,
                                 _ fixed: UnsafeMutablePointer<UInt32>, _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    do {
        guard let writer = session(handle).writer else { throw NTFSError("The volume is open read-only", code: EROFS) }
        let counts = try writer.repairSecurity(string(path))
        checked.pointee = counts.checked
        fixed.pointee = counts.fixed
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_format")
public func ntfs_format(_ descriptor: Int32, _ bytes: UInt64, _ sectorSize: Int32, _ hiddenSectors: UInt32, _ label: UnsafePointer<CChar>,
                        _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> Int32 {
    do {
        let storage = DescriptorStorage(descriptor: descriptor, byteCount: bytes, writable: true, alignment: Int(sectorSize))
        var options = NTFSFormatter.Options()
        options.label = string(label)
        options.hiddenSectors = hiddenSectors
        options.sectorSize = Int(sectorSize)
        try NTFSFormatter.format(storage, options: options)
        return 0
    } catch { return fail(error, message, messageSize) }
}

@_cdecl("ntfs_check")
public func ntfs_check(_ descriptor: Int32, _ bytes: UInt64, _ alignment: Int32, _ mode: UnsafePointer<CChar>,
                       _ progress: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void)?, _ context: UnsafeMutableRawPointer?,
                       _ message: UnsafeMutablePointer<CChar>?, _ messageSize: Int) -> UnsafeMutablePointer<CChar>? {
    do {
        guard let checkMode = NTFSChecker.Mode(rawValue: string(mode)) else { throw NTFSError("Invalid operation", code: EINVAL) }
        let storage = DescriptorStorage(descriptor: descriptor, byteCount: bytes, writable: checkMode != .verify, alignment: Int(alignment))
        let report = try NTFSChecker.run(storage, mode: checkMode) { percent in progress?(Int32(percent), context) }
        return json(["result": report.result, "dirtyBefore": report.dirtyBefore, "dirtyAfter": report.dirtyAfter,
                     "journalNotClean": report.journalNotClean, "freeBytes": report.freeBytes, "totalBytes": report.totalBytes,
                     "errors": report.errors.count, "minor": report.minor.count, "unfixable": report.unfixable.count,
                     "repaired": report.repaired.count, "log": report.log])
    } catch { _ = fail(error, message, messageSize); return nil }
}
