import Foundation
import Darwin

/// Consistency check and repair.
///
/// verify: reads everything, changes nothing.
/// safe:   like verify; if no problems are found, clears the dirty flag.
/// repair: fixes what it can (bitmaps, link counts, index entries that point to the wrong record,
///         names missing from their folder index), then clears the dirty flag if nothing remains.
enum NTFSChecker {
    enum Mode: String { case verify, safe, repair }

    struct Report {
        var errors = [String]()      // must be repaired before the volume is trusted
        var minor = [String]()       // harmless (lost space, counts), repaired too
        var unfixable = [String]()
        var repaired = [String]()
        var journalNotClean = false
        var dirtyBefore = false
        var dirtyAfter = false
        var totalBytes: UInt64 = 0
        var freeBytes: UInt64 = 0
        var records = 0
        var folders = 0

        var result: String {
            if !unfixable.isEmpty { return "errors" }
            if journalNotClean { return "journal" }
            if !repaired.isEmpty { return errors.isEmpty && minor.isEmpty ? "repaired" : "errors" }
            if !errors.isEmpty { return "errors" }
            return minor.isEmpty ? "clean" : "minor"
        }

        var log: String {
            var lines = ["Checking NTFS volume.", "Verified \(records) MFT records and \(folders) folders."]
            if dirtyBefore { lines.append("The volume is marked as needing a check.") }
            if journalNotClean { lines.append("The NTFS journal contains changes that Windows did not finish.") }
            lines += errors.map { "Error: " + $0 } + minor.map { "Minor: " + $0 } + unfixable.map { "Not repaired: " + $0 } + repaired.map { "Repaired: " + $0 }
            lines.append(String(format: "%.2f GB total, %.2f GB free.", Double(totalBytes) / 1e9, Double(freeBytes) / 1e9))
            lines.append(errors.isEmpty && minor.isEmpty && unfixable.isEmpty && !journalNotClean ? "No problems were found." : "Problems were found.")
            return lines.joined(separator: "\n")
        }
    }

    private struct NameInfo {
        let parent: UInt64      // reference, with sequence
        let units: [UInt16]
        let namespace: UInt8
        let key: [UInt8]
    }

    private struct RecordInfo {
        var sequence: UInt16 = 0
        var directory = false
        var links: UInt16 = 0
        var names = [NameInfo]()
        var securityID: UInt32 = 0
    }

    static func run(_ storage: NTFSWritableStorage, mode: Mode, progress: ((Int) -> Void)? = nil) throws -> Report {
        let volume = try NativeNTFSVolume(storage: storage)
        let geometry = volume.geometry
        var report = Report()
        report.dirtyBefore = volume.dirty
        report.totalBytes = geometry.clusterCount * UInt64(geometry.clusterSize)
        report.journalNotClean = !(try NTFSWriter.journalIsClean(volume))
        let clusters = geometry.clusterCount
        let cluster = UInt64(geometry.clusterSize)
        var used = [UInt8](repeating: 0, count: Int((clusters + 7) / 8))
        func mark(_ runs: [NTFSRun], owner: UInt64) {
            for run in runs {
                guard let lcn = run.lcn else { continue }
                guard lcn + run.length <= clusters else {
                    report.errors.append("Record \(owner) uses clusters beyond the end of the volume.")
                    continue
                }
                var crossed = false
                for c in lcn..<(lcn + run.length) {
                    let byte = Int(c >> 3), bit = UInt8(1 << (c & 7))
                    if used[byte] & bit != 0 { crossed = true }
                    used[byte] |= bit
                }
                if crossed { report.unfixable.append("Record \(owner) shares clusters with another file.") }
            }
        }

        // Pass 1: every MFT record.
        let recordCount = volume.recordCount
        let recordBitmap = try volume.record(0).attribute(NTFSType.bitmap)
        var mftBits = try NTFSWriter.readStream(recordBitmap, volume: volume, bytes: recordBitmap.size)
        var info = [UInt64: RecordInfo]()
        var directories = [UInt64: NTFSRecord]()   // parsed once, reused for the index pass
        var extensionsOf = [UInt64: [NTFSRawRecord]]()
        var bases = [NTFSRawRecord]()
        var inUse = Set<UInt64>()
        let chunkRecords = UInt64(max(1, 4 * 1024 * 1024 / geometry.recordSize))
        var number: UInt64 = 0
        while number < recordCount {
            let take = min(chunkRecords, recordCount - number)
            let bytes = try volume.mft.read(storage: storage, geometry: geometry,
                                            at: number * UInt64(geometry.recordSize), count: Int(take) * geometry.recordSize)
            for i in 0..<Int(take) {
                let n = number + UInt64(i)
                let raw = Array(bytes[(i * geometry.recordSize)..<((i + 1) * geometry.recordSize)])
                let marked = Int(n / 8) < mftBits.count && mftBits[Int(n / 8)] & (1 << (n % 8)) != 0
                guard Array(raw[0..<4]) == Array("FILE".utf8), raw.get16(22) & 1 != 0 else {
                    if marked && n >= 24 { report.minor.append("Record \(n) is free but marked as used.") }
                    continue
                }
                do {
                    let record = try NTFSRawRecord(number: n, bytes: raw, geometry: geometry)
                    inUse.insert(n)
                    if !marked { report.errors.append("Record \(n) is used but marked as free.") }
                    if record.baseReference != 0 {
                        extensionsOf[record.baseReference & 0x0000ffffffffffff, default: []].append(record)
                    } else {
                        bases.append(record)
                    }
                } catch {
                    report.unfixable.append("Record \(n) is damaged: \(error).")
                }
            }
            number += take
            progress?(Int(number * 50 / max(recordCount, 1)))
        }
        report.records = inUse.count

        // Pass 2: join extension records, mark clusters, collect names.
        for base in bases {
            var extensions = extensionsOf[base.number] ?? []
            extensions = extensions.filter { $0.baseReference == base.reference }
            do {
                let record = try NTFSRecord(base: base, extensions: extensions, geometry: geometry)
                for attribute in record.attributes where attribute.resident == nil { mark(attribute.runs, owner: base.number) }
                if let list = base.extents.first(where: { $0.type == NTFSType.attributeList }), list.resident == nil { mark(list.runs, owner: base.number) }
                var entry = RecordInfo(sequence: base.sequence, directory: record.directory, links: base.links)
                for attribute in record.attributes where attribute.type == NTFSType.fileName {
                    guard let value = attribute.resident, value.count >= 66 else { continue }
                    let length = Int(value[64])
                    guard value.count >= 66 + length * 2 else { continue }
                    entry.names.append(NameInfo(parent: value.get64(0), units: (0..<length).map { value.get16(66 + $0 * 2) },
                                                namespace: value[65], key: value))
                }
                if let si = record.attributes.first(where: { $0.type == NTFSType.standardInformation })?.resident, si.count >= 56 {
                    entry.securityID = si.get32(52)
                }
                info[base.number] = entry
                if record.directory { directories[base.number] = record }
            } catch {
                report.unfixable.append("Record \(base.number) cannot be read: \(error).")
            }
        }

        // Pass 3: folder indexes.
        var listed = [UInt64: [(parent: UInt64, units: [UInt16], namespace: UInt8)]]()
        var badEntries = [UInt64: Set<UInt64>]()     // folder -> references to drop
        var folderOrderBroken = Set<UInt64>()
        let folders = info.filter { $0.value.directory }.map(\.key).sorted()
        for (index, folder) in folders.enumerated() {
            progress?(50 + index * 40 / max(folders.count, 1))
            do {
                let record = try directories[folder] ?? volume.record(folder)
                let items = try volume.indexItems(in: record)
                var previous: [UInt16]? = nil
                for item in items {
                    guard let entry = item.entry else { continue }
                    let folded = volume.upcase(item.units)
                    if let previous, compareUnits(previous, folded) > 0 { folderOrderBroken.insert(folder) }
                    previous = folded
                    let target = entry.reference & 0x0000ffffffffffff
                    let name = String(utf16CodeUnits: item.units, count: item.units.count)
                    guard let targetInfo = info[target], targetInfo.sequence == UInt16(entry.reference >> 48) else {
                        report.errors.append("Folder \(folder) lists \"\(name)\" for a record that is free or reused.")
                        badEntries[folder, default: []].insert(entry.reference)
                        continue
                    }
                    guard targetInfo.names.contains(where: { $0.parent & 0x0000ffffffffffff == folder && $0.units == item.units }) else {
                        report.errors.append("Folder \(folder) lists \"\(name)\", which its record does not carry.")
                        badEntries[folder, default: []].insert(entry.reference)
                        continue
                    }
                    listed[target, default: []].append((folder, item.units, item.namespace))
                }
                report.folders += 1
            } catch {
                report.unfixable.append("The index of folder \(folder) is damaged: \(error).")
            }
        }
        for folder in folderOrderBroken { report.errors.append("The index of folder \(folder) is out of order.") }

        // Names missing from their folder, link counts, security identifiers.
        var orphans = [(UInt64, NameInfo)]()
        var linkFixes = [UInt64: UInt16]()
        let securityIDs: Set<UInt32>
        do {
            securityIDs = Set(try volume.securityIndex(volume.record(9), name: "$SII").compactMap { $0.count >= 8 ? $0.get32(4) : nil })
        } catch {
            securityIDs = []
            report.unfixable.append("The security index is damaged: \(error).")
        }
        for (number, entry) in info.sorted(by: { $0.key < $1.key }) {
            for name in entry.names where number != 5 {
                let parent = name.parent & 0x0000ffffffffffff
                let found = listed[number]?.contains { $0.parent == parent && $0.units == name.units } ?? false
                if !found && number >= 16 {
                    if info[parent]?.directory == true, info[parent]?.sequence == UInt16(name.parent >> 48) {
                        report.errors.append("\"\(String(utf16CodeUnits: name.units, count: name.units.count))\" (record \(number)) is missing from its folder.")
                        orphans.append((number, name))
                    } else {
                        report.unfixable.append("Record \(number) names a folder that does not exist.")
                    }
                }
            }
            let expected = UInt16(entry.names.filter { $0.namespace != 2 }.count)
            if number >= 16 || (12...15).contains(number), entry.links != expected {
                report.minor.append("Record \(number) has link count \(entry.links) instead of \(expected).")
                linkFixes[number] = expected
            }
            if number >= 16, entry.securityID != 0, !securityIDs.isEmpty, !securityIDs.contains(entry.securityID) {
                report.errors.append("Record \(number) uses security id \(entry.securityID), which does not exist.")
            }
        }

        // Volume bitmap.
        let bitmapAttribute = try volume.record(6).attribute(NTFSType.data)
        let bitmapBytes = (clusters + 7) / 8
        let onDisk = try NTFSWriter.readStream(bitmapAttribute, volume: volume, bytes: bitmapBytes)
        var lostRanges = [(UInt64, UInt64)](), missingRanges = [(UInt64, UInt64)]()
        func addRange(_ list: inout [(UInt64, UInt64)], _ c: UInt64) {
            if let last = list.last, last.0 + last.1 == c { list[list.count - 1].1 += 1 } else { list.append((c, 1)) }
        }
        var freeCount: UInt64 = 0
        for byte in 0..<Int(bitmapBytes) where used[byte] != onDisk[byte] || onDisk[byte] != 0xff {
            for bit in 0..<8 {
                let c = UInt64(byte) * 8 + UInt64(bit)
                guard c < clusters else { break }
                let disk = onDisk[byte] & (1 << bit) != 0, real = used[byte] & (1 << bit) != 0
                if !disk { freeCount += 1 }
                if disk && !real { addRange(&lostRanges, c) }
                if !disk && real { addRange(&missingRanges, c) }
            }
        }
        report.freeBytes = freeCount * cluster
        for range in missingRanges.prefix(20) {
            report.errors.append(String(format: "Used clusters 0x%llx - 0x%llx are marked as free.", range.0, range.0 + range.1 - 1))
        }
        for range in lostRanges.prefix(20) {
            report.minor.append(String(format: "Free clusters 0x%llx - 0x%llx are marked as used.", range.0, range.0 + range.1 - 1))
        }
        if lostRanges.count > 20 || missingRanges.count > 20 { report.minor.append("More cluster ranges differ; they are not listed.") }

        progress?(95)
        let problems = !report.errors.isEmpty || !report.minor.isEmpty || !report.unfixable.isEmpty
        switch mode {
        case .verify:
            report.dirtyAfter = report.dirtyBefore
            return report
        case .safe:
            guard !problems, !report.journalNotClean else { report.dirtyAfter = report.dirtyBefore; return report }
            if report.dirtyBefore { try setDirty(false, volume: volume, storage: storage) }
            report.dirtyAfter = false
            return report
        case .repair:
            guard !report.journalNotClean else { report.dirtyAfter = report.dirtyBefore; return report }
            guard report.unfixable.isEmpty else { report.dirtyAfter = report.dirtyBefore; return report }
            if !problems {
                if report.dirtyBefore { try setDirty(false, volume: volume, storage: storage) }
                report.dirtyAfter = false
                return report
            }
            // Bitmaps first: the cluster bitmap becomes exactly the set of clusters in use.
            var repairedBitmap = used
            if clusters % 8 != 0 { repairedBitmap[repairedBitmap.count - 1] |= ~UInt8((1 << (clusters % 8)) - 1) }
            let fullBitmapSize = Int(bitmapAttribute.size)
            let padding = [UInt8](repeating: 0xff, count: max(0, fullBitmapSize - repairedBitmap.count))
            if repairedBitmap != onDisk {
                try NTFSWriter.writeWholeStream(bitmapAttribute, bytes: repairedBitmap + padding, volume: volume, storage: storage)
                report.repaired.append("Volume bitmap rebuilt (\(lostRanges.count + missingRanges.count) ranges).")
            }
            var newMFTBits = mftBits
            for n in 0..<UInt64(newMFTBits.count * 8) {
                let byte = Int(n / 8), bit = UInt8(1 << (n % 8))
                let shouldBeUsed = inUse.contains(n) || n < 16
                if shouldBeUsed { newMFTBits[byte] |= bit } else if n >= 24 { newMFTBits[byte] &= ~bit }
            }
            if newMFTBits != mftBits {
                if recordBitmap.resident != nil { throw NTFSError("Resident MFT bitmaps are not repaired", code: ENOTSUP) }
                try NTFSWriter.writeWholeStream(recordBitmap, bytes: newMFTBits, volume: volume, storage: storage)
                mftBits = newMFTBits
                report.repaired.append("MFT bitmap corrected.")
            }
            try storage.synchronize()
            // Records and indexes through the normal writer (it marks the volume dirty while open).
            let repaired = try NativeNTFSVolume(storage: storage)
            let writer = try NTFSWriter(volume: repaired, storage: storage, allowDirty: true)
            for (number, links) in linkFixes {
                try writer.setLinkCount(number, links)
                report.repaired.append("Link count of record \(number) set to \(links).")
            }
            for (folder, references) in badEntries {
                try writer.dropEntries(references, from: folder)
                report.repaired.append("Removed \(references.count) wrong entries from folder \(folder).")
            }
            for folder in folderOrderBroken where badEntries[folder] == nil {
                try writer.dropEntries([], from: folder)
                report.repaired.append("Index of folder \(folder) rebuilt.")
            }
            for (number, name) in orphans {
                guard let reference = info[number].map({ number | UInt64($0.sequence) << 48 }) else { continue }
                let text = String(utf16CodeUnits: name.units, count: name.units.count)
                do {
                    try writer.addEntry(key: name.key, reference: reference, to: name.parent & 0x0000ffffffffffff)
                    report.repaired.append("Returned \"\(text)\" to its folder.")
                } catch {
                    report.unfixable.append("\"\(text)\" (record \(number)) could not be returned to its folder: \(error).")
                }
            }
            try writer.close()
            // The writer clears only a mark it set itself; the repaired volume is clean now.
            if try NativeNTFSVolume(storage: storage).dirty {
                try setDirty(false, volume: try NativeNTFSVolume(storage: storage), storage: storage)
            }
            report.errors = []
            report.minor = []
            report.dirtyAfter = false
            let final = try NativeNTFSVolume(storage: storage)
            report.freeBytes = try final.freeClusters() * cluster
            return report
        }
    }

    static func setDirty(_ dirty: Bool, volume: NativeNTFSVolume, storage: NTFSWritableStorage) throws {
        let writer = try NTFSWriter(volume: volume, storage: storage, allowDirty: true, markDirty: false)
        try writer.setVolumeDirtyFlag(dirty)
        try storage.synchronize()
        writer.abandon()
    }
}

extension NTFSWriter {
    /// Writes a complete stream (bitmaps during repair).
    static func writeWholeStream(_ attribute: NTFSAttribute, bytes: [UInt8], volume: NativeNTFSVolume, storage: NTFSWritableStorage) throws {
        let cluster = UInt64(volume.geometry.clusterSize)
        var cursor = 0
        for run in attribute.runs where cursor < bytes.count {
            guard let lcn = run.lcn else { throw NTFSError("Sparse metadata stream") }
            let take = min(Int(run.length * cluster), bytes.count - cursor)
            try storage.write(at: lcn * cluster, bytes: Array(bytes[cursor..<(cursor + take)]))
            cursor += take
        }
        guard cursor == bytes.count else { throw NTFSError("Metadata stream is too short") }
    }
}
