import Foundation
import Darwin

struct NTFSError: Error, CustomStringConvertible {
    let code: Int32
    let description: String
    init(_ description: String, code: Int32 = EIO) {
        self.code = code
        self.description = description
    }
    var nsError: NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}

func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw NTFSError("Offset overflow") }
    return value
}

func checkedMultiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow else { throw NTFSError("Size overflow") }
    return value
}

// Readers only see this interface; writing requires the separate NTFSWritableStorage.
protocol NTFSStorage {
    var byteCount: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> [UInt8]
}

protocol NTFSWritableStorage: NTFSStorage {
    func write(at offset: UInt64, bytes: [UInt8]) throws
    /// Makes every completed write durable (F_FULLFSYNC / device cache flush).
    func synchronize() throws
}

/// Positional I/O on an already opened descriptor (an image file or a partition device that the
/// caller has validated and locked). The descriptor is not closed by this object.
final class DescriptorStorage: NTFSWritableStorage {
    private let descriptor: Int32
    let byteCount: UInt64
    let writable: Bool
    /// Device sector size: block devices only accept transfers aligned to it.
    let alignment: UInt64

    init(descriptor: Int32, byteCount: UInt64, writable: Bool, alignment: Int = 1) {
        self.descriptor = descriptor
        self.byteCount = byteCount
        self.writable = writable
        self.alignment = UInt64(max(1, alignment))
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard alignment > 1 else { return try positionalRead(descriptor, byteCount, offset, count) }
        guard count >= 0, offset <= byteCount, UInt64(count) <= byteCount - offset else { throw NTFSError("Read outside the volume") }
        if count == 0 { return [] }
        let start = offset / alignment * alignment
        let end = (offset + UInt64(count) + alignment - 1) / alignment * alignment
        let data = try positionalRead(descriptor, byteCount, start, Int(min(end, byteCount) - start))
        let skip = Int(offset - start)
        return Array(data[skip..<(skip + count)])
    }

    func write(at offset: UInt64, bytes: [UInt8]) throws {
        guard writable else { throw NTFSError("The volume is open read-only", code: EROFS) }
        guard alignment > 1 else { return try positionalWrite(descriptor, byteCount, offset, bytes) }
        guard offset <= byteCount, UInt64(bytes.count) <= byteCount - offset else { throw NTFSError("Write outside the volume") }
        if bytes.isEmpty { return }
        let start = offset / alignment * alignment
        let end = (offset + UInt64(bytes.count) + alignment - 1) / alignment * alignment
        if start == offset && end == offset + UInt64(bytes.count) {
            return try positionalWrite(descriptor, byteCount, offset, bytes)
        }
        // Read-modify-write of the partial first and last sectors.
        var block = try positionalRead(descriptor, byteCount, start, Int(end - start))
        let skip = Int(offset - start)
        block.replaceSubrange(skip..<(skip + bytes.count), with: bytes)
        try positionalWrite(descriptor, byteCount, start, block)
    }

    func synchronize() throws {
        guard writable else { return }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw NTFSError("Cannot flush the volume", code: errno) }
    }
}

func positionalRead(_ descriptor: Int32, _ byteCount: UInt64, _ offset: UInt64, _ count: Int) throws -> [UInt8] {
    guard count >= 0, count <= 64 * 1024 * 1024, offset <= byteCount, UInt64(count) <= byteCount - offset,
          offset <= UInt64(Int64.max) else { throw NTFSError("Read outside the volume") }
    var bytes = [UInt8](repeating: 0, count: count)
    try bytes.withUnsafeMutableBytes { buffer in
        var done = 0
        while done < count {
            let result = pread(descriptor, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw NTFSError("Incomplete read", code: result < 0 ? errno : EIO) }
            done += result
        }
    }
    return bytes
}

func positionalWrite(_ descriptor: Int32, _ byteCount: UInt64, _ offset: UInt64, _ bytes: [UInt8]) throws {
    guard offset <= byteCount, UInt64(bytes.count) <= byteCount - offset, offset <= UInt64(Int64.max) else {
        throw NTFSError("Write outside the volume")
    }
    try bytes.withUnsafeBytes { buffer in
        var done = 0
        while done < bytes.count {
            let result = pwrite(descriptor, buffer.baseAddress!.advanced(by: done), bytes.count - done, off_t(offset) + off_t(done))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw NTFSError("Incomplete write", code: result < 0 ? errno : EIO) }
            done += result
        }
    }
}

final class ImageStorage: NTFSWritableStorage {
    private let descriptor: Int32
    let byteCount: UInt64
    let writable: Bool

    init(path: String, writable: Bool = false) throws {
        self.writable = writable
        let fd = Darwin.open(path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw NTFSError("Cannot open image", code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw NTFSError("Cannot inspect image", code: saved)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 512 else {
            Darwin.close(fd)
            throw NTFSError("This tool accepts regular partition image files only", code: EINVAL)
        }
        guard flock(fd, (writable ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw NTFSError(writable ? "Image is in use" : "Image is in use by a writer", code: EBUSY)
        }
        descriptor = fd
        byteCount = UInt64(info.st_size)
    }

    deinit { Darwin.close(descriptor) }

    func write(at offset: UInt64, bytes: [UInt8]) throws {
        guard writable else { throw NTFSError("The image is open read-only", code: EROFS) }
        try positionalWrite(descriptor, byteCount, offset, bytes)
    }

    func synchronize() throws {
        guard writable else { return }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw NTFSError("Cannot flush the image", code: errno) }
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, count <= 8 * 1024 * 1024,
              offset <= byteCount, UInt64(count) <= byteCount - offset,
              offset <= UInt64(Int64.max) else { throw NTFSError("Read outside image") }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let result = pread(descriptor, buffer.baseAddress!.advanced(by: done),
                                   count - done, off_t(offset) + off_t(done))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw NTFSError("Incomplete image read", code: result < 0 ? errno : EIO) }
                done += result
            }
        }
        return bytes
    }
}

struct Bytes {
    var data: [UInt8]
    var count: Int { data.count }

    func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw NTFSError("Truncated NTFS structure")
        }
        return Array(data[offset..<(offset + length)])
    }

    func integer(_ offset: Int, _ length: Int) throws -> UInt64 {
        guard (1...8).contains(length) else { throw NTFSError("Invalid integer width") }
        let bytes = try slice(offset, length)
        return bytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }

    func u8(_ offset: Int) throws -> UInt8 { UInt8(try integer(offset, 1)) }
    func u16(_ offset: Int) throws -> UInt16 { UInt16(try integer(offset, 2)) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try integer(offset, 4)) }
    func u64(_ offset: Int) throws -> UInt64 { try integer(offset, 8) }

    func utf16(_ offset: Int, units: Int) throws -> String {
        let bytes = try slice(offset, units * 2)
        guard let name = String(data: Data(bytes), encoding: .utf16LittleEndian) else {
            throw NTFSError("Invalid UTF-16 name", code: EILSEQ)
        }
        return name
    }
}
