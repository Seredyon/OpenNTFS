import Foundation
import Darwin

// Writing support for NTFS 3.x volumes.
//
// Ordering (best effort without a journal; the volume is marked dirty while a session is open):
//   allocate (bitmap bit written) -> write the structure that uses it -> link it into an index;
//   unlink from the index -> release records and clusters.
// Directory and security indexes change in memory and are rebuilt when the session commits.

// MARK: - Little-endian helpers

extension Array where Element == UInt8 {
    mutating func put(_ value: UInt64, at offset: Int, width: Int) {
        for i in 0..<width { self[offset + i] = UInt8(truncatingIfNeeded: value >> (UInt64(i) * 8)) }
    }
    mutating func put16(_ value: UInt16, at offset: Int) { put(UInt64(value), at: offset, width: 2) }
    mutating func put32(_ value: UInt32, at offset: Int) { put(UInt64(value), at: offset, width: 4) }
    mutating func put64(_ value: UInt64, at offset: Int) { put(value, at: offset, width: 8) }
    func get(_ offset: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<width { value |= UInt64(self[offset + i]) << (UInt64(i) * 8) }
        return value
    }
    func get16(_ offset: Int) -> UInt16 { UInt16(get(offset, width: 2)) }
    func get32(_ offset: Int) -> UInt32 { UInt32(get(offset, width: 4)) }
    func get64(_ offset: Int) -> UInt64 { get(offset, width: 8) }
}

func align8(_ value: Int) -> Int { (value + 7) & ~7 }

/// Current time in NTFS units (100 ns since 1601-01-01 UTC).
func ntfsNow() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)
    return (UInt64(now.tv_sec) + 11_644_473_600) * 10_000_000 + UInt64(now.tv_nsec / 100)
}

func utf16LE(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }

/// Applies NTFS multi-sector protection to a record or index block in place.
func applyFixups(_ data: inout [UInt8]) throws {
    let offset = Int(data.get16(4)), count = Int(data.get16(6))
    guard offset >= 8, count == data.count / 512 + 1, offset + count * 2 <= 510 else { throw NTFSError("Invalid update sequence array") }
    var usn = data.get16(offset) &+ 1
    if usn == 0 || usn == 0xffff { usn = 1 }
    data.put16(usn, at: offset)
    for sector in 1..<count {
        let trailer = sector * 512 - 2
        data[offset + sector * 2] = data[trailer]
        data[offset + sector * 2 + 1] = data[trailer + 1]
        data.put16(usn, at: trailer)
    }
}

// MARK: - Attribute records

enum AttributeRecord {
    static func type(_ a: [UInt8]) -> UInt32 { a.get32(0) }
    static func isResident(_ a: [UInt8]) -> Bool { a[8] == 0 }
    static func identifier(_ a: [UInt8]) -> UInt16 { a.get16(14) }
    static func name(_ a: [UInt8]) -> String {
        let length = Int(a[9]), offset = Int(a.get16(10))
        guard length > 0 else { return "" }
        let units = (0..<length).map { a.get16(offset + $0 * 2) }
        return String(utf16CodeUnits: units, count: units.count)
    }
    static func value(_ a: [UInt8]) -> [UInt8] {
        let length = Int(a.get32(16)), offset = Int(a.get16(20))
        return Array(a[offset..<(offset + length)])
    }

    static func resident(type: UInt32, name: String = "", value: [UInt8], identifier: UInt16, indexed: Bool = false) -> [UInt8] {
        let encodedName = utf16LE(name)
        let valueOffset = align8(24 + encodedName.count)
        var a = [UInt8](repeating: 0, count: align8(valueOffset + value.count))
        a.put32(type, at: 0)
        a.put32(UInt32(a.count), at: 4)
        a[8] = 0
        a[9] = UInt8(encodedName.count / 2)
        a.put16(encodedName.isEmpty ? 0 : 24, at: 10)
        a.put16(identifier, at: 14)
        a.put32(UInt32(value.count), at: 16)
        a.put16(UInt16(valueOffset), at: 20)
        a[22] = indexed ? 1 : 0
        a.replaceSubrange(24..<(24 + encodedName.count), with: encodedName)
        a.replaceSubrange(valueOffset..<(valueOffset + value.count), with: value)
        return a
    }

    static func nonresident(type: UInt32, name: String = "", runs: [NTFSRun], size: UInt64, initialized: UInt64,
                            identifier: UInt16, clusterSize: Int, extentOf allocatedClusters: UInt64? = nil) -> [UInt8] {
        if let allocatedClusters, let first = runs.first, first.vcn > 0 || runs.reduce(0, { $0 + $1.length }) != allocatedClusters {
            return extent(type: type, name: name, runs: runs, size: size, initialized: initialized, identifier: identifier,
                          clusterSize: clusterSize, totalClusters: allocatedClusters)
        }
        let encodedName = utf16LE(name)
        let pairs = mappingPairs(runs)
        let runsOffset = align8(64 + encodedName.count)
        var a = [UInt8](repeating: 0, count: align8(runsOffset + pairs.count))
        let clusters = runs.reduce(UInt64(0)) { $0 + $1.length }
        a.put32(type, at: 0)
        a.put32(UInt32(a.count), at: 4)
        a[8] = 1
        a[9] = UInt8(encodedName.count / 2)
        a.put16(encodedName.isEmpty ? 0 : 64, at: 10)
        a.put16(identifier, at: 14)
        a.put64(0, at: 16)
        a.put64(clusters == 0 ? UInt64.max : clusters - 1, at: 24)
        a.put16(UInt16(runsOffset), at: 32)
        a.put64(clusters * UInt64(clusterSize), at: 40)
        a.put64(size, at: 48)
        a.put64(initialized, at: 56)
        a.replaceSubrange(64..<(64 + encodedName.count), with: encodedName)
        a.replaceSubrange(runsOffset..<(runsOffset + pairs.count), with: pairs)
        return a
    }

    /// One extent (part of the cluster map) of a stream split over several records. Only the
    /// first extent (lowest VCN 0) carries the stream sizes.
    static func extent(type: UInt32, name: String = "", runs: [NTFSRun], size: UInt64, initialized: UInt64,
                       identifier: UInt16, clusterSize: Int, totalClusters: UInt64) -> [UInt8] {
        let encodedName = utf16LE(name)
        let pairs = mappingPairs(runs)
        let runsOffset = align8(64 + encodedName.count)
        var a = [UInt8](repeating: 0, count: align8(runsOffset + pairs.count))
        let first = runs.first?.vcn ?? 0
        let last = runs.last.map { $0.vcn + $0.length - 1 } ?? first
        a.put32(type, at: 0)
        a.put32(UInt32(a.count), at: 4)
        a[8] = 1
        a[9] = UInt8(encodedName.count / 2)
        a.put16(encodedName.isEmpty ? 0 : 64, at: 10)
        a.put16(identifier, at: 14)
        a.put64(first, at: 16)
        a.put64(last, at: 24)
        a.put16(UInt16(runsOffset), at: 32)
        if first == 0 {
            a.put64(totalClusters * UInt64(clusterSize), at: 40)
            a.put64(size, at: 48)
            a.put64(initialized, at: 56)
        }
        a.replaceSubrange(64..<(64 + encodedName.count), with: encodedName)
        a.replaceSubrange(runsOffset..<(runsOffset + pairs.count), with: pairs)
        return a
    }

    static func mappingPairs(_ runs: [NTFSRun]) -> [UInt8] {
        var output = [UInt8](), previous: Int64 = 0
        func bytes(unsigned value: UInt64) -> [UInt8] {
            var v = value, out = [UInt8]()
            repeat { out.append(UInt8(v & 0xff)); v >>= 8 } while v != 0
            return out
        }
        func bytes(signed value: Int64) -> [UInt8] {
            var out = [UInt8](), v = value
            while true {
                let byte = UInt8(truncatingIfNeeded: v)
                out.append(byte)
                v >>= 8
                if (v == 0 && byte & 0x80 == 0) || (v == -1 && byte & 0x80 != 0) { break }
            }
            return out
        }
        for run in runs {
            let length = bytes(unsigned: run.length)
            var offset = [UInt8]()
            if let lcn = run.lcn {
                offset = bytes(signed: Int64(lcn) - previous)
                previous = Int64(lcn)
            }
            output.append(UInt8(offset.count << 4 | length.count))
            output += length + offset
        }
        output.append(0)
        return output
    }
}

// MARK: - MFT record image

/// A mutable MFT record: the stored header (layout preserved) plus complete attribute records.
struct RecordImage {
    let number: UInt64
    var header: [UInt8]
    var attributes: [[UInt8]]
    let size: Int

    var sequence: UInt16 { get { header.get16(16) } set { header.put16(newValue, at: 16) } }
    var links: UInt16 { get { header.get16(18) } set { header.put16(newValue, at: 18) } }
    var flags: UInt16 { get { header.get16(22) } set { header.put16(newValue, at: 22) } }
    var baseReference: UInt64 { get { header.get64(32) } set { header.put64(newValue, at: 32) } }
    var nextIdentifier: UInt16 { get { header.get16(40) } set { header.put16(newValue, at: 40) } }
    var reference: UInt64 { number | UInt64(sequence) << 48 }
    var inUse: Bool { flags & 1 != 0 }

    /// Decodes a record whose fixups were already restored.
    init(number: UInt64, fixed: [UInt8]) throws {
        self.number = number
        size = fixed.count
        let offset = Int(fixed.get16(20)), used = Int(fixed.get32(24))
        guard offset >= 42, offset % 8 == 0, used <= size, offset < used else { throw NTFSError("Invalid MFT record header") }
        header = Array(fixed[0..<offset])
        var cursor = offset, parsed = [[UInt8]]()
        while cursor + 4 <= used {
            let type = fixed.get32(cursor)
            if type == UInt32.max { break }
            let length = Int(fixed.get32(cursor + 4))
            guard length >= 24, length % 8 == 0, cursor + length <= used else { throw NTFSError("Invalid attribute length") }
            parsed.append(Array(fixed[cursor..<(cursor + length)]))
            cursor += length
        }
        attributes = parsed
    }

    /// A blank record header in the NTFS 3.1 layout (update sequence array at offset 48).
    init(blank number: UInt64, size: Int, sequence: UInt16) {
        self.number = number
        self.size = size
        let count = size / 512 + 1
        var h = [UInt8](repeating: 0, count: align8(48 + count * 2))
        h.replaceSubrange(0..<4, with: Array("FILE".utf8))
        h.put16(48, at: 4)
        h.put16(UInt16(count), at: 6)
        h.put16(sequence, at: 16)
        h.put16(UInt16(h.count), at: 20)
        h.put32(UInt32(size), at: 28)
        h.put32(UInt32(truncatingIfNeeded: number), at: 44)
        h.put16(0, at: 48)
        header = h
        attributes = []
    }

    mutating func takeIdentifier() -> UInt16 {
        let id = nextIdentifier
        nextIdentifier = id &+ 1
        return id
    }

    func index(of type: UInt32, name: String = "") -> Int? {
        attributes.firstIndex { AttributeRecord.type($0) == type && AttributeRecord.name($0) == name }
    }

    /// Inserts keeping NTFS order (by type, then name), or replaces the attribute with the same id.
    mutating func set(_ attribute: [UInt8]) {
        let type = AttributeRecord.type(attribute), name = AttributeRecord.name(attribute), id = AttributeRecord.identifier(attribute)
        if let existing = attributes.firstIndex(where: { AttributeRecord.type($0) == type && AttributeRecord.identifier($0) == id }) {
            attributes[existing] = attribute
            return
        }
        let position = attributes.firstIndex {
            let t = AttributeRecord.type($0)
            return t > type || (t == type && AttributeRecord.name($0) > name)
        } ?? attributes.count
        attributes.insert(attribute, at: position)
    }

    mutating func remove(type: UInt32, name: String = "") {
        attributes.removeAll { AttributeRecord.type($0) == type && AttributeRecord.name($0) == name }
    }

    var usedSize: Int { header.count + attributes.reduce(0) { $0 + $1.count } + 8 }

    func encoded() throws -> [UInt8] {
        guard usedSize <= size else { throw NTFSError("The MFT record is full", code: ENOSPC) }
        var data = [UInt8](repeating: 0, count: size)
        var h = header
        h.put32(UInt32(usedSize), at: 24)
        h.put32(UInt32(size), at: 28)
        data.replaceSubrange(0..<h.count, with: h)
        var cursor = h.count
        for attribute in attributes {
            data.replaceSubrange(cursor..<(cursor + attribute.count), with: attribute)
            cursor += attribute.count
        }
        data.put32(UInt32.max, at: cursor)
        try applyFixups(&data)
        return data
    }
}

// MARK: - Index entries and index building

/// Collation used to keep index entries in the order NTFS expects.
enum Collation {
    case fileName(upcase: [UInt16])
    case unsignedLong          // $SII
    case securityHash          // $SDH
}

/// One index entry without its child pointer: the 16-byte entry header, key and (for view
/// indexes) data, padded to 8 bytes.
struct IndexEntryBody {
    var bytes: [UInt8]
    let sortKey: [UInt16]       // folded name, or numeric key words
    let tieKey: [UInt16]

    static func fileName(reference: UInt64, key: [UInt8], upcase: [UInt16]) -> IndexEntryBody {
        var bytes = [UInt8](repeating: 0, count: align8(16 + key.count))
        bytes.put64(reference, at: 0)
        bytes.put16(UInt16(bytes.count), at: 8)
        bytes.put16(UInt16(key.count), at: 10)
        bytes.replaceSubrange(16..<(16 + key.count), with: key)
        let length = Int(key[64])
        let units = (0..<length).map { key.get16(66 + $0 * 2) }
        return IndexEntryBody(bytes: bytes, sortKey: units.map { upcase[Int($0)] }, tieKey: units)
    }

    static func view(key: [UInt8], data: [UInt8], padding: [UInt8] = []) -> IndexEntryBody {
        let dataOffset = 16 + key.count
        var bytes = [UInt8](repeating: 0, count: align8(dataOffset + data.count + padding.count))
        bytes.put16(UInt16(dataOffset), at: 0)
        bytes.put16(UInt16(data.count), at: 2)
        bytes.put16(UInt16(bytes.count), at: 8)
        bytes.put16(UInt16(key.count), at: 10)
        bytes.replaceSubrange(16..<dataOffset, with: key)
        bytes.replaceSubrange(dataOffset..<(dataOffset + data.count), with: data)
        bytes.replaceSubrange((dataOffset + data.count)..<(dataOffset + data.count + padding.count), with: padding)
        let words = stride(from: 0, to: key.count, by: 2).map { key.get16($0) }
        return IndexEntryBody(bytes: bytes, sortKey: words, tieKey: [])
    }
}

func compareUnits(_ a: [UInt16], _ b: [UInt16]) -> Int {
    for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
    return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
}

func compareEntries(_ a: IndexEntryBody, _ b: IndexEntryBody, _ collation: Collation) -> Int {
    switch collation {
    case .fileName:
        let order = compareUnits(a.sortKey, b.sortKey)
        return order != 0 ? order : compareUnits(a.tieKey, b.tieKey)
    case .unsignedLong:
        let x = UInt32(a.sortKey[0]) | UInt32(a.sortKey[1]) << 16, y = UInt32(b.sortKey[0]) | UInt32(b.sortKey[1]) << 16
        return x == y ? 0 : (x < y ? -1 : 1)
    case .securityHash:
        for word in [1, 0, 3, 2] where a.sortKey[word] != b.sortKey[word] { return a.sortKey[word] < b.sortKey[word] ? -1 : 1 }
        return 0
    }
}

/// The node layout of a rebuilt index: the root's entries and the INDX blocks (by block number).
struct BuiltIndex {
    var rootEntries: [UInt8]
    var rootHasChildren: Bool
    var blocks: [[UInt8]]          // entry bytes of each block (end entry included)
    var blockHasChildren: [Bool]
}

enum IndexBuilder {
    static let endEntrySize = 16

    static func entry(_ body: IndexEntryBody, child: UInt64?, last: Bool = false) -> [UInt8] {
        var bytes = body.bytes
        var flags: UInt16 = last ? 2 : 0
        if let child {
            flags |= 1
            bytes += [UInt8](repeating: 0, count: 8)
            bytes.put64(child, at: bytes.count - 8)
        }
        bytes.put16(UInt16(bytes.count), at: 8)
        bytes.put16(flags, at: 12)
        return bytes
    }

    static func end(child: UInt64?) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: child == nil ? 16 : 24)
        bytes.put16(UInt16(bytes.count), at: 8)
        bytes.put16(child == nil ? 2 : 3, at: 12)
        if let child { bytes.put64(child, at: 16) }
        return bytes
    }

    /// Builds a balanced tree bottom-up, level by level. A node takes entries while they fit; the
    /// next entry becomes a separator one level up (NTFS nodes hold the keys between children),
    /// and the node's end entry points at that separator's left subtree.
    static func build(_ entries: [IndexEntryBody], rootCapacity: Int, blockCapacity: Int, vcnOf: (Int) -> UInt64) throws -> BuiltIndex {
        let leafBytes = entries.reduce(0) { $0 + $1.bytes.count } + endEntrySize
        if leafBytes <= rootCapacity {
            return BuiltIndex(rootEntries: entries.flatMap(\.bytes) + end(child: nil), rootHasChildren: false, blocks: [], blockHasChildren: [])
        }
        typealias Item = (body: IndexEntryBody, child: Int?)
        var blocks = [[UInt8]](), hasChildren = [Bool]()
        var items: [Item] = entries.map { ($0, nil) }
        var tail: Int? = nil
        func size(_ item: Item) -> Int { item.body.bytes.count + (item.child == nil ? 0 : 8) }
        func emit(_ slice: ArraySlice<Item>, endChild: Int?) -> Int {
            var bytes = [UInt8]()
            for item in slice { bytes += entry(item.body, child: item.child.map(vcnOf)) }
            bytes += end(child: endChild.map(vcnOf))
            blocks.append(bytes)
            hasChildren.append(endChild != nil || slice.contains { $0.child != nil })
            return blocks.count - 1
        }
        let limit = blockCapacity - 24
        while true {
            if tail != nil, items.reduce(0, { $0 + size($1) }) + 24 <= rootCapacity {
                var root = [UInt8]()
                for item in items { root += entry(item.body, child: item.child.map(vcnOf)) }
                root += end(child: tail.map(vcnOf))
                return BuiltIndex(rootEntries: root, rootHasChildren: true, blocks: blocks, blockHasChildren: hasChildren)
            }
            var upper = [Item](), i = 0, newTail: Int? = nil
            while i < items.count {
                var j = i, used = 0
                while j < items.count, used + size(items[j]) <= limit { used += size(items[j]); j += 1 }
                guard j > i else { throw NTFSError("Index entry is too large") }
                if j == items.count {
                    newTail = emit(items[i..<j], endChild: tail)
                    break
                }
                if j == items.count - 1, j - 1 > i { j -= 1 }
                let node = emit(items[i..<j], endChild: items[j].child)
                upper.append((items[j].body, node))
                i = j + 1
                if i == items.count {
                    newTail = emit(items[i..<i], endChild: tail)
                    break
                }
            }
            items = upper
            tail = newTail
            if items.isEmpty {
                return BuiltIndex(rootEntries: end(child: tail.map(vcnOf)), rootHasChildren: true, blocks: blocks, blockHasChildren: hasChildren)
            }
        }
    }
}

// MARK: - In-memory bitmaps

/// A bitmap stream ($Bitmap data, or the $MFT bitmap) held in memory. Allocations are written
/// through immediately; the changed byte ranges are tracked for writing.
final class BitmapStream {
    var bits: [UInt8]
    let count: UInt64
    private(set) var dirty = IndexSet()
    /// Set bits below `count`: counted once here and kept up to date by `set`, because a large
    /// volume's bitmap is too long to count for every file.
    private var used = 0

    init(bytes: [UInt8], count: UInt64) {
        bits = bytes
        self.count = count
        let whole = min(Int(count / 8), bytes.count)
        for index in 0..<whole { used += bytes[index].nonzeroBitCount }
        if count % 8 != 0, whole < bytes.count { used += (bytes[whole] & UInt8((1 << (count % 8)) - 1)).nonzeroBitCount }
    }

    var freeCount: UInt64 { count - min(UInt64(max(used, 0)), count) }

    func isSet(_ index: UInt64) -> Bool { bits[Int(index >> 3)] & (1 << (index & 7)) != 0 }

    func set(_ start: UInt64, _ length: UInt64, _ value: Bool) {
        var i = start
        while i < start + length {
            let byte = Int(i >> 3)
            if i & 7 == 0, start + length - i >= 8 {
                used += (value ? 8 : 0) - bits[byte].nonzeroBitCount
                bits[byte] = value ? 0xff : 0
                i += 8
            } else {
                let mask: UInt8 = 1 << (i & 7)
                if (bits[byte] & mask != 0) != value { used += value ? 1 : -1 }
                if value { bits[byte] |= mask } else { bits[byte] &= ~mask }
                i += 1
            }
            dirty.insert(byte)
        }
    }

    func takeDirty() -> IndexSet { let d = dirty; dirty = IndexSet(); return d }

    /// Free runs scanning from `from`, skipping full bytes quickly.
    func freeRun(atLeast length: UInt64, from: UInt64, below limit: UInt64) -> (UInt64, UInt64)? {
        var i = from, best: (UInt64, UInt64)? = nil
        while i < limit {
            if i & 7 == 0, bits[Int(i >> 3)] == 0xff { i += 8; continue }
            if isSet(i) { i += 1; continue }
            var j = i
            while j < limit, !isSet(j), j - i < length { j += 1 }
            if j - i >= length { return (i, j - i) }
            if best == nil || j - i > best!.1 { best = (i, j - i) }
            i = j
        }
        return best
    }
}

// MARK: - Writer

struct NTFSFileHandle {
    let number: UInt64
    let size: UInt64
    let runs: [NTFSRun]
    let resident: Bool
}

final class NTFSWriter {
    let volume: NativeNTFSVolume
    let storage: NTFSWritableStorage
    var geometry: NTFSGeometry { volume.geometry }
    private let clusterBitmap: BitmapStream
    private var recordBitmap: BitmapStream
    private var directories = [UInt64: DirectoryState]()
    private var pendingRecordFrees = [UInt64]()
    private var pendingClusterFrees = [NTFSRun]()
    private var allocationHint: UInt64 = 0
    private var security: SecurityStore?
    private var open = true
    /// Whether this session has marked the volume dirty. Marking happens right before the first
    /// change, so a session that only validates (or fails before writing) leaves the volume as it was.
    private var marked = false
    private let marksDirty: Bool

    final class DirectoryState {
        let number: UInt64
        var entries: [IndexEntryBody]
        var dirty = false
        init(number: UInt64, entries: [IndexEntryBody]) {
            self.number = number
            self.entries = entries
        }
    }

    init(volume: NativeNTFSVolume, storage: NTFSWritableStorage, allowDirty: Bool = false, markDirty: Bool = true) throws {
        self.volume = volume
        self.storage = storage
        marksDirty = markDirty
        guard allowDirty || !volume.dirty else { throw NTFSError("NTFS is marked dirty. Run a filesystem check before writing", code: EROFS) }
        guard try Self.journalIsClean(volume) else {
            throw NTFSError("Windows left unfinished changes in the NTFS journal. Open the drive on Windows and shut down normally before writing", code: EROFS)
        }
        let geometry = volume.geometry
        let bitmap = try volume.record(6).attribute(NTFSType.data)
        let clusters = geometry.clusterCount
        guard bitmap.size >= (clusters + 7) / 8 else { throw NTFSError("Volume bitmap is too small") }
        clusterBitmap = BitmapStream(bytes: try Self.readStream(bitmap, volume: volume, bytes: (clusters + 7) / 8), count: clusters)
        let mftRecord = try volume.record(0)
        let mftBits = try mftRecord.attribute(NTFSType.bitmap)
        recordBitmap = BitmapStream(bytes: try Self.readStream(mftBits, volume: volume, bytes: mftBits.size), count: volume.recordCount)
        allocationHint = geometry.mftCluster + geometry.clusterCount / 8
    }

    /// Marks the volume dirty (durably) before the session's first change.
    private func beginChanges() throws {
        guard marksDirty, !marked else { return }
        marked = true
        try setVolumeDirty(true)
        try storage.synchronize()
    }

    func setVolumeDirtyFlag(_ dirty: Bool) throws { try setVolumeDirty(dirty) }

    /// Ends the session without committing or clearing the dirty flag.
    func abandon() { open = false }

    func setLinkCount(_ number: UInt64, _ links: UInt16) throws {
        var record = try loadRecord(number)
        record.links = links
        try storeRecord(record)
    }

    /// Removes the index entries that name `references` and rebuilds the folder index in order.
    func dropEntries(_ references: Set<UInt64>, from folder: UInt64) throws {
        let state = try directoryState(folder)
        state.entries.removeAll { references.contains($0.bytes.get64(0)) }
        state.entries.sort { compareEntries($0, $1, .fileName(upcase: volume.uppercase)) < 0 }
        state.dirty = true
    }

    deinit { if open { try? close() } }

    static func readStream(_ attribute: NTFSAttribute, volume: NativeNTFSVolume, bytes: UInt64) throws -> [UInt8] {
        var data = [UInt8](), position: UInt64 = 0
        data.reserveCapacity(Int(bytes))
        while position < bytes {
            let chunk = try attribute.read(storage: volume.storage, geometry: volume.geometry, at: position, count: Int(min(4 * 1024 * 1024, bytes - position)))
            guard !chunk.isEmpty else { throw NTFSError("Short metadata stream") }
            data += chunk
            position += UInt64(chunk.count)
        }
        return data
    }

    /// Clean when the restart area says so, or when the log is empty (all 0xff, as after format).
    static func journalIsClean(_ volume: NativeNTFSVolume) throws -> Bool {
        let log = try volume.record(2).attribute(NTFSType.data)
        let page = try log.read(storage: volume.storage, geometry: volume.geometry, at: 0, count: 4096)
        if page.allSatisfy({ $0 == 0xff }) { return true }
        guard page.count == 4096, Array(page[0..<4]) == Array("RSTR".utf8) else { return false }
        var fixed = page
        let usaOffset = Int(fixed.get16(4)), usaCount = Int(fixed.get16(6))
        if usaOffset >= 8, usaCount >= 2, usaOffset + usaCount * 2 <= 512 {
            for sector in 1..<min(usaCount, 9) {
                fixed[sector * 512 - 2] = page[usaOffset + sector * 2]
                fixed[sector * 512 - 1] = page[usaOffset + sector * 2 + 1]
            }
        }
        let area = Int(fixed.get16(24))
        guard area >= 30, area + 24 <= fixed.count else { return false }
        return fixed.get16(area + 14) & 0x0002 != 0
    }

    // MARK: Records

    func loadRecord(_ number: UInt64) throws -> RecordImage {
        let bytes = try volume.mft.read(storage: storage, geometry: geometry,
                                        at: checkedMultiply(number, UInt64(geometry.recordSize)), count: geometry.recordSize)
        let fixed = try restoreFixups(bytes, signature: "FILE")
        return try RecordImage(number: number, fixed: fixed.data)
    }

    func storeRecord(_ record: RecordImage) throws {
        try beginChanges()
        let data = try record.encoded()
        try writeStream(volume.mft, at: record.number * UInt64(geometry.recordSize), bytes: data)
        if record.number < 4 { try writeMirror(record.number, data) }
        volume.invalidate(record.number)
    }

    private func writeMirror(_ number: UInt64, _ data: [UInt8]) throws {
        let mirror = try volume.record(1).attribute(NTFSType.data)
        guard mirror.size >= (number + 1) * UInt64(geometry.recordSize) else { return }
        try writeStream(mirror, at: number * UInt64(geometry.recordSize), bytes: data)
    }

    /// Writes bytes into the allocated clusters of a nonresident stream.
    func writeStream(_ attribute: NTFSAttribute, at offset: UInt64, bytes: [UInt8]) throws {
        try beginChanges()
        guard attribute.resident == nil else { throw NTFSError("Resident stream written as nonresident") }
        var position = offset, cursor = 0
        let cluster = UInt64(geometry.clusterSize)
        for run in attribute.runs where cursor < bytes.count {
            let start = run.vcn * cluster, end = (run.vcn + run.length) * cluster
            if position >= end { continue }
            guard position >= start, let lcn = run.lcn else { throw NTFSError("Write into an unallocated stream range") }
            let take = Int(min(end - position, UInt64(bytes.count - cursor)))
            try storage.write(at: lcn * cluster + (position - start), bytes: Array(bytes[cursor..<(cursor + take)]))
            cursor += take
            position += UInt64(take)
        }
        guard cursor == bytes.count else { throw NTFSError("Write beyond the allocated stream") }
    }

    private func setVolumeDirty(_ dirty: Bool) throws {
        var record = try loadRecord(3)
        guard let index = record.index(of: NTFSType.volumeInformation) else { throw NTFSError("Missing volume information") }
        var attribute = record.attributes[index]
        let valueOffset = Int(attribute.get16(20))
        var flags = attribute.get16(valueOffset + 10)
        flags = dirty ? flags | 1 : flags & ~1
        attribute.put16(flags, at: valueOffset + 10)
        record.attributes[index] = attribute
        try storeRecord(record)
    }

    // MARK: Allocation

    private func writeBitmapChanges(_ bitmap: BitmapStream, stream: NTFSAttribute, residentIn record: UInt64? = nil) throws {
        let dirty = bitmap.takeDirty()
        guard !dirty.isEmpty else { return }
        if stream.resident != nil, let record {
            var image = try loadRecord(record)
            guard let index = image.index(of: NTFSType.bitmap) else { throw NTFSError("Missing bitmap attribute") }
            let old = image.attributes[index]
            image.attributes[index] = AttributeRecord.resident(type: NTFSType.bitmap, value: Array(bitmap.bits[0..<Int(stream.size)]),
                                                               identifier: AttributeRecord.identifier(old))
            try storeRecord(image)
            return
        }
        for range in dirty.rangeView {
            let start = range.lowerBound / 512 * 512, end = min((range.upperBound + 511) / 512 * 512, bitmap.bits.count)
            try writeStream(stream, at: UInt64(start), bytes: Array(bitmap.bits[start..<end]))
        }
    }

    private func flushClusterBitmap() throws {
        try writeBitmapChanges(clusterBitmap, stream: try volume.record(6).attribute(NTFSType.data))
        volume.freeClusterCache = nil
    }

    private func flushRecordBitmap() throws {
        try writeBitmapChanges(recordBitmap, stream: try volume.record(0).attribute(NTFSType.bitmap), residentIn: 0)
    }

    var freeClusters: UInt64 { clusterBitmap.freeCount }

    /// Allocates `count` clusters, as few runs as possible, preferring space outside the MFT zone.
    func allocateClusters(_ count: UInt64, near: UInt64? = nil) throws -> [NTFSRun] {
        guard count > 0 else { return [] }
        let total = clusterBitmap.count
        let zoneStart = geometry.mftCluster, zoneEnd = min(total, geometry.mftCluster + total / 8)
        var pieces = [NTFSRun](), remaining = count, vcn: UInt64 = 0
        func take(_ start: UInt64, _ length: UInt64) {
            clusterBitmap.set(start, length, true)
            pieces.append(NTFSRun(vcn: vcn, length: length, lcn: start))
            vcn += length
            remaining -= length
        }
        // One contiguous run if possible: after the hint, then before it, then inside the MFT zone.
        let searches: [(UInt64, UInt64)] = [(near ?? allocationHint, total), (zoneEnd, near ?? allocationHint), (0, zoneStart), (zoneStart, zoneEnd)]
        for (from, to) in searches where from < to {
            if let run = clusterBitmap.freeRun(atLeast: remaining, from: from, below: to), run.1 >= remaining {
                take(run.0, remaining)
                allocationHint = run.0 + count
                try flushClusterBitmap()
                return pieces
            }
        }
        // Fragmented: largest runs first.
        guard freeClusters >= count else { throw NTFSError("There is not enough free space on the NTFS volume.", code: ENOSPC) }
        while remaining > 0 {
            guard let run = clusterBitmap.freeRun(atLeast: remaining, from: 0, below: total) else {
                for piece in pieces { clusterBitmap.set(piece.lcn!, piece.length, false) }
                throw NTFSError("There is not enough free space on the NTFS volume.", code: ENOSPC)
            }
            take(run.0, min(run.1, remaining))
        }
        try flushClusterBitmap()
        return pieces
    }

    private func releaseClusters(_ runs: [NTFSRun]) {
        for run in runs { if let lcn = run.lcn { clusterBitmap.set(lcn, run.length, false) } }
    }

    /// Takes a free MFT record (24 and above), growing the MFT when necessary.
    private func allocateRecord() throws -> RecordImage {
        while true {
            let count = volume.recordCount
            var number: UInt64 = 24
            while number < count, number < recordBitmap.count, recordBitmap.isSet(number) { number += 1 }
            if number < count, number < recordBitmap.count, !pendingRecordFrees.contains(number) {
                recordBitmap.set(number, 1, true)
                try flushRecordBitmap()
                var sequence: UInt16 = 1
                if let old = try? loadRecord(number) {
                    guard !old.inUse else { throw NTFSError("MFT bitmap and record state disagree", code: EIO) }
                    sequence = old.sequence == 0 || old.sequence == 0xffff ? 1 : old.sequence &+ 1
                    if sequence == 0 { sequence = 1 }
                }
                return RecordImage(blank: number, size: geometry.recordSize, sequence: sequence)
            }
            try growMFT()
        }
    }

    /// Adds clusters to $MFT (next to its last run when possible) and extends its bitmap.
    private func growMFT() throws {
        let recordsPerCluster = max(1, geometry.clusterSize / geometry.recordSize)
        let growthRecords = max(64, Int(volume.recordCount / 8))
        let clusters = UInt64(max(1, (growthRecords * geometry.recordSize + geometry.clusterSize - 1) / geometry.clusterSize))
        let mft = volume.mft
        let lastRun = mft.runs.last!
        var added = try allocateClusters(clusters, near: lastRun.lcn! + lastRun.length)
        let oldClusters = mft.runs.reduce(UInt64(0)) { $0 + $1.length }
        added = added.map { NTFSRun(vcn: $0.vcn + oldClusters, length: $0.length, lcn: $0.lcn) }
        var runs = mft.runs
        for run in added {
            if let previous = runs.last, previous.lcn! + previous.length == run.lcn! {
                runs[runs.count - 1] = NTFSRun(vcn: previous.vcn, length: previous.length + run.length, lcn: previous.lcn)
            } else { runs.append(run) }
        }
        let newRecords = (oldClusters + clusters) * UInt64(geometry.clusterSize) / UInt64(geometry.recordSize)
        let firstNew = volume.recordCount
        // Format the new records as free before they become reachable.
        try beginChanges()
        for run in added {
            var blank = [UInt8]()
            for i in 0..<(Int(run.length) * recordsPerCluster) {
                let number = firstNew + UInt64(run.vcn - oldClusters) * UInt64(recordsPerCluster) + UInt64(i)
                var image = RecordImage(blank: number, size: geometry.recordSize, sequence: 0)
                image.flags = 0
                blank += try image.encoded()
            }
            if geometry.clusterSize < geometry.recordSize { continue }
            try storage.write(at: run.lcn! * UInt64(geometry.clusterSize), bytes: blank)
        }
        var record0 = try loadRecord(0)
        guard let dataIndex = record0.index(of: NTFSType.data) else { throw NTFSError("Missing $MFT data") }
        let dataID = AttributeRecord.identifier(record0.attributes[dataIndex])
        let size = newRecords * UInt64(geometry.recordSize)
        record0.attributes[dataIndex] = AttributeRecord.nonresident(type: NTFSType.data, runs: runs, size: size, initialized: size,
                                                                    identifier: dataID, clusterSize: geometry.clusterSize)
        // Extend the MFT bitmap (bits for the new records start cleared).
        let bitmapBytes = UInt64(align8(Int((newRecords + 7) / 8)))
        guard let bitmapIndex = record0.index(of: NTFSType.bitmap) else { throw NTFSError("Missing $MFT bitmap") }
        let bitmapID = AttributeRecord.identifier(record0.attributes[bitmapIndex])
        var bits = recordBitmap.bits + [UInt8](repeating: 0, count: max(0, Int(bitmapBytes) - recordBitmap.bits.count))
        bits = Array(bits[0..<Int(bitmapBytes)])
        let oldBitmap = try NTFSRawRecord(number: 0, bytes: record0.encoded(), geometry: geometry).extents.first { $0.type == NTFSType.bitmap }!
        if oldBitmap.resident != nil && bitmapBytes <= 256 {
            record0.attributes[bitmapIndex] = AttributeRecord.resident(type: NTFSType.bitmap, value: bits, identifier: bitmapID)
        } else {
            var bitmapRuns = oldBitmap.runs
            let have = bitmapRuns.reduce(UInt64(0)) { $0 + $1.length } * UInt64(geometry.clusterSize)
            if have < bitmapBytes {
                let more = (bitmapBytes - have + UInt64(geometry.clusterSize) - 1) / UInt64(geometry.clusterSize)
                let start = bitmapRuns.reduce(UInt64(0)) { $0 + $1.length }
                bitmapRuns += try allocateClusters(more).map { NTFSRun(vcn: $0.vcn + start, length: $0.length, lcn: $0.lcn) }
                try beginChanges()
                for run in bitmapRuns { try storage.write(at: run.lcn! * UInt64(geometry.clusterSize), bytes: [UInt8](repeating: 0, count: Int(run.length) * geometry.clusterSize)) }
            }
            record0.attributes[bitmapIndex] = AttributeRecord.nonresident(type: NTFSType.bitmap, runs: bitmapRuns, size: bitmapBytes, initialized: bitmapBytes,
                                                                          identifier: bitmapID, clusterSize: geometry.clusterSize)
        }
        recordBitmap = BitmapStream(bytes: bits, count: newRecords)
        try storeRecord(record0)
        let updated = try NTFSRawRecord(number: 0, bytes: record0.encoded(), geometry: geometry)
        volume.replaceMFT(try NTFSAttribute.merge(updated.extents.filter { $0.type == NTFSType.data && $0.name.isEmpty }, geometry: geometry))
        volume.invalidate(0)
        let stream = try volume.record(0).attribute(NTFSType.bitmap)
        if stream.resident == nil { try writeStream(stream, at: 0, bytes: bits) }
    }

    // MARK: Directories

    private func directoryState(_ number: UInt64) throws -> DirectoryState {
        if let state = directories[number] { return state }
        let record = try volume.record(number)
        guard record.directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
        let items = try volume.indexItems(in: record)
        let state = DirectoryState(number: number, entries: items.map {
            IndexEntryBody.fileName(reference: $0.entry!.reference, key: $0.key, upcase: volume.uppercase)
        })
        directories[number] = state
        return state
    }

    private func position(of body: IndexEntryBody, in state: DirectoryState) -> Int {
        var low = 0, high = state.entries.count
        while low < high {
            let mid = (low + high) / 2
            if compareEntries(state.entries[mid], body, .fileName(upcase: volume.uppercase)) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Entries of `state` whose folded name equals `name`, as indices.
    private func matches(_ name: String, in state: DirectoryState) -> [Int] {
        let folded = volume.upcase(Array(name.utf16))
        var low = 0, high = state.entries.count
        while low < high {
            let mid = (low + high) / 2
            if compareUnits(state.entries[mid].sortKey, folded) < 0 { low = mid + 1 } else { high = mid }
        }
        var result = [Int]()
        while low < state.entries.count, state.entries[low].sortKey == folded { result.append(low); low += 1 }
        return result
    }

    struct Located {
        let parent: UInt64
        let reference: UInt64
        let name: String
        let directory: Bool
    }

    /// Resolves a path through the in-memory directory states (they include uncommitted changes).
    func locate(_ path: String) throws -> Located {
        var parent: UInt64 = 5, reference = try volume.record(5).reference, name = "/", directory = true
        for component in path.split(separator: "/") {
            guard component != ".", component != ".." else { throw NTFSError("Relative path components are not accepted", code: EINVAL) }
            guard directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
            let state = try directoryState(reference & 0x0000ffffffffffff)
            let found = matches(String(component), in: state).filter { state.entries[$0].bytes[16 + 65] != 2 }
            let exact = found.first { state.entries[$0].tieKey == Array(component.utf16) }
            guard let index = exact ?? (found.count == 1 ? found[0] : nil) else {
                throw NTFSError(found.isEmpty ? "File not found" : "Ambiguous filename", code: found.isEmpty ? ENOENT : EIO)
            }
            let entry = state.entries[index]
            parent = state.number
            reference = entry.bytes.get64(0)
            name = String(utf16CodeUnits: entry.tieKey, count: entry.tieKey.count)
            directory = entry.bytes.get32(16 + 56) & 0x10000000 != 0
        }
        return Located(parent: parent, reference: reference, name: name, directory: directory)
    }

    private func split(_ path: String) throws -> (String, String) {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.isEmpty else { throw NTFSError("Invalid path", code: EINVAL) }
        guard name.utf16.count <= 255 else { throw NTFSError("Name is too long", code: ENAMETOOLONG) }
        guard !name.utf16.contains(where: { $0 < 0x20 || "\"*/:<>?\\|".utf16.contains($0) }) else {
            throw NTFSError("Name contains characters Windows does not allow", code: EINVAL)
        }
        return ("/" + parts.dropLast().joined(separator: "/"), name)
    }

    /// A $FILE_NAME value. New names use the POSIX namespace (0), like other non-Windows writers;
    /// a Win32-only name without a matching DOS name is reported as an error by checkers.
    static func fileNameKey(parent: UInt64, name: String, time: UInt64, size: UInt64, allocated: UInt64,
                            attributes: UInt32, namespace: UInt8) -> [UInt8] {
        let encoded = utf16LE(name)
        var key = [UInt8](repeating: 0, count: 66 + encoded.count)
        key.put64(parent, at: 0)
        for offset in [8, 16, 24, 32] { key.put64(time, at: offset) }
        key.put64(allocated, at: 40)
        key.put64(size, at: 48)
        key.put32(attributes, at: 56)
        key[64] = UInt8(encoded.count / 2)
        key[65] = namespace
        key.replaceSubrange(66..<key.count, with: encoded)
        return key
    }

    static func standardInformation(time: UInt64, attributes: UInt32, securityID: UInt32) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 72)
        for offset in [0, 8, 16, 24] { value.put64(time, at: offset) }
        value.put32(attributes, at: 32)
        value.put32(securityID, at: 52)
        return value
    }

    /// Adds a name to a folder index (used by format for the system files).
    func addEntry(key: [UInt8], reference: UInt64, to parent: UInt64) throws {
        try insertName(key, reference: reference, into: parent)
    }

    private func insertName(_ key: [UInt8], reference: UInt64, into parent: UInt64) throws {
        let state = try directoryState(parent)
        let body = IndexEntryBody.fileName(reference: reference, key: key, upcase: volume.uppercase)
        guard matches(String(utf16CodeUnits: body.tieKey, count: body.tieKey.count), in: state).isEmpty else {
            throw NTFSError("A file or folder with this name already exists", code: EEXIST)
        }
        state.entries.insert(body, at: position(of: body, in: state))
        state.dirty = true
    }

    // MARK: Creating

    /// Creates a file whose clusters are allocated up front. Data is written with `write` and
    /// becomes valid with `finish`.
    func createFile(_ path: String, size: UInt64, securityDescriptor: [UInt8]? = nil) throws -> NTFSFileHandle {
        let (folder, name) = try split(path)
        let parent = try locate(folder)
        guard parent.directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
        let parentState = try directoryState(parent.reference & 0x0000ffffffffffff)
        guard matches(name, in: parentState).isEmpty else { throw NTFSError("A file or folder with this name already exists", code: EEXIST) }
        let descriptor = try securityDescriptor ?? WindowsSecurity.inherit(parent: descriptor(ofReference: parent.reference), directory: false)
        let securityID = try securityStore().identifier(for: descriptor)
        let time = ntfsNow()
        let cluster = UInt64(geometry.clusterSize)
        let residentLimit = geometry.recordSize - 400
        var runs = [NTFSRun](), allocated: UInt64 = 0
        let resident = size <= UInt64(residentLimit)
        // Clusters first: a full volume must not leave a reserved MFT record behind.
        if !resident {
            runs = try allocateClusters((size + cluster - 1) / cluster)
            allocated = runs.reduce(0) { $0 + $1.length } * cluster
        }
        var record: RecordImage
        do { record = try allocateRecord() } catch {
            releaseClusters(runs)
            try? flushClusterBitmap()
            throw error
        }
        record.flags = 1
        record.links = 1
        let si = Self.standardInformation(time: time, attributes: 0x20, securityID: securityID)
        record.set(AttributeRecord.resident(type: NTFSType.standardInformation, value: si, identifier: record.takeIdentifier()))
        let key = Self.fileNameKey(parent: parent.reference, name: name, time: time, size: size, allocated: resident ? align8Size(size) : allocated,
                                   attributes: 0x20, namespace: 0)
        record.set(AttributeRecord.resident(type: NTFSType.fileName, value: key, identifier: record.takeIdentifier(), indexed: true))
        if resident {
            record.set(AttributeRecord.resident(type: NTFSType.data, value: [UInt8](repeating: 0, count: Int(size)), identifier: record.takeIdentifier()))
        } else {
            record.set(AttributeRecord.nonresident(type: NTFSType.data, runs: runs, size: size, initialized: 0,
                                                   identifier: record.takeIdentifier(), clusterSize: geometry.clusterSize))
        }
        var extensions = [UInt64]()
        do {
            if record.usedSize > geometry.recordSize {
                // The cluster map does not fit: move $DATA into extension records listed by an
                // attribute list in the base record.
                record.remove(type: NTFSType.data)
                extensions = try placeExtents(of: runs, size: size, initialized: 0, base: &record)
            }
            try storeRecord(record)
        } catch {
            releaseClusters(runs)
            recordBitmap.set(record.number, 1, false)
            for number in extensions {
                if var ext = try? loadRecord(number) { ext.flags = 0; try? storeRecord(ext) }
                recordBitmap.set(number, 1, false)
            }
            try? flushRecordBitmap()
            try? flushClusterBitmap()
            throw error
        }
        try insertName(key, reference: record.reference, into: parent.reference & 0x0000ffffffffffff)
        return NTFSFileHandle(number: record.number, size: size, runs: runs, resident: resident)
    }

    private func align8Size(_ size: UInt64) -> UInt64 { (size + 7) & ~7 }

    /// Splits a stream's runs into extents that each fill one extension record, writes those
    /// records, and puts an attribute list naming every attribute into the base record.
    private func placeExtents(of runs: [NTFSRun], size: UInt64, initialized: UInt64, base: inout RecordImage) throws -> [UInt64] {
        let total = runs.reduce(UInt64(0)) { $0 + $1.length }
        var created = [UInt64](), listed = [(type: UInt32, lowestVCN: UInt64, segment: UInt64, id: UInt16)]()
        var remaining = runs[...]
        while !remaining.isEmpty {
            var ext = try allocateRecord()
            created.append(ext.number)
            ext.flags = 1
            ext.links = 0
            ext.baseReference = base.reference
            let room = geometry.recordSize - ext.usedSize
            var take = 1
            while take < remaining.count {
                let candidate = AttributeRecord.extent(type: NTFSType.data, runs: Array(remaining.prefix(take + 1)), size: size,
                                                       initialized: initialized, identifier: 0, clusterSize: geometry.clusterSize, totalClusters: total)
                if candidate.count > room { break }
                take += 1
            }
            let id = ext.takeIdentifier()
            let piece = Array(remaining.prefix(take))
            ext.set(AttributeRecord.extent(type: NTFSType.data, runs: piece, size: size, initialized: initialized, identifier: id,
                                           clusterSize: geometry.clusterSize, totalClusters: total))
            try storeRecord(ext)
            listed.append((NTFSType.data, piece[0].vcn, ext.reference, id))
            remaining = remaining.dropFirst(take)
        }
        try writeAttributeList(&base, extra: listed)
        guard base.usedSize <= geometry.recordSize else { throw NTFSError("The free space is too fragmented for this file", code: ENOSPC) }
        return created
    }

    /// (Re)writes the base record's attribute list: its own attributes plus `extra` entries for
    /// attributes stored in extension records.
    private func writeAttributeList(_ base: inout RecordImage, extra: [(type: UInt32, lowestVCN: UInt64, segment: UInt64, id: UInt16)]) throws {
        let listID = base.attributes.first { AttributeRecord.type($0) == NTFSType.attributeList }.map(AttributeRecord.identifier) ?? base.takeIdentifier()
        base.remove(type: NTFSType.attributeList)
        var entries = [(type: UInt32, name: String, lowestVCN: UInt64, segment: UInt64, id: UInt16)]()
        for attribute in base.attributes {
            let lowest = AttributeRecord.isResident(attribute) ? 0 : attribute.get64(16)
            entries.append((AttributeRecord.type(attribute), AttributeRecord.name(attribute), lowest, base.reference, AttributeRecord.identifier(attribute)))
        }
        entries += extra.map { ($0.type, "", $0.lowestVCN, $0.segment, $0.id) }
        entries.sort { ($0.type, $0.lowestVCN) < ($1.type, $1.lowestVCN) }
        var data = [UInt8]()
        for entry in entries {
            let name = utf16LE(entry.name)
            var item = [UInt8](repeating: 0, count: align8(26 + name.count))
            item.put32(entry.type, at: 0)
            item.put16(UInt16(item.count), at: 4)
            item[6] = UInt8(name.count / 2)
            item[7] = 26
            item.put64(entry.lowestVCN, at: 8)
            item.put64(entry.segment, at: 16)
            item.put16(entry.id, at: 24)
            item.replaceSubrange(26..<(26 + name.count), with: name)
            data += item
        }
        base.set(AttributeRecord.resident(type: NTFSType.attributeList, value: data, identifier: listID))
    }

    /// Entries of the base record's attribute list that live in extension records.
    private func extensionEntries(of base: RecordImage) throws -> [(type: UInt32, lowestVCN: UInt64, segment: UInt64, id: UInt16)] {
        guard let index = base.index(of: NTFSType.attributeList) else { return [] }
        let attribute = base.attributes[index]
        guard AttributeRecord.isResident(attribute) else { throw NTFSError("Nonresident attribute lists are not rewritten", code: ENOTSUP) }
        return try NTFSAttributeListEntry.parse(AttributeRecord.value(attribute))
            .filter { $0.segment & 0x0000ffffffffffff != base.number }
            .map { ($0.type, $0.lowestVCN, $0.segment, $0.identifier) }
    }

    private func firstExtentRecord(of base: RecordImage) throws -> UInt64? {
        try extensionEntries(of: base).first { $0.type == NTFSType.data && $0.lowestVCN == 0 }.map { $0.segment & 0x0000ffffffffffff }
    }



    func write(_ handle: NTFSFileHandle, at offset: UInt64, bytes: [UInt8]) throws {
        guard offset <= handle.size, UInt64(bytes.count) <= handle.size - offset else { throw NTFSError("Write beyond the file size", code: EINVAL) }
        if handle.resident {
            var record = try loadRecord(handle.number)
            guard let index = record.index(of: NTFSType.data) else { throw NTFSError("Missing file data") }
            var value = AttributeRecord.value(record.attributes[index])
            value.replaceSubrange(Int(offset)..<(Int(offset) + bytes.count), with: bytes)
            record.attributes[index] = AttributeRecord.resident(type: NTFSType.data, value: value, identifier: AttributeRecord.identifier(record.attributes[index]))
            try storeRecord(record)
            return
        }
        let stream = try volume.record(handle.number).attribute(NTFSType.data)
        let cluster = UInt64(geometry.clusterSize)
        // Pad the final partial cluster so whole sectors are written.
        var data = bytes
        if offset + UInt64(bytes.count) == handle.size, handle.size % cluster != 0 {
            data += [UInt8](repeating: 0, count: Int(cluster - handle.size % cluster))
        }
        try writeStream(stream, at: offset, bytes: data)
    }

    /// Marks the written data valid (initialized size = size).
    func finish(_ handle: NTFSFileHandle) throws {
        guard !handle.resident else { return }
        var record = try loadRecord(handle.number)
        if record.index(of: NTFSType.attributeList) != nil, record.index(of: NTFSType.data) == nil {
            guard let segment = try firstExtentRecord(of: record) else { throw NTFSError("Missing file data") }
            record = try loadRecord(segment)
        }
        guard let index = record.index(of: NTFSType.data) else { throw NTFSError("Missing file data") }
        var attribute = record.attributes[index]
        attribute.put64(handle.size, at: 56)
        record.attributes[index] = attribute
        try storeRecord(record)
    }

    func createDirectory(_ path: String, securityDescriptor: [UInt8]? = nil) throws {
        let (folder, name) = try split(path)
        let parent = try locate(folder)
        guard parent.directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
        let parentState = try directoryState(parent.reference & 0x0000ffffffffffff)
        guard matches(name, in: parentState).isEmpty else { throw NTFSError("A file or folder with this name already exists", code: EEXIST) }
        let descriptor = try securityDescriptor ?? WindowsSecurity.inherit(parent: descriptor(ofReference: parent.reference), directory: true)
        let securityID = try securityStore().identifier(for: descriptor)
        var record = try allocateRecord()
        let time = ntfsNow()
        record.flags = 3
        record.links = 1
        let attributes: UInt32 = 0x10000000
        record.set(AttributeRecord.resident(type: NTFSType.standardInformation,
                                            value: Self.standardInformation(time: time, attributes: attributes, securityID: securityID),
                                            identifier: record.takeIdentifier()))
        let key = Self.fileNameKey(parent: parent.reference, name: name, time: time, size: 0, allocated: 0, attributes: attributes, namespace: 0)
        record.set(AttributeRecord.resident(type: NTFSType.fileName, value: key, identifier: record.takeIdentifier(), indexed: true))
        record.set(AttributeRecord.resident(type: NTFSType.indexRoot, name: "$I30",
                                            value: indexRoot(type: NTFSType.fileName, collation: 1, entries: IndexBuilder.end(child: nil), large: false),
                                            identifier: record.takeIdentifier()))
        do { try storeRecord(record) } catch { recordBitmap.set(record.number, 1, false); throw error }
        try insertName(key, reference: record.reference, into: parent.reference & 0x0000ffffffffffff)
        directories[record.number] = DirectoryState(number: record.number, entries: [])
    }

    func indexRoot(type: UInt32, collation: UInt32, entries: [UInt8], large: Bool) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 32)
        value.put32(type, at: 0)
        value.put32(collation, at: 4)
        value.put32(UInt32(geometry.indexSize), at: 8)
        value[12] = UInt8(geometry.indexSize >= geometry.clusterSize ? geometry.indexSize / geometry.clusterSize : geometry.indexSize / 512)
        value.put32(16, at: 16)
        value.put32(UInt32(16 + entries.count), at: 20)
        value.put32(UInt32(16 + entries.count), at: 24)
        value[28] = large ? 1 : 0
        return value + entries
    }

    // MARK: Removing and renaming

    func remove(_ path: String, directory: Bool) throws {
        let item = try locate(path)
        guard item.parent != item.reference & 0x0000ffffffffffff, path.split(separator: "/").count > 0 else { throw NTFSError("The root directory is protected", code: EPERM) }
        let number = item.reference & 0x0000ffffffffffff
        guard number >= 16 else { throw NTFSError("System files cannot be removed", code: EPERM) }
        let record = try volume.record(reference: item.reference)
        guard record.directory == directory else { throw NTFSError(directory ? "Not a directory" : "Is a directory", code: directory ? ENOTDIR : EISDIR) }
        if directory {
            let state = try directoryState(number)
            guard state.entries.isEmpty else { throw NTFSError("The folder is not empty", code: ENOTEMPTY) }
        }
        guard record.reparseTag == nil else { throw NTFSError("Links and reparse points are not removed", code: EPERM) }
        let names = record.attributes.filter { $0.type == NTFSType.fileName }.compactMap { $0.resident }
        let otherParents = names.filter { $0.get64(0) & 0x0000ffffffffffff != item.parent }
        guard otherParents.isEmpty else { throw NTFSError("Files with hard links in other folders are not removed", code: ENOTSUP) }
        // Unlink every name of this file in the folder (a Windows name and its DOS short name).
        let state = try directoryState(item.parent)
        state.entries.removeAll { $0.bytes.get64(0) & 0x0000ffffffffffff == number }
        state.dirty = true
        directories.removeValue(forKey: number)
        pendingRecordFrees.append(number)
        for attribute in record.attributes where attribute.resident == nil { pendingClusterFrees += attribute.runs }
        let raw = try NTFSRawRecord(number: number, bytes: loadRecord(number).encoded(), geometry: geometry)
        if let list = raw.extents.first(where: { $0.type == NTFSType.attributeList }) {
            if list.resident == nil { pendingClusterFrees += list.runs }
            let data = try list.resident ?? Self.readStream(list, volume: volume, bytes: list.size)
            for entry in try NTFSAttributeListEntry.parse(data) {
                let segment = entry.segment & 0x0000ffffffffffff
                if segment != number, !pendingRecordFrees.contains(segment) { pendingRecordFrees.append(segment) }
            }
        }
    }

    func rename(_ from: String, to destination: String) throws {
        let item = try locate(from)
        let number = item.reference & 0x0000ffffffffffff
        guard number >= 16 else { throw NTFSError("System files cannot be renamed", code: EPERM) }
        let (folder, name) = try split(destination)
        let target = try locate(folder)
        guard target.directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
        // A folder cannot move into itself.
        var cursor = target.reference & 0x0000ffffffffffff
        while cursor != 5 {
            guard cursor != number else { throw NTFSError("Cannot move a folder into itself", code: EINVAL) }
            let parentRecord = try volume.record(cursor)
            guard let fileName = parentRecord.attributes.first(where: { $0.type == NTFSType.fileName })?.resident else { break }
            cursor = fileName.get64(0) & 0x0000ffffffffffff
        }
        let targetState = try directoryState(target.reference & 0x0000ffffffffffff)
        let sourceState = try directoryState(item.parent)
        let clash = matches(name, in: targetState).filter { targetState.entries[$0].bytes.get64(0) & 0x0000ffffffffffff != number }
        guard clash.isEmpty else { throw NTFSError("A file or folder with this name already exists", code: EEXIST) }
        var record = try loadRecord(number)
        guard record.baseReference == 0 else { throw NTFSError("Invalid file record") }
        guard let old = record.attributes.first(where: { AttributeRecord.type($0) == NTFSType.fileName && AttributeRecord.value($0).get64(0) & 0x0000ffffffffffff == item.parent }) else {
            throw NTFSError("The file name was not found in its record", code: EIO)
        }
        var key = AttributeRecord.value(old)
        let encoded = utf16LE(name)
        key = Array(key[0..<66]) + encoded
        key.put64(target.reference, at: 0)
        key[64] = UInt8(encoded.count / 2)
        key[65] = 0
        // Like Windows: the record change time moves to now and the new name copies all four
        // $STANDARD_INFORMATION times (checkers compare them).
        if let siIndex = record.index(of: NTFSType.standardInformation) {
            var si = AttributeRecord.value(record.attributes[siIndex])
            si.put64(ntfsNow(), at: 16)
            record.attributes[siIndex] = AttributeRecord.resident(type: NTFSType.standardInformation, value: si,
                                                                  identifier: AttributeRecord.identifier(record.attributes[siIndex]))
            for offset in [0, 8, 16, 24] { key.put64(si.get64(offset), at: 8 + offset) }
        }
        // Drop the old names in the source folder (including a DOS short name) and add the new one.
        record.attributes.removeAll { AttributeRecord.type($0) == NTFSType.fileName && AttributeRecord.value($0).get64(0) & 0x0000ffffffffffff == item.parent }
        record.set(AttributeRecord.resident(type: NTFSType.fileName, value: key, identifier: record.takeIdentifier(), indexed: true))
        record.links = UInt16(record.attributes.filter { AttributeRecord.type($0) == NTFSType.fileName && AttributeRecord.value($0)[65] != 2 }.count)
        if record.index(of: NTFSType.attributeList) != nil { try writeAttributeList(&record, extra: try extensionEntries(of: record)) }
        try storeRecord(record)
        sourceState.entries.removeAll { $0.bytes.get64(0) & 0x0000ffffffffffff == number }
        sourceState.dirty = true
        let body = IndexEntryBody.fileName(reference: record.reference, key: key, upcase: volume.uppercase)
        targetState.entries.insert(body, at: position(of: body, in: targetState))
        targetState.dirty = true
    }

    // MARK: Listing (includes uncommitted changes)

    struct ListedEntry {
        let name: String
        let reference: UInt64
        let key: [UInt8]
    }

    private func listed(_ body: IndexEntryBody) -> ListedEntry {
        ListedEntry(name: String(utf16CodeUnits: body.tieKey, count: body.tieKey.count), reference: body.bytes.get64(0),
                    key: Array(body.bytes[16..<(16 + Int(body.bytes.get16(10)))]))
    }

    func listing(_ path: String) throws -> [ListedEntry] {
        let folder = try locate(path)
        guard folder.directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
        let state = try directoryState(folder.reference & 0x0000ffffffffffff)
        return state.entries.filter { $0.bytes[16 + 65] != 2 && $0.tieKey != [0x2e] }.map(listed)
    }

    func lookup(_ path: String) throws -> ListedEntry? {
        let parts = path.split(separator: "/")
        guard let last = parts.last else { return nil }
        let folder: Located
        do { folder = try locate("/" + parts.dropLast().joined(separator: "/")) }
        catch let failure as NTFSError where failure.code == ENOENT || failure.code == ENOTDIR { return nil }
        guard folder.directory else { return nil }
        let state = try directoryState(folder.reference & 0x0000ffffffffffff)
        let found = matches(String(last), in: state).filter { state.entries[$0].bytes[16 + 65] != 2 }
        let exact = found.first { state.entries[$0].tieKey == Array(last.utf16) }
        guard let index = exact ?? found.first else { return nil }
        return listed(state.entries[index])
    }

    // MARK: Security

    /// Group SID found in descriptors that an earlier engine wrote without explicit security.
    static let foreignGroup = WindowsSecurity.sid(5, [21, 1987932187, 4155540637, 3944497785, 513])

    /// Re-derives security for objects that still carry a writer default (owner Everyone with the
    /// foreign group, or the parent's descriptor copied verbatim), recursing into folders.
    func repairSecurity(_ path: String) throws -> (checked: UInt32, fixed: UInt32) {
        var checked: UInt32 = 0, fixed: UInt32 = 0
        func identifier(_ reference: UInt64) throws -> UInt32 {
            let record = try volume.record(reference: reference)
            return record.attributes.first(where: { $0.type == NTFSType.standardInformation })?.resident.flatMap { $0.count >= 56 ? $0.get32(52) : nil } ?? 0
        }
        func visit(_ path: String) throws {
            checked += 1
            guard checked <= 50000 else { throw NTFSError("Too many objects", code: E2BIG) }
            let item = try locate(path)
            let record = try volume.record(reference: item.reference)
            if record.reparseTag != nil { return }
            let parentPath = "/" + path.split(separator: "/").dropLast().joined(separator: "/")
            let parent = try locate(parentPath)
            let parentDescriptor = try descriptor(ofReference: parent.reference)
            let current = try descriptor(ofReference: item.reference)
            let id = try identifier(item.reference), parentID = try identifier(parent.reference)
            var engineDefault = id >= 0x100 && id == parentID
            if let current, let parsed = try? WindowsSecurity.parse(current),
               parsed.owner == WindowsSecurity.everyone && parsed.group == Self.foreignGroup { engineDefault = true }
            if current == nil { engineDefault = true }
            if engineDefault {
                let wanted = WindowsSecurity.inherit(parent: parentDescriptor, directory: item.directory)
                if wanted != current {
                    try setSecurityDescriptor(path, wanted)
                    fixed += 1
                }
            }
            if item.directory {
                for child in try listing(path) { try visit(path == "/" ? "/" + child.name : path + "/" + child.name) }
            }
        }
        try visit(path)
        return (checked, fixed)
    }

    func securityStore() throws -> SecurityStore {
        if let security { return security }
        let store = try SecurityStore(writer: self)
        security = store
        return store
    }

    func securityDescriptor(_ path: String) throws -> [UInt8]? {
        try descriptor(ofReference: locate(path).reference)
    }

    /// Security of an object, including descriptors added earlier in this session.
    func descriptor(ofReference reference: UInt64) throws -> [UInt8]? {
        let record = try volume.record(reference: reference)
        if let own = record.attributes.first(where: { $0.type == 0x50 }) {
            return try own.resident ?? Self.readStream(own, volume: volume, bytes: own.size)
        }
        guard let si = record.attributes.first(where: { $0.type == NTFSType.standardInformation })?.resident, si.count >= 56 else { return nil }
        return try securityStore().descriptor(si.get32(52))
    }

    func setSecurityDescriptor(_ path: String, _ descriptor: [UInt8]) throws {
        let item = try locate(path)
        let number = item.reference & 0x0000ffffffffffff
        let id = try securityStore().identifier(for: descriptor)
        var record = try loadRecord(number)
        guard let index = record.index(of: NTFSType.standardInformation) else { throw NTFSError("Missing standard information") }
        var value = AttributeRecord.value(record.attributes[index])
        if value.count < 72 { value += [UInt8](repeating: 0, count: 72 - value.count) }
        value.put32(id, at: 52)
        record.attributes[index] = AttributeRecord.resident(type: NTFSType.standardInformation, value: value,
                                                            identifier: AttributeRecord.identifier(record.attributes[index]))
        record.remove(type: 0x50)
        if record.index(of: NTFSType.attributeList) != nil { try writeAttributeList(&record, extra: try extensionEntries(of: record)) }
        try storeRecord(record)
    }

    // MARK: Index writing

    /// Rebuilds an index (directory $I30 or a security view) in record `number`.
    func writeIndex(record number: UInt64, name: String, type: UInt32, collation: UInt32, entries: [IndexEntryBody]) throws {
        var record = try loadRecord(number)
        guard let rootIndex = record.index(of: NTFSType.indexRoot, name: name) else { throw NTFSError("Missing index root") }
        let rootID = AttributeRecord.identifier(record.attributes[rootIndex])
        let indexSize = geometry.indexSize
        let unit = volume.indexBlockUnit()
        let usaCount = indexSize / 512 + 1
        let entriesStart = align8(0x28 + usaCount * 2)
        let blockCapacity = indexSize - entriesStart
        // Space left for the root: the record minus everything else and the root's own headers.
        var withoutRoot = record
        withoutRoot.attributes.remove(at: rootIndex)
        let rootHeaders = align8(24 + name.utf16.count * 2) + 32
        let rootCapacity = max(0, geometry.recordSize - withoutRoot.usedSize - rootHeaders - 160)
        let built = try IndexBuilder.build(entries, rootCapacity: rootCapacity, blockCapacity: blockCapacity) {
            UInt64($0) * UInt64(indexSize) / unit
        }
        let existing = try NTFSRawRecord(number: number, bytes: record.encoded(), geometry: geometry)
        let oldAllocation = existing.extents.first { $0.type == NTFSType.indexAllocation && $0.name == name }
        record.attributes[rootIndex] = AttributeRecord.resident(type: NTFSType.indexRoot, name: name,
                                                                value: indexRoot(type: type, collation: collation, entries: built.rootEntries, large: built.rootHasChildren),
                                                                identifier: rootID)
        if built.blocks.isEmpty {
            if let oldAllocation { pendingClusterFrees += oldAllocation.runs }
            record.remove(type: NTFSType.indexAllocation, name: name)
            record.remove(type: NTFSType.bitmap, name: name)
            try storeRecord(record)
            return
        }
        // Reuse the existing index allocation and extend it when more blocks are needed.
        let cluster = UInt64(geometry.clusterSize)
        var runs = oldAllocation?.runs ?? []
        let haveBytes = runs.reduce(UInt64(0)) { $0 + $1.length } * cluster
        let needBytes = UInt64(built.blocks.count * indexSize)
        if haveBytes < needBytes {
            let more = (needBytes - haveBytes + cluster - 1) / cluster
            let start = runs.reduce(UInt64(0)) { $0 + $1.length }
            runs += try allocateClusters(more).map { NTFSRun(vcn: $0.vcn + start, length: $0.length, lcn: $0.lcn) }
        }
        let allocatedBytes = runs.reduce(UInt64(0)) { $0 + $1.length } * cluster
        let streamSize = max(needBytes, allocatedBytes / UInt64(indexSize) * UInt64(indexSize))
        let allocationID = oldAllocation?.identifier ?? record.takeIdentifier()
        record.set(AttributeRecord.nonresident(type: NTFSType.indexAllocation, name: name, runs: runs, size: streamSize, initialized: streamSize,
                                               identifier: allocationID, clusterSize: geometry.clusterSize))
        var bits = [UInt8](repeating: 0, count: align8(Int((streamSize / UInt64(indexSize) + 7) / 8)))
        for block in 0..<built.blocks.count { bits[block / 8] |= 1 << (block % 8) }
        let bitmapID = record.attributes.first { AttributeRecord.type($0) == NTFSType.bitmap && AttributeRecord.name($0) == name }.map(AttributeRecord.identifier) ?? record.takeIdentifier()
        record.set(AttributeRecord.resident(type: NTFSType.bitmap, name: name, value: bits, identifier: bitmapID))
        // Blocks first, then the record that makes them reachable.
        let stream = try NTFSAttribute(Bytes(data: AttributeRecord.nonresident(type: NTFSType.indexAllocation, name: name, runs: runs, size: streamSize,
                                                                               initialized: streamSize, identifier: allocationID, clusterSize: geometry.clusterSize)), geometry: geometry)
        for (number, entriesBytes) in built.blocks.enumerated() {
            var block = [UInt8](repeating: 0, count: indexSize)
            block.replaceSubrange(0..<4, with: Array("INDX".utf8))
            block.put16(0x28, at: 4)
            block.put16(UInt16(usaCount), at: 6)
            block.put64(UInt64(number) * UInt64(indexSize) / unit, at: 16)
            block.put32(UInt32(entriesStart - 0x18), at: 0x18)
            block.put32(UInt32(entriesStart - 0x18 + entriesBytes.count), at: 0x1c)
            block.put32(UInt32(indexSize - 0x18), at: 0x20)
            block[0x24] = built.blockHasChildren[number] ? 1 : 0
            guard entriesStart + entriesBytes.count <= indexSize else { throw NTFSError("Index block overflow") }
            block.replaceSubrange(entriesStart..<(entriesStart + entriesBytes.count), with: entriesBytes)
            try applyFixups(&block)
            try writeStream(stream, at: UInt64(number * indexSize), bytes: block)
        }
        try storeRecord(record)
    }

    // MARK: Commit

    /// Writes directory and security indexes, then releases removed records and clusters, then
    /// makes everything durable.
    func flush() throws {
        for state in directories.values where state.dirty {
            try writeIndex(record: state.number, name: "$I30", type: NTFSType.fileName, collation: 1, entries: state.entries)
            state.dirty = false
        }
        try security?.commit()
        try storage.synchronize()
        for number in pendingRecordFrees {
            var record = try loadRecord(number)
            record.flags = 0
            record.sequence = record.sequence &+ 1 == 0 ? 1 : record.sequence &+ 1
            try storeRecord(record)
            recordBitmap.set(number, 1, false)
        }
        pendingRecordFrees = []
        releaseClusters(pendingClusterFrees)
        pendingClusterFrees = []
        try flushRecordBitmap()
        try flushClusterBitmap()
        try storage.synchronize()
    }

    /// Commits and clears the dirty flag.
    func close() throws {
        guard open else { return }
        try flush()
        if marked {
            try setVolumeDirty(false)
            try storage.synchronize()
        }
        open = false
    }
}

// MARK: - $Secure

/// Security descriptors stored in $Secure: the $SDS stream and the $SII / $SDH view indexes.
final class SecurityStore {
    private unowned let writer: NTFSWriter
    private var byID = [UInt32: (hash: UInt32, offset: UInt64, length: UInt32)]()
    private var added = false
    private static let blockSize: UInt64 = 256 * 1024

    init(writer: NTFSWriter) throws {
        self.writer = writer
        let volume = writer.volume
        let record = try volume.record(9)
        for item in try volume.securityIndex(record, name: "$SII") {
            let data = item
            byID[data.get32(4)] = (data.get32(0), data.get64(8), data.get32(16))
        }
    }

    static func hash(_ descriptor: [UInt8]) -> UInt32 {
        var hash: UInt32 = 0
        for i in stride(from: 0, to: descriptor.count / 4 * 4, by: 4) {
            hash = (hash >> 29 | hash << 3) &+ descriptor.get32(i)
        }
        return hash
    }

    func descriptor(_ id: UInt32) throws -> [UInt8]? {
        guard let entry = byID[id] else { return nil }
        let sds = try writer.volume.record(9).attribute(NTFSType.data, name: "$SDS")
        let data = try sds.read(storage: writer.storage, geometry: writer.geometry, at: entry.offset, count: Int(entry.length))
        guard data.count == Int(entry.length), entry.length >= 20, data.get32(4) == id else { throw NTFSError("Invalid security descriptor entry") }
        return Array(data[20...])
    }

    func identifier(for descriptor: [UInt8]) throws -> UInt32 {
        let hash = Self.hash(descriptor)
        for (id, entry) in byID where entry.hash == hash && entry.length == UInt32(descriptor.count + 20) {
            if try self.descriptor(id) == descriptor { return id }
        }
        // Append a new entry: aligned to 16, never crossing a 256 KB block, mirrored one block later.
        let id = max(0x100, (byID.keys.max() ?? 0xff) + 1)
        var end: UInt64 = 0
        for entry in byID.values { end = max(end, (entry.offset + UInt64(entry.length) + 15) & ~15) }
        var offset = end
        let length = UInt64(descriptor.count + 20)
        if offset % (2 * Self.blockSize) >= Self.blockSize { offset = (offset / (2 * Self.blockSize) + 1) * 2 * Self.blockSize }
        if offset % (2 * Self.blockSize) + length > Self.blockSize { offset = (offset / (2 * Self.blockSize) + 1) * 2 * Self.blockSize }
        var entry = [UInt8](repeating: 0, count: Int(length))
        entry.put32(hash, at: 0)
        entry.put32(id, at: 4)
        entry.put64(offset, at: 8)
        entry.put32(UInt32(length), at: 16)
        entry.replaceSubrange(20..<entry.count, with: descriptor)
        try writer.ensureSDS(capacity: offset + Self.blockSize + length)
        let sds = try writer.volume.record(9).attribute(NTFSType.data, name: "$SDS")
        try writer.writeStream(sds, at: offset, bytes: entry)
        try writer.writeStream(sds, at: offset + Self.blockSize, bytes: entry)
        byID[id] = (hash, offset, UInt32(length))
        added = true
        return id
    }

    func commit() throws {
        guard added else { return }
        func header(_ id: UInt32, _ entry: (hash: UInt32, offset: UInt64, length: UInt32)) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 20)
            data.put32(entry.hash, at: 0); data.put32(id, at: 4); data.put64(entry.offset, at: 8); data.put32(entry.length, at: 16)
            return data
        }
        var sii = byID.map { id, entry -> IndexEntryBody in
            var key = [UInt8](repeating: 0, count: 4); key.put32(id, at: 0)
            return IndexEntryBody.view(key: key, data: header(id, entry))
        }
        sii.sort { compareEntries($0, $1, .unsignedLong) < 0 }
        var sdh = byID.map { id, entry -> IndexEntryBody in
            var key = [UInt8](repeating: 0, count: 8); key.put32(entry.hash, at: 0); key.put32(id, at: 4)
            return IndexEntryBody.view(key: key, data: header(id, entry), padding: [0x49, 0, 0x49, 0])
        }
        sdh.sort { compareEntries($0, $1, .securityHash) < 0 }
        try writer.writeIndex(record: 9, name: "$SII", type: 0, collation: 0x10, entries: sii)
        try writer.writeIndex(record: 9, name: "$SDH", type: 0, collation: 0x12, entries: sdh)
        added = false
    }
}

extension NTFSWriter {
    /// Grows the $SDS stream so that `capacity` bytes are allocated and initialized.
    func ensureSDS(capacity: UInt64) throws {
        var record = try loadRecord(9)
        guard let index = record.index(of: NTFSType.data, name: "$SDS") else { throw NTFSError("Missing $SDS") }
        let raw = try NTFSAttribute(Bytes(data: record.attributes[index]), geometry: geometry)
        guard raw.lowestVCN == 0, raw.resident == nil else { throw NTFSError("Unsupported $SDS layout", code: ENOTSUP) }
        let cluster = UInt64(geometry.clusterSize)
        let have = raw.runs.reduce(UInt64(0)) { $0 + $1.length } * cluster
        guard capacity > raw.size else { return }
        var runs = raw.runs
        if have < capacity {
            let more = (capacity - have + cluster - 1) / cluster
            let start = runs.reduce(UInt64(0)) { $0 + $1.length }
            let added = try allocateClusters(more).map { NTFSRun(vcn: $0.vcn + start, length: $0.length, lcn: $0.lcn) }
            try beginChanges()
            for run in added { try storage.write(at: run.lcn! * cluster, bytes: [UInt8](repeating: 0, count: Int(run.length * cluster))) }
            runs += added
        }
        // Zero the gap between the old valid size and the new end.
        let size = capacity
        record.attributes[index] = AttributeRecord.nonresident(type: NTFSType.data, name: "$SDS", runs: runs, size: size, initialized: size,
                                                               identifier: raw.identifier, clusterSize: geometry.clusterSize)
        if raw.initializedSize < size {
            let stream = try NTFSAttribute(Bytes(data: record.attributes[index]), geometry: geometry)
            try writeStream(stream, at: raw.initializedSize, bytes: [UInt8](repeating: 0, count: Int(size - raw.initializedSize)))
        }
        try storeRecord(record)
    }
}

extension NativeNTFSVolume {
    /// The security descriptor of a file: its own $SECURITY_DESCRIPTOR, or the shared one in $Secure.
    func securityDescriptor(of record: NTFSRecord) throws -> [UInt8]? {
        if let own = record.attributes.first(where: { $0.type == 0x50 }) {
            return try own.resident ?? NTFSWriter.readStream(own, volume: self, bytes: own.size)
        }
        guard let si = record.attributes.first(where: { $0.type == NTFSType.standardInformation })?.resident, si.count >= 56 else { return nil }
        let id = si.get32(52)
        let secure = try self.record(9)
        guard let header = try securityIndex(secure, name: "$SII").first(where: { $0.count >= 20 && $0.get32(4) == id }) else { return nil }
        let sds = try secure.attribute(NTFSType.data, name: "$SDS")
        let data = try sds.read(storage: storage, geometry: geometry, at: header.get64(8), count: Int(header.get32(16)))
        guard data.count >= 20, data.get32(4) == id else { throw NTFSError("Invalid security descriptor entry") }
        return Array(data[20...])
    }

    /// Data parts of a view index ($SII), in key order.
    func securityIndex(_ record: NTFSRecord, name: String) throws -> [[UInt8]] {
        let rootAttribute = try record.attribute(NTFSType.indexRoot, name: name)
        guard let rootData = rootAttribute.resident else { throw NTFSError("Nonresident index root") }
        let allocation = record.attributes.first { $0.type == NTFSType.indexAllocation && $0.name == name }
        var output = [[UInt8]](), visited = Set<UInt64>()
        func walk(_ node: Bytes, header: Int, depth: Int) throws {
            guard depth <= 32 else { throw NTFSError("Security index is too deep") }
            let relative = Int(try node.u32(header)), used = Int(try node.u32(header + 4))
            var cursor = header + relative
            let end = header + used
            guard relative >= 16, end <= node.count else { throw NTFSError("Invalid security index bounds") }
            while cursor + 16 <= end {
                let dataOffset = Int(try node.u16(cursor)), dataLength = Int(try node.u16(cursor + 2))
                let length = Int(try node.u16(cursor + 8)), flags = try node.u16(cursor + 12)
                guard length >= 16, cursor + length <= end else { throw NTFSError("Invalid security index entry") }
                if flags & 1 != 0 {
                    guard let allocation else { throw NTFSError("Missing security index allocation") }
                    let vcn = try node.u64(cursor + length - 8)
                    guard visited.insert(vcn).inserted else { throw NTFSError("Cycle in security index") }
                    let offset = vcn * indexBlockUnit()
                    let raw = try allocation.read(storage: storage, geometry: geometry, at: offset, count: geometry.indexSize)
                    try walk(try restoreFixups(raw, signature: "INDX"), header: 24, depth: depth + 1)
                }
                if flags & 2 != 0 { return }
                guard dataOffset + dataLength <= length else { throw NTFSError("Invalid security index data") }
                output.append(try node.slice(cursor + dataOffset, dataLength))
                cursor += length
            }
        }
        try walk(Bytes(data: rootData), header: 16, depth: 0)
        return output
    }
}
