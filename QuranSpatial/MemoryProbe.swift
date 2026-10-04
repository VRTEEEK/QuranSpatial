//
//  MemoryProbe.swift
//  QuranSpatial
//
//  Process memory, read from the kernel rather than inferred from asset sizes.
//
//  `phys_footprint` is the figure that matters: it is what jetsam accounts against, and it
//  includes IOSurface and GPU-side allocations that `resident_size` misses — which for a
//  21MB texture set is most of the point of measuring at all.
//

import Darwin
import Foundation

enum MemoryProbe {

    /// Bytes. `nil` when the kernel call fails rather than a misleading zero.
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    static func mb(_ bytes: UInt64?) -> String {
        guard let bytes else { return "<unavailable>" }
        return String(format: "%.2f MB", Double(bytes) / 1_048_576)
    }

    static func mbDelta(_ after: UInt64?, _ before: UInt64?) -> String {
        guard let after, let before else { return "<unavailable>" }
        let d = Int64(bitPattern: after) - Int64(bitPattern: before)
        return String(format: "%+.2f MB", Double(d) / 1_048_576)
    }
}
