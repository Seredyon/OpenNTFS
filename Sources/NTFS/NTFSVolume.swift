import Foundation
import Darwin

struct NTFSGeometry {
    let sectorSize: Int
    let clusterSize: Int
    let recordSize: Int
    let indexSize: Int
    let volumeBytes: UInt64
    let mftCluster: UInt64
    let serial: UInt64
    var clusterCount: UInt64 { volumeBytes / UInt64(clusterSize) }

    init(storage: NTFSStorage) throws {
        let boot = Bytes(data: try storage.read(at: 0, count: 512))
        guard try boot.slice(3, 8) == Array("NTFS    ".utf8),
              try boot.u16(510) == 0xaa55 else { throw NTFSError("Not an NTFS partition", code: EINVAL) }
        let sector = Int(try boot.u16(11))
        let sectorsPerCluster = Int(try boot.u8(13))
        guard [512, 1024, 2048, 4096].contains(sector),
              sectorsPerCluster > 0, sectorsPerCluster <= 128,
              sectorsPerCluster & (sectorsPerCluster - 1) == 0 else {
            throw NTFSError("Unsupported NTFS sector or cluster size", code: ENOTSUP)
        }
        sectorSize = sector
        clusterSize = sector * sectorsPerCluster
        func structureSize(_ encoded: UInt8) throws -> Int {
            let signed = Int(Int8(bitPattern: encoded))
            guard signed != 0, signed >= -16 else { throw NTFSError("Invalid NTFS record size") }
            let size = signed < 0 ? 1 << (-signed) : signed * sector * sectorsPerCluster
            guard size >= 512, size <= 65536, size & (size - 1) == 0 else {
                throw NTFSError("Unsupported NTFS record size", code: ENOTSUP)
            }
            return size
        }
        recordSize = try structureSize(boot.u8(64))
        indexSize = try structureSize(boot.u8(68))
        volumeBytes = try checkedMultiply(boot.u64(40), UInt64(sector))
        guard volumeBytes >= UInt64(clusterSize), volumeBytes <= storage.byteCount else {
            throw NTFSError("Truncated NTFS partition")
        }
        mftCluster = try boot.u64(48)
        guard mftCluster > 0, mftCluster < volumeBytes / UInt64(clusterSize) else {
            throw NTFSError("MFT is outside the partition")
        }
        serial = try boot.u64(72)
    }
}

func restoreFixups(_ raw: [UInt8], signature: String) throws -> Bytes {
    var bytes = Bytes(data: raw)
    guard raw.count >= 512, raw.count % 512 == 0,
          try bytes.slice(0, 4) == Array(signature.utf8) else { throw NTFSError("Invalid \(signature) record") }
    let offset = Int(try bytes.u16(4)), count = Int(try bytes.u16(6))
    // The NTFS multi-sector sequence stride is 512 bytes, including on 4K media.
    guard offset >= 8, offset % 2 == 0, count == raw.count / 512 + 1,
          offset + count * 2 <= 510 else { throw NTFSError("Invalid update sequence array") }
    let sequence = try bytes.u16(offset)
    for sector in 1..<count {
        let trailer = sector * 512 - 2
        guard try bytes.u16(trailer) == sequence else { throw NTFSError("NTFS torn-write signature mismatch") }
        bytes.data[trailer] = raw[offset + sector * 2]
        bytes.data[trailer + 1] = raw[offset + sector * 2 + 1]
    }
    return bytes
}

struct NTFSRun {
    let vcn: UInt64
    let length: UInt64
    let lcn: UInt64?
}

// Attribute type codes used by the reader.
enum NTFSType {
    static let standardInformation: UInt32 = 0x10
    static let attributeList: UInt32 = 0x20
    static let fileName: UInt32 = 0x30
    static let volumeName: UInt32 = 0x60
    static let volumeInformation: UInt32 = 0x70
    static let data: UInt32 = 0x80
    static let indexRoot: UInt32 = 0x90
    static let indexAllocation: UInt32 = 0xa0
    static let bitmap: UInt32 = 0xb0
    static let reparsePoint: UInt32 = 0xc0
}

struct NTFSAttribute {
    let type: UInt32
    let name: String
    let flags: UInt16
    let identifier: UInt16
    let resident: [UInt8]?
    let runs: [NTFSRun]
    let lowestVCN: UInt64
    let highestVCN: UInt64
    let size: UInt64
    let initializedSize: UInt64
    let allocatedSize: UInt64
    /// log2 of the compression unit in clusters; 0 when the stream is not compressed.
    let compressionUnit: Int

    var compressed: Bool { flags & 0x00ff != 0 }
    var encrypted: Bool { flags & 0x4000 != 0 }

    /// Parses one attribute record. A nonresident attribute may be one extent of a longer
    /// stream (lowest VCN above zero); `NTFSAttribute.merge` joins extents into one stream.
    init(_ bytes: Bytes, geometry: NTFSGeometry) throws {
        type = try bytes.u32(0)
        flags = try bytes.u16(12)
        identifier = try bytes.u16(14)
        let nonresident = try bytes.u8(8)
        guard nonresident <= 1 else { throw NTFSError("Invalid attribute storage form") }
        let nameLength = Int(try bytes.u8(9)), nameOffset = Int(try bytes.u16(10))
        let minimum = nonresident == 0 ? 24 : 64
        guard bytes.count >= minimum, nameLength == 0 || nameOffset >= minimum else {
            throw NTFSError("Invalid attribute name offset")
        }
        name = try bytes.utf16(nameOffset, units: nameLength)
        if nonresident == 0 {
            let length = Int(try bytes.u32(16)), offset = Int(try bytes.u16(20))
            guard offset >= minimum, nameLength == 0 || nameOffset + nameLength * 2 <= offset else {
                throw NTFSError("Invalid resident attribute offset")
            }
            resident = try bytes.slice(offset, length)
            size = UInt64(length)
            initializedSize = size
            allocatedSize = size
            runs = []
            lowestVCN = 0
            highestVCN = 0
            compressionUnit = 0
            return
        }
        resident = nil
        lowestVCN = try bytes.u64(16)
        highestVCN = try bytes.u64(24)
        let unit = Int(try bytes.u16(34))
        let compressedFlag = flags & 0x00ff
        guard compressedFlag <= 1 else { throw NTFSError("Unknown NTFS compression format", code: ENOTSUP) }
        if compressedFlag == 1 {
            // NTFS only compresses with 16-cluster units on clusters of 4 KB or less.
            guard unit == 4, geometry.clusterSize <= 4096 else {
                throw NTFSError("Unsupported NTFS compression unit", code: ENOTSUP)
            }
        } else if unit != 0, lowestVCN == 0 {
            throw NTFSError("Compression unit on an uncompressed stream")
        }
        compressionUnit = compressedFlag == 1 ? unit : 0
        size = try bytes.u64(48)
        initializedSize = try bytes.u64(56)
        allocatedSize = try bytes.u64(40)
        guard initializedSize <= size, size <= UInt64(Int64.max), highestVCN >= lowestVCN || highestVCN == lowestVCN &- 1 else {
            throw NTFSError("Invalid attribute length")
        }
        let headerMinimum = compressedFlag == 1 && lowestVCN == 0 ? 72 : minimum
        var offset = Int(try bytes.u16(32))
        guard offset >= headerMinimum, nameLength == 0 || nameOffset + nameLength * 2 <= offset else {
            throw NTFSError("Invalid runlist offset")
        }
        var parsed = [NTFSRun](), vcn = lowestVCN, previousLCN: Int64 = 0
        while true {
            let header = try bytes.u8(offset)
            offset += 1
            if header == 0 { break }
            let lengthBytes = Int(header & 15), offsetBytes = Int(header >> 4)
            guard (1...8).contains(lengthBytes), offsetBytes <= 8 else { throw NTFSError("Invalid runlist widths") }
            let length = try bytes.integer(offset, lengthBytes)
            offset += lengthBytes
            guard length > 0, length <= UInt64(Int64.max) else { throw NTFSError("Empty run in NTFS runlist") }
            var lcn: UInt64?
            if offsetBytes > 0 {
                var bits = try bytes.integer(offset, offsetBytes)
                if offsetBytes < 8, bits & (UInt64(1) << (offsetBytes * 8 - 1)) != 0 {
                    bits |= UInt64.max << (offsetBytes * 8)
                }
                let (next, overflow) = previousLCN.addingReportingOverflow(Int64(bitPattern: bits))
                guard !overflow, next >= 0 else { throw NTFSError("Invalid relative cluster offset") }
                previousLCN = next
                lcn = UInt64(next)
                let end = try checkedMultiply(checkedAdd(UInt64(next), length), UInt64(geometry.clusterSize))
                guard end <= geometry.volumeBytes else { throw NTFSError("Run extends beyond the partition") }
            }
            offset += offsetBytes
            parsed.append(NTFSRun(vcn: vcn, length: length, lcn: lcn))
            vcn = try checkedAdd(vcn, length)
        }
        guard parsed.isEmpty ? highestVCN == lowestVCN &- 1 || size == 0 : highestVCN == vcn - 1 else {
            throw NTFSError("Incomplete NTFS runlist")
        }
        runs = parsed
    }

    private init(merging first: NTFSAttribute, runs: [NTFSRun], highestVCN: UInt64) {
        type = first.type; name = first.name; flags = first.flags; identifier = first.identifier
        resident = nil; self.runs = runs; lowestVCN = 0; self.highestVCN = highestVCN
        size = first.size; initializedSize = first.initializedSize; allocatedSize = first.allocatedSize
        compressionUnit = first.compressionUnit
    }

    /// Joins the extents of one nonresident stream (ordered by VCN) and validates coverage.
    static func merge(_ extents: [NTFSAttribute], geometry: NTFSGeometry) throws -> NTFSAttribute {
        let ordered = extents.sorted { $0.lowestVCN < $1.lowestVCN }
        guard let first = ordered.first, first.resident == nil, first.lowestVCN == 0 else {
            throw NTFSError("Attribute extents do not start at VCN 0")
        }
        var runs = [NTFSRun](), next: UInt64 = 0
        for extent in ordered {
            guard extent.resident == nil, extent.lowestVCN == next,
                  extent.compressed == first.compressed else { throw NTFSError("Attribute extents are not contiguous") }
            runs += extent.runs
            next = extent.highestVCN &+ 1
        }
        let merged = NTFSAttribute(merging: first, runs: runs, highestVCN: next &- 1)
        let covered = try checkedMultiply(next, UInt64(geometry.clusterSize))
        guard first.size == 0 || (next > 0 && covered >= first.size) else { throw NTFSError("Incomplete NTFS runlist") }
        return merged
    }

    func read(storage: NTFSStorage, geometry: NTFSGeometry, at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, count <= 8 * 1024 * 1024 else { throw NTFSError("Read request exceeds limit", code: EINVAL) }
        guard offset < size, count > 0 else { return [] }
        let amount = Int(min(UInt64(count), size - offset))
        if let resident {
            guard UInt64(resident.count) >= size else { throw NTFSError("Truncated resident attribute") }
            return Array(resident[Int(offset)..<(Int(offset) + amount)])
        }
        guard !encrypted else { throw NTFSError("Encrypted (EFS) files can only be read on Windows", code: ENOTSUP) }
        if compressed { return try readCompressed(storage: storage, geometry: geometry, at: offset, count: amount) }
        var output = [UInt8](repeating: 0, count: amount)
        var position = offset
        let end = try checkedAdd(offset, UInt64(amount))
        let limit = min(end, initializedSize)
        for run in runs {
            if position >= limit { break }
            let start = try checkedMultiply(run.vcn, UInt64(geometry.clusterSize))
            let runEnd = try checkedMultiply(checkedAdd(run.vcn, run.length), UInt64(geometry.clusterSize))
            if position >= runEnd { continue }
            guard position >= start else { throw NTFSError("Gap in NTFS runlist") }
            let length = Int(min(runEnd, limit) - position)
            if let lcn = run.lcn {
                let diskOffset = try checkedAdd(checkedMultiply(lcn, UInt64(geometry.clusterSize)), position - start)
                let data = try storage.read(at: diskOffset, count: length)
                guard data.count == length else { throw NTFSError("Short storage read") }
                let destination = Int(position - offset)
                output.replaceSubrange(destination..<(destination + length), with: data)
            }
            position += UInt64(length)
        }
        guard position >= limit else { throw NTFSError("Runlist did not cover requested bytes") }
        return output
    }

    /// Clusters [vcn, vcn + count) as (lcn or nil for sparse) pieces, in VCN order.
    private func mapping(_ vcn: UInt64, _ count: UInt64) throws -> [(lcn: UInt64?, count: UInt64)] {
        var pieces = [(lcn: UInt64?, count: UInt64)](), position = vcn
        let end = try checkedAdd(vcn, count)
        for run in runs where position < end {
            let runEnd = run.vcn + run.length
            if position >= runEnd { continue }
            guard position >= run.vcn else { throw NTFSError("Gap in NTFS runlist") }
            let take = min(runEnd, end) - position
            pieces.append((run.lcn.map { $0 + (position - run.vcn) }, take))
            position += take
        }
        if position < end { pieces.append((nil, end - position)) }
        return pieces
    }

    /// Reads a compressed stream unit by unit: a unit stored in all of its clusters is plain
    /// data, a unit with no clusters is zeros, otherwise its clusters hold LZNT1 chunks.
    private func readCompressed(storage: NTFSStorage, geometry: NTFSGeometry, at offset: UInt64, count: Int) throws -> [UInt8] {
        let unitClusters = UInt64(1) << compressionUnit
        let unitBytes = unitClusters * UInt64(geometry.clusterSize)
        var output = [UInt8](repeating: 0, count: count)
        var position = offset
        let end = offset + UInt64(count)
        while position < end {
            let unitIndex = position / unitBytes
            let unitStart = unitIndex * unitBytes
            var plain = [UInt8](repeating: 0, count: Int(unitBytes))
            if unitStart < initializedSize {
                let pieces = try mapping(unitIndex * unitClusters, unitClusters)
                let stored = pieces.reduce(UInt64(0)) { $0 + ($1.lcn == nil ? 0 : $1.count) }
                if stored > 0 {
                    var raw = [UInt8]()
                    for piece in pieces { guard let lcn = piece.lcn else { break }
                        raw += try storage.read(at: checkedMultiply(lcn, UInt64(geometry.clusterSize)), count: Int(piece.count) * geometry.clusterSize)
                    }
                    if stored == unitClusters { plain = raw } else { plain = try LZNT1.decompress(raw, limit: Int(unitBytes)) }
                    if plain.count < Int(unitBytes) { plain += [UInt8](repeating: 0, count: Int(unitBytes) - plain.count) }
                }
                if initializedSize < unitStart + unitBytes {
                    let valid = Int(initializedSize - unitStart)
                    for i in valid..<plain.count { plain[i] = 0 }
                }
            }
            let from = Int(position - unitStart)
            let take = Int(min(unitBytes - UInt64(from), end - position))
            let destination = Int(position - offset)
            output.replaceSubrange(destination..<(destination + take), with: plain[from..<(from + take)])
            position += UInt64(take)
        }
        return output
    }
}

/// LZNT1 decompression as specified in [MS-XCA] section 2.5.
enum LZNT1 {
    static func decompress(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        var output = [UInt8](), cursor = 0
        output.reserveCapacity(limit)
        while cursor + 2 <= input.count, output.count < limit {
            let header = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            if header == 0 { break }
            guard (header >> 12) & 7 == 3 else { throw NTFSError("Invalid LZNT1 chunk signature") }
            let chunkEnd = cursor + (header & 0x0fff) + 3
            guard chunkEnd <= input.count else { throw NTFSError("Truncated LZNT1 chunk") }
            var position = cursor + 2
            let chunkStart = output.count
            if header & 0x8000 == 0 {
                output += input[position..<chunkEnd]
            } else {
                while position < chunkEnd {
                    let flags = input[position]
                    position += 1
                    for bit in 0..<8 where position < chunkEnd {
                        if flags & (1 << bit) == 0 {
                            output.append(input[position])
                            position += 1
                            continue
                        }
                        guard position + 2 <= chunkEnd else { throw NTFSError("Truncated LZNT1 token") }
                        let token = Int(input[position]) | Int(input[position + 1]) << 8
                        position += 2
                        let written = output.count - chunkStart
                        guard written > 0 else { throw NTFSError("LZNT1 copy before any data") }
                        var lengthBits = 12, span = written - 1
                        while span >= 0x10 { span >>= 1; lengthBits -= 1 }
                        let displacement = (token >> lengthBits) + 1
                        let length = (token & ((1 << lengthBits) - 1)) + 3
                        guard displacement <= written, written + length <= 4096 else { throw NTFSError("Invalid LZNT1 copy") }
                        for _ in 0..<length { output.append(output[output.count - displacement]) }
                    }
                }
                guard output.count - chunkStart <= 4096 else { throw NTFSError("Oversized LZNT1 chunk") }
            }
            cursor = chunkEnd
            // Every chunk stands for 4 KB of output: the zeros at the end of a short one are not stored.
            let more = cursor + 2 <= input.count && (input[cursor] != 0 || input[cursor + 1] != 0)
            if more, output.count - chunkStart < 4096 {
                output += [UInt8](repeating: 0, count: 4096 - (output.count - chunkStart))
            }
        }
        return output.count > limit ? Array(output[0..<limit]) : output
    }
}

struct NTFSAttributeListEntry {
    let type: UInt32
    let name: String
    let lowestVCN: UInt64
    let segment: UInt64
    let identifier: UInt16

    static func parse(_ data: [UInt8]) throws -> [NTFSAttributeListEntry] {
        let bytes = Bytes(data: data)
        var entries = [NTFSAttributeListEntry](), offset = 0
        while offset + 26 <= data.count {
            let type = try bytes.u32(offset)
            let length = Int(try bytes.u16(offset + 4))
            let nameLength = Int(try bytes.u8(offset + 6)), nameOffset = Int(try bytes.u8(offset + 7))
            guard length >= 26, length % 8 == 0 || offset + length == data.count, offset + length <= data.count,
                  nameLength == 0 || (nameOffset >= 26 && nameOffset + nameLength * 2 <= length) else {
                throw NTFSError("Invalid attribute list entry")
            }
            entries.append(NTFSAttributeListEntry(
                type: type, name: try bytes.utf16(offset + nameOffset, units: nameLength),
                lowestVCN: try bytes.u64(offset + 8), segment: try bytes.u64(offset + 16), identifier: try bytes.u16(offset + 24)))
            guard entries.count <= 100_000 else { throw NTFSError("Attribute list is too long") }
            offset += length
        }
        return entries
    }
}

/// One MFT record as stored, before attribute-list extensions are joined.
struct NTFSRawRecord {
    let number: UInt64
    let sequence: UInt16
    let flags: UInt16
    let links: UInt16
    let baseReference: UInt64
    let extents: [NTFSAttribute]
    var reference: UInt64 { number | UInt64(sequence) << 48 }

    init(number: UInt64, bytes: [UInt8], geometry: NTFSGeometry) throws {
        let fixed = try restoreFixups(bytes, signature: "FILE")
        self.number = number
        sequence = try fixed.u16(16)
        links = try fixed.u16(18)
        flags = try fixed.u16(22)
        guard flags & 1 != 0 else { throw NTFSError("File record is not in use", code: ENOENT) }
        baseReference = try fixed.u64(32)
        let used = Int(try fixed.u32(24)), allocated = Int(try fixed.u32(28))
        var offset = Int(try fixed.u16(20))
        let usaEnd = Int(try fixed.u16(4)) + Int(try fixed.u16(6)) * 2
        guard allocated == fixed.count, used <= allocated, used >= offset + 4,
              offset >= max(48, usaEnd), offset % 8 == 0 else { throw NTFSError("Invalid MFT attribute bounds") }
        var parsed = [NTFSAttribute]()
        while true {
            guard offset + 4 <= used else { throw NTFSError("Missing attribute terminator") }
            let type = try fixed.u32(offset)
            if type == UInt32.max { break }
            guard offset + 16 <= used else { throw NTFSError("Truncated attribute header") }
            let length = Int(try fixed.u32(offset + 4))
            guard length >= 24, length % 8 == 0, length <= used - offset else { throw NTFSError("Invalid attribute length") }
            parsed.append(try NTFSAttribute(Bytes(data: fixed.slice(offset, length)), geometry: geometry))
            offset += length
        }
        extents = parsed
    }
}

struct NTFSRecord {
    let number: UInt64
    let sequence: UInt16
    let directory: Bool
    let links: UInt16
    /// Attributes of the base record and its extension records; nonresident extents joined.
    let attributes: [NTFSAttribute]
    /// Number of extension records joined through an attribute list.
    let extensionRecords: Int
    var reference: UInt64 { number | UInt64(sequence) << 48 }

    init(base: NTFSRawRecord, extensions: [NTFSRawRecord], geometry: NTFSGeometry) throws {
        extensionRecords = extensions.count
        number = base.number
        sequence = base.sequence
        directory = base.flags & 2 != 0
        links = base.links
        var resident = [NTFSAttribute](), streams = [String: [NTFSAttribute]](), order = [String]()
        for attribute in (base.extents + extensions.flatMap(\.extents)) where attribute.type != NTFSType.attributeList {
            if attribute.resident != nil { resident.append(attribute); continue }
            let key = "\(attribute.type):\(attribute.name)"
            if streams[key] == nil { order.append(key) }
            streams[key, default: []].append(attribute)
        }
        var merged = resident
        for key in order {
            let stream = try NTFSAttribute.merge(streams[key]!, geometry: geometry)
            guard !resident.contains(where: { $0.type == stream.type && $0.name == stream.name }) else {
                throw NTFSError("Attribute stored both resident and nonresident")
            }
            merged.append(stream)
        }
        attributes = merged
    }

    func attribute(_ type: UInt32, name: String = "") throws -> NTFSAttribute {
        let matching = attributes.filter { $0.type == type && $0.name == name }
        guard matching.count == 1 else {
            throw NTFSError(matching.isEmpty ? "Required NTFS attribute is missing" : "Duplicate NTFS attribute",
                            code: matching.isEmpty ? EIO : EIO)
        }
        return matching[0]
    }

    /// The reparse tag, if this record is a reparse point.
    var reparseTag: UInt32? {
        guard let data = attributes.first(where: { $0.type == NTFSType.reparsePoint })?.resident, data.count >= 4 else {
            return attributes.contains(where: { $0.type == NTFSType.reparsePoint }) ? 0 : nil
        }
        return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }
}

struct NTFSEntry {
    let name: String
    let reference: UInt64
    let directory: Bool
    let size: UInt64
    let allocatedSize: UInt64
    let fileAttributes: UInt32
    let created: UInt64
    let modified: UInt64
    let changed: UInt64
    let accessed: UInt64
}

final class NativeNTFSVolume {
    let storage: NTFSStorage
    let geometry: NTFSGeometry
    private(set) var mft: NTFSAttribute
    let label: String
    let dirty: Bool
    let majorVersion: UInt8
    let minorVersion: UInt8
    let uppercase: [UInt16]
    private var recordCache = [UInt64: NTFSRecord]()
    private var cacheOrder = [UInt64]()
    private let cacheLock = NSLock()
    var freeClusterCache: UInt64?

    var recordCount: UInt64 { mft.size / UInt64(geometry.recordSize) }

    init(storage: NTFSStorage) throws {
        self.storage = storage
        let geometry = try NTFSGeometry(storage: storage)
        self.geometry = geometry
        let offset = try checkedMultiply(geometry.mftCluster, UInt64(geometry.clusterSize))
        guard try checkedAdd(offset, UInt64(geometry.recordSize)) <= geometry.volumeBytes else {
            throw NTFSError("Initial MFT record extends beyond partition")
        }
        let first = try NTFSRawRecord(number: 0, bytes: storage.read(at: offset, count: geometry.recordSize), geometry: geometry)
        guard first.baseReference == 0 else { throw NTFSError("MFT record 0 is an extension record") }
        // Bootstrap: the base record holds at least the first $MFT extent; extension records named
        // by the attribute list must lie inside the part of the MFT already mapped.
        func dataExtents(_ record: NTFSRawRecord) -> [NTFSAttribute] {
            record.extents.filter { $0.type == NTFSType.data && $0.name.isEmpty }
        }
        var extents = dataExtents(first)
        var mft = try NTFSAttribute.merge(extents.filter { $0.lowestVCN == 0 }, geometry: geometry)
        func check(_ attribute: NTFSAttribute) throws {
            guard attribute.resident == nil, attribute.runs.allSatisfy({ $0.lcn != nil }), !attribute.compressed,
                  attribute.initializedSize == attribute.size, attribute.size % UInt64(geometry.recordSize) == 0 else {
                throw NTFSError("Unsupported MFT layout", code: ENOTSUP)
            }
        }
        if let listAttribute = first.extents.first(where: { $0.type == NTFSType.attributeList }) {
            let listData = try listAttribute.resident ?? Self.readWhole(listAttribute, storage: storage, geometry: geometry)
            let entries = try NTFSAttributeListEntry.parse(listData)
            var loaded = Set<UInt64>([0])
            for entry in entries where entry.type == NTFSType.data && entry.name.isEmpty {
                let number = entry.segment & 0x0000ffffffffffff
                guard !loaded.contains(number) else { continue }
                loaded.insert(number)
                let partial = NTFSAttribute.partial(extents, geometry: geometry)
                let bytes = try partial.read(storage: storage, geometry: geometry,
                                             at: checkedMultiply(number, UInt64(geometry.recordSize)), count: geometry.recordSize)
                guard bytes.count == geometry.recordSize else { throw NTFSError("MFT extension record is outside the mapped MFT") }
                let ext = try NTFSRawRecord(number: number, bytes: bytes, geometry: geometry)
                guard ext.sequence == UInt16(entry.segment >> 48), ext.baseReference == first.reference else {
                    throw NTFSError("Invalid MFT extension record")
                }
                extents += dataExtents(ext)
            }
            mft = try NTFSAttribute.merge(extents, geometry: geometry)
        }
        try check(mft)
        self.mft = mft
        func initialRecord(_ number: UInt64) throws -> NTFSRecord {
            try Self.loadRecord(number, mft: mft, storage: storage, geometry: geometry)
        }
        let volume = try initialRecord(3)
        let info = try volume.attribute(NTFSType.volumeInformation)
        guard let infoBytes = info.resident, infoBytes.count >= 12,
              infoBytes[8] == 3, infoBytes[9] <= 1 else { throw NTFSError("Only NTFS 3.0 and 3.1 are supported", code: ENOTSUP) }
        majorVersion = infoBytes[8]
        minorVersion = infoBytes[9]
        dirty = try Bytes(data: infoBytes).u16(10) & 1 != 0
        if let name = volume.attributes.first(where: { $0.type == NTFSType.volumeName }), let data = name.resident {
            guard data.count % 2 == 0 else { throw NTFSError("Invalid volume name") }
            label = try Bytes(data: data).utf16(0, units: data.count / 2)
        } else { label = "NTFS" }
        let upcase = try initialRecord(10).attribute(NTFSType.data)
        guard upcase.size == 131072, upcase.initializedSize == upcase.size else { throw NTFSError("Invalid NTFS uppercase table") }
        let table = Bytes(data: try upcase.read(storage: storage, geometry: geometry, at: 0, count: 131072))
        uppercase = try (0..<65536).map { try table.u16($0 * 2) }
    }

    private static func readWhole(_ attribute: NTFSAttribute, storage: NTFSStorage, geometry: NTFSGeometry) throws -> [UInt8] {
        guard attribute.size <= 16 * 1024 * 1024 else { throw NTFSError("Metadata attribute is too large", code: EFBIG) }
        let whole = try NTFSAttribute.merge([attribute], geometry: geometry)
        var data = [UInt8](), position: UInt64 = 0
        while position < whole.size {
            let chunk = try whole.read(storage: storage, geometry: geometry, at: position, count: 4 * 1024 * 1024)
            guard !chunk.isEmpty else { break }
            data += chunk
            position += UInt64(chunk.count)
        }
        return data
    }

    private static func rawRecord(_ number: UInt64, mft: NTFSAttribute, storage: NTFSStorage, geometry: NTFSGeometry) throws -> NTFSRawRecord {
        guard number < mft.size / UInt64(geometry.recordSize) else { throw NTFSError("MFT reference outside table") }
        let bytes = try mft.read(storage: storage, geometry: geometry,
                                 at: checkedMultiply(number, UInt64(geometry.recordSize)), count: geometry.recordSize)
        return try NTFSRawRecord(number: number, bytes: bytes, geometry: geometry)
    }

    private static func loadRecord(_ number: UInt64, mft: NTFSAttribute, storage: NTFSStorage, geometry: NTFSGeometry) throws -> NTFSRecord {
        let base = try rawRecord(number, mft: mft, storage: storage, geometry: geometry)
        guard base.baseReference == 0 else { throw NTFSError("MFT reference names an extension record", code: ESTALE) }
        guard let listAttribute = base.extents.first(where: { $0.type == NTFSType.attributeList }) else {
            return try NTFSRecord(base: base, extensions: [], geometry: geometry)
        }
        guard base.extents.filter({ $0.type == NTFSType.attributeList }).count == 1 else { throw NTFSError("Duplicate attribute list") }
        let data = try listAttribute.resident ?? readWhole(listAttribute, storage: storage, geometry: geometry)
        let entries = try NTFSAttributeListEntry.parse(data)
        var extensions = [NTFSRawRecord](), seen = Set<UInt64>([number])
        for entry in entries {
            let segment = entry.segment & 0x0000ffffffffffff
            guard !seen.contains(segment) else { continue }
            guard seen.count <= 4096 else { throw NTFSError("Too many MFT extension records") }
            seen.insert(segment)
            let ext = try rawRecord(segment, mft: mft, storage: storage, geometry: geometry)
            guard ext.sequence == UInt16(entry.segment >> 48), ext.baseReference == base.reference else {
                throw NTFSError("Invalid MFT extension record")
            }
            extensions.append(ext)
        }
        // Every listed attribute must exist where the list says it is.
        let all = [number: base.extents] .merging(extensions.map { ($0.number, $0.extents) }) { a, _ in a }
        for entry in entries {
            let segment = entry.segment & 0x0000ffffffffffff
            guard all[segment]?.contains(where: { $0.type == entry.type && $0.name == entry.name &&
                    $0.identifier == entry.identifier && ($0.resident != nil || $0.lowestVCN == entry.lowestVCN) }) == true else {
                throw NTFSError("Attribute list names a missing attribute")
            }
        }
        return try NTFSRecord(base: base, extensions: extensions, geometry: geometry)
    }

    func record(_ number: UInt64, expectedSequence: UInt16? = nil) throws -> NTFSRecord {
        cacheLock.lock()
        let cached = recordCache[number]
        cacheLock.unlock()
        let record = try cached ?? Self.loadRecord(number, mft: mft, storage: storage, geometry: geometry)
        if cached == nil {
            cacheLock.lock()
            if recordCache[number] == nil {
                recordCache[number] = record
                cacheOrder.append(number)
                if cacheOrder.count > 4096 { recordCache.removeValue(forKey: cacheOrder.removeFirst()) }
            }
            cacheLock.unlock()
        }
        if let expectedSequence, record.sequence != expectedSequence { throw NTFSError("Stale NTFS file reference", code: ESTALE) }
        return record
    }

    func record(reference: UInt64) throws -> NTFSRecord {
        try record(reference & 0x0000ffffffffffff, expectedSequence: UInt16(reference >> 48))
    }

    func contents(of record: NTFSRecord, at offset: UInt64, count: Int) throws -> [UInt8] {
        guard !record.directory else { throw NTFSError("Cannot read a directory as a file", code: EISDIR) }
        if let tag = record.reparseTag {
            throw NTFSError(String(format: "Reparse points are not readable as files (tag 0x%08x)", tag), code: ENOTSUP)
        }
        return try record.attribute(NTFSType.data).read(storage: storage, geometry: geometry, at: offset, count: count)
    }

    /// Target of a relative Windows symbolic link, with "/" separators; nil for other reparse points.
    func symbolicLinkTarget(of record: NTFSRecord) throws -> String? {
        guard record.reparseTag == 0xa000000c, let data = record.attributes.first(where: { $0.type == NTFSType.reparsePoint })?.resident else { return nil }
        let bytes = Bytes(data: data)
        guard data.count >= 20 else { throw NTFSError("Invalid symbolic link") }
        let substituteOffset = Int(try bytes.u16(8)), substituteLength = Int(try bytes.u16(10))
        let flags = try bytes.u32(16)
        guard flags & 1 != 0 else { return nil }   // absolute targets name Windows drives
        guard substituteLength % 2 == 0, 20 + substituteOffset + substituteLength <= data.count else { throw NTFSError("Invalid symbolic link") }
        let target = try bytes.utf16(20 + substituteOffset, units: substituteLength / 2)
        return target.replacingOccurrences(of: "\\", with: "/")
    }

    private func upcased(_ units: [UInt16]) -> [UInt16] { units.map { uppercase[Int($0)] } }

    private func compareNames(_ a: [UInt16], _ b: [UInt16]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    private struct IndexContext {
        let directory: NTFSRecord
        let allocation: NTFSAttribute?
        let bitmap: NTFSAttribute?
        let root: Bytes
        var visited = Set<UInt64>()
    }

    private func indexContext(_ directory: NTFSRecord) throws -> IndexContext {
        guard directory.directory else { throw NTFSError("Not a directory", code: ENOTDIR) }
        let rootAttribute = try directory.attribute(NTFSType.indexRoot, name: "$I30")
        guard let rootData = rootAttribute.resident else { throw NTFSError("Nonresident index root") }
        let root = Bytes(data: rootData)
        guard try root.u32(0) == NTFSType.fileName, try root.u32(4) == 1,
              try root.u32(8) == UInt32(geometry.indexSize) else { throw NTFSError("Unsupported directory index", code: ENOTSUP) }
        return IndexContext(directory: directory,
                            allocation: directory.attributes.first { $0.type == NTFSType.indexAllocation && $0.name == "$I30" },
                            bitmap: directory.attributes.first { $0.type == NTFSType.bitmap && $0.name == "$I30" },
                            root: root)
    }

    private func child(_ vcn: UInt64, _ context: inout IndexContext) throws -> Bytes {
        guard let allocation = context.allocation, let bitmap = context.bitmap else { throw NTFSError("Missing directory allocation or bitmap") }
        guard context.visited.insert(vcn).inserted else { throw NTFSError("Cycle in directory index") }
        guard context.visited.count <= 1_000_000 else { throw NTFSError("Directory index is too large", code: EFBIG) }
        // Index VCNs count clusters when an index block is at least a cluster, else 512-byte units.
        let unit = UInt64(geometry.indexSize >= geometry.clusterSize ? geometry.clusterSize : 512)
        let offset = try checkedMultiply(vcn, unit)
        guard offset % UInt64(geometry.indexSize) == 0 else { throw NTFSError("Unaligned index child") }
        let index = offset / UInt64(geometry.indexSize)
        let bit = try bitmap.read(storage: storage, geometry: geometry, at: index / 8, count: 1)
        guard bit.count == 1, bit[0] & (1 << (index % 8)) != 0 else { throw NTFSError("Index child is not allocated") }
        let raw = try allocation.read(storage: storage, geometry: geometry, at: offset, count: geometry.indexSize)
        guard raw.count == geometry.indexSize else { throw NTFSError("Truncated directory index block") }
        let block = try restoreFixups(raw, signature: "INDX")
        guard try block.u64(16) == vcn else { throw NTFSError("Directory child VCN mismatch") }
        return block
    }

    struct IndexItem {
        let child: UInt64?
        let entry: NTFSEntry?   // nil for the end marker
        let namespace: UInt8
        let units: [UInt16]
        let key: [UInt8]
    }

    /// Entries of one index node in key order, validated.
    private func items(_ node: Bytes, header: Int, directory: NTFSRecord) throws -> [IndexItem] {
        let relative = Int(try node.u32(header)), used = Int(try node.u32(header + 4))
        let allocated = Int(try node.u32(header + 8))
        guard relative >= 16, used >= relative + 16, allocated >= used,
              header <= node.count, allocated <= node.count - header else { throw NTFSError("Invalid directory index bounds") }
        var cursor = header + relative, result = [IndexItem]()
        let end = header + used
        while cursor + 16 <= end {
            let reference = try node.u64(cursor)
            let length = Int(try node.u16(cursor + 8)), keyLength = Int(try node.u16(cursor + 10))
            let flags = try node.u16(cursor + 12)
            guard flags & ~UInt16(3) == 0, length >= 16, length % 8 == 0, length <= end - cursor,
                  keyLength <= length - 16 - (flags & 1 != 0 ? 8 : 0) else { throw NTFSError("Invalid directory index entry") }
            let child = flags & 1 != 0 ? try node.u64(cursor + length - 8) : nil
            if flags & 2 != 0 {
                guard keyLength == 0 else { throw NTFSError("Invalid directory end entry") }
                result.append(IndexItem(child: child, entry: nil, namespace: 0, units: [], key: []))
                return result
            }
            guard keyLength >= 66 else { throw NTFSError("Truncated filename index key") }
            let key = Bytes(data: try node.slice(cursor + 16, keyLength))
            let nameLength = Int(try key.u8(64)), namespace = try key.u8(65)
            guard namespace <= 3, nameLength > 0, 66 + nameLength * 2 <= keyLength,
                  try key.u64(0) == directory.reference else { throw NTFSError("Invalid filename index key") }
            let units = Array(try key.slice(66, nameLength * 2)).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map(UInt16.init(littleEndian:)) }
            guard let name = String(utf16CodeUnits: units, count: units.count) as String?,
                  !units.contains(0), !units.contains(0x2f) else { throw NTFSError("Unrepresentable filename", code: EILSEQ) }
            let attributes = try key.u32(56)
            let entry = NTFSEntry(name: name, reference: reference, directory: attributes & 0x10000000 != 0,
                                  size: try key.u64(48), allocatedSize: try key.u64(40), fileAttributes: attributes,
                                  created: try key.u64(8), modified: try key.u64(16), changed: try key.u64(24), accessed: try key.u64(32))
            result.append(IndexItem(child: child, entry: entry, namespace: namespace, units: units, key: key.data))
            cursor += length
        }
        throw NTFSError("Missing directory end entry")
    }

    /// Every index entry of a directory (all namespaces, including DOS names), in key order.
    func indexItems(in directory: NTFSRecord) throws -> [IndexItem] {
        var context = try indexContext(directory)
        var output = [IndexItem]()
        func walk(_ node: Bytes, header: Int, depth: Int) throws {
            guard depth <= 32 else { throw NTFSError("Directory index is too deep") }
            for item in try items(node, header: header, directory: directory) {
                if let child = item.child { try walk(self.child(child, &context), header: 24, depth: depth + 1) }
                guard item.entry != nil else { return }
                output.append(item)
            }
        }
        try walk(context.root, header: 16, depth: 0)
        return output
    }

    /// Index blocks of a directory currently marked in use, as VCNs.
    func indexBlockUnit() -> UInt64 { UInt64(geometry.indexSize >= geometry.clusterSize ? geometry.clusterSize : 512) }

    func invalidate(_ number: UInt64) {
        cacheLock.lock()
        recordCache.removeValue(forKey: number)
        cacheOrder.removeAll { $0 == number }
        cacheLock.unlock()
    }

    func replaceMFT(_ attribute: NTFSAttribute) { mft = attribute }

    func upcase(_ units: [UInt16]) -> [UInt16] { units.map { uppercase[Int($0)] } }

    func entries(in directory: NTFSRecord) throws -> [NTFSEntry] {
        var context = try indexContext(directory)
        var names = Set<[UInt16]>(), output = [NTFSEntry]()
        func walk(_ node: Bytes, header: Int, depth: Int) throws {
            guard depth <= 32 else { throw NTFSError("Directory index is too deep") }
            for item in try items(node, header: header, directory: directory) {
                if let child = item.child { try walk(self.child(child, &context), header: 24, depth: depth + 1) }
                guard let entry = item.entry else { return }
                if item.namespace != 2, entry.name != "." {
                    guard names.insert(item.units).inserted else { throw NTFSError("Duplicate directory name") }
                    output.append(entry)
                    guard output.count <= 4_000_000 else { throw NTFSError("Directory is too large", code: EFBIG) }
                }
            }
        }
        try walk(context.root, header: 16, depth: 0)
        return output
    }

    /// Finds `name` by descending the directory's B+ tree (collated by the volume's $UpCase).
    func find(_ name: String, in directory: NTFSRecord) throws -> NTFSEntry? {
        var context = try indexContext(directory)
        let wantedUnits = Array(name.utf16)
        let wanted = upcased(wantedUnits)
        var matches = [(NTFSEntry, [UInt16])]()
        func search(_ node: Bytes, header: Int, depth: Int) throws {
            guard depth <= 32 else { throw NTFSError("Directory index is too deep") }
            for item in try items(node, header: header, directory: directory) {
                guard let entry = item.entry else {
                    if let child = item.child { try search(self.child(child, &context), header: 24, depth: depth + 1) }
                    return
                }
                let order = compareNames(wanted, upcased(item.units))
                if order < 0 {
                    if let child = item.child { try search(self.child(child, &context), header: 24, depth: depth + 1) }
                    return
                }
                if order == 0 {
                    if let child = item.child { try search(self.child(child, &context), header: 24, depth: depth + 1) }
                    if item.namespace != 2 { matches.append((entry, item.units)) }
                }
            }
        }
        try search(context.root, header: 16, depth: 0)
        if let exact = matches.first(where: { $0.1 == wantedUnits }) { return exact.0 }
        guard matches.count <= 1 else { throw NTFSError("Ambiguous filename", code: EIO) }
        return matches.first?.0
    }

    func lookup(_ name: String, in directory: NTFSRecord) throws -> (NTFSRecord, String) {
        guard let entry = try find(name, in: directory) else { throw NTFSError("File not found", code: ENOENT) }
        return (try record(reference: entry.reference), entry.name)
    }

    func resolve(_ path: String) throws -> NTFSRecord {
        var current = try record(5)
        for component in path.split(separator: "/") {
            guard component != ".", component != ".." else { throw NTFSError("Relative path components are not accepted", code: EINVAL) }
            current = try lookup(String(component), in: current).0
        }
        return current
    }

    /// Free clusters counted from $Bitmap (cached after the first call).
    func freeClusters() throws -> UInt64 {
        if let freeClusterCache { return freeClusterCache }
        let bitmap = try record(6).attribute(NTFSType.data)
        let clusters = geometry.clusterCount
        guard bitmap.size >= (clusters + 7) / 8 else { throw NTFSError("Volume bitmap is too small") }
        var used: UInt64 = 0, position: UInt64 = 0
        let bytes = (clusters + 7) / 8
        while position < bytes {
            let chunk = try bitmap.read(storage: storage, geometry: geometry, at: position, count: Int(min(4 * 1024 * 1024, bytes - position)))
            guard !chunk.isEmpty else { throw NTFSError("Short volume bitmap") }
            for (i, byte) in chunk.enumerated() {
                let index = position + UInt64(i)
                var value = byte
                if index == bytes - 1, clusters % 8 != 0 { value &= UInt8((1 << (clusters % 8)) - 1) }
                used += UInt64(value.nonzeroBitCount)
            }
            position += UInt64(chunk.count)
        }
        let free = clusters - min(used, clusters)
        freeClusterCache = free
        return free
    }
}

extension NTFSAttribute {
    /// A view of whichever extents are known so far (used only while bootstrapping the MFT).
    static func partial(_ extents: [NTFSAttribute], geometry: NTFSGeometry) -> NTFSAttribute {
        let ordered = extents.sorted { $0.lowestVCN < $1.lowestVCN }
        var runs = [NTFSRun](), next: UInt64 = 0
        for extent in ordered where extent.lowestVCN == next { runs += extent.runs; next = extent.highestVCN &+ 1 }
        return NTFSAttribute(merging: ordered[0], runs: runs, highestVCN: next &- 1)
    }
}
