import Foundation
import DiskArbitration

/// While a volume is open in OpenNTFS, macOS (or any other app) must not mount it: a second
/// file system driver reading or writing the partition during our writes could corrupt it.
/// A Disk Arbitration mount-approval callback refuses mounts of the guarded partition until the
/// volume is closed, returned to Finder, ejected, or the app quits.
final class MountGuard {
    static let shared = MountGuard()
    private var session: DASession?
    private(set) var guarded: Set<String> = []

    func protect(_ bsdName: String) {
        guarded = [bsdName]
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(s, nil, { disk, context in
            guard let context = context, let bsd = DADiskGetBSDName(disk) else { return nil }
            let owner = Unmanaged<MountGuard>.fromOpaque(context).takeUnretainedValue()
            guard owner.guarded.contains(String(cString: bsd)) else { return nil }
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), "OpenNTFS is using this volume" as CFString)
            return Unmanaged.passRetained(dissenter)
        }, context)
        session = s
    }

    func release() { guarded = [] }
}
