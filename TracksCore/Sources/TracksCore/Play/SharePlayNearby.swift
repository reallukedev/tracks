import Foundation
import Network

// SharePlay by code: the host offers itself nearby with Bonjour, peer-to-peer Wi-Fi included
// as AirDrop does, so it works in a car with no network at all. A guest who scanned the code
// looks for the host with the code's tag and connects with TLS keyed by the code (see
// ``SharePlayInvite``). Then they say what a session in Messages says (``SharePlayMessage``),
// each message framed as Nearby Devices frames its own (``NearbyFraming``).

/// The host's side: offers itself to anyone with the code, and hears from each guest.
@MainActor
public final class SharePlayNearbyHost {
    public enum Status: Sendable, Equatable {
        case starting
        /// Offered nearby: a guest with the code can join.
        case ready
        /// Local Network is off for Tracks, so nothing nearby can reach it.
        case needsLocalNetwork
        /// Couldn't offer itself. It tries again on its own.
        case failed
    }

    public let invite: SharePlayInvite
    public private(set) var status: Status = .starting {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    /// Guests who've said hello, by the id this host gave their connection.
    public private(set) var guests: Set<UUID> = []

    public var onStatus: ((Status) -> Void)?
    public var onGuestsChanged: ((Set<UUID>) -> Void)?
    public var onMessage: ((SharePlayMessage, UUID) -> Void)?

    public static let serviceType = "_tracksshareplay._tcp"
    /// A carful and then some. Anyone past it is turned away rather than slowing everyone.
    public static let largestGroup = 12
    /// How long a connection may go without saying hello before it's let go.
    static let helloTimeout: Duration = .seconds(15)

    private var listener: NWListener?
    private var links: [UUID: SharePlayNearbyLink] = [:]
    private var restart: Task<Void, Never>?
    private var isRunning = false

    public init(invite: SharePlayInvite) {
        self.invite = invite
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        listen()
    }

    /// Stops offering itself and lets every guest go, telling them it's over when it is.
    public func stop(sayingGoodbye: Bool) {
        isRunning = false
        restart?.cancel()
        restart = nil
        listener?.cancel()
        listener = nil
        for link in links.values {
            link.onMessage = nil
            link.onClosed = nil
            if sayingGoodbye, guests.contains(link.id) {
                // Let go once it's sent, or after a moment if it can't be.
                link.send(.ended) { [link] _ in link.cancel() }
                Task { [link] in
                    try? await Task.sleep(for: .seconds(2))
                    link.cancel()
                }
            } else {
                link.cancel()
            }
        }
        links = [:]
        guests = []
    }

    /// Where it's listening, once it is.
    var port: NWEndpoint.Port? { listener?.port }

    public func send(_ message: SharePlayMessage, to guest: UUID) {
        links[guest]?.send(message)
    }

    /// To everyone who's said hello.
    public func broadcast(_ message: SharePlayMessage) {
        for id in guests { links[id]?.send(message) }
    }

    private func listen() {
        do {
            let listener = try NWListener(using: SharePlayNearbyLink.parameters(for: invite))
            listener.service = NWListener.Service(type: Self.serviceType, txtRecord: NWTXTRecord(["t": invite.tag]))
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.adopt(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = .failed
            listenAgainSoon()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard isRunning else { return }
        switch state {
        case .ready:
            status = .ready
        case .waiting(let error):
            status = SharePlayNearbyLink.isLocalNetworkDenied(error) ? .needsLocalNetwork : .starting
        case .failed:
            status = .failed
            listener?.cancel()
            listener = nil
            listenAgainSoon()
        default:
            break
        }
    }

    /// iOS stops a listener when Tracks is suspended, or when the network changes under it.
    /// The same code keeps working once it's back.
    private func listenAgainSoon() {
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, isRunning, listener == nil else { return }
            listen()
        }
    }

    /// Listening again straight away, as Tracks comes back to the foreground.
    public func resume() {
        guard isRunning, listener == nil || status == .failed else { return }
        listener?.cancel()
        listener = nil
        listen()
    }

    private func adopt(_ connection: NWConnection) {
        guard isRunning, links.count < Self.largestGroup else {
            connection.cancel()
            return
        }
        let link = SharePlayNearbyLink(connection)
        links[link.id] = link
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            if case .hello = message, guests.insert(link.id).inserted {
                onGuestsChanged?(guests)
            }
            onMessage?(message, link.id)
        }
        link.onClosed = { [weak self, weak link] in
            guard let self, let link else { return }
            links.removeValue(forKey: link.id)
            if guests.remove(link.id) != nil {
                onGuestsChanged?(guests)
            }
        }
        link.start()
        Task { [weak self, weak link] in
            try? await Task.sleep(for: Self.helloTimeout)
            guard let self, let link, !guests.contains(link.id) else { return }
            link.cancel()
        }
    }
}

/// A guest's side: finds the host with the code, connects, and keeps connecting while the
/// host's there.
@MainActor
public final class SharePlayNearbyGuest {
    public enum Status: Sendable, Equatable {
        /// Looking for the host, or waiting to find it again.
        case looking
        case connected
        /// Local Network is off for Tracks, so it can't look.
        case needsLocalNetwork
    }

    public let invite: SharePlayInvite
    public private(set) var status: Status = .looking {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    public var onStatus: ((Status) -> Void)?
    public var onMessage: ((SharePlayMessage) -> Void)?

    private var browser: NWBrowser?
    private var link: SharePlayNearbyLink?
    private var redial: Task<Void, Never>?
    private var isRunning = false
    /// A host to dial straight away instead of looking for one: for tests, where the Mac
    /// keeps Bonjour's addresses from a process that can't ask for Local Network.
    private let endpoint: NWEndpoint?

    public init(invite: SharePlayInvite) {
        self.invite = invite
        endpoint = nil
    }

    init(invite: SharePlayInvite, dialing endpoint: NWEndpoint) {
        self.invite = invite
        self.endpoint = endpoint
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        if let endpoint {
            dial(endpoint)
        } else {
            browse()
        }
        // Nothing new is found when the host comes back as it was, so what's found is tried
        // again every couple of seconds while there's no connection.
        redial = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, isRunning else { return }
                guard link == nil else { continue }
                if let endpoint {
                    dial(endpoint)
                } else if let browser {
                    found(browser.browseResults)
                } else {
                    browse()
                }
            }
        }
    }

    public func stop() {
        isRunning = false
        redial?.cancel()
        redial = nil
        browser?.cancel()
        browser = nil
        link?.cancel()
        link = nil
    }

    /// Sends to the host, when there's a connection to send on.
    @discardableResult
    public func send(_ message: SharePlayMessage) -> Bool {
        guard let link, link.isReady else { return false }
        link.send(message)
        return true
    }

    private func browse() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: SharePlayNearbyHost.serviceType, domain: nil),
            using: SharePlayNearbyLink.parameters(for: invite)
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserChanged(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func browserChanged(_ state: NWBrowser.State) {
        guard isRunning else { return }
        switch state {
        case .ready:
            if status == .needsLocalNetwork { status = .looking }
        case .waiting(let error):
            if SharePlayNearbyLink.isLocalNetworkDenied(error) { status = .needsLocalNetwork }
        case .failed:
            // Started again by the redial loop.
            browser?.cancel()
            browser = nil
        default:
            break
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard isRunning, link == nil else { return }
        let host = results.first { result in
            if case .bonjour(let txt) = result.metadata { txt["t"] == invite.tag } else { false }
        }
        guard let host else { return }
        dial(host.endpoint)
    }

    private func dial(_ endpoint: NWEndpoint) {
        guard isRunning, link == nil else { return }
        let link = SharePlayNearbyLink(NWConnection(to: endpoint, using: SharePlayNearbyLink.parameters(for: invite)))
        self.link = link
        link.onReady = { [weak self] in
            self?.status = .connected
        }
        link.onMessage = { [weak self] message in
            self?.onMessage?(message)
        }
        link.onClosed = { [weak self, weak link] in
            guard let self, self.link === link else { return }
            self.link = nil
            if status == .connected { status = .looking }
        }
        link.start()
    }
}

/// One connection between a host and a guest: TLS with the code's key, messages framed.
@MainActor
final class SharePlayNearbyLink {
    let id = UUID()
    private let connection: NWConnection
    private(set) var isReady = false
    private var isClosed = false

    var onReady: (() -> Void)?
    var onMessage: ((SharePlayMessage) -> Void)?
    var onClosed: (() -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        connection.start(queue: .main)
    }

    func cancel() {
        connection.cancel()
        close()
    }

    func send(_ message: SharePlayMessage, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !isClosed, let data = try? NearbyFraming.frame(message) else {
            completion?(false)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            MainActor.assumeIsolated { completion?(error == nil) }
        })
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            onReady?()
            receive()
        case .failed, .cancelled:
            close()
        case .waiting:
            // Can't reach the other end, and would wait for the network to change, which
            // may be never. Let it go; the guest dials again in a moment.
            cancel()
        default:
            break
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        onClosed?()
    }

    /// Reads one message, hands it on, and reads the next.
    private func receive() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                guard error == nil, let header, let length = NearbyFraming.length(of: header), length > 0 else {
                    self.cancel()
                    return
                }
                self.receiveBody(length: length)
            }
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                guard error == nil, let body, let message = try? NearbyFraming.message(SharePlayMessage.self, from: body) else {
                    self.cancel()
                    return
                }
                self.onMessage?(message)
                self.receive()
            }
        }
    }

    // MARK: - Parameters

    /// TLS with the code's key, over TCP that notices the other end gone within about 20
    /// seconds, with peer-to-peer Wi-Fi as well as any network.
    static func parameters(for invite: SharePlayInvite) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data(SharePlayInvite.pskIdentity.utf8)
        let secret = invite.secret
        secret.withUnsafeBytes { secretBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(
                    tls.securityProtocolOptions,
                    DispatchData(bytes: secretBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData
                )
            }
        }
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { true } else { false }
    }
}
