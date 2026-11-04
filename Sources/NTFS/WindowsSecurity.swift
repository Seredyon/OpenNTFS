import Foundation

/// Windows access control inheritance for new objects, so files written here get the same
/// security Windows itself would assign (owner/group, inherited ACEs with the INHERITED flag,
/// CREATOR OWNER substitution, generic rights mapped to file rights).
enum WindowsSecurity {
    static let objectInherit: UInt8 = 1, containerInherit: UInt8 = 2, noPropagate: UInt8 = 4, inheritOnly: UInt8 = 8, inherited: UInt8 = 0x10

    struct ACE {
        var type: UInt8
        var flags: UInt8
        var mask: UInt32 = 0
        var sid: [UInt8] = []
        var raw: [UInt8] = []     // body of ACE types without a plain mask + SID
    }

    struct Descriptor {
        var owner: [UInt8] = []
        var group: [UInt8] = []
        var daclPresent = false
        var dacl: [ACE] = []
    }

    static func sid(_ authority: UInt8, _ subs: [UInt32]) -> [UInt8] {
        var s: [UInt8] = [1, UInt8(subs.count), 0, 0, 0, 0, 0, authority]
        for v in subs { for i in 0..<4 { s.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        return s
    }

    static let everyone = sid(1, [0]), creatorOwner = sid(3, [0]), creatorGroup = sid(3, [1])
    static let system = sid(5, [18]), administrators = sid(5, [32, 544]), users = sid(5, [32, 545]), authenticated = sid(5, [11])

    private static func sidLength(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o + 8 <= b.count, b[o] == 1, b[o + 1] <= 15 else { throw NTFSError("Invalid security identifier") }
        let n = 8 + 4 * Int(b[o + 1])
        guard o + n <= b.count else { throw NTFSError("Invalid security identifier") }
        return n
    }

    static func parse(_ b: [UInt8]) throws -> Descriptor {
        guard b.count >= 20, b[0] == 1 else { throw NTFSError("Invalid security descriptor") }
        let control = b.get16(2)
        guard control & 0x8000 != 0 else { throw NTFSError("Security descriptor is not self-relative") }
        var d = Descriptor()
        let oo = Int(b.get32(4)), og = Int(b.get32(8)), od = Int(b.get32(16))
        if oo != 0 { let n = try sidLength(b, oo); d.owner = Array(b[oo..<(oo + n)]) }
        if og != 0 { let n = try sidLength(b, og); d.group = Array(b[og..<(og + n)]) }
        if control & 4 != 0, od != 0 {
            guard od + 8 <= b.count else { throw NTFSError("Invalid DACL") }
            let size = Int(b.get16(od + 2)), count = Int(b.get16(od + 4))
            guard size >= 8, od + size <= b.count else { throw NTFSError("Invalid DACL") }
            d.daclPresent = true
            var p = od + 8
            for _ in 0..<count {
                guard p + 4 <= od + size else { throw NTFSError("Invalid ACE") }
                var ace = ACE(type: b[p], flags: b[p + 1])
                let aceSize = Int(b.get16(p + 2))
                guard aceSize >= 4, p + aceSize <= od + size else { throw NTFSError("Invalid ACE") }
                if ace.type <= 3, aceSize >= 16 {
                    ace.mask = b.get32(p + 4)
                    let n = try sidLength(b, p + 8)
                    guard 8 + n <= aceSize else { throw NTFSError("Invalid ACE") }
                    ace.sid = Array(b[(p + 8)..<(p + 8 + n)])
                } else {
                    ace.raw = Array(b[(p + 4)..<(p + aceSize)])
                }
                d.dacl.append(ace)
                p += aceSize
            }
        }
        return d
    }

    static func build(_ d: Descriptor, control: UInt16) -> [UInt8] {
        var acl = [UInt8](repeating: 0, count: 8)
        var revision: UInt8 = 2
        for ace in d.dacl {
            var body = [UInt8]()
            if !ace.sid.isEmpty {
                body = [UInt8](repeating: 0, count: 4)
                body.put32(ace.mask, at: 0)
                body += ace.sid
            } else {
                body = ace.raw
                if (5...8).contains(ace.type) { revision = 4 }
            }
            while body.count % 4 != 0 { body.append(0) }
            acl += [ace.type, ace.flags, 0, 0]
            acl.put16(UInt16(4 + body.count), at: acl.count - 2)
            acl += body
        }
        acl[0] = revision
        acl.put16(UInt16(acl.count), at: 2)
        acl.put16(UInt16(d.dacl.count), at: 4)
        var out = [UInt8](repeating: 0, count: 20)
        out[0] = 1
        out.put16(control | 0x8000 | 4, at: 2)
        out.put32(UInt32(out.count), at: 16)
        out += acl
        out.put32(UInt32(out.count), at: 4)
        out += d.owner
        out.put32(UInt32(out.count), at: 8)
        out += d.group
        return out
    }

    static func mapGeneric(_ m: UInt32) -> UInt32 {
        var r = m & 0x0fffffff
        if m & 0x80000000 != 0 { r |= 0x120089 }
        if m & 0x40000000 != 0 { r |= 0x120116 }
        if m & 0x20000000 != 0 { r |= 0x1200a0 }
        if m & 0x10000000 != 0 { r |= 0x1f01ff }
        return r
    }

    private static func usable(_ s: [UInt8]) -> Bool { !s.isEmpty && s != everyone && s != creatorOwner && s != creatorGroup }

    /// The descriptor Windows would give a new child of an object with `parent` (nil: none).
    static func inherit(parent: [UInt8]?, directory: Bool) -> [UInt8] {
        let parsed = parent.flatMap { try? parse($0) }
        var child = Descriptor()
        child.owner = parsed.map { usable($0.owner) ? $0.owner : administrators } ?? administrators
        child.group = parsed.map { usable($0.group) ? $0.group : administrators } ?? administrators
        child.daclPresent = true
        func substitute(_ s: [UInt8]) -> [UInt8] { s == creatorOwner ? child.owner : (s == creatorGroup ? child.group : s) }
        if let parsed, parsed.daclPresent {
            for ace in parsed.dacl {
                let f = ace.flags, basic = !ace.sid.isEmpty
                if !directory {
                    guard f & objectInherit != 0 else { continue }
                    var c = ace
                    c.flags = inherited
                    if basic { c.mask = mapGeneric(ace.mask); c.sid = substitute(ace.sid) }
                    child.dacl.append(c)
                    continue
                }
                guard f & (objectInherit | containerInherit) != 0 else { continue }
                let applies = f & containerInherit != 0, propagate = f & noPropagate == 0
                if applies {
                    let split = propagate && basic && (ace.sid == creatorOwner || ace.sid == creatorGroup || ace.mask & 0xf0000000 != 0)
                    if split || !propagate {
                        var c = ace
                        c.flags = inherited
                        if basic { c.mask = mapGeneric(ace.mask); c.sid = substitute(ace.sid) }
                        child.dacl.append(c)
                    }
                    if propagate {
                        var c = ace
                        c.flags = (f & (objectInherit | containerInherit)) | inherited | (split ? inheritOnly : 0)
                        child.dacl.append(c)
                    }
                } else if propagate {
                    var c = ace
                    c.flags = objectInherit | inheritOnly | inherited
                    child.dacl.append(c)
                }
            }
        }
        if !child.dacl.isEmpty { return build(child, control: 0x0400) }
        // Nothing inheritable: the defaults Windows uses for the root of removable NTFS media.
        let f: UInt8 = directory ? (objectInherit | containerInherit) : 0
        for (sid, mask) in [(administrators, UInt32(0x1f01ff)), (system, 0x1f01ff), (authenticated, 0x1301bf), (users, 0x1200a9)] {
            child.dacl.append(ACE(type: 0, flags: f, mask: mask, sid: sid))
        }
        return build(child, control: 0)
    }
}
