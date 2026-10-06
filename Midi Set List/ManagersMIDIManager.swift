//
//  MIDIManager.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation
import CoreMIDI
import Observation
import Synchronization

/// Manages MIDI connections and communication
@Observable
class MIDIManager {
    // MIDI client and ports
    private var midiClient: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private var inputPort: MIDIPortRef = 0
    
    // Discovered devices
    private(set) var availableDevices: [MIDIDevice] = []
    private(set) var connectedDevices: Set<MIDIUniqueID> = []
    /// IDs the user has explicitly connected to — persisted so devices auto-reconnect on reappearance.
    private var desiredConnections: Set<MIDIUniqueID> = []
    private let desiredConnectionsKey = "midi.desiredOutputIDs"

    /// MIDI inputs (controllers, foot pedals…) the app is listening to.
    private(set) var availableSources: [MIDIDevice] = []
    private var connectedSourceRefs: Set<MIDIEndpointRef> = []

    /// Called on the main thread for every incoming CC, Program Change and Note On,
    /// whatever its channel. Set by the app to drive snapshots and set list navigation.
    var onRemoteMessage: ((MIDIRemoteMessage) -> Void)?
    
    // Status
    private(set) var isInitialized = false
    private(set) var lastError: String?
    private(set) var lastSentCommand: String?

    // OSC routing — set by the app after both managers are created
    var oscManager: OSCManager?

    // Diagnostics — set by the app after both managers are created
    var activityLog: ActivityLog?

    // MIDI Clock
    private(set) var isClockRunning = false
    private(set) var currentClockBPM: Int = 120
    private(set) var clockSendsTransport = false   // true = send Start/Stop; false = clock pulses only
    /// Host time of the running clock's first pulse (beat 1), for the metronome to line up with
    private(set) var clockStartHostTime: UInt64 = 0
    private var clockRun: ClockRun?
    
    init() {
        loadDesiredConnections()
        setupMIDI()
        scanForDevices()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Setup
    
    private func setupMIDI() {
        var status: OSStatus

        // Create MIDI client with a notification block so Bluetooth MIDI devices
        // that connect after launch are picked up automatically.
        status = MIDIClientCreateWithBlock("MIDI Set List Client" as CFString, &midiClient) { [weak self] notificationPtr in
            let msgID = notificationPtr.pointee.messageID
            if msgID == .msgObjectAdded || msgID == .msgObjectRemoved || msgID == .msgSetupChanged {
                DispatchQueue.main.async { self?.scanForDevices() }
            }
        }
        guard status == noErr else {
            lastError = "Failed to create MIDI client: \(status)"
            activityLog?.log("MIDI client init failed (status \(status))", direction: .error, proto: .midi)
            return
        }

        // Create output port
        status = MIDIOutputPortCreate(midiClient, "MIDI Set List Output" as CFString, &outputPort)
        guard status == noErr else {
            lastError = "Failed to create output port: \(status)"
            activityLog?.log("MIDI output port init failed (status \(status))", direction: .error, proto: .midi)
            return
        }

        isInitialized = true
        setupInputPort()
        activityLog?.log("MIDI initialized", direction: .system, proto: .midi)
    }

    private func setupInputPort() {
        let status = MIDIInputPortCreateWithBlock(
            midiClient, "MIDI Set List Input" as CFString, &inputPort
        ) { [weak self] packetListPtr, _ in
            var packet = packetListPtr.pointee.packet
            let count = Int(packetListPtr.pointee.numPackets)
            for i in 0..<count {
                let length = Int(packet.length)
                if length > 0 {
                    let bytes: [UInt8] = withUnsafeBytes(of: packet.data) { Array($0.prefix(length)) }
                    self?.handleIncomingMIDI(bytes: bytes)
                }
                if i < count - 1 { packet = MIDIPacketNext(&packet).pointee }
            }
        }
        if status != noErr {
            activityLog?.log("MIDI input port init failed (status \(status))", direction: .error, proto: .midi)
        }
    }

    /// Splits a packet into channel messages. A packet can hold several messages
    /// (common over Bluetooth) and may use running status.
    private func handleIncomingMIDI(bytes: [UInt8]) {
        var i = 0
        var runningStatus: UInt8 = 0
        while i < bytes.count {
            var status = bytes[i]
            if status >= 0xF8 { i += 1; continue }          // realtime (clock etc.) — ignore
            if status >= 0xF0 {                              // SysEx / system common — skip its data
                i += 1
                while i < bytes.count && bytes[i] < 0x80 { i += 1 }
                if i < bytes.count && bytes[i] == 0xF7 { i += 1 }
                runningStatus = 0
                continue
            }
            if status & 0x80 != 0 {
                runningStatus = status
                i += 1
            } else if runningStatus != 0 {
                status = runningStatus
            } else {
                i += 1                                       // stray data byte
                continue
            }
            let type = status & 0xF0
            let dataLength = (type == 0xC0 || type == 0xD0) ? 1 : 2
            guard i + dataLength <= bytes.count else { break }
            handleChannelMessage(status: status, data1: bytes[i], data2: dataLength == 2 ? bytes[i + 1] : 0)
            i += dataLength
        }
    }

    private func handleChannelMessage(status: UInt8, data1: UInt8, data2: UInt8) {
        let messageType = status & 0xF0
        let ch = Int(status & 0x0F) + 1
        var remote: MIDIRemoteMessage?

        switch messageType {
        case 0x90:
            let note = Int(data1), vel = Int(data2)
            let label = vel == 0 ? "Note Off \(note) [Ch \(ch)]" : "Note On \(note) vel \(vel) [Ch \(ch)]"
            activityLog?.log(label, direction: .in, proto: .midi)
            if vel > 0 { remote = MIDIRemoteMessage(kind: .note, channel: ch, number: note, value: vel) }
        case 0x80:
            activityLog?.log("Note Off \(Int(data1)) [Ch \(ch)]", direction: .in, proto: .midi)
        case 0xB0:
            let ccNum = Int(data1), ccVal = Int(data2)
            let kind: ActivityLog.Entry.MIDIPayload.Kind = ccNum == 0 ? .bankSelectMSB
                                                         : ccNum == 32 ? .bankSelectLSB
                                                         : .controlChange
            let payload = ActivityLog.Entry.MIDIPayload(kind: kind, channel: ch, value1: ccNum, value2: ccVal)
            activityLog?.log("CC \(ccNum) = \(ccVal) [Ch \(ch)]", direction: .in, proto: .midi, midiPayload: payload)
            remote = MIDIRemoteMessage(kind: .controlChange, channel: ch, number: ccNum, value: ccVal)
        case 0xC0:
            let prog = Int(data1)
            let payload = ActivityLog.Entry.MIDIPayload(kind: .programChange, channel: ch, value1: prog, value2: nil)
            activityLog?.log("PC \(prog) [Ch \(ch)]", direction: .in, proto: .midi, midiPayload: payload)
            remote = MIDIRemoteMessage(kind: .programChange, channel: ch, number: prog, value: 127)
        default:
            break
        }

        if let remote {
            DispatchQueue.main.async { [weak self] in self?.onRemoteMessage?(remote) }
        }
    }

    /// Listens to every MIDI source once. Safe to call repeatedly (e.g. whenever
    /// a Bluetooth controller connects or disconnects).
    private func connectAllSources() {
        guard inputPort != 0 else { return }
        var current: Set<MIDIEndpointRef> = []
        var sources: [MIDIDevice] = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            current.insert(source)
            if !connectedSourceRefs.contains(source) {
                MIDIPortConnectSource(inputPort, source, nil)
            }

            var uniqueID: MIDIUniqueID = 0
            var name: Unmanaged<CFString>?
            var manufacturer: Unmanaged<CFString>?
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            MIDIObjectGetStringProperty(source, kMIDIPropertyManufacturer, &manufacturer)
            sources.append(MIDIDevice(id: uniqueID,
                                      name: name?.takeRetainedValue() as String? ?? "Unknown Source",
                                      manufacturer: manufacturer?.takeRetainedValue() as String?,
                                      endpoint: source))
        }
        connectedSourceRefs = current
        availableSources = sources
    }

    private func cleanup() {
        clockRun?.running.store(false, ordering: .relaxed)
        clockRun = nil
        if inputPort  != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }
    
    // MARK: - Desired-connection persistence

    private func loadDesiredConnections() {
        let raw = UserDefaults.standard.array(forKey: desiredConnectionsKey) as? [Int] ?? []
        desiredConnections = Set(raw.map { MIDIUniqueID($0) })
    }

    private func persistDesiredConnections() {
        UserDefaults.standard.set(desiredConnections.map { Int($0) }, forKey: desiredConnectionsKey)
    }

    // MARK: - Device Discovery

    func scanForDevices() {
        availableDevices.removeAll()

        let destinationCount = MIDIGetNumberOfDestinations()

        for i in 0..<destinationCount {
            let endpoint = MIDIGetDestination(i)
            guard endpoint != 0 else { continue }

            // Get device properties
            var uniqueID: MIDIUniqueID = 0
            var name: Unmanaged<CFString>?
            var manufacturer: Unmanaged<CFString>?

            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyManufacturer, &manufacturer)

            let deviceName = name?.takeRetainedValue() as String? ?? "Unknown Device"
            let manufacturerName = manufacturer?.takeRetainedValue() as String?

            let device = MIDIDevice(
                id: uniqueID,
                name: deviceName,
                displayName: deviceName,
                manufacturer: manufacturerName,
                isOnline: true,
                endpoint: endpoint
            )

            availableDevices.append(device)
        }
        activityLog?.log("Scan found \(availableDevices.count) MIDI destination\(availableDevices.count == 1 ? "" : "s")", direction: .system, proto: .midi)
        connectAllSources()

        // Auto-reconnect to any previously connected device that just became available.
        for device in availableDevices where desiredConnections.contains(device.id) {
            guard !connectedDevices.contains(device.id) else { continue }
            connectedDevices.insert(device.id)
            activityLog?.log("Auto-reconnected to \(device.displayName)", direction: .system, proto: .midi)
        }
        // Drop any connectedDevices that are no longer in the available list.
        connectedDevices = connectedDevices.filter { id in availableDevices.contains(where: { $0.id == id }) }
    }
    
    // MARK: - Device Connection
    
    func connect(to device: MIDIDevice) {
        connectedDevices.insert(device.id)
        desiredConnections.insert(device.id)
        persistDesiredConnections()
        activityLog?.log("Connected to \(device.displayName)", direction: .system, proto: .midi)
    }

    func disconnect(from device: MIDIDevice) {
        connectedDevices.remove(device.id)
        desiredConnections.remove(device.id)
        persistDesiredConnections()
        activityLog?.log("Disconnected from \(device.displayName)", direction: .system, proto: .midi)
    }
    
    func toggleConnection(for device: MIDIDevice) {
        if isConnected(device) {
            disconnect(from: device)
        } else {
            connect(to: device)
        }
    }
    
    func isConnected(_ device: MIDIDevice) -> Bool {
        connectedDevices.contains(device.id)
    }
    
    var connectedDevicesList: [MIDIDevice] {
        availableDevices.filter { connectedDevices.contains($0.id) }
    }
    
    // MARK: - Send MIDI Commands
    
    /// Send a single command — routes to OSC or MIDI based on command type.
    func sendCommand(_ command: MIDICommand,
                     formulaContext: FormulaEvaluator.Context = FormulaEvaluator.Context(variables: [:])) async throws {
        // Route OSC messages before any MIDI checks
        if command.commandType == .oscMessage {
            let floatArg: Double?
            if let formula = command.oscFormula, !formula.trimmingCharacters(in: .whitespaces).isEmpty {
                floatArg = FormulaEvaluator.evaluate(formula, context: formulaContext)
                if floatArg == nil {
                    activityLog?.log("Formula error in '\(command.oscAddress ?? "")'", direction: .error, proto: .osc)
                }
            } else {
                floatArg = command.oscFloatArg
            }
            oscManager?.send(address: command.oscAddress ?? "", floatArg: floatArg)
            lastSentCommand = command.displayDescription
            return
        }

        guard isInitialized else {
            activityLog?.log("Send failed: MIDI not initialized", direction: .error, proto: .midi)
            throw MIDIError.notInitialized
        }

        let connectedDevicesList = self.connectedDevicesList

        guard !connectedDevicesList.isEmpty else {
            activityLog?.log("Send failed: no MIDI devices connected", direction: .error, proto: .midi)
            throw MIDIError.noDevicesConnected
        }
        
        // Determine channels to send to
        let channels: [UInt8]
        if let specificChannel = command.channel {
            channels = [UInt8(specificChannel - 1)] // MIDI channels are 0-15 internally
        } else {
            // Omni mode - send to all 16 channels
            channels = Array(0..<16)
        }

        // Resolve formula overrides for value1 and value2
        let resolvedValue1: Int
        if let f = command.value1Formula, !f.trimmingCharacters(in: .whitespaces).isEmpty,
           let d = FormulaEvaluator.evaluate(f, context: formulaContext) {
            resolvedValue1 = Int(d.rounded())
        } else {
            resolvedValue1 = command.value1
        }
        let resolvedValue2: Int?
        if let f = command.value2Formula, !f.trimmingCharacters(in: .whitespaces).isEmpty,
           let d = FormulaEvaluator.evaluate(f, context: formulaContext) {
            resolvedValue2 = Int(d.rounded())
        } else {
            resolvedValue2 = command.value2
        }

        // Build MIDI packet
        for channel in channels {
            let packet = buildMIDIPacket(for: command, channel: channel,
                                         value1: resolvedValue1, value2: resolvedValue2)

            // Send to all connected devices
            for device in connectedDevicesList {
                try sendPacket(packet, to: device)
            }
        }

        // Log the actual sent values, not the formula placeholder
        let channelText = command.channel.map { "Ch \($0)" } ?? "Omni"
        let sentDescription: String
        switch command.commandType {
        case .programChange:  sentDescription = "PC \(resolvedValue1) [\(channelText)]"
        case .controlChange:  sentDescription = "CC #\(resolvedValue1) = \(resolvedValue2 ?? 0) [\(channelText)]"
        case .bankSelectMSB:  sentDescription = "Bank MSB \(resolvedValue1) [\(channelText)]"
        case .bankSelectLSB:  sentDescription = "Bank LSB \(resolvedValue1) [\(channelText)]"
        case .oscMessage:     sentDescription = command.displayDescription
        }
        lastSentCommand = sentDescription
        activityLog?.log(sentDescription, direction: .out, proto: .midi)
    }

    /// Send a sequence of commands with delays
    func sendCommandSequence(_ commands: [MIDICommand],
                             formulaContext: FormulaEvaluator.Context = FormulaEvaluator.Context(variables: [:])) async throws {
        guard !commands.isEmpty else { return }
        for command in commands {
            try await sendCommand(command, formulaContext: formulaContext)
            if command.delayMilliseconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(command.delayMilliseconds) * 1_000_000)
            }
        }
    }

    /// Loads a song: sends its Snapshot 1, providing BPM as a formula variable.
    func sendSong(_ song: Song) async throws {
        try await sendSnapshot(0, of: song)
    }

    /// Sends one snapshot's commands in order.
    /// `practiceRate` scales the {bpm} formula variable (1.0 = full tempo).
    func sendSnapshot(_ index: Int, of song: Song, practiceRate: Double = 1.0) async throws {
        let adjustedBPM = song.bpm.map { max(1, Int((Double($0) * practiceRate).rounded())) }
        let ctx = FormulaEvaluator.Context.forSong(bpm: adjustedBPM)
        try await sendCommandSequence(song.commands(inSnapshot: index), formulaContext: ctx)
    }
    
    // MARK: - MIDI Packet Building
    
    private func buildMIDIPacket(for command: MIDICommand, channel: UInt8,
                                  value1: Int, value2: Int?) -> [UInt8] {
        var packet: [UInt8] = []

        switch command.commandType {
        case .programChange:
            let statusByte: UInt8 = 0xC0 | (channel & 0x0F)
            packet = [statusByte, UInt8(clamping: value1)]

        case .controlChange:
            let statusByte: UInt8 = 0xB0 | (channel & 0x0F)
            packet = [statusByte, UInt8(clamping: value1), UInt8(clamping: value2 ?? 0)]

        case .bankSelectMSB:
            let statusByte: UInt8 = 0xB0 | (channel & 0x0F)
            packet = [statusByte, 0x00, UInt8(clamping: value1)]

        case .bankSelectLSB:
            let statusByte: UInt8 = 0xB0 | (channel & 0x0F)
            packet = [statusByte, 0x20, UInt8(clamping: value1)]

        case .oscMessage:
            break  // OSC is routed before buildMIDIPacket is called; nothing to encode here
        }

        return packet
    }
    
    private func sendPacket(_ packet: [UInt8], to device: MIDIDevice) throws {
        var packetList = MIDIPacketList()
        var currentPacket = MIDIPacketListInit(&packetList)
        
        currentPacket = MIDIPacketListAdd(
            &packetList,
            1024,
            currentPacket,
            0,
            packet.count,
            packet
        )
        
        let status = MIDISend(outputPort, device.endpoint, &packetList)
        guard status == noErr else {
            activityLog?.log("MIDI send to \(device.displayName) failed (status \(status))", direction: .error, proto: .midi)
            throw MIDIError.sendFailed(status: status)
        }
    }
    
    // MARK: - MIDI Clock

    /// Starts a MIDI clock at the given BPM, streaming Timing Clock (0xF8) at 24 PPQN.
    /// `startAt` is the host time (mach ticks) of the first pulse — beat 1 — so the
    /// metronome can share it; nil starts a moment from now. Call from the main thread.
    ///
    /// Each pulse is handed to CoreMIDI a few milliseconds early, stamped with the exact
    /// time it should go out, so thread wake-up delays never reach the wire as jitter.
    func startClock(bpm: Int, sendTransport: Bool = false, startAt: UInt64? = nil) {
        stopClock()

        // Clock is a system broadcast — send to all available devices, not just connected ones.
        let endpoints = availableDevices.map(\.endpoint)
        guard !endpoints.isEmpty, bpm > 0 else { return }

        currentClockBPM = bpm
        clockSendsTransport = sendTransport

        let pulse = HostTime.clockPulseTicks(bpm: bpm)
        let firstPulse = startAt ?? (mach_absolute_time() + HostTime.ticks(seconds: Self.clockLeadIn))
        clockStartHostTime = firstPulse

        let run = ClockRun()
        clockRun = run
        Self.runClock(run, port: outputPort, endpoints: endpoints, firstPulse: firstPulse,
                      pulse: pulse, sendStart: sendTransport)
        isClockRunning = true
        activityLog?.log("Clock started at \(bpm) BPM", direction: .system, proto: .midi)
    }

    /// Stops the MIDI clock and sends MIDI Stop (0xFC). Call from the main thread.
    func stopClock() {
        // Each run has its own flag, so a quick stop + start can never leave the old
        // thread running beside the new one (which would double the clock)
        clockRun?.running.store(false, ordering: .relaxed)
        clockRun = nil

        let endpoints = availableDevices.map(\.endpoint)
        if clockSendsTransport && !endpoints.isEmpty {
            Self.sendRealtime(0xFC, at: 0, port: outputPort, endpoints: endpoints)
        }
        isClockRunning = false
        clockSendsTransport = false
        activityLog?.log("Clock stopped", direction: .system, proto: .midi)
    }

    /// Time from starting the clock to its first pulse, so the first one can be stamped ahead
    static let clockLeadIn: Double = 0.03
    /// How early each pulse is handed to CoreMIDI
    private nonisolated static let clockLookahead: Double = 0.005

    /// One running clock's stop flag, shared with its thread
    nonisolated final class ClockRun: Sendable {
        let running = Atomic<Bool>(true)
    }

    /// The clock thread. Nonisolated: it touches only the values passed in, never the manager.
    private nonisolated static func runClock(_ run: ClockRun, port: MIDIPortRef, endpoints: [MIDIEndpointRef],
                                             firstPulse: UInt64, pulse: UInt64, sendStart: Bool) {
        let lookahead = HostTime.ticks(seconds: clockLookahead)
        let thread = Thread {
            // Start goes out one pulse before beat 1, so Start→first Clock is one pulse
            if sendStart { sendRealtime(0xFA, at: firstPulse &- pulse, port: port, endpoints: endpoints) }
            var nextPulse = firstPulse
            while run.running.load(ordering: .relaxed) {
                mach_wait_until(nextPulse &- lookahead)    // kernel-level precision wait
                guard run.running.load(ordering: .relaxed) else { break }
                sendRealtime(0xF8, at: nextPulse, port: port, endpoints: endpoints)
                nextPulse += pulse                          // absolute schedule — never drifts
            }
        }
        thread.threadPriority = 1.0   // real-time priority for timing accuracy
        thread.start()
    }

    /// Sends a single-byte MIDI System Real-Time message, delivered by CoreMIDI at
    /// `timeStamp` (host time; 0 = now). Safe to call from any thread.
    private nonisolated static func sendRealtime(_ byte: UInt8, at timeStamp: MIDITimeStamp,
                                                 port: MIDIPortRef, endpoints: [MIDIEndpointRef]) {
        var bytes: [UInt8] = [byte]
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, timeStamp, 1, &bytes)
        for endpoint in endpoints {
            MIDISend(port, endpoint, &packetList)
        }
    }

    // MARK: - Test Commands
    
    /// Send a test note on/off to verify connection
    func sendTestNote(channel: Int = 1, note: Int = 60, velocity: Int = 100) async throws {
        guard isInitialized else {
            throw MIDIError.notInitialized
        }
        
        let connectedDevicesList = self.connectedDevicesList
        guard !connectedDevicesList.isEmpty else {
            throw MIDIError.noDevicesConnected
        }
        
        let ch = UInt8((channel - 1) & 0x0F)
        
        // Note On
        let noteOnPacket: [UInt8] = [0x90 | ch, UInt8(note & 0x7F), UInt8(velocity & 0x7F)]
        
        for device in connectedDevicesList {
            try sendPacket(noteOnPacket, to: device)
        }
        
        // Wait 500ms
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Note Off
        let noteOffPacket: [UInt8] = [0x80 | ch, UInt8(note & 0x7F), 0x00]
        
        for device in connectedDevicesList {
            try sendPacket(noteOffPacket, to: device)
        }
        
        lastSentCommand = "Test Note: \(note) Ch \(channel)"
        activityLog?.log("Test note \(note) Ch \(channel)", direction: .out, proto: .midi)
    }
}

// MARK: - Errors

enum MIDIError: LocalizedError {
    case notInitialized
    case noDevicesConnected
    case packetCreationFailed
    case sendFailed(status: OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "MIDI system not initialized"
        case .noDevicesConnected:
            return "No MIDI devices connected"
        case .packetCreationFailed:
            return "Failed to create MIDI packet"
        case .sendFailed(let status):
            return "Failed to send MIDI data (status: \(status))"
        }
    }
}

// MARK: - Integer Clamping Extension

extension UInt8 {
    init(clamping value: Int) {
        if value < 0 {
            self = 0
        } else if value > 127 {
            self = 127
        } else {
            self = UInt8(value)
        }
    }
}
