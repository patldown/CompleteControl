//
//  MIDIManager.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation
import CoreMIDI
import Observation

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
    private var clockThread: Thread?
    private var clockThreadRunning = false
    
    init() {
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

    private func handleIncomingMIDI(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let status = bytes[0]
        guard status < 0xF8 else { return }   // ignore realtime messages (clock, etc.)

        let messageType = status & 0xF0
        let ch = Int(status & 0x0F) + 1

        switch messageType {
        case 0x90:
            guard bytes.count >= 3 else { return }
            let note = Int(bytes[1]), vel = Int(bytes[2])
            let label = vel == 0 ? "Note Off \(note) [Ch \(ch)]" : "Note On \(note) vel \(vel) [Ch \(ch)]"
            activityLog?.log(label, direction: .in, proto: .midi)
        case 0x80:
            guard bytes.count >= 2 else { return }
            activityLog?.log("Note Off \(Int(bytes[1])) [Ch \(ch)]", direction: .in, proto: .midi)
        case 0xB0:
            guard bytes.count >= 3 else { return }
            let ccNum = Int(bytes[1]), ccVal = Int(bytes[2])
            let kind: ActivityLog.Entry.MIDIPayload.Kind = ccNum == 0 ? .bankSelectMSB
                                                         : ccNum == 32 ? .bankSelectLSB
                                                         : .controlChange
            let payload = ActivityLog.Entry.MIDIPayload(kind: kind, channel: ch, value1: ccNum, value2: ccVal)
            activityLog?.log("CC \(ccNum) = \(ccVal) [Ch \(ch)]", direction: .in, proto: .midi, midiPayload: payload)
        case 0xC0:
            guard bytes.count >= 2 else { return }
            let prog = Int(bytes[1])
            let payload = ActivityLog.Entry.MIDIPayload(kind: .programChange, channel: ch, value1: prog, value2: nil)
            activityLog?.log("PC \(prog) [Ch \(ch)]", direction: .in, proto: .midi, midiPayload: payload)
        default:
            break
        }
    }

    private func connectAllSources() {
        guard inputPort != 0 else { return }
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let source = MIDIGetSource(i)
            if source != 0 { MIDIPortConnectSource(inputPort, source, nil) }
        }
    }

    private func cleanup() {
        clockThreadRunning = false
        clockThread = nil
        if inputPort  != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
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
    }
    
    // MARK: - Device Connection
    
    func connect(to device: MIDIDevice) {
        connectedDevices.insert(device.id)
        activityLog?.log("Connected to \(device.displayName)", direction: .system, proto: .midi)
    }

    func disconnect(from device: MIDIDevice) {
        connectedDevices.remove(device.id)
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

    /// Send all commands for a song, providing BPM as a formula variable.
    func sendSong(_ song: Song) async throws {
        let ctx = FormulaEvaluator.Context.forSong(bpm: song.bpm)
        try await sendCommandSequence(song.sortedCommands, formulaContext: ctx)
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

    /// Starts a MIDI clock at the given BPM.
    /// Sends MIDI Start (0xFA) immediately, then streams Timing Clock (0xF8)
    /// pulses at 24 PPQN. Call from the main thread.
    func startClock(bpm: Int, sendTransport: Bool = false) {
        stopClock()

        // Clock is a system broadcast — send to all available devices, not just connected ones.
        let devices = availableDevices
        guard !devices.isEmpty, bpm > 0 else { return }

        currentClockBPM = bpm
        clockSendsTransport = sendTransport

        // Optionally send MIDI Start (0xFA) — only when the user explicitly wants transport.
        if sendTransport {
            sendSystemRealtime(0xFA, to: devices)
        }

        // Convert pulse interval to Mach absolute time units (same kernel primitive
        // used by AudioUnit) for sub-millisecond accuracy across all Apple hardware.
        var tbInfo = mach_timebase_info_data_t()
        mach_timebase_info(&tbInfo)
        let nsPerPulse = UInt64(60_000_000_000.0 / Double(bpm * 24))
        // machPerPulse = nsPerPulse × (denom / numer)  — converts ns → mach ticks
        let machPerPulse = tbInfo.numer == tbInfo.denom
            ? nsPerPulse
            : nsPerPulse * UInt64(tbInfo.denom) / UInt64(tbInfo.numer)

        clockThreadRunning = true
        let thread = Thread {
            // Start one full period after the Start message so the first
            // Start→Clock interval is exactly one beat-subdivision.
            var nextFire = mach_absolute_time() + machPerPulse
            while self.clockThreadRunning {
                mach_wait_until(nextFire)          // kernel-level precision wait
                guard self.clockThreadRunning else { break }
                self.sendSystemRealtime(0xF8, to: devices)
                nextFire += machPerPulse           // absolute schedule — never drifts
            }
        }
        thread.threadPriority = 1.0   // real-time priority for timing accuracy
        thread.start()
        clockThread = thread
        isClockRunning = true
        activityLog?.log("Clock started at \(bpm) BPM", direction: .system, proto: .midi)
    }

    /// Stops the MIDI clock and sends MIDI Stop (0xFC). Call from the main thread.
    func stopClock() {
        clockThreadRunning = false
        clockThread = nil

        let devices = availableDevices
        if clockSendsTransport && !devices.isEmpty {
            sendSystemRealtime(0xFC, to: devices)
        }
        isClockRunning = false
        clockSendsTransport = false
        activityLog?.log("Clock stopped", direction: .system, proto: .midi)
    }

    /// Sends a single-byte MIDI System Real-Time message to all specified devices.
    /// Safe to call from any thread — does not touch @Observable properties.
    private func sendSystemRealtime(_ byte: UInt8, to devices: [MIDIDevice]) {
        var bytes: [UInt8] = [byte]
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, 1, &bytes)
        for device in devices {
            MIDISend(outputPort, device.endpoint, &packetList)
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
