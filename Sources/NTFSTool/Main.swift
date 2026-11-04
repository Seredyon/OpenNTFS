import Foundation
import Darwin

func hex(_ value: Any?) -> [UInt8]? {
    guard let text = value as? String, text.count % 2 == 0 else { return nil }
    var bytes = [UInt8](), index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

@main
struct NativeNTFSCLI {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 3 else {
                throw NTFSError("Usage: native-ntfs info IMAGE | list IMAGE [PATH] | stat IMAGE PATH | free IMAGE | read IMAGE PATH [OFFSET LENGTH]", code: EINVAL)
            }
            if arguments[1] == "format" {
                // format IMAGE [LABEL]: creates a new NTFS volume in a disposable image file.
                let storage = try ImageStorage(path: arguments[2], writable: true)
                var options = NTFSFormatter.Options()
                if arguments.count > 3 { options.label = arguments[3] }
                try NTFSFormatter.format(storage, options: options)
                try FileHandle.standardOutput.write(contentsOf: Data("{\"ok\":true}\n".utf8))
                return
            }
            if arguments[1] == "check" {
                // check IMAGE verify|safe|repair
                guard arguments.count == 4, let mode = NTFSChecker.Mode(rawValue: arguments[3]) else {
                    throw NTFSError("check requires IMAGE and verify, safe or repair", code: EINVAL)
                }
                let storage = try ImageStorage(path: arguments[2], writable: mode != .verify)
                let report = try NTFSChecker.run(storage, mode: mode)
                let json: [String: Any] = ["result": report.result, "errors": report.errors, "minor": report.minor,
                                           "unfixable": report.unfixable, "repaired": report.repaired,
                                           "dirtyBefore": report.dirtyBefore, "dirtyAfter": report.dirtyAfter,
                                           "journalNotClean": report.journalNotClean, "records": report.records,
                                           "folders": report.folders, "freeBytes": report.freeBytes, "log": report.log]
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                return
            }
            if arguments[1] == "write" {
                // write IMAGE OPERATIONS.json: one writable session over a disposable image.
                guard arguments.count == 4 else { throw NTFSError("write requires IMAGE and an operations file", code: EINVAL) }
                let storage = try ImageStorage(path: arguments[2], writable: true)
                let volume = try NativeNTFSVolume(storage: storage)
                let writer = try NTFSWriter(volume: volume, storage: storage)
                let list = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[3]))) as? [[String: Any]] ?? []
                var completed = 0
                do {
                    for operation in list {
                        switch operation["op"] as? String {
                        case "mkdir": try writer.createDirectory(operation["path"] as! String, securityDescriptor: hex(operation["sd"]))
                        case "put":
                            let local = try Data(contentsOf: URL(fileURLWithPath: operation["local"] as! String))
                            let handle = try writer.createFile(operation["path"] as! String, size: UInt64(local.count), securityDescriptor: hex(operation["sd"]))
                            var offset = 0
                            while offset < local.count {
                                let end = min(local.count, offset + 1024 * 1024)
                                try writer.write(handle, at: UInt64(offset), bytes: [UInt8](local[offset..<end]))
                                offset = end
                            }
                            try writer.finish(handle)
                        case "remove": try writer.remove(operation["path"] as! String, directory: operation["directory"] as? Bool ?? false)
                        case "rename": try writer.rename(operation["from"] as! String, to: operation["to"] as! String)
                        case "flush": try writer.flush()
                        case "setsd": try writer.setSecurityDescriptor(operation["path"] as! String, hex(operation["sd"])!)
                        case "fail": throw NTFSError("Requested failure", code: EINTR)
                        case "abort": exit(3)   // simulates a crash in the middle of a session
                        default: throw NTFSError("Unknown write operation", code: EINVAL)
                        }
                        completed += 1
                    }
                    try writer.close()
                } catch {
                    try? writer.close()
                    throw NTFSError("operation \(completed): \(error)", code: (error as? NTFSError)?.code ?? EIO)
                }
                let data = try JSONSerialization.data(withJSONObject: ["ok": true, "completed": completed])
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                return
            }
            let storage = try ImageStorage(path: arguments[2])
            let volume = try NativeNTFSVolume(storage: storage)
            var json: Any?
            switch arguments[1] {
            case "info":
                json = ["label": volume.label, "serial": String(volume.geometry.serial, radix: 16),
                        "bytes": volume.geometry.volumeBytes, "clusterSize": volume.geometry.clusterSize,
                        "recordSize": volume.geometry.recordSize, "dirty": volume.dirty, "readOnly": true] as [String: Any]
            case "list":
                let directory = try volume.resolve(arguments.count > 3 ? arguments[3] : "/")
                json = try volume.entries(in: directory).map {
                    ["name": $0.name, "reference": String($0.reference), "directory": $0.directory, "size": $0.size] as [String: Any]
                }
            case "stat":
                guard arguments.count == 4 else { throw NTFSError("stat requires PATH", code: EINVAL) }
                let record = try volume.resolve(arguments[3])
                json = ["number": record.number, "sequence": record.sequence, "directory": record.directory,
                        "links": record.links, "extensionRecords": record.extensionRecords,
                        "attributes": record.attributes.map { attribute -> [String: Any] in
                            ["type": String(format: "0x%x", attribute.type), "name": attribute.name,
                             "resident": attribute.resident != nil, "size": attribute.size,
                             "runs": attribute.runs.count, "compressed": attribute.compressed]
                        }] as [String: Any]
            case "security":
                guard arguments.count == 4 else { throw NTFSError("security requires PATH", code: EINVAL) }
                let descriptor = try volume.securityDescriptor(of: volume.resolve(arguments[3]))
                json = ["descriptor": descriptor.map { $0.map { String(format: "%02x", $0) }.joined() } ?? NSNull()] as [String: Any]
            case "free":
                json = ["freeClusters": try volume.freeClusters(), "clusterSize": volume.geometry.clusterSize,
                        "totalClusters": volume.geometry.clusterCount] as [String: Any]
            case "read":
                guard arguments.count == 4 || arguments.count == 6 else { throw NTFSError("read requires PATH and optional OFFSET LENGTH", code: EINVAL) }
                let record = try volume.resolve(arguments[3])
                var offset: UInt64 = 0
                var remaining = try record.attribute(0x80).size
                if arguments.count == 6 {
                    guard let start = UInt64(arguments[4]), let count = UInt64(arguments[5]) else { throw NTFSError("Invalid read range", code: EINVAL) }
                    offset = start
                    remaining = count
                }
                while remaining > 0 {
                    let bytes = try volume.contents(of: record, at: offset, count: Int(min(remaining, 1024 * 1024)))
                    if bytes.isEmpty { break }
                    try FileHandle.standardOutput.write(contentsOf: Data(bytes))
                    offset = try checkedAdd(offset, UInt64(bytes.count))
                    remaining -= UInt64(bytes.count)
                }
            default: throw NTFSError("Unknown command", code: EINVAL)
            }
            if let json {
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
        } catch {
            let message = "native-ntfs: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }
}
