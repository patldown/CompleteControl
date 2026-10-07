//
//  AppOSCRouter.swift
//  Midi Set List
//
//  Handles /app/ OSC messages (see ModelsAppOSC.swift for the address forms). OSCManager
//  hands them here instead of sending them to the network. Changes are saved to the
//  channel, so they persist like an edit in the Routing tab, and applied to the running
//  engine immediately (values jump; no glide).
//

import CoreData
import Foundation

enum AppOSCRouter {

    enum RouteError: LocalizedError {
        case malformed, unknownChannel(String), unknownEffect(String), unknownParam(String), needsValue

        var errorDescription: String? {
            switch self {
            case .malformed:               "Not an /app/ address the app understands"
            case .unknownChannel(let c):   "No routing channel named \"\(c)\""
            case .unknownEffect(let f):    "No \"\(f)\" effect on that channel"
            case .unknownParam(let p):     "Unknown parameter \"\(p)\""
            case .needsValue:              "This address needs a value"
            }
        }
    }

    /// Applies one /app/ message. Returns a short description of what changed, for the log.
    @discardableResult
    static func handle(address: String, value: Double?) throws -> String {
        let parts = address.dropFirst(AppOSC.prefix.count)
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw RouteError.malformed }

        let engine = AudioRoutingEngine.shared
        let store = AudioRoutingStore.shared

        // /app/engine/run
        if parts.count == 2, parts[0].lowercased() == "engine", parts[1].lowercased() == "run" {
            guard let value else { throw RouteError.needsValue }
            if value >= 0.5 {
                if !engine.isRunning { Task { await engine.start() } }
                return "Engine start"
            }
            engine.stop()
            return "Engine stop"
        }

        guard parts.count == 2 || parts.count == 3 else { throw RouteError.malformed }
        guard var channel = findChannel(parts[0], in: store.channels) else {
            throw RouteError.unknownChannel(parts[0])
        }

        // /app/<channel>/volume | mute
        if parts.count == 2 {
            guard let value else { throw RouteError.needsValue }
            switch parts[1].lowercased() {
            case "volume": channel.volume = Float(min(1, max(0, value)))
            case "mute":   channel.isMuted = value >= 0.5
            default:       throw RouteError.unknownParam(parts[1])
            }
            store.update(channel)
            if engine.isRunning { engine.applyVolume(of: channel) }
            return "\(channel.displayName) \(parts[1]) → \(format(value))"
        }

        // /app/<channel>/<fx>/<param>
        let fxSegment = parts[1].lowercased()
        guard let slotIndex = AppOSC.fxSegments(for: channel)
            .first(where: { $0.segment == fxSegment })?.slotIndex,
              let type = channel.slots[slotIndex].type
        else { throw RouteError.unknownEffect(parts[1]) }

        let key = parts[2]
        var slot = channel.slots[slotIndex]
        let applied: Double
        if key.lowercased() == "bypass" {
            guard let value else { throw RouteError.needsValue }
            slot.isBypassed = value >= 0.5
            applied = slot.isBypassed ? 1 : 0
        } else {
            guard let param = type.oscParams.first(where: { $0.key.lowercased() == key.lowercased() }) else {
                throw RouteError.unknownParam(key)
            }
            if case .action = param.kind {
                applied = 0
            } else if value == nil {
                throw RouteError.needsValue
            } else {
                applied = param.normalized(value ?? 0)
            }
            param.set(&slot, applied)
        }

        channel.slots[slotIndex] = slot
        store.update(channel)
        if engine.isRunning { engine.applySlot(slot, channelID: channel.id, slotIndex: slotIndex) }
        return "\(channel.displayName) \(fxSegment)/\(key) → \(format(applied))"
    }

    /// Name match ignoring case, spaces, "-" and "_"; or ch1, ch2… by strip position
    static func findChannel(_ segment: String, in channels: [AudioChannel]) -> AudioChannel? {
        let wanted = AppOSC.normalize(segment)
        if let byName = channels.first(where: { AppOSC.normalize($0.name) == wanted }) { return byName }
        if wanted.hasPrefix("ch"), let n = Int(wanted.dropFirst(2)), channels.indices.contains(n - 1) {
            return channels[n - 1]
        }
        return nil
    }

    private static func format(_ v: Double) -> String { String(format: "%g", v) }
}

// MARK: - Channel renames

extension AppOSCRouter {
    /// A channel was renamed: rewrite /app/<old>/… in every device macro and song command to
    /// /app/<new>/…, so name-based macros keep working. Position-based (ch1…) addresses are
    /// left alone. Returns how many addresses changed.
    @discardableResult
    static func retargetChannel(from oldName: String, to newSegment: String,
                                in context: NSManagedObjectContext) -> Int {
        let old = AppOSC.normalize(oldName)
        guard !old.isEmpty, old != AppOSC.normalize(newSegment) else { return 0 }

        func rewritten(_ address: String?) -> String? {
            guard let address, AppOSC.isAppAddress(address) else { return nil }
            let rest = address.dropFirst(AppOSC.prefix.count)
            guard let slash = rest.firstIndex(of: "/"),
                  AppOSC.normalize(String(rest[..<slash])) == old else { return nil }
            return AppOSC.prefix + newSegment + rest[slash...]
        }

        let predicate = NSPredicate(format: "oscAddress BEGINSWITH %@", AppOSC.prefix)
        var changed = 0

        let macros = NSFetchRequest<DeviceMacro>(entityName: "DeviceMacro")
        macros.predicate = predicate
        for macro in (try? context.fetch(macros)) ?? [] {
            if let new = rewritten(macro.oscAddress) { macro.oscAddress = new; changed += 1 }
        }

        let commands = NSFetchRequest<MIDICommand>(entityName: "MIDICommand")
        commands.predicate = predicate
        for command in (try? context.fetch(commands)) ?? [] {
            if let new = rewritten(command.oscAddress) { command.oscAddress = new; changed += 1 }
        }

        if changed > 0 { try? context.save() }
        return changed
    }
}
