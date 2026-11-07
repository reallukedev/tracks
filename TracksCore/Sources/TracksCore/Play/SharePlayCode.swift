import Foundation
import Observation

// SharePlay by code, both ways of reaching the host at once: nearby, which needs no network
// at all and is how it usually goes in a car, and the relay, for an App Clip (which can't look
// nearby) or an iPhone that can't reach the host's that way. A guest uses whichever connects
// first and says hello only on that one, so the host counts each person once.

/// The host's side: offers itself nearby and on the relay, and hears from guests on either.
@MainActor
public final class SharePlayCodeHost {
    public enum Status: Sendable, Equatable {
        case starting
        /// A guest with the code can join, one way or the other.
        case ready
        /// Nothing can reach it: Local Network is off, and there's no relay to fall back on.
        case needsLocalNetwork
        /// Couldn't offer itself either way yet. It keeps trying.
        case failed
    }

    public let invite: SharePlayInvite
    public private(set) var status: Status = .starting {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    /// Everyone who's said hello and is still there, either way.
    public var guests: Set<UUID> { nearby.guests.union(relay?.guests ?? []) }

    public var onStatus: ((Status) -> Void)?
    public var onGuestsChanged: ((Set<UUID>) -> Void)?
    public var onMessage: ((SharePlayMessage, UUID) -> Void)?

    private let nearby: SharePlayNearbyHost
    private let relay: SharePlayRelayHost?

    public init(invite: SharePlayInvite, relay config: SharePlayRelayConfig?) {
        self.invite = invite
        nearby = SharePlayNearbyHost(invite: invite)
        relay = config.map { SharePlayRelayHost(invite: invite, config: $0) }
        nearby.onStatus = { [weak self] _ in self?.updateStatus() }
        relay?.onStatus = { [weak self] _ in self?.updateStatus() }
        nearby.onGuestsChanged = { [weak self] _ in self?.guestsChanged() }
        relay?.onGuestsChanged = { [weak self] _ in self?.guestsChanged() }
        nearby.onMessage = { [weak self] message, guest in self?.onMessage?(message, guest) }
        relay?.onMessage = { [weak self] message, guest in self?.onMessage?(message, guest) }
    }

    public func start() {
        nearby.start()
        relay?.start()
    }

    public func resume() {
        nearby.resume()
        relay?.resume()
    }

    public func stop(sayingGoodbye: Bool) {
        nearby.stop(sayingGoodbye: sayingGoodbye)
        relay?.stop(sayingGoodbye: sayingGoodbye)
    }

    public func send(_ message: SharePlayMessage, to guest: UUID) {
        if nearby.guests.contains(guest) {
            nearby.send(message, to: guest)
        } else {
            relay?.send(message, to: guest)
        }
    }

    public func broadcast(_ message: SharePlayMessage) {
        nearby.broadcast(message)
        relay?.broadcast(message)
    }

    private func guestsChanged() {
        onGuestsChanged?(guests)
    }

    private func updateStatus() {
        status = Self.status(nearby: nearby.status, relay: relay?.status)
    }

    /// Ready when either way is; otherwise what's wrong nearby, which is what someone can fix.
    static func status(nearby: SharePlayNearbyHost.Status, relay: SharePlayRelayHost.Status?) -> Status {
        if nearby == .ready || relay == .ready { return .ready }
        switch nearby {
        case .needsLocalNetwork: return .needsLocalNetwork
        case .failed: return .failed
        case .starting, .ready: return .starting
        }
    }
}

/// A guest's side: looks for the host both ways, uses the first that connects, and keeps
/// what the host has said in a ``SharePlayGuest``.
@MainActor
@Observable
public final class SharePlayCodeGuest {
    public let invite: SharePlayInvite
    public private(set) var guest = SharePlayGuest()
    /// Fifteen seconds and no host: it's likely out of reach.
    public private(set) var isSlowToConnect = false
    /// Joined, then lost the host: looking for it again.
    public private(set) var isReconnecting = false
    /// Local Network is off here, and there's no other way to the host.
    public private(set) var needsLocalNetwork = false

    private enum Way { case nearby, relay }

    @ObservationIgnored private let relayConfig: SharePlayRelayConfig?
    @ObservationIgnored private let looksNearby: Bool
    @ObservationIgnored private var nearby: SharePlayNearbyGuest?
    @ObservationIgnored private var relay: SharePlayRelayGuest?
    @ObservationIgnored private var way: Way?
    @ObservationIgnored private var nearbyIsDenied = false
    @ObservationIgnored private var slowTimer: Task<Void, Never>?
    @ObservationIgnored private var giveUp: Task<Void, Never>?
    @ObservationIgnored private var lastResumed = Date.distantPast
    @ObservationIgnored private var isRunning = false

    /// How long it looks for a host it lost before taking SharePlay as over: the host may
    /// have ended it while this iPhone was away and missed the goodbye.
    public static let reconnectLimit: TimeInterval = 300

    /// - Parameter looksNearby: false for an App Clip, which can only use the relay.
    public init(invite: SharePlayInvite, relay: SharePlayRelayConfig?, looksNearby: Bool = true) {
        self.invite = invite
        relayConfig = relay
        self.looksNearby = looksNearby
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        // No way to the host at all (an App Clip built without a relay): say so at once.
        if !looksNearby, relayConfig == nil { isSlowToConnect = true }
        look()
        slowTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, guest.phase == .joining else { return }
            isSlowToConnect = true
            updateNeedsLocalNetwork()
        }
    }

    public func stop() {
        isRunning = false
        slowTimer?.cancel()
        giveUp?.cancel()
        nearby?.stop()
        relay?.stop()
        nearby = nil
        relay = nil
        way = nil
    }

    /// Back in the foreground, where connections may have gone while it was away.
    public func resume() {
        lastResumed = .now
        relay?.resume()
    }

    /// Sends a song to the host, once, however many times it's pressed. Gives up on it if the
    /// host never answers.
    public func add(_ song: SharePlaySong, placement: SharePlayPlacement) {
        guard let request = guest.add(song, placement: placement, at: .now) else { return }
        guard send(.add(request)) else {
            guest.failedToSend(request.id)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(SharePlayGuest.answerTimeout))
            self?.guest.expire(at: .now)
        }
    }

    /// Whether there's a way to the host to send on.
    public var canSend: Bool { way != nil }

    // MARK: - Finding the host

    /// Looks every way it isn't already.
    private func look() {
        guard isRunning else { return }
        if looksNearby, nearby == nil {
            let nearby = SharePlayNearbyGuest(invite: invite)
            nearby.onStatus = { [weak self] status in self?.nearbyChanged(status) }
            nearby.onMessage = { [weak self] message in self?.received(message, on: .nearby) }
            self.nearby = nearby
            nearby.start()
        }
        if let relayConfig, relay == nil {
            let relay = SharePlayRelayGuest(invite: invite, config: relayConfig)
            relay.onStatus = { [weak self] status in self?.changed(.relay, isConnected: status == .connected) }
            relay.onMessage = { [weak self] message in self?.received(message, on: .relay) }
            relay.onHostReturned = { [weak self] in
                guard let self, way == .relay else { return }
                send(.hello)
            }
            self.relay = relay
            relay.start()
        }
    }

    private func nearbyChanged(_ status: SharePlayNearbyGuest.Status) {
        nearbyIsDenied = status == .needsLocalNetwork
        updateNeedsLocalNetwork()
        changed(.nearby, isConnected: status == .connected)
    }

    private func changed(_ changed: Way, isConnected: Bool) {
        if isConnected {
            guard way == nil else { return }
            way = changed
            // One way at a time, so the host counts this iPhone once.
            switch changed {
            case .nearby:
                relay?.stop()
                relay = nil
            case .relay:
                nearby?.stop()
                nearby = nil
            }
            isReconnecting = false
            giveUp?.cancel()
            updateNeedsLocalNetwork()
            // The host answers with what's on, and again after every reconnection.
            send(.hello)
        } else if way == changed {
            way = nil
            if guest.phase == .joined {
                isReconnecting = true
                giveUpEventually()
            }
            look()
        }
    }

    /// Takes SharePlay as over once the host has been gone for ``reconnectLimit``. Counted
    /// while this iPhone is in use: back from a while away, it gets a moment to find the host
    /// before giving up.
    private func giveUpEventually() {
        giveUp?.cancel()
        let lostAt = Date.now
        giveUp = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, isReconnecting else { return }
                let isOverdue = Date.now.timeIntervalSince(lostAt) >= Self.reconnectLimit
                let hasHadAMoment = Date.now.timeIntervalSince(lastResumed) >= 20
                if isOverdue, hasHadAMoment {
                    guest.end()
                    isReconnecting = false
                    stop()
                    return
                }
            }
        }
    }

    private func updateNeedsLocalNetwork() {
        // With a relay, keep looking quietly; say so only once it's taken too long.
        needsLocalNetwork = nearbyIsDenied && way == nil && (relayConfig == nil || isSlowToConnect)
    }

    @discardableResult
    private func send(_ message: SharePlayMessage) -> Bool {
        switch way {
        case .nearby: nearby?.send(message) ?? false
        case .relay: relay?.send(message) ?? false
        case nil: false
        }
    }

    private func received(_ message: SharePlayMessage, on from: Way) {
        guard from == way else { return }
        switch message {
        case .snapshot(let snapshot):
            guest.receive(snapshot)
            isSlowToConnect = false
        case .reply(let reply):
            guest.receive(reply)
        case .ended:
            guest.end()
            isReconnecting = false
            stop()
        case .hello, .add:
            break
        }
    }

    #if DEBUG
    /// For sample data's pretend sessions.
    public func pretend(_ change: (inout SharePlayGuest) -> Void, isSlow: Bool? = nil, isReconnecting: Bool? = nil, needsLocalNetwork: Bool? = nil) {
        change(&guest)
        if let isSlow { isSlowToConnect = isSlow }
        if let isReconnecting { self.isReconnecting = isReconnecting }
        if let needsLocalNetwork { self.needsLocalNetwork = needsLocalNetwork }
    }
    #endif
}
