import Foundation
import CryptoKit

// SharePlay by code, over the internet: for passengers without Tracks, whose App Clip can't
// look for the host nearby (Apple keeps Bonjour from App Clips), and for anyone whose iPhone
// can't reach the host's that way.
//
// The host and its guests meet on a Supabase Realtime channel named by the code's tag. Every
// message is sealed with a key worked out from the code, so the relay passes along boxes it
// can't open, and an iPhone without the code can't read or add anything. Who's there comes
// from the channel's presence: the host is "host", each guest its own id.

/// Where the relay is: a Supabase project's Realtime, and its publishable key.
public struct SharePlayRelayConfig: Sendable, Hashable {
    /// The project's host, like `abcdefgh.supabase.co`.
    public var host: String
    public var key: String

    public init?(host: String?, key: String?) {
        guard let host, let key, !host.isEmpty, !key.isEmpty, !host.contains("$(") else { return nil }
        self.host = host
        self.key = key
    }

    /// The relay the app was built with: `TracksRelayHost` and `TracksRelayKey` in its
    /// Info.plist, from the xcconfig. Nil when they're empty.
    public static var main: SharePlayRelayConfig? {
        SharePlayRelayConfig(
            host: Bundle.main.object(forInfoDictionaryKey: "TracksRelayHost") as? String,
            key: Bundle.main.object(forInfoDictionaryKey: "TracksRelayKey") as? String
        )
    }

    var socketURL: URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "vsn", value: "1.0.0")]
        return components.url
    }

    /// The channel for an invite: named by its tag, never its key.
    static func topic(for invite: SharePlayInvite) -> String {
        "realtime:motif-shareplay-\(invite.tag)"
    }
}

/// Seals and opens messages with a key only the code's holders can work out.
public struct SharePlayRelayBox: Sendable {
    private let key: SymmetricKey

    public init(invite: SharePlayInvite) {
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: invite.key),
            salt: Data("Tracks SharePlay".utf8),
            info: Data("relay".utf8),
            outputByteCount: 32
        )
    }

    public func seal(_ message: SharePlayMessage) -> String? {
        guard let body = try? JSONEncoder().encode(message),
              let sealed = try? AES.GCM.seal(body, using: key).combined
        else { return nil }
        return sealed.base64EncodedString()
    }

    /// The message in a box, or nil for one sealed with another key, or not a box at all.
    public func open(_ box: String) -> SharePlayMessage? {
        guard let data = Data(base64Encoded: box),
              data.count <= NearbyFraming.largest,
              let sealed = try? AES.GCM.SealedBox(combined: data),
              let body = try? AES.GCM.open(sealed, using: key)
        else { return nil }
        return try? JSONDecoder().decode(SharePlayMessage.self, from: body)
    }
}

/// Who's on a channel, from Realtime's presence: the full state on joining, then what
/// changed. Someone connected twice (a phone that reconnected before its old connection was
/// noticed gone) stays until both have left.
public struct SharePlayRelayPresence: Sendable, Equatable {
    /// Each key's connections, by Realtime's reference for each.
    private(set) var connections: [String: Set<String>] = [:]

    public init() {}

    public var keys: Set<String> { Set(connections.keys) }

    public mutating func replace(with state: [String: Any]) {
        connections = [:]
        add(state)
    }

    public mutating func apply(joins: [String: Any], leaves: [String: Any]) {
        add(joins)
        for (key, refs) in Self.references(in: leaves) {
            connections[key]?.subtract(refs)
            if connections[key]?.isEmpty == true { connections[key] = nil }
        }
    }

    private mutating func add(_ entries: [String: Any]) {
        for (key, refs) in Self.references(in: entries) {
            connections[key, default: []].formUnion(refs)
        }
    }

    private static func references(in entries: [String: Any]) -> [String: Set<String>] {
        entries.reduce(into: [:]) { result, entry in
            let metas = (entry.value as? [String: Any])?["metas"] as? [[String: Any]] ?? []
            result[entry.key] = Set(metas.compactMap { $0["phx_ref"] as? String })
        }
    }
}

/// One Realtime channel over a web socket: joins it, says who's here, passes messages both
/// ways, and comes back on its own after the connection drops.
@MainActor
final class SharePlayRelayChannel {
    enum Status: Equatable {
        case connecting
        case joined
    }

    struct Envelope: Codable, Equatable {
        var from: String
        var to: String
        var box: String
    }

    private(set) var status: Status = .connecting {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private(set) var presence = SharePlayRelayPresence() {
        didSet { if presence != oldValue { onPresence?(presence) } }
    }

    var onStatus: ((Status) -> Void)?
    var onEnvelope: ((Envelope) -> Void)?
    var onPresence: ((SharePlayRelayPresence) -> Void)?

    private let config: SharePlayRelayConfig
    private let topic: String
    private let presenceKey: String
    private var socket: URLSessionWebSocketTask?
    private var loops: [Task<Void, Never>] = []
    private var reference = 0
    private var joinReference = "0"
    private var failures = 0
    private var isRunning = false
    private let session = URLSession(configuration: .ephemeral)
    /// The heartbeat sent last, until the server answers it. Still unanswered at the next
    /// one, the connection has quietly died (a network switch, a phone asleep): start again.
    private var unansweredHeartbeat: String?
    /// When the server last said anything.
    private var lastHeard = Date.distantPast

    init(config: SharePlayRelayConfig, invite: SharePlayInvite, presenceKey: String) {
        self.config = config
        topic = SharePlayRelayConfig.topic(for: invite)
        self.presenceKey = presenceKey
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        disconnect()
        session.invalidateAndCancel()
    }

    /// Sends when joined; says whether it went.
    @discardableResult
    func send(_ envelope: Envelope) -> Bool {
        guard status == .joined,
              let payload = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
        else { return false }
        push(event: "broadcast", payload: ["type": "broadcast", "event": "m", "payload": payload])
        return true
    }

    /// Connecting again straight away, as the app comes back to the foreground, unless the
    /// connection has plainly survived.
    func resume() {
        guard isRunning, status != .joined || Date.now.timeIntervalSince(lastHeard) > 30 else { return }
        failures = 0
        disconnect()
        connect()
    }

    private func connect() {
        guard isRunning, let url = config.socketURL else { return }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        reference += 1
        joinReference = String(reference)
        push(event: "phx_join", payload: [
            "config": [
                "broadcast": ["self": false, "ack": false],
                "presence": ["enabled": true, "key": presenceKey],
                "private": false,
            ],
        ], reference: joinReference)
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else {
                    // Closed here, on purpose, rather than dropped: nothing to do.
                    if !Task.isCancelled { self?.dropped(socket) }
                    return
                }
                guard case .string(let text) = message else { continue }
                self?.received(text)
            }
        })
        // Realtime lets a connection go after a minute without a word.
        unansweredHeartbeat = nil
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                guard unansweredHeartbeat == nil else {
                    dropped(socket)
                    return
                }
                reference += 1
                unansweredHeartbeat = String(reference)
                push(topic: "phoenix", event: "heartbeat", payload: [:], reference: unansweredHeartbeat)
            }
        })
    }

    private func disconnect() {
        loops.forEach { $0.cancel() }
        loops = []
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .connecting
        presence = SharePlayRelayPresence()
    }

    /// Tries again, waiting longer each time it fails in a row, up to fifteen seconds. Only
    /// for the connection in use: one already replaced has nothing to say.
    private func dropped(_ from: URLSessionWebSocketTask? = nil) {
        guard isRunning, from == nil || from === socket else { return }
        disconnect()
        failures += 1
        let wait = min(15, 1 << min(failures - 1, 4))
        loops.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, isRunning else { return }
            loops.removeAll()
            connect()
        })
    }

    private func push(topic: String? = nil, event: String, payload: [String: Any], reference: String? = nil) {
        guard let socket else { return }
        if reference == nil { self.reference += 1 }
        var frame: [String: Any] = [
            "topic": topic ?? self.topic,
            "event": event,
            "payload": payload,
            "ref": reference ?? String(self.reference),
        ]
        if topic == nil { frame["join_ref"] = joinReference }
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.dropped(socket) }
        }
    }

    private func received(_ text: String) {
        lastHeard = .now
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = frame["event"] as? String
        else { return }
        if frame["topic"] as? String == "phoenix" {
            if event == "phx_reply", frame["ref"] as? String == unansweredHeartbeat { unansweredHeartbeat = nil }
            return
        }
        guard frame["topic"] as? String == topic else { return }
        let payload = frame["payload"] as? [String: Any] ?? [:]
        switch event {
        case "phx_reply" where frame["ref"] as? String == joinReference:
            guard payload["status"] as? String == "ok" else {
                dropped()
                return
            }
            failures = 0
            status = .joined
            push(event: "presence", payload: ["type": "presence", "event": "track", "payload": ["at": Date.now.timeIntervalSince1970]])
        case "presence_state":
            presence.replace(with: payload)
        case "presence_diff":
            presence.apply(joins: payload["joins"] as? [String: Any] ?? [:], leaves: payload["leaves"] as? [String: Any] ?? [:])
        case "broadcast":
            // Checked first: a bare string or number here makes JSONSerialization raise an
            // Objective-C exception, which `try?` can't catch, and anyone on the channel can
            // send one.
            guard let inner = payload["payload"],
                  JSONSerialization.isValidJSONObject(inner),
                  let body = try? JSONSerialization.data(withJSONObject: inner),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
            else { return }
            onEnvelope?(envelope)
        case "phx_error", "phx_close":
            dropped()
        default:
            break
        }
    }
}

/// The host's side over the relay: the same as ``SharePlayNearbyHost``, reached from anywhere
/// with a connection.
@MainActor
public final class SharePlayRelayHost {
    public enum Status: Sendable, Equatable {
        case starting
        case ready
    }

    public let invite: SharePlayInvite
    public private(set) var status: Status = .starting {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    /// Guests who've said hello and are still on the channel.
    public private(set) var guests: Set<UUID> = []
    /// Guests the channel has shown as here: only one seen and then gone has left. A hello
    /// can arrive before its sender's presence does.
    private var seen: Set<UUID> = []

    public var onStatus: ((Status) -> Void)?
    public var onGuestsChanged: ((Set<UUID>) -> Void)?
    public var onMessage: ((SharePlayMessage, UUID) -> Void)?

    static let presenceKey = "host"

    private let channel: SharePlayRelayChannel
    private let box: SharePlayRelayBox

    public init(invite: SharePlayInvite, config: SharePlayRelayConfig) {
        self.invite = invite
        box = SharePlayRelayBox(invite: invite)
        channel = SharePlayRelayChannel(config: config, invite: invite, presenceKey: Self.presenceKey)
        channel.onStatus = { [weak self] status in
            self?.status = status == .joined ? .ready : .starting
        }
        channel.onEnvelope = { [weak self] envelope in self?.received(envelope) }
        channel.onPresence = { [weak self] presence in self?.presenceChanged(presence.keys) }
    }

    public func start() { channel.start() }
    public func resume() { channel.resume() }

    public func stop(sayingGoodbye: Bool) {
        if sayingGoodbye, !guests.isEmpty {
            broadcast(.ended)
            let channel = channel
            // A moment for the goodbye to leave before the connection closes under it.
            Task {
                try? await Task.sleep(for: .seconds(1))
                channel.stop()
            }
        } else {
            channel.stop()
        }
        guests = []
    }

    public func send(_ message: SharePlayMessage, to guest: UUID) {
        guard let sealed = box.seal(message) else { return }
        channel.send(.init(from: Self.presenceKey, to: guest.uuidString, box: sealed))
    }

    public func broadcast(_ message: SharePlayMessage) {
        guard !guests.isEmpty, let sealed = box.seal(message) else { return }
        channel.send(.init(from: Self.presenceKey, to: "*", box: sealed))
    }

    /// Anyone who can seal a message with the code is a guest, hello or not: one this host
    /// let go of (it reconnected, and the channel said they'd gone) is taken back, and hears
    /// what's on first.
    private func received(_ envelope: SharePlayRelayChannel.Envelope) {
        guard envelope.to == Self.presenceKey,
              let guest = UUID(uuidString: envelope.from),
              let message = box.open(envelope.box)
        else { return }
        if !guests.contains(guest) {
            guard guests.count < SharePlayNearbyHost.largestGroup else { return }
            guests.insert(guest)
            onGuestsChanged?(guests)
            if message != .hello { onMessage?(.hello, guest) }
        }
        onMessage?(message, guest)
    }

    /// A guest seen on the channel and then gone from it has left. Only while joined: the
    /// channel forgets everyone while it reconnects, and says who's here once it's back.
    private func presenceChanged(_ keys: Set<String>) {
        guard channel.status == .joined else { return }
        seen.formUnion(guests.filter { keys.contains($0.uuidString) })
        let gone = guests.filter { seen.contains($0) && !keys.contains($0.uuidString) }
        guard !gone.isEmpty else { return }
        guests.subtract(gone)
        seen.subtract(gone)
        onGuestsChanged?(guests)
    }
}

/// A guest's side over the relay: joins the code's channel, and counts as connected while
/// the host is there too.
@MainActor
public final class SharePlayRelayGuest {
    public enum Status: Sendable, Equatable {
        /// Connecting, or on the channel without the host.
        case looking
        case connected
    }

    public let invite: SharePlayInvite
    public let id = UUID()
    public private(set) var status: Status = .looking {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    public var onStatus: ((Status) -> Void)?
    public var onMessage: ((SharePlayMessage) -> Void)?
    /// The host came back on a new connection while this one stayed: it may have let this
    /// guest go, so it should hear hello again.
    public var onHostReturned: (() -> Void)?

    private let channel: SharePlayRelayChannel
    private let box: SharePlayRelayBox
    /// The host's connections as last seen.
    private var hostConnections: Set<String> = []

    public init(invite: SharePlayInvite, config: SharePlayRelayConfig) {
        self.invite = invite
        box = SharePlayRelayBox(invite: invite)
        channel = SharePlayRelayChannel(config: config, invite: invite, presenceKey: id.uuidString)
        channel.onStatus = { [weak self] _ in self?.update() }
        channel.onPresence = { [weak self] _ in self?.update() }
        channel.onEnvelope = { [weak self] envelope in self?.received(envelope) }
    }

    public func start() { channel.start() }
    public func stop() { channel.stop() }
    public func resume() { channel.resume() }

    @discardableResult
    public func send(_ message: SharePlayMessage) -> Bool {
        guard status == .connected, let sealed = box.seal(message) else { return false }
        return channel.send(.init(from: id.uuidString, to: SharePlayRelayHost.presenceKey, box: sealed))
    }

    private func update() {
        let connections = channel.presence.connections[SharePlayRelayHost.presenceKey] ?? []
        let isHere = channel.status == .joined && !connections.isEmpty
        let returned = isHere && status == .connected && !connections.isSubset(of: hostConnections)
        hostConnections = connections
        status = isHere ? .connected : .looking
        if returned { onHostReturned?() }
    }

    private func received(_ envelope: SharePlayRelayChannel.Envelope) {
        guard envelope.from == SharePlayRelayHost.presenceKey,
              envelope.to == "*" || envelope.to == id.uuidString,
              let message = box.open(envelope.box)
        else { return }
        onMessage?(message)
    }
}
