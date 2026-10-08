//
//  OSCManager.swift
//  Midi Set List
//

import Foundation
import Network
import Observation

@Observable
class OSCManager {
    private(set) var connectedTargets: Set<UUID> = []
    private(set) var lastSentAddress: String?
    private(set) var lastError: String?

    // Diagnostics — set by the app after both managers are created
    var activityLog: ActivityLog?

    private var connections: [UUID: NWConnection] = [:]
    private var listeners:   [UUID: NWListener]   = [:]
    private var keepaliveTimers: [UUID: DispatchSourceTimer] = [:]
    private let oscQueue = DispatchQueue(label: "com.midisetlist.osc", qos: .userInteractive)

    /// UUIDs of targets the user has connected to — persisted so they auto-reconnect on launch.
    private var desiredTargetIDs: Set<UUID> = []
    private let desiredTargetIDsKey = "osc.desiredTargetIDs"

    // MARK: - Persistence helpers

    private func persistDesiredTargetIDs() {
        UserDefaults.standard.set(desiredTargetIDs.map { $0.uuidString }, forKey: desiredTargetIDsKey)
    }

    /// Reconnects any target whose ID was previously saved as "desired connected."
    /// Call on launch after Core Data targets are available.
    func restoreConnections(from targets: [OSCTarget]) {
        let raw = UserDefaults.standard.stringArray(forKey: desiredTargetIDsKey) ?? []
        desiredTargetIDs = Set(raw.compactMap { UUID(uuidString: $0) })
        for target in targets where desiredTargetIDs.contains(target.id) {
            connect(to: target)
        }
    }

    // MARK: - Connection Management

    func connect(to target: OSCTarget) {
        guard !connectedTargets.contains(target.id) else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.sendPort)) else {
            lastError = "Invalid send port \(target.sendPort) for \(target.name)"
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: port,
            using: .udp
        )
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.activityLog?.log("OSC ready: \(target.name) (\(target.host):\(target.sendPort))", direction: .system, proto: .osc)
            case .waiting(let error):
                self?.activityLog?.log("OSC waiting: \(target.name) — \(error.localizedDescription)", direction: .error, proto: .osc)
            case .failed(let error):
                DispatchQueue.main.async {
                    self?.lastError = "OSC connection to \(target.name) failed: \(error.localizedDescription)"
                    self?.activityLog?.log("OSC failed: \(target.name) — \(error.localizedDescription)", direction: .error, proto: .osc)
                }
            default:
                break
            }
        }
        connection.start(queue: oscQueue)

        // Receive replies on the SAME connection — the XR18 sends feedback back to
        // our ephemeral source port, not to whatever port NWListener is bound to.
        receiveLoop(connection)

        connections[target.id] = connection
        connectedTargets.insert(target.id)
        desiredTargetIDs.insert(target.id)
        persistDesiredTargetIDs()
        activityLog?.log("OSC connecting: \(target.name) (\(target.host) tx:\(target.sendPort) rx:\(target.receivePort))", direction: .system, proto: .osc)

        startKeepalive(for: target)
        startListener(for: target)
    }

    func disconnect(from target: OSCTarget) {
        stopKeepalive(for: target.id)
        stopListener(for: target.id)
        connections[target.id]?.cancel()
        connections.removeValue(forKey: target.id)
        connectedTargets.remove(target.id)
        desiredTargetIDs.remove(target.id)
        persistDesiredTargetIDs()
        activityLog?.log("OSC disconnected: \(target.name)", direction: .system, proto: .osc)
    }

    func toggleConnection(for target: OSCTarget) {
        if connectedTargets.contains(target.id) {
            disconnect(from: target)
        } else {
            connect(to: target)
        }
    }

    func isConnected(_ target: OSCTarget) -> Bool {
        connectedTargets.contains(target.id)
    }

    /// Call after editing a connected target to restart keepalive with updated settings.
    func updateKeepalive(for target: OSCTarget) {
        guard connectedTargets.contains(target.id) else { return }
        stopKeepalive(for: target.id)
        startKeepalive(for: target)
    }

    // MARK: - Sending

    /// Sends an OSC message with an optional float argument to all connected targets.
    func send(address: String, floatArg: Double?) {
        // /app/… controls this app's own effects — handled here, never sent to the network
        if AppOSC.isAppAddress(address) {
            do {
                let result = try AppOSCRouter.handle(address: address, value: floatArg)
                activityLog?.log("App: \(result)", direction: .out, proto: .osc)
            } catch {
                activityLog?.log("App OSC \(address): \(error.localizedDescription)", direction: .error, proto: .osc)
            }
            lastSentAddress = address
            return
        }
        guard !connections.isEmpty else {
            activityLog?.log("OSC send skipped (no connections): \(address)", direction: .error, proto: .osc)
            return
        }
        let data = OSCEncoder.encode(address: address, floatArg: floatArg.map { Float($0) })
        let logMsg = floatArg.map { "\(address) \u{2192} \(String(format: "%.4g", $0))" } ?? address
        for connection in connections.values {
            connection.send(content: data, completion: .contentProcessed({ [weak self] error in
                if let error {
                    self?.activityLog?.log("OSC send error: \(error.localizedDescription)", direction: .error, proto: .osc)
                }
            }))
        }
        DispatchQueue.main.async {
            self.lastSentAddress = address
            self.activityLog?.log(logMsg, direction: .out, proto: .osc)
        }
    }

    /// Sends a single OSC message to a specific target (used for manual tests).
    func sendTest(address: String, to target: OSCTarget) {
        guard let connection = connections[target.id] else {
            activityLog?.log("OSC test skipped — not connected to \(target.name)", direction: .error, proto: .osc)
            return
        }
        let data = OSCEncoder.encode(address: address, floatArg: nil)
        connection.send(content: data, completion: .contentProcessed({ [weak self] error in
            if let error {
                self?.activityLog?.log("OSC test send error: \(error.localizedDescription)", direction: .error, proto: .osc)
            }
        }))
        activityLog?.log("\(address) [test → \(target.name)]", direction: .out, proto: .osc)
    }

    // MARK: - Keepalive

    private func startKeepalive(for target: OSCTarget) {
        guard let address = target.keepaliveAddress,
              !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        stopKeepalive(for: target.id)

        let interval = target.keepaliveIntervalSeconds
        let timer = DispatchSource.makeTimerSource(flags: [], queue: oscQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self, let conn = self.connections[target.id] else { return }
            let data = OSCEncoder.encode(address: address, floatArg: nil)
            conn.send(content: data, completion: .contentProcessed({ [weak self] error in
                if let error {
                    self?.activityLog?.log("Keepalive send error: \(error.localizedDescription)", direction: .error, proto: .osc)
                }
            }))
            // Keepalive fires silently — only errors surface to avoid log noise
        }
        timer.resume()
        keepaliveTimers[target.id] = timer
        activityLog?.log("Keepalive active: \(address) every \(interval)s → \(target.name)", direction: .system, proto: .osc)
    }

    private func stopKeepalive(for id: UUID) {
        keepaliveTimers[id]?.cancel()
        keepaliveTimers.removeValue(forKey: id)
    }

    // MARK: - Receive / Listener

    private func startListener(for target: OSCTarget) {
        guard target.receivePort > 0,
              let listenPort = NWEndpoint.Port(rawValue: UInt16(target.receivePort)) else { return }
        stopListener(for: target.id)

        do {
            let listener = try NWListener(using: .udp, on: listenPort)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.activityLog?.log("Listening on port \(target.receivePort) ← \(target.name)", direction: .system, proto: .osc)
                case .failed(let error):
                    self?.activityLog?.log("Listener failed on port \(target.receivePort): \(error.localizedDescription)", direction: .error, proto: .osc)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.oscQueue ?? .global())
                self?.receiveLoop(conn)
            }
            listener.start(queue: oscQueue)
            listeners[target.id] = listener
        } catch {
            activityLog?.log("Cannot start listener on port \(target.receivePort): \(error.localizedDescription)", direction: .error, proto: .osc)
        }
    }

    private func stopListener(for id: UUID) {
        listeners[id]?.cancel()
        listeners.removeValue(forKey: id)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                let (address, floatArg) = Self.parseOSCPacket(from: data)
                let msg = floatArg.map { "\(address) \u{2192} \(String(format: "%.4g", $0))" } ?? address
                self?.activityLog?.log(msg, direction: .in, proto: .osc)
                // Linked gain / fader values from the mixer move the strip's controls
                Task { @MainActor in MixerLink.shared.received(address: address, value: floatArg) }
            }
            // For UDP, isComplete is true per datagram — always re-arm unless connection errored
            guard error == nil else { return }
            self?.receiveLoop(connection)
        }
    }

    /// Parses an OSC packet and returns the address and optional first float argument.
    private static func parseOSCPacket(from data: Data) -> (address: String, floatArg: Float?) {
        var offset = 0

        // Read null-terminated address string
        var address = ""
        while offset < data.count, data[offset] != 0 {
            address.append(Character(UnicodeScalar(data[offset])))
            offset += 1
        }
        if address.isEmpty { return ("(empty packet)", nil) }

        // Advance past null terminator and pad to 4-byte boundary
        offset += 1
        if offset % 4 != 0 { offset += 4 - (offset % 4) }

        // Read type tag string (must start with ',')
        guard offset < data.count, data[offset] == UInt8(ascii: ",") else {
            return (address, nil)
        }
        var typeTag = ""
        while offset < data.count, data[offset] != 0 {
            typeTag.append(Character(UnicodeScalar(data[offset])))
            offset += 1
        }

        // Advance past null terminator and pad to 4-byte boundary
        offset += 1
        if offset % 4 != 0 { offset += 4 - (offset % 4) }

        // Read first float argument if present
        if typeTag.contains("f"), offset + 4 <= data.count {
            var bits: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &bits) { data.copyBytes(to: $0, from: offset..<(offset + 4)) }
            return (address, Float(bitPattern: UInt32(bigEndian: bits)))
        }

        return (address, nil)
    }
}
