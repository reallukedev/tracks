import Foundation
import Network
import CryptoKit
import Observation
import TracksCore
#if os(iOS)
import UIKit
#else
import IOKit.ps
#endif

/// Your other devices running Tracks close by: what each is playing, live, and its controls.
///
/// Each device offers itself on the local network with Bonjour, peer-to-peer Wi-Fi included
/// as AirDrop does, and looks for the others. Only yours connect: every connection is TLS with
/// a key your devices share through iCloud, so a stranger's Tracks on the same Wi-Fi can't see
/// or reach yours, and a device that isn't signed in to your iCloud has no key.
@MainActor
@Observable
final class NearbyDevices {
    struct Device: Identifiable, Equatable {
        let id: String
        var name: String
        var platform: String
        /// What it said it is, a ``NearbyDeviceKind``'s wire name.
        var kindName: String?
        var state: NearbyState?

        var kind: NearbyDeviceKind { NearbyDeviceKind(platform: platform, kind: kindName) }
    }

    /// Devices connected and introduced.
    private(set) var devices: [Device] = []

    /// Every device that's been here lately, kept on this device to show the ones away.
    private(set) var known: [KnownNearbyDevice] = []

    /// The ones seen lately that aren't here now, latest first.
    var away: [KnownNearbyDevice] {
        KnownNearbyDevices.away(known, connected: Set(devices.map(\.id)), now: .now)
    }

    /// Local Network is off for Tracks, so it can't look for your devices or be found. Settings
    /// says so, since nothing else would.
    private(set) var needsLocalNetwork = false

    /// The ones with a song to show, playing first.
    var withSongs: [Device] {
        devices.filter { $0.state?.hasSong == true }.sorted { ($0.state?.isPlaying ?? false) && !($1.state?.isPlaying ?? false) }
    }

    /// Another device asked this one to play, pause or skip.
    @ObservationIgnored var onCommand: ((TransportCommand) -> Void)?
    /// Another device took the song over: this one pauses.
    @ObservationIgnored var onPause: (() -> Void)?
    /// A device joined: it should hear what's playing here.
    @ObservationIgnored var onJoin: (() -> Void)?
    /// Another device moved its song to a point, from its player's scrubber.
    @ObservationIgnored var onSeek: ((TimeInterval) -> Void)?
    /// Another device handed its song here, to play from where it had got to, and which
    /// device it was.
    @ObservationIgnored var onTakeOver: ((NearbyState, Device) -> Void)?

    /// What this device is, for its own symbol.
    static let thisKind: NearbyDeviceKind = {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let hardwareModel = String(decoding: model.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        return NearbyDeviceKind.mac(hardwareModel: hardwareModel, hasBattery: hasBattery)
        #endif
    }()

    static var thisDeviceSymbol: String { thisKind.symbol }

    /// "This Mac", "This iPhone", as Apple's own lists name the device in your hand.
    static var thisDeviceName: String {
        switch thisKind {
        case .iPhone: String(localized: "This iPhone")
        case .iPad: String(localized: "This iPad")
        default: String(localized: "This Mac")
        }
    }

    #if os(macOS)
    private static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
    #endif

    static let storageKey = "showsNearbyDevices"
    static var isOn: Bool { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true }

    /// Music moving here brings what it's playing from and Up Next with it, not just the song.
    static let bringsQueueKey = "bringsQueueFromDevices"
    static var bringsQueue: Bool { UserDefaults.standard.object(forKey: bringsQueueKey) as? Bool ?? true }

    private static let knownKey = "nearbyKnownDevices"
    /// The sample's devices are never saved over the real ones.
    @ObservationIgnored private var isSample = false

    @ObservationIgnored private let myID: String
    @ObservationIgnored private let myName: String
    @ObservationIgnored private let myPlatform: String
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var parameters: NWParameters?
    /// The shared key the listener and connections were made with, to notice iCloud has
    /// another by the time a connection is turned away.
    @ObservationIgnored private var keyInUse: Data?
    @ObservationIgnored private var redial: Task<Void, Never>?
    /// Dials in a row that came to nothing, to wait longer before each next one.
    @ObservationIgnored private var failedRedials = 0
    @ObservationIgnored private var links: [ObjectIdentifier: Link] = [:]
    @ObservationIgnored private var lastState: NearbyState?
    @ObservationIgnored private var keyObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isRunning = false

    private static let serviceType = "_tracks._tcp"
    private nonisolated static let keyName = "nearbyKey"
    private static let idKey = "nearbyDeviceID"

    /// One connection, and who's at the other end once they've said.
    private final class Link {
        let connection: NWConnection
        var peerID: String?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.idKey) {
            myID = id
        } else {
            myID = UUID().uuidString
            defaults.set(myID, forKey: Self.idKey)
        }
        #if os(iOS)
        myName = UIDevice.current.model
        myPlatform = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        myName = Host.current().localizedName ?? "Mac"
        myPlatform = "Mac"
        #endif
        known = KnownNearbyDevices.decoded(defaults.data(forKey: Self.knownKey))
    }

    /// Takes a device out of the ones seen lately. It comes back the next time it's here.
    func forget(_ id: String) {
        known.removeAll { $0.id == id }
        saveKnown()
        if !isSample { TracksShortcuts.updateAppShortcutParameters() }
    }

    /// For a run on sample data: starts with no devices known, and saves none.
    func keepToThisRun() {
        isSample = true
        known = []
    }

    /// Looks for your devices if it isn't already, for Siri and Shortcuts, which can run
    /// before any window has started it, and waits a few seconds for one to say hello.
    func waitForDevices(until found: (Device) -> Bool) async -> Device? {
        guard Self.isOn else { return nil }
        if isRunning { resume() } else { start() }
        for _ in 0..<16 {
            if let device = devices.first(where: found) { return device }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return devices.first(where: found)
    }

    /// Notes a device as here now, with the song it's playing.
    private func remember(_ device: Device) {
        let seen = KnownNearbyDevice(
            id: device.id,
            name: device.name,
            platform: device.platform,
            kind: device.kindName,
            lastSeen: .now,
            song: device.state?.hasSong == true ? device.state?.title : nil,
            artist: device.state?.hasSong == true ? device.state?.artist : nil
        )
        let isNew = !known.contains { $0.id == device.id }
        known = KnownNearbyDevices.remembering(seen, in: known)
        saveKnown()
        // "Play on <device> with Tracks" learns its name.
        if isNew, !isSample { TracksShortcuts.updateAppShortcutParameters() }
    }

    private func saveKnown() {
        guard !isSample else { return }
        UserDefaults.standard.set(KnownNearbyDevices.encoded(known), forKey: Self.knownKey)
    }

    #if DEBUG
    /// `-TracksNearbyDemo YES` (or `paused`): a device nearby, for screenshots.
    /// `away` shows only devices seen lately, `none` none at all, `many` several here at once.
    func showSample() {
        guard let mode = UserDefaults.standard.string(forKey: "TracksNearbyDemo") else { return }
        isSample = true
        let day: TimeInterval = 86_400
        known = [
            KnownNearbyDevice(id: "sample-ipad", name: "Luke's iPad", platform: "iPad", kind: "iPad", lastSeen: .now.addingTimeInterval(-day), song: "Paper Parade", artist: "June Arcade"),
            KnownNearbyDevice(id: "sample-imac", name: "Studio iMac", platform: "Mac", kind: "iMac", lastSeen: .now.addingTimeInterval(-6 * day), song: nil, artist: nil),
        ]
        guard mode != "away", mode != "none" else {
            if mode == "none" { known = [] }
            return
        }
        devices = [Device(id: "sample", name: "Luke's MacBook Pro", platform: "Mac", kindName: "MacBook", state: NearbyState(
            title: "Golden Moon", artist: "Nova Harbor", album: "Golden Moon",
            isPlaying: mode != "paused", position: 84, duration: 212
        ))]
        if mode == "many" {
            known.removeAll { $0.id == "sample-ipad" }
            devices.append(Device(id: "sample-ipad", name: "Luke's iPad", platform: "iPad", kindName: "iPad", state: NearbyState(
                title: "Paper Parade", artist: "June Arcade", isPlaying: false, position: 30, duration: 190
            )))
            devices.append(Device(id: "sample-mini", name: "Living Room Mac mini", platform: "Mac", kindName: "Mac mini", state: nil))
        }
    }
    #endif

    // MARK: - Starting and stopping

    func start() {
        guard Self.isOn, !isRunning else { return }
        isRunning = true
        let key = Self.sharedKey()
        let parameters = Self.parameters(key: key)
        self.parameters = parameters
        keyInUse = key.withUnsafeBytes { Data($0) }
        do {
            let listener = try NWListener(using: parameters)
            // Bonjour names are seen by anyone on the network, so this says only "Mac" or
            // "iPhone". The real name goes to your own devices once they've connected.
            listener.service = NWListener.Service(name: myPlatform, type: Self.serviceType, txtRecord: NWTXTRecord(["id": myID]))
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { _ = self?.adopt(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .failed: self.restartSoon()
                    case .waiting(let error): self.noteWaiting(error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            restartSoon()
            return
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { _ = self?.found(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .waiting(let error): self.noteWaiting(error)
                case .ready: self.needsLocalNetwork = false
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        // Another device made the key first: start again with theirs.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            guard keys.contains(NearbyDevices.keyName) else { return }
            MainActor.assumeIsolated { _ = self?.restart() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    func stop() {
        isRunning = false
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        parameters = nil
        keyInUse = nil
        redial?.cancel()
        redial = nil
        failedRedials = 0
        needsLocalNetwork = false
        for link in links.values { link.connection.cancel() }
        links = [:]
        devices = []
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    /// Back in the foreground, where iOS may have stopped listening, and connections may have
    /// ended while Tracks was suspended: any device not connected is tried again.
    func resume() {
        guard Self.isOn else { return }
        if listener?.state != .ready {
            restart()
        } else if let browser {
            found(browser.browseResults)
        }
    }

    private func restart() {
        stop()
        start()
    }

    /// The listener or browser can't go on yet. Local Network turned off is the one reason
    /// someone can do anything about.
    private func noteWaiting(_ error: NWError) {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            needsLocalNetwork = true
        }
    }

    private func restartSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.isRunning else { return }
            self.restart()
        }
    }

    // MARK: - Telling and asking

    /// What's playing here, for every device connected. Sent only when it's changed.
    func publish(_ state: NearbyState) {
        if let lastState, lastState.isSame(as: state) { return }
        lastState = state
        broadcast(.state(state))
    }

    func send(_ command: TransportCommand, to device: Device) {
        send(.command(command), to: device.id)
    }

    /// Asks a device to pause, as its song moves here.
    func pause(_ device: Device) {
        send(.pause, to: device.id)
    }

    /// Moves a device's song to a point.
    func seek(_ device: Device, to position: TimeInterval) {
        send(.seek(position), to: device.id)
    }

    /// Hands a device the song playing here, to carry on from where it's got to.
    func handOver(_ state: NearbyState, to device: Device) {
        send(.takeOver(state), to: device.id)
    }

    private func send(_ message: NearbyMessage, to peerID: String) {
        guard let link = links.values.first(where: { $0.peerID == peerID }) else { return }
        send(message, on: link)
    }

    private func broadcast(_ message: NearbyMessage) {
        for link in links.values where link.peerID != nil { send(message, on: link) }
    }

    private func send(_ message: NearbyMessage, on link: Link) {
        guard let data = try? NearbyFraming.frame(message) else { return }
        link.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Connections

    /// Devices found: each connected to from one side only, the one whose id sorts first, so
    /// two devices don't each open a connection to the other. See ``NearbyPeering``.
    private func found(_ results: Set<NWBrowser.Result>) {
        guard let parameters else { return }
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let peerID = txt["id"],
                  NearbyPeering.dials(peerID, from: myID, linked: links.values.compactMap(\.peerID))
            else { continue }
            let connection = NWConnection(to: result.endpoint, using: parameters)
            let link = adopt(connection)
            link.peerID = peerID
        }
    }

    /// Tries the devices still found but not connected, a moment after a connection ends: the
    /// other side only waits to be dialled, and nothing new is found when it comes back on the
    /// same network. The wait, longer after each dial that comes to nothing, keeps a device
    /// that's really gone, or one turned away, from being dialled over and over.
    private func redialSoon() {
        guard isRunning, redial == nil else { return }
        let wait = min(60, 3 * (1 << min(failedRedials, 5)))
        failedRedials += 1
        redial = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.redial = nil
            // Turned away for the wrong key: iCloud may have the one the others use by now.
            if let saved = Self.savedKey(), saved != self.keyInUse {
                self.restart()
            } else if let browser = self.browser {
                self.found(browser.browseResults)
            }
        }
    }

    @discardableResult
    private func adopt(_ connection: NWConnection) -> Link {
        let link = Link(connection)
        links[ObjectIdentifier(connection)] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            MainActor.assumeIsolated {
                guard let self, let link else { return }
                switch state {
                case .ready:
                    self.send(.hello(id: self.myID, name: self.myName, platform: self.myPlatform, kind: Self.thisKind.wireName), on: link)
                    self.receive(on: link)
                case .failed, .cancelled:
                    self.drop(link)
                case .waiting where link.peerID != nil && !self.devices.contains(where: { $0.id == link.peerID }):
                    // A device dialled that can't be reached waits for the network to change,
                    // which may be never. Let it go, and dial again in a moment.
                    self.drop(link)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        return link
    }

    private func drop(_ link: Link) {
        guard links.removeValue(forKey: ObjectIdentifier(link.connection)) != nil else { return }
        link.connection.cancel()
        if let peerID = link.peerID, !links.values.contains(where: { $0.peerID == peerID }) {
            if let device = devices.first(where: { $0.id == peerID }) { remember(device) }
            devices.removeAll { $0.id == peerID }
            redialSoon()
        }
    }

    /// Reads one message, handles it, and reads the next.
    private func receive(on link: Link) {
        link.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak link] header, _, _, error in
            MainActor.assumeIsolated {
                guard let self, let link else { return }
                guard error == nil, let header, let length = NearbyFraming.length(of: header), length > 0 else {
                    self.drop(link)
                    return
                }
                link.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak link] body, _, _, error in
                    MainActor.assumeIsolated {
                        guard let self, let link else { return }
                        guard error == nil, let body, let message = try? NearbyFraming.message(from: body) else {
                            self.drop(link)
                            return
                        }
                        self.handle(message, from: link)
                        self.receive(on: link)
                    }
                }
            }
        }
    }

    private func handle(_ message: NearbyMessage, from link: Link) {
        switch message {
        case .hello(let id, let name, let platform, let kind):
            link.peerID = id
            failedRedials = 0
            // Back on a new connection: the one from before it went away is let go, however
            // alive it still looks. See ``NearbyPeering``.
            let peers = links.mapValues(\.peerID)
            for old in NearbyPeering.replaced(by: ObjectIdentifier(link.connection), from: id, links: peers) {
                if let stale = links[old] { drop(stale) }
            }
            if let position = devices.firstIndex(where: { $0.id == id }) {
                devices[position].name = name
                devices[position].kindName = kind
            } else {
                devices.append(Device(id: id, name: name, platform: platform, kindName: kind))
            }
            if let device = devices.first(where: { $0.id == id }) { remember(device) }
            if let lastState { send(.state(lastState), on: link) }
            onJoin?()
        case .state(let state):
            guard let id = link.peerID, let position = devices.firstIndex(where: { $0.id == id }) else { return }
            let isNewSong = devices[position].state?.title != state.title
            devices[position].state = state
            if isNewSong, state.hasSong { remember(devices[position]) }
        case .command(let command):
            onCommand?(command)
        case .pause:
            onPause?()
        case .seek(let position):
            onSeek?(position)
        case .takeOver(let state):
            guard let id = link.peerID, let device = devices.first(where: { $0.id == id }) else { return }
            onTakeOver?(state, device)
        }
    }

    // MARK: - Keeping it to your devices

    /// The key your devices share through iCloud, made by the first of them to need one.
    private static func sharedKey() -> SymmetricKey {
        if let saved = savedKey() {
            return SymmetricKey(data: saved)
        }
        let store = NSUbiquitousKeyValueStore.default
        let key = SymmetricKey(size: .bits256)
        store.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), forKey: keyName)
        store.synchronize()
        return key
    }

    /// The key as iCloud has it on this device, if it has one.
    private static func savedKey() -> Data? {
        guard let saved = NSUbiquitousKeyValueStore.default.string(forKey: keyName),
              let data = Data(base64Encoded: saved), data.count == 32
        else { return nil }
        return data
    }

    /// TLS with a key both ends already have, over TCP that notices a device gone, with
    /// peer-to-peer Wi-Fi as well as the network.
    private static func parameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data("Tracks Nearby".utf8)
        let secret = Data(HMAC<SHA256>.authenticationCode(for: identity, using: key))
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
        // A device that's gone (closed, asleep, out of range) is noticed in about 20 seconds,
        // rather than the minutes TCP takes on its own, so it can be dialled again.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}
