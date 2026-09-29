//
//  OSCTarget.swift
//  Midi Set List
//

import CoreData
import Foundation

@objc(OSCTarget)
class OSCTarget: NSManagedObject, Identifiable {

    // ── Attributes ─────────────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var host: String
    @NSManaged var dateCreated: Date

    // Core Data backing stores keep their original names to avoid migration
    @NSManaged private var portRaw: Int32
    @NSManaged private var receivePortRaw: Int32

    /// Port to SEND to on the remote device (e.g. 10024 for Behringer XR18).
    var sendPort: Int {
        get { Int(portRaw) }
        set { portRaw = Int32(newValue) }
    }

    /// Local UDP port the app LISTENS on for incoming messages from this target.
    var receivePort: Int {
        get { receivePortRaw <= 0 ? 10024 : Int(receivePortRaw) }
        set { receivePortRaw = Int32(newValue) }
    }

    /// OSC address sent on a repeating timer to keep the mixer subscription alive.
    /// Set to "/xremote" for Behringer XR18/X32. Nil disables keepalive.
    @NSManaged var keepaliveAddress: String?

    @NSManaged private var keepaliveIntervalRaw: Int32
    /// How often (seconds) the keepalive address is sent. Default 8.
    var keepaliveIntervalSeconds: Int {
        get { keepaliveIntervalRaw <= 0 ? 8 : Int(keepaliveIntervalRaw) }
        set { keepaliveIntervalRaw = Int32(max(1, newValue)) }
    }

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        host: String,
        sendPort: Int = 10024,
        receivePort: Int = 10024,
        keepaliveAddress: String? = nil,
        keepaliveIntervalSeconds: Int = 8,
        in context: NSManagedObjectContext
    ) -> OSCTarget {
        let t = OSCTarget(context: context)
        t.id = UUID()
        t.name = name
        t.host = host
        t.portRaw = Int32(sendPort)
        t.receivePortRaw = Int32(receivePort)
        t.keepaliveAddress = keepaliveAddress
        t.keepaliveIntervalRaw = Int32(keepaliveIntervalSeconds)
        t.dateCreated = Date()
        return t
    }

    // ── Computed ───────────────────────────────────────────────────────
    var displayAddress: String { "\(host)  tx:\(sendPort)  rx:\(receivePort)" }
}
