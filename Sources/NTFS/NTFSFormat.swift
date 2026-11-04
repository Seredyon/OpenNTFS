import Foundation
import Darwin

/// Creates an empty NTFS 3.1 volume. The layout follows the conventions Windows uses: boot
/// sector with a backup in the last sector, $MFT after the first 512 KB with a 256-record
/// initial table, $MFTMirr and $LogFile in the middle of the volume, an empty (0xff) journal,
/// system records 0-15, $Extend children 24-26. Indexes are built by the normal writer.
enum NTFSFormatter {
    struct Options {
        var label = "OPENNTFS"
        var hiddenSectors: UInt32 = 0
        var sectorSize = 512
        var clusterSize: Int? = nil
        var serial: UInt64? = nil
    }

    static func defaultClusterSize(volumeBytes: UInt64, sectorSize: Int) -> Int {
        // 4 KB up to 16 TB, then the smallest power of two that keeps clusters below 2^32.
        var size = max(4096, sectorSize)
        while volumeBytes / UInt64(size) >= UInt64(1) << 32, size < 2 * 1024 * 1024 { size *= 2 }
        return size
    }

    static func format(_ storage: NTFSWritableStorage, options: Options = Options()) throws {
        let sector = options.sectorSize
        guard [512, 1024, 2048, 4096].contains(sector) else { throw NTFSError("Unsupported sector size", code: EINVAL) }
        let volumeBytes = storage.byteCount / UInt64(sector) * UInt64(sector)
        let clusterSize = options.clusterSize ?? defaultClusterSize(volumeBytes: volumeBytes, sectorSize: sector)
        guard clusterSize >= sector, clusterSize & (clusterSize - 1) == 0, clusterSize / sector <= 128 else {
            throw NTFSError("Unsupported cluster size", code: EINVAL)
        }
        guard volumeBytes >= 8 * 1024 * 1024 else { throw NTFSError("The volume is too small for NTFS", code: EINVAL) }
        guard options.label.utf16.count <= 32 else { throw NTFSError("Volume name must contain 1-32 characters", code: EINVAL) }
        let cluster = UInt64(clusterSize)
        // The last sector holds the boot sector backup and is not part of the volume.
        let totalSectors = volumeBytes / UInt64(sector) - 1
        let clusters = totalSectors * UInt64(sector) / cluster
        let recordSize = 1024, indexSize = 4096
        let initialRecords: UInt64 = 256
        let mftClusters = (initialRecords * UInt64(recordSize) + cluster - 1) / cluster

        let used = BitmapStream(bytes: [UInt8](repeating: 0, count: Int((clusters + 7) / 8)), count: clusters)
        func reserve(_ start: UInt64, _ count: UInt64) throws -> [NTFSRun] {
            guard start + count <= clusters else { throw NTFSError("The volume is too small for NTFS", code: EINVAL) }
            used.set(start, count, true)
            return [NTFSRun(vcn: 0, length: count, lcn: start)]
        }
        let bootClusters = (8192 + cluster - 1) / cluster
        let bootRuns = try reserve(0, bootClusters)
        let mftStart = max(bootClusters, (512 * 1024) / cluster)
        let mftRuns = try reserve(mftStart, mftClusters)
        // Metadata streams go to the middle of the volume, leaving room for the MFT to grow.
        var cursor = clusters / 2
        func place(_ bytes: UInt64) throws -> [NTFSRun] {
            let count = max(1, (bytes + cluster - 1) / cluster)
            let runs = try reserve(cursor, count)
            cursor += count
            return runs
        }
        let mirrorBytes = UInt64(max(4 * recordSize, clusterSize))
        let mirrorRuns = try place(mirrorBytes)
        let logBytes = min(64 * 1024 * 1024, max(2 * 1024 * 1024, volumeBytes / 256)) / cluster * cluster
        let logRuns = try place(logBytes)
        let bitmapBytes = UInt64(align8(Int((clusters + 7) / 8)))
        let bitmapRuns = try place(bitmapBytes)
        let mftBitmapBytes = UInt64(align8(Int((initialRecords + 7) / 8)))
        let mftBitmapRuns = try place(mftBitmapBytes)
        let attrDef = attributeDefinitions()
        let attrDefRuns = try place(UInt64(attrDef.count))
        let upcase = upcaseTable()
        let upcaseRuns = try place(UInt64(upcase.count * 2))

        // Zero the metadata areas, fill the journal with 0xff.
        for runs in [mirrorRuns, bitmapRuns, mftBitmapRuns, attrDefRuns, upcaseRuns, mftRuns] {
            for run in runs { try zero(storage, run.lcn! * cluster, run.length * cluster) }
        }
        for run in logRuns { try fill(storage, run.lcn! * cluster, run.length * cluster, 0xff) }

        let time = ntfsNow()
        var records = [RecordImage]()
        func record(_ number: UInt64, flags: UInt16) -> RecordImage {
            var image = RecordImage(blank: number, size: recordSize, sequence: number < 16 ? UInt16(max(1, number)) : 1)
            image.flags = flags
            image.links = 1
            return image
        }
        func addName(_ image: inout RecordImage, _ name: String, parent: UInt64, attributes: UInt32, size: UInt64 = 0, allocated: UInt64 = 0) {
            let key = NTFSWriter.fileNameKey(parent: parent, name: name, time: time, size: size, allocated: allocated, attributes: attributes, namespace: 3)
            image.set(AttributeRecord.resident(type: NTFSType.fileName, value: key, identifier: image.takeIdentifier(), indexed: true))
        }
        func addStandard(_ image: inout RecordImage, attributes: UInt32, security: UInt32) {
            image.set(AttributeRecord.resident(type: NTFSType.standardInformation,
                                               value: NTFSWriter.standardInformation(time: time, attributes: attributes, securityID: security),
                                               identifier: image.takeIdentifier()))
        }
        func addData(_ image: inout RecordImage, name: String = "", runs: [NTFSRun], size: UInt64) {
            image.set(AttributeRecord.nonresident(type: NTFSType.data, name: name, runs: runs, size: size, initialized: size,
                                                  identifier: image.takeIdentifier(), clusterSize: clusterSize))
        }
        let root = UInt64(5) | UInt64(5) << 48
        let extend = UInt64(11) | UInt64(11) << 48
        let hiddenSystem: UInt32 = 0x06
        let systemSD: UInt32 = 0x100, rootSD: UInt32 = 0x101
        func systemFile(_ number: UInt64, _ name: String, runs: [NTFSRun], size: UInt64) -> RecordImage {
            var image = record(number, flags: 1)
            addStandard(&image, attributes: hiddenSystem, security: systemSD)
            addName(&image, name, parent: root, attributes: hiddenSystem, size: size, allocated: runs.reduce(0) { $0 + $1.length } * cluster)
            addData(&image, runs: runs, size: size)
            return image
        }
        var mft = systemFile(0, "$MFT", runs: mftRuns, size: initialRecords * UInt64(recordSize))
        mft.set(AttributeRecord.nonresident(type: NTFSType.bitmap, runs: mftBitmapRuns, size: mftBitmapBytes, initialized: mftBitmapBytes,
                                            identifier: mft.takeIdentifier(), clusterSize: clusterSize))
        records.append(mft)
        records.append(systemFile(1, "$MFTMirr", runs: mirrorRuns, size: UInt64(4 * recordSize)))
        records.append(systemFile(2, "$LogFile", runs: logRuns, size: logBytes))
        var volume = record(3, flags: 1)
        addStandard(&volume, attributes: hiddenSystem, security: systemSD)
        addName(&volume, "$Volume", parent: root, attributes: hiddenSystem)
        volume.set(AttributeRecord.resident(type: NTFSType.volumeName, value: utf16LE(options.label), identifier: volume.takeIdentifier()))
        var information = [UInt8](repeating: 0, count: 12)
        information[8] = 3
        information[9] = 1
        volume.set(AttributeRecord.resident(type: NTFSType.volumeInformation, value: information, identifier: volume.takeIdentifier()))
        volume.set(AttributeRecord.resident(type: NTFSType.data, value: [], identifier: volume.takeIdentifier()))
        records.append(volume)
        records.append(systemFile(4, "$AttrDef", runs: attrDefRuns, size: UInt64(attrDef.count)))
        var rootRecord = record(5, flags: 3)
        addStandard(&rootRecord, attributes: hiddenSystem | 0x10000000, security: rootSD)
        addName(&rootRecord, ".", parent: root, attributes: hiddenSystem | 0x10000000)
        rootRecord.set(AttributeRecord.resident(type: NTFSType.indexRoot, name: "$I30",
                                                value: emptyRoot(type: NTFSType.fileName, collation: 1, clusterSize: clusterSize),
                                                identifier: rootRecord.takeIdentifier()))
        records.append(rootRecord)
        records.append(systemFile(6, "$Bitmap", runs: bitmapRuns, size: bitmapBytes))
        records.append(systemFile(7, "$Boot", runs: bootRuns, size: bootClusters * cluster))
        var bad = record(8, flags: 1)
        addStandard(&bad, attributes: hiddenSystem, security: systemSD)
        addName(&bad, "$BadClus", parent: root, attributes: hiddenSystem)
        bad.set(AttributeRecord.resident(type: NTFSType.data, value: [], identifier: bad.takeIdentifier()))
        bad.set(AttributeRecord.nonresident(type: NTFSType.data, name: "$Bad", runs: [NTFSRun(vcn: 0, length: clusters, lcn: nil)],
                                            size: clusters * cluster, initialized: clusters * cluster, identifier: bad.takeIdentifier(), clusterSize: clusterSize))
        records.append(bad)
        var secure = record(9, flags: 9)
        addStandard(&secure, attributes: hiddenSystem | 0x20000000, security: systemSD)
        addName(&secure, "$Secure", parent: root, attributes: hiddenSystem | 0x20000000)
        secure.set(AttributeRecord.nonresident(type: NTFSType.data, name: "$SDS", runs: [], size: 0, initialized: 0,
                                               identifier: secure.takeIdentifier(), clusterSize: clusterSize))
        secure.set(AttributeRecord.resident(type: NTFSType.indexRoot, name: "$SDH", value: emptyRoot(type: 0, collation: 0x12, clusterSize: clusterSize),
                                            identifier: secure.takeIdentifier()))
        secure.set(AttributeRecord.resident(type: NTFSType.indexRoot, name: "$SII", value: emptyRoot(type: 0, collation: 0x10, clusterSize: clusterSize),
                                            identifier: secure.takeIdentifier()))
        records.append(secure)
        records.append(systemFile(10, "$UpCase", runs: upcaseRuns, size: UInt64(upcase.count * 2)))
        var extendRecord = record(11, flags: 3)
        addStandard(&extendRecord, attributes: hiddenSystem | 0x10000000, security: systemSD)
        addName(&extendRecord, "$Extend", parent: root, attributes: hiddenSystem | 0x10000000)
        extendRecord.set(AttributeRecord.resident(type: NTFSType.indexRoot, name: "$I30",
                                                  value: emptyRoot(type: NTFSType.fileName, collation: 1, clusterSize: clusterSize),
                                                  identifier: extendRecord.takeIdentifier()))
        records.append(extendRecord)
        for number in UInt64(12)...15 {
            var reserved = record(number, flags: 1)
            reserved.links = 0
            addStandard(&reserved, attributes: hiddenSystem, security: systemSD)
            reserved.set(AttributeRecord.resident(type: NTFSType.data, value: [], identifier: reserved.takeIdentifier()))
            records.append(reserved)
        }
        let viewFile: UInt32 = 0x20000026
        func viewIndexFile(_ number: UInt64, _ name: String, _ indexes: [(String, UInt32, [UInt8])]) -> RecordImage {
            var image = record(number, flags: 13)
            addStandard(&image, attributes: viewFile, security: systemSD)
            addName(&image, name, parent: extend, attributes: viewFile)
            for (indexName, collation, entries) in indexes {
                var value = emptyRoot(type: 0, collation: collation, clusterSize: clusterSize)
                if !entries.isEmpty {
                    value = Array(value[0..<32]) + entries + IndexBuilder.end(child: nil)
                    value.put32(UInt32(16 + entries.count + 16), at: 20)
                    value.put32(UInt32(16 + entries.count + 16), at: 24)
                }
                image.set(AttributeRecord.resident(type: NTFSType.indexRoot, name: indexName, value: value, identifier: image.takeIdentifier()))
            }
            return image
        }
        // The default quota entry (owner id 1): version 2, default limits, no limits set.
        var quota = [UInt8](repeating: 0, count: 48)
        quota.put32(2, at: 0)
        quota.put32(1, at: 4)
        quota.put64(time, at: 16)
        quota.put64(UInt64.max, at: 24)
        quota.put64(UInt64.max, at: 32)
        var quotaKey = [UInt8](repeating: 0, count: 4)
        quotaKey.put32(1, at: 0)
        let quotaEntry = IndexBuilder.entry(IndexEntryBody.view(key: quotaKey, data: quota), child: nil)
        records.append(viewIndexFile(24, "$Quota", [("$O", 0x11, []), ("$Q", 0x10, quotaEntry)]))
        records.append(viewIndexFile(25, "$ObjId", [("$O", 0x13, [])]))
        records.append(viewIndexFile(26, "$Reparse", [("$R", 0x13, [])]))

        // Write the MFT (all records, free ones formatted) and its mirror.
        var table = [UInt8]()
        for number in 0..<initialRecords {
            if let image = records.first(where: { $0.number == number }) {
                table += try image.encoded()
            } else {
                var free = RecordImage(blank: number, size: recordSize, sequence: 0)
                free.flags = 0
                table += try free.encoded()
            }
        }
        try storage.write(at: mftRuns[0].lcn! * cluster, bytes: table)
        try storage.write(at: mirrorRuns[0].lcn! * cluster, bytes: Array(table[0..<(4 * recordSize)]))
        var mftBits = [UInt8](repeating: 0, count: Int(mftBitmapBytes))
        for number in records.map(\.number) { mftBits[Int(number / 8)] |= 1 << (number % 8) }
        try storage.write(at: mftBitmapRuns[0].lcn! * cluster, bytes: mftBits)
        try storage.write(at: attrDefRuns[0].lcn! * cluster, bytes: attrDef)
        try storage.write(at: upcaseRuns[0].lcn! * cluster, bytes: upcase.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        // Bits past the last cluster (the partial cluster at the end and the padding) stay set.
        var bitmap = used.bits + [UInt8](repeating: 0xff, count: Int(bitmapBytes) - used.bits.count)
        for bit in clusters..<UInt64(used.bits.count * 8) { bitmap[Int(bit / 8)] |= 1 << (bit % 8) }
        try storage.write(at: bitmapRuns[0].lcn! * cluster, bytes: bitmap)

        // Boot sector and its backup.
        var boot = [UInt8](repeating: 0, count: sector)
        boot.replaceSubrange(0..<3, with: [0xeb, 0x52, 0x90])
        boot.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        boot.put16(UInt16(sector), at: 11)
        boot[13] = UInt8(clusterSize / sector)
        boot[21] = 0xf8
        boot.put16(63, at: 24)
        boot.put16(255, at: 26)
        boot.put32(options.hiddenSectors, at: 28)
        boot.put32(0x00800080, at: 36)
        boot.put64(totalSectors, at: 40)
        boot.put64(mftRuns[0].lcn!, at: 48)
        boot.put64(mirrorRuns[0].lcn!, at: 56)
        boot[64] = recordSize >= clusterSize ? UInt8(recordSize / clusterSize) : UInt8(bitPattern: Int8(-Int(log2(Double(recordSize)))))
        boot[68] = indexSize >= clusterSize ? UInt8(indexSize / clusterSize) : UInt8(bitPattern: Int8(-Int(log2(Double(indexSize)))))
        var serial = options.serial ?? 0
        if options.serial == nil { arc4random_buf(&serial, 8) }
        boot.put64(serial, at: 72)
        // Not bootable: the code only halts.
        boot.replaceSubrange(84..<88, with: [0xfa, 0xf4, 0xeb, 0xfd])
        boot.put16(0xaa55, at: 510)
        try storage.write(at: 0, bytes: boot)
        try storage.write(at: totalSectors * UInt64(sector), bytes: boot)
        try storage.synchronize()

        // Directory and security indexes, written by the normal writer.
        let created = try NativeNTFSVolume(storage: storage)
        let writer = try NTFSWriter(volume: created, storage: storage)
        let systemDescriptor = WindowsSecurity.build(WindowsSecurity.Descriptor(
            owner: WindowsSecurity.administrators, group: WindowsSecurity.administrators, daclPresent: true,
            dacl: [WindowsSecurity.ACE(type: 0, flags: 0, mask: 0x12019f, sid: WindowsSecurity.system),
                   WindowsSecurity.ACE(type: 0, flags: 0, mask: 0x12019f, sid: WindowsSecurity.administrators)]), control: 0)
        guard try writer.securityStore().identifier(for: systemDescriptor) == systemSD,
              try writer.securityStore().identifier(for: WindowsSecurity.inherit(parent: nil, directory: true)) == rootSD else {
            throw NTFSError("Unexpected security identifiers while formatting")
        }
        for image in records where image.number < 12 {
            guard let index = image.index(of: NTFSType.fileName) else { continue }
            let key = AttributeRecord.value(image.attributes[index])
            let parent = key.get64(0) & 0x0000ffffffffffff
            try writer.addEntry(key: key, reference: image.reference, to: parent)
        }
        for image in records where (24...26).contains(image.number) {
            let key = AttributeRecord.value(image.attributes[image.index(of: NTFSType.fileName)!])
            try writer.addEntry(key: key, reference: image.reference, to: 11)
        }
        try writer.close()
    }

    private static func zero(_ storage: NTFSWritableStorage, _ offset: UInt64, _ length: UInt64) throws {
        try fill(storage, offset, length, 0)
    }

    private static func fill(_ storage: NTFSWritableStorage, _ offset: UInt64, _ length: UInt64, _ value: UInt8) throws {
        let chunk = [UInt8](repeating: value, count: 1024 * 1024)
        var position: UInt64 = 0
        while position < length {
            let take = Int(min(UInt64(chunk.count), length - position))
            try storage.write(at: offset + position, bytes: take == chunk.count ? chunk : Array(chunk[0..<take]))
            position += UInt64(take)
        }
    }

    static func emptyRoot(type: UInt32, collation: UInt32, clusterSize: Int) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 32)
        value.put32(type, at: 0)
        value.put32(collation, at: 4)
        value.put32(4096, at: 8)
        value[12] = UInt8(4096 >= clusterSize ? 4096 / clusterSize : 4096 / 512)
        value.put32(16, at: 16)
        value.put32(32, at: 20)
        value.put32(32, at: 24)
        return value + IndexBuilder.end(child: nil)
    }

    /// The attribute definition table ($AttrDef) of NTFS 3.1.
    static func attributeDefinitions() -> [UInt8] {
        let definitions: [(String, UInt32, UInt32, Int64, Int64)] = [
            ("$STANDARD_INFORMATION", 0x10, 0x40, 48, 72), ("$ATTRIBUTE_LIST", 0x20, 0x80, 0, -1),
            ("$FILE_NAME", 0x30, 0x42, 68, 578), ("$OBJECT_ID", 0x40, 0x40, 0, 256),
            ("$SECURITY_DESCRIPTOR", 0x50, 0x80, 0, -1), ("$VOLUME_NAME", 0x60, 0x40, 2, 256),
            ("$VOLUME_INFORMATION", 0x70, 0x40, 12, 12), ("$DATA", 0x80, 0x00, 0, -1),
            ("$INDEX_ROOT", 0x90, 0x40, 0, -1), ("$INDEX_ALLOCATION", 0xa0, 0x80, 0, -1),
            ("$BITMAP", 0xb0, 0x80, 0, -1), ("$REPARSE_POINT", 0xc0, 0x80, 0, 16384),
            ("$EA_INFORMATION", 0xd0, 0x40, 8, 8), ("$EA", 0xe0, 0x00, 0, 65536),
            ("$LOGGED_UTILITY_STREAM", 0x100, 0x80, 0, 65536),
        ]
        var table = [UInt8](repeating: 0, count: 2560)
        for (i, definition) in definitions.enumerated() {
            let base = i * 160
            let name = utf16LE(definition.0)
            table.replaceSubrange(base..<(base + name.count), with: name)
            table.put32(definition.1, at: base + 128)
            table.put32(definition.2, at: base + 140)
            table.put64(UInt64(bitPattern: definition.3), at: base + 144)
            table.put64(UInt64(bitPattern: definition.4), at: base + 152)
        }
        return table
    }

    /// The $UpCase table Windows writes: simple uppercase mappings of characters assigned by
    /// Unicode 5.1, kept only when they round-trip (the uppercase form lowercases back to the
    /// same character), with the single-character titlecase form where the full uppercase
    /// mapping is longer (Greek with ypogegrammeni).
    static func upcaseTable() -> [UInt16] {
        func assignedBy51(_ scalar: Unicode.Scalar) -> Bool {
            guard let age = scalar.properties.age else { return false }
            return age.major < 5 || (age.major == 5 && age.minor <= 1)
        }
        func single(_ text: String) -> Unicode.Scalar? {
            let scalars = text.unicodeScalars
            return scalars.count == 1 ? scalars.first : nil
        }
        return (0..<65536).map { value -> UInt16 in
            guard let scalar = Unicode.Scalar(UInt32(value)), assignedBy51(scalar) else { return UInt16(value) }
            let properties = scalar.properties
            guard let upper = single(properties.uppercaseMapping) ?? single(properties.titlecaseMapping),
                  upper.value <= 0xffff, upper != scalar, assignedBy51(upper),
                  single(upper.properties.lowercaseMapping) == scalar else { return UInt16(value) }
            return UInt16(upper.value)
        }
    }
}
