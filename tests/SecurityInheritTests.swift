// Unit test for the Windows ACL inheritance given to new NTFS objects (no disk access).
// Built by run_tests.sh together with Sources/NTFS.
import Foundation

@main
struct SecurityInheritTests {
    typealias W = WindowsSecurity
    static func ace(_ type: UInt8, _ flags: UInt8, _ mask: UInt32, _ sid: [UInt8]) -> W.ACE { W.ACE(type: type, flags: flags, mask: mask, sid: sid) }

    struct E {
        let type: UInt8, flags: UInt8, mask: UInt32, sid: [UInt8]
        init(_ type: UInt8, _ flags: UInt8, _ mask: UInt32, _ sid: [UInt8]) { self.type = type; self.flags = flags; self.mask = mask; self.sid = sid }
    }

    static func main() {
        let user1005 = W.sid(5, [21, 1, 2, 3, 1005]), user1006 = W.sid(5, [21, 1, 2, 3, 1006]), user1007 = W.sid(5, [21, 1, 2, 3, 1007])
        let OI: UInt8 = W.objectInherit, CI: UInt8 = W.containerInherit, NP: UInt8 = W.noPropagate, IO: UInt8 = W.inheritOnly, INH: UInt8 = W.inherited
        let OICI: UInt8 = OI | CI, OICIINH: UInt8 = OI | CI | INH, CIINH: UInt8 = CI | INH, OICIIO: UInt8 = OI | CI | IO, OICIIOINH: UInt8 = OI | CI | IO | INH, OINP: UInt8 = OI | NP
        var parent = W.Descriptor(owner: W.administrators, group: W.system, daclPresent: true, dacl: [])
        parent.dacl = [
            ace(1, OICI, 0x40000, user1005),             // deny WRITE_DAC to a user
            ace(0, OICI, 0x1f01ff, W.administrators),
            ace(0, OICI, 0x1f01ff, W.system),
            ace(0, OICIIO, 0x10000000, W.creatorOwner),  // CREATOR OWNER generic all, inherit only
            ace(0, OICI, 0x1301bf, W.authenticated),
            ace(0, OICI, 0x1200a9, W.users),
            ace(0, CI, 0x100004, user1006),              // folders only
            ace(0, OINP, 0x120089, user1007),            // files directly inside only
            ace(0, 0, 0x1f01ff, W.everyone),             // not inheritable
        ]
        let parentBytes = W.build(parent, control: 0x1000)
        var failures = 0
        func expect(_ label: String, _ bytes: [UInt8], _ wanted: [E], owner: [UInt8] = W.administrators) {
            guard let got = try? W.parse(bytes) else { print("FAIL \(label): unparseable"); failures += 1; return }
            let actual = got.dacl.map { E($0.type, $0.flags, $0.mask, $0.sid) }
            var same = actual.count == wanted.count
            for (a, b) in zip(actual, wanted) where a.type != b.type || a.flags != b.flags || a.mask != b.mask || a.sid != b.sid { same = false }
            if !same || got.owner != owner {
                print("FAIL \(label): \(actual.map { String(format: "%u/0x%02x/0x%08x", $0.type, $0.flags, $0.mask) })")
                failures += 1
            } else {
                print("ok \(label): \(actual.count) entries")
            }
            if W.build(got, control: bytes.get16(2) & 0x7ffb) != bytes { print("FAIL \(label): round trip"); failures += 1 }
        }
        let file = W.inherit(parent: parentBytes, directory: false)
        expect("file", file, [E(1, INH, 0x40000, user1005), E(0, INH, 0x1f01ff, W.administrators), E(0, INH, 0x1f01ff, W.system),
                              E(0, INH, 0x1f01ff, W.administrators), E(0, INH, 0x1301bf, W.authenticated), E(0, INH, 0x1200a9, W.users),
                              E(0, INH, 0x120089, user1007)])
        let folder = W.inherit(parent: parentBytes, directory: true)
        expect("folder", folder, [E(1, OICIINH, 0x40000, user1005), E(0, OICIINH, 0x1f01ff, W.administrators),
                                  E(0, OICIINH, 0x1f01ff, W.system), E(0, INH, 0x1f01ff, W.administrators),
                                  E(0, OICIIOINH, 0x10000000, W.creatorOwner), E(0, OICIINH, 0x1301bf, W.authenticated),
                                  E(0, OICIINH, 0x1200a9, W.users), E(0, CIINH, 0x100004, user1006)])
        let nested = W.inherit(parent: folder, directory: false)
        expect("file in new folder", nested, [E(1, INH, 0x40000, user1005), E(0, INH, 0x1f01ff, W.administrators), E(0, INH, 0x1f01ff, W.system),
                                              E(0, INH, 0x1f01ff, W.administrators), E(0, INH, 0x1301bf, W.authenticated), E(0, INH, 0x1200a9, W.users)])
        let fallback = W.inherit(parent: [1, 2, 3], directory: false)
        expect("fallback file", fallback, [E(0, 0, 0x1f01ff, W.administrators), E(0, 0, 0x1f01ff, W.system),
                                           E(0, 0, 0x1301bf, W.authenticated), E(0, 0, 0x1200a9, W.users)])
        let fallbackFolder = W.inherit(parent: nil, directory: true)
        expect("fallback folder", fallbackFolder, [E(0, OICI, 0x1f01ff, W.administrators), E(0, OICI, 0x1f01ff, W.system),
                                                   E(0, OICI, 0x1301bf, W.authenticated), E(0, OICI, 0x1200a9, W.users)])
        print(failures == 0 ? "OK" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
