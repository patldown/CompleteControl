//
//  LiveFollowSession.swift
//  Midi Set List
//
//  Live Follow: one device leads, bandmates' devices follow its set list, song and
//  snapshot — each showing its own parts. Peer-to-peer over Wi-Fi or Bluetooth
//  (MultipeerConnectivity), so it needs no router, internet or accounts.
//
//  When a follower joins, or the leader starts another set list, the leader sends the
//  set list with its songs. New songs are added; if the follower already has some of
//  them it's asked before they're updated.
//
//  Followers send no MIDI or OSC unless they turn that on: the leader is already
//  driving the shared gear, and a second device sending would double every change.
//

import CoreData
import Foundation
import MultipeerConnectivity
import Observation
import UIKit

/// What the leader is playing
struct LiveState: Codable, Equatable {
    var setListID: UUID?
    var setListName: String?
    var songID: UUID?
    var songIndex: Int
    var snapshot: Int
}

/// Everything sent between devices
enum LiveMessage: Codable {
    case state(LiveState)
    /// Where the leader is in a chart, 0 (top) to 1 (end)
    case scroll(chartID: UUID, fraction: Double)
}

@MainActor
@Observable
final class LiveFollowSession: NSObject {

    static let shared = LiveFollowSession()
    static let serviceType = "msl-live"
    /// Posted on followers with userInfo ["chartID": UUID, "fraction": Double]
    static let scrollNotification = Notification.Name("LiveFollowScroll")

    enum Mode: Equatable { case off, leading, following }

    struct Leader: Identifiable, Equatable {
        let peer: MCPeerID
        var id: String { peer.displayName }
        var name: String { peer.displayName }
    }

    /// A set list the leader sent that would update songs already here
    struct PendingSet: Identifiable {
        let id = UUID()
        let archive: DataArchive
        let from: String
        let existingCount: Int
        let newCount: Int
    }

    // MARK: State

    private(set) var mode: Mode = .off
    /// Leading: names of devices following
    private(set) var followerNames: [String] = []
    /// Following: leaders nearby to join
    private(set) var nearbyLeaders: [Leader] = []
    /// Following: the leader's name, and whether we're connected to it right now
    private(set) var leaderName: String?
    private(set) var isConnected = false
    /// Short news for the UI ("Got Friday Gig from Pat")
    private(set) var statusMessage: String?
    var pendingSet: PendingSet?

    // MARK: Settings (this device)

    var stageName: String {
        didSet { UserDefaults.standard.set(stageName, forKey: "liveStageName") }
    }
    /// Followers send their own snapshots' MIDI / OSC too (only for gear on this device)
    var followerSendsCommands: Bool {
        didSet { UserDefaults.standard.set(followerSendsCommands, forKey: "liveFollowerSendsCommands") }
    }
    /// Followers' charts scroll with the leader's when they show the same chart
    var followScroll: Bool {
        didSet { UserDefaults.standard.set(followScroll, forKey: "liveFollowScroll") }
    }
    /// Followers may trigger snapshots themselves. Off by default: only the leader changes
    /// snapshots, so two devices never fight over the same gear.
    var followerControlsSnapshots: Bool {
        didSet { UserDefaults.standard.set(followerControlsSnapshots, forKey: "liveFollowerControlsSnapshots") }
    }

    /// Following without the override: Perform's snapshots are greyed out, and pedals and
    /// MIDI triggers don't change them
    var snapshotsLocked: Bool { mode == .following && !followerControlsSnapshots }

    /// Set by the app
    @ObservationIgnored weak var performance: PerformanceSession?

    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var lastSentState: LiveState?
    @ObservationIgnored private var lastSentSetListID: UUID?
    @ObservationIgnored private var lastScrollSent = Date.distantPast
    /// Following: the leader's latest state, re-applied once a set list it needs arrives
    @ObservationIgnored private var latestState: LiveState?

    private override init() {
        let defaults = UserDefaults.standard
        // Device names need an entitlement, and a name the person types is friendlier anyway
        stageName = defaults.string(forKey: "liveStageName") ?? "My \(UIDevice.current.model)"
        followerSendsCommands = defaults.bool(forKey: "liveFollowerSendsCommands")
        followScroll = defaults.object(forKey: "liveFollowScroll") as? Bool ?? true
        followerControlsSnapshots = defaults.bool(forKey: "liveFollowerControlsSnapshots")
        super.init()
    }

    var connectedCount: Int { session?.connectedPeers.count ?? 0 }

    // MARK: Leading

    func startLeading() {
        stop()
        let peer = makePeer()
        let session = makeSession(peer)
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.session = session
        self.advertiser = advertiser
        mode = .leading
        statusMessage = nil
    }

    /// Called whenever the leader's performance changes
    func leaderStateChanged() {
        guard mode == .leading, let session, !session.connectedPeers.isEmpty else { return }
        let state = currentState()
        if state.setListID != lastSentSetListID, state.setListID != nil {
            sendSetList(to: session.connectedPeers)
        }
        guard state != lastSentState else { return }
        lastSentState = state
        send(.state(state), to: session.connectedPeers, reliable: true)
    }

    /// Leading: report where this device is in a chart (throttled)
    func reportScroll(chartID: UUID, fraction: Double) {
        guard mode == .leading, let session, !session.connectedPeers.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScrollSent) > 0.2 else { return }
        lastScrollSent = now
        send(.scroll(chartID: chartID, fraction: fraction), to: session.connectedPeers, reliable: false)
    }

    private func currentState() -> LiveState {
        let performance = performance
        return LiveState(
            setListID: performance?.setList?.id,
            setListName: performance?.setList?.name,
            songID: performance?.currentSong?.id,
            songIndex: performance?.songIndex ?? 0,
            snapshot: performance?.activeSnapshot ?? 0
        )
    }

    /// Sends the playing set list, with its songs, parts and files
    private func sendSetList(to peers: [MCPeerID]) {
        guard let session, let setList = performance?.setList, !peers.isEmpty else { return }
        lastSentSetListID = setList.id
        do {
            let archive = try DataArchiveExporter.share([setList], title: setList.name)
            let url = try DataArchiveExporter.write(archive, fileName: "Live-\(UUID().uuidString).json")
            for peer in peers {
                session.sendResource(at: url, withName: "setlist", toPeer: peer) { _ in }
            }
        } catch {
            statusMessage = "Couldn't send the set list: \(error.localizedDescription)"
        }
    }

    // MARK: Following

    func startBrowsing() {
        stop()
        let peer = makePeer()
        session = makeSession(peer)
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        mode = .following
        statusMessage = nil
    }

    func join(_ leader: Leader) {
        guard let session, let browser else { return }
        leaderName = leader.name
        statusMessage = "Joining \(leader.name)…"
        browser.invitePeer(leader.peer, to: session, withContext: nil, timeout: 15)
    }

    /// Leave, lead or stop — ends any Live Follow session
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        mode = .off
        followerNames = []
        nearbyLeaders = []
        leaderName = nil
        isConnected = false
        lastSentState = nil
        lastSentSetListID = nil
        latestState = nil
    }

    private func apply(_ state: LiveState) {
        latestState = state
        guard let performance else { return }
        guard let setListID = state.setListID else {
            if performance.isPlaying { performance.stop() }
            statusMessage = "\(leaderName ?? "The leader") isn't playing a set list"
            return
        }
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<SetList>(entityName: "SetList")
        request.predicate = NSPredicate(format: "id == %@", setListID as CVarArg)
        request.fetchLimit = 1
        guard let setList = try? context.fetch(request).first else {
            statusMessage = "Waiting for \"\(state.setListName ?? "the set list")\" from \(leaderName ?? "the leader")…"
            return
        }
        // Follow by song, not position, in case this device's copy is in another order
        let songs = setList.songs
        let index = state.songID.flatMap { id in songs.firstIndex { $0.id == id } } ?? state.songIndex
        performance.follow(setList, songIndex: index, snapshot: state.snapshot, sendCommands: followerSendsCommands)
        if statusMessage?.hasPrefix("Waiting") == true || statusMessage?.hasPrefix("Joining") == true {
            statusMessage = nil
        }
    }

    private func receivedSetList(at url: URL, from name: String) {
        defer { try? FileManager.default.removeItem(at: url) }
        let context = PersistenceController.shared.viewContext
        do {
            let archive = try DataArchiveImporter.read(url)
            let summary = DataArchiveImporter.summary(of: archive, context: context)
            let songs = summary.lines.first { $0.entity == "Song" }
            let existing = (songs?.existing ?? 0) + (summary.lines.first { $0.entity == "SetList" }?.existing ?? 0)
            if existing == 0 {
                try DataArchiveImporter.apply(archive, mode: .merge, context: context)
                statusMessage = "Got \"\(archive.title)\" from \(name)"
                if let latestState { apply(latestState) }
            } else {
                pendingSet = PendingSet(archive: archive, from: name, existingCount: songs?.existing ?? 0,
                                        newCount: (songs?.total ?? 0) - (songs?.existing ?? 0))
            }
        } catch {
            statusMessage = "Couldn't read the set list from \(name): \(error.localizedDescription)"
        }
    }

    /// Answer to "Update songs from the leader?": true updates them, false keeps this device's
    func resolvePendingSet(update: Bool) {
        guard let pending = pendingSet else { return }
        pendingSet = nil
        do {
            try DataArchiveImporter.apply(pending.archive, mode: update ? .merge : .addNewOnly,
                                          context: PersistenceController.shared.viewContext)
            statusMessage = update ? "Updated \"\(pending.archive.title)\" from \(pending.from)"
                                   : "Kept your songs; added what was new"
            if let latestState { apply(latestState) }
        } catch {
            statusMessage = "Couldn't add the set list: \(error.localizedDescription)"
        }
    }

    // MARK: Plumbing

    private func makePeer() -> MCPeerID {
        let trimmed = stageName.trimmingCharacters(in: .whitespacesAndNewlines)
        // MCPeerID names are limited to 63 bytes of UTF-8
        var name = trimmed.isEmpty ? "Band Member" : trimmed
        while name.utf8.count > 63 { name.removeLast() }
        return MCPeerID(displayName: name)
    }

    private func makeSession(_ peer: MCPeerID) -> MCSession {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    private func send(_ message: LiveMessage, to peers: [MCPeerID], reliable: Bool) {
        guard let session, !peers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers, with: reliable ? .reliable : .unreliable)
    }

    private func peerChanged(_ peer: MCPeerID, state: MCSessionState) {
        switch mode {
        case .leading:
            followerNames = session?.connectedPeers.map(\.displayName).sorted() ?? []
            if state == .connected {
                // Catch the new follower up: the set list, then where we are in it
                sendSetList(to: [peer])
                send(.state(currentState()), to: [peer], reliable: true)
            }
        case .following:
            guard peer.displayName == leaderName else { return }
            isConnected = state == .connected
            switch state {
            case .connected: statusMessage = nil
            case .notConnected: statusMessage = "\(peer.displayName) disconnected — reconnecting…"
            default: break
            }
        case .off:
            break
        }
    }

    private func received(_ message: LiveMessage) {
        guard mode == .following else { return }
        switch message {
        case .state(let state):
            apply(state)
        case .scroll(let chartID, let fraction):
            guard followScroll else { return }
            NotificationCenter.default.post(name: Self.scrollNotification, object: nil,
                                            userInfo: ["chartID": chartID, "fraction": fraction])
        }
    }

    private func found(_ peer: MCPeerID) {
        guard mode == .following else { return }
        if !nearbyLeaders.contains(where: { $0.name == peer.displayName }) {
            nearbyLeaders.append(Leader(peer: peer))
        }
        // Reconnect to the leader we were following
        if !isConnected, peer.displayName == leaderName, let session {
            browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
        }
    }

    private func lost(_ peer: MCPeerID) {
        nearbyLeaders.removeAll { $0.name == peer.displayName }
    }
}

// MARK: - MultipeerConnectivity delegates (called off the main thread)

extension LiveFollowSession: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peerChanged(peerID, state: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let message = try? JSONDecoder().decode(LiveMessage.self, from: data) else { return }
            self.received(message)
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // The received file is removed when this returns, so move it first
        guard error == nil, let localURL else { return }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Live-in-\(UUID().uuidString).json")
        guard (try? FileManager.default.moveItem(at: localURL, to: kept)) != nil else { return }
        let name = peerID.displayName
        Task { @MainActor in self.receivedSetList(at: kept, from: name) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            invitationHandler(self.mode == .leading, self.session)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.lost(peerID) }
    }
}
