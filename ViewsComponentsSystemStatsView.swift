//
//  SystemStatsView.swift
//  Midi Set List
//
//  Floating CPU / RAM indicator. Touch-transparent so it never interferes.
//  CPU = this app's threads summed; RAM = physical memory footprint.
//

import Darwin
import Foundation
import Observation
import SwiftUI

// MARK: - Monitor

@Observable
final class SystemStatsMonitor {
    private(set) var cpuPercent: Double = 0
    private(set) var usedMB: Int = 0

    private var timer: Timer?

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sample() }
        }
    }

    deinit { timer?.invalidate() }

    private func sample() {
        cpuPercent = Self.appCPUPercent()
        usedMB     = Self.appMemoryFootprintMB()
    }

    // Sum CPU usage across all threads (can exceed 100 on multi-core).
    private static func appCPUPercent() -> Double {
        var threadsList: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadsList, &count) == KERN_SUCCESS,
              let threads = threadsList else { return 0 }
        defer {
            let size = vm_size_t(UInt(count) * UInt(MemoryLayout<thread_t>.stride))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        }
        // THREAD_BASIC_INFO_COUNT and TH_FLAGS_IDLE/TH_USAGE_SCALE use explicit values
        // because the C macros are not reliably bridged on all iOS SDK configurations.
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.stride / MemoryLayout<natural_t>.stride
        )
        let thFlagsIdle: Int32 = 0x4
        let thUsageScale: Double = 1000.0

        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = basicInfoCount
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS, info.flags & thFlagsIdle == 0 {
                total += Double(info.cpu_usage) / thUsageScale * 100
            }
        }
        return total
    }

    // Physical memory footprint of this process in MB.
    private static func appMemoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint) / 1_048_576
    }
}

// MARK: - View

struct SystemStatsView: View {
    @State private var monitor = SystemStatsMonitor()

    var body: some View {
        HStack(spacing: 4) {
            Text("CPU").foregroundStyle(.tertiary)
            Text(String(format: "%.0f%%", monitor.cpuPercent))
            Text("·").foregroundStyle(.tertiary)
            Text("\(monitor.usedMB) MB")
            Text("RAM").foregroundStyle(.tertiary)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .allowsHitTesting(false)   // touches pass straight through
    }
}
