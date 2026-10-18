import SwiftUI
import Combine
import GroupActivities
import MusicKit
import TracksCore
import TracksMusic

/// Tracks’ SharePlay sessions, for the whole process: hosting, where this iPhone plays and
/// takes songs from the group, and joining someone else's, where this iPhone only picks.
///
/// The host tells the group what's on whenever it changes; a guest asks for a song, the host
/// looks it up the way its player would play it and answers. The rules for what goes in live
/// in TracksCore (``SharePlayGate``, ``SharePlayGuest``); this is the plumbing around them.
///
/// People join one of two ways, and the host treats them the same:
/// - In Messages, from the share sheet: a real SharePlay session.
/// - By scanning the host's code, shown in the car or on its iPhone: Apple keeps the car's
///   SharePlay code to Music, so Tracks shows its own, and the passenger's Tracks connects
///   straight to the host's iPhone nearby (see ``SharePlayInvite`` and
///   ``SharePlayNearbyHost``).
@MainActor
@Observable
final class SharePlayController {
    static let shared = SharePlayController()

    enum Role: Equatable {
        case idle
        /// This iPhone started SharePlay and plays for the group.
        case host
        /// This iPhone joined someone else's and picks songs for it.
        case guest
    }

    private(set) var role: Role = .idle

    // MARK: Host

    /// People who've joined, across every session this iPhone started and its code.
    private(set) var guestCount = 0
    /// Which songs in Up Next someone at SharePlay added.
    private(set) var ledger = SharePlayLedger()

    /// Whether the people nearby can join with this iPhone's code.
    enum CodeStatus: Equatable {
        /// No code showing, and no one joined by one.
        case off
        case starting
        case ready
        /// Local Network is off for Tracks, so nothing nearby can reach it.
        case needsLocalNetwork
        /// Couldn't offer itself nearby. It tries again on its own.
        case failed
    }

    private(set) var codeStatus: CodeStatus = .off
    /// The code's invite, kept until SharePlay ends, so a code shown twice is the same code
    /// and anyone still looking with it finds this iPhone.
    private(set) var invite: SharePlayInvite?

    /// The code's sheet is up on this iPhone.
    var showsCode = false

    /// Where the code is showing.
    enum CodeViewer: Hashable {
        case car
        case phone
    }

    // MARK: Guest

    /// What the host has said, and what became of this person's picks.
    var guest: SharePlayGuest { codeGuest?.guest ?? sessionGuest }
    /// The guest page is up. Set as a session arrives and cleared as it's left.
    var showsGuestPage = false
    /// Joined, but the host hasn't answered for a while.
    var isSlowToConnect: Bool { codeGuest?.isSlowToConnect ?? sessionIsSlow }

    /// How this iPhone joined someone else's SharePlay.
    enum GuestConnection: Equatable {
        /// Invited in Messages.
        case sharePlay
        /// Scanned their code, and connected straight to their iPhone.
        case code
    }

    private(set) var guestConnection: GuestConnection = .sharePlay
    /// Joined by code, and the connection to the host dropped: looking for it again.
    var isReconnecting: Bool { codeGuest?.isReconnecting ?? false }
    /// Joined by code, but Local Network is off for Tracks here and there's no other way.
    var guestNeedsLocalNetwork: Bool { codeGuest?.needsLocalNetwork ?? false }
    /// Someone else's SharePlay, joined by code.
    private(set) var codeGuest: SharePlayCodeGuest?
    /// Someone else's SharePlay, joined in Messages.
    private var sessionGuest = SharePlayGuest()
    private var sessionIsSlow = false
    /// A code scanned while this iPhone hosts its own SharePlay, waiting on whether to end it.
    var pendingInvite: SharePlayInvite?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var hostLinks: [ObjectIdentifier: Link] = [:]
    @ObservationIgnored private var guestLink: Link?
    @ObservationIgnored private var snapshotFollower: Task<Void, Never>?
    @ObservationIgnored private var gate = SharePlayGate()
    @ObservationIgnored private var broadcast = SharePlayBroadcast()
    /// Guests in sessions started from Messages.
    @ObservationIgnored private var sessionGuestCount = 0
    @ObservationIgnored private var codeHost: SharePlayCodeHost?
    @ObservationIgnored private var codeGuests: Set<UUID> = []
    /// Someone has joined by code since it started, so it may be someone coming back.
    @ObservationIgnored private var hadCodeGuests = false
    @ObservationIgnored private var codeViewers: Set<CodeViewer> = []
    @ObservationIgnored private var idleStop: Task<Void, Never>?
    @ObservationIgnored private var guestInvite: SharePlayInvite?
    /// The relay, where the build has one.
    @ObservationIgnored private let relay = SharePlayRelayConfig.main
    @ObservationIgnored private var foregroundObserver: NotificationCenter.ObservationToken?
    #if DEBUG
    /// Sample data's pretend sessions, which the simulator can't run for real.
    @ObservationIgnored private(set) var demo: SharePlayDemo?
    #endif

    /// One session and what listens to it.
    private final class Link {
        let session: GroupSession<SharePlayActivity>
        let messenger: GroupSessionMessenger
        var tasks: [Task<Void, Never>] = []

        init(session: GroupSession<SharePlayActivity>) {
            self.session = session
            messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        }

        func cancel() {
            tasks.forEach { $0.cancel() }
            tasks = []
        }
    }

    /// Starts listening for sessions, once per process: one this iPhone started from the
    /// share sheet, or one it was invited to and joined in Messages.
    func start(model: AppModel) {
        guard listener == nil else { return }
        self.model = model
        #if DEBUG
        if model.isDemoLaunch, let scene = LaunchScene.sharePlayDemo {
            demo = SharePlayDemo(scene: scene)
            demo?.start(in: self, model: model)
            listener = Task {}
            return
        }
        #endif
        listener = Task { [weak self] in
            for await session in SharePlayActivity.sessions() {
                self?.receive(session)
            }
        }
        // iOS stops listening nearby while Tracks is suspended: back in the foreground, the
        // code works again straight away.
        foregroundObserver = NotificationCenter.default.addObserver(of: UIApplication.self, for: .didBecomeActive) { [weak self] _ in
            self?.codeHost?.resume()
            self?.codeGuest?.resume()
        }
    }

    private func receive(_ session: GroupSession<SharePlayActivity>) {
        if session.isLocallyInitiated {
            host(session)
        } else {
            joinAsGuest(session)
        }
    }

    // MARK: - Hosting

    /// Whether a song in Up Next came from SharePlay, for the glyph on its row.
    func isFromSharePlay(_ track: PlayerTrack) -> Bool {
        role == .host && ledger.contains(track.songIdentity)
    }

    /// Ends SharePlay for everyone, in Messages and by code. A code shown after this is a
    /// new one.
    func endHosting() {
        for link in hostLinks.values {
            link.cancel()
            link.session.end()
        }
        hostLinks = [:]
        stopCode(sayingGoodbye: true)
        invite = nil
        stopHosting()
    }

    // MARK: - The code

    /// Shows the code somewhere: this iPhone offers itself nearby for as long as the code
    /// shows, and for as long as anyone who joined with it stays.
    func showCode(on viewer: CodeViewer) {
        codeViewers.insert(viewer)
        idleStop?.cancel()
        idleStop = nil
        #if DEBUG
        if let demo {
            invite = invite ?? SharePlayInvite()
            codeStatus = demo.scene == "host.nolocalnetwork" ? .needsLocalNetwork : .ready
            if role != .host { pretend(role: .host) }
            return
        }
        #endif
        if let codeHost {
            codeHost.resume()
            return
        }
        // Hosting and picking for someone else at once would mix up whose queue is whose.
        if role == .guest { leave() }
        let invite = invite ?? SharePlayInvite()
        self.invite = invite
        let host = SharePlayCodeHost(invite: invite, relay: relay)
        host.onStatus = { [weak self] status in self?.codeStatus = CodeStatus(status) }
        host.onGuestsChanged = { [weak self] guests in self?.codeGuestsChanged(guests) }
        host.onMessage = { [weak self, weak host] message, id in
            self?.hostReceived(message, from: id) { answer in host?.send(answer, to: id) }
        }
        codeHost = host
        codeStatus = .starting
        role = .host
        host.start()
        followPlayer()
    }

    /// The code has gone from somewhere. Once it shows nowhere and no one's joined with it,
    /// this iPhone stops offering itself.
    func hideCode(on viewer: CodeViewer) {
        guard codeViewers.remove(viewer) != nil else { return }
        stopCodeIfUnused()
    }

    private func stopCodeIfUnused() {
        guard codeViewers.isEmpty, codeHost != nil, codeGuests.isEmpty else { return }
        guard hadCodeGuests else {
            stopCode(sayingGoodbye: false)
            return
        }
        // Everyone who joined has gone, perhaps only for a moment (a phone locked, a tunnel):
        // their way back stays open for a while.
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled, codeViewers.isEmpty, codeGuests.isEmpty else { return }
            stopCode(sayingGoodbye: false)
        }
    }

    private func stopCode(sayingGoodbye: Bool) {
        idleStop?.cancel()
        idleStop = nil
        guard let codeHost else { return }
        codeHost.stop(sayingGoodbye: sayingGoodbye)
        self.codeHost = nil
        codeGuests = []
        hadCodeGuests = false
        codeStatus = .off
        updateGuestCount()
        if hostLinks.isEmpty { stopHosting() }
    }

    private func codeGuestsChanged(_ guests: Set<UUID>) {
        codeGuests = guests
        if !guests.isEmpty {
            hadCodeGuests = true
            idleStop?.cancel()
            idleStop = nil
        }
        updateGuestCount()
        if guests.isEmpty { stopCodeIfUnused() }
    }

    private func updateGuestCount() {
        guestCount = sessionGuestCount + codeGuests.count
    }

    private func host(_ session: GroupSession<SharePlayActivity>) {
        // Hosting and picking for someone else at once would mix up whose queue is whose.
        if role == .guest { leave() }
        let link = Link(session: session)
        let key = ObjectIdentifier(session)
        hostLinks[key] = link
        role = .host
        link.tasks.append(Task { [weak self, weak link] in
            guard let link else { return }
            let messenger = link.messenger
            for await (message, context) in messenger.messages(of: SharePlayMessage.self) {
                let participant = context.source
                self?.hostReceived(message, from: participant.id) { answer in
                    Task { try? await messenger.send(answer, to: .only(participant)) }
                }
            }
        })
        link.tasks.append(Task { [weak self] in
            for await participants in session.$activeParticipants.values {
                self?.participantsChanged(participants, in: session)
            }
        })
        link.tasks.append(Task { [weak self] in
            for await state in session.$state.values {
                if case .invalidated = state {
                    self?.hostSessionEnded(key)
                    break
                }
            }
        })
        session.join()
        followPlayer()
    }

    private func participantsChanged(_ participants: Set<Participant>, in session: GroupSession<SharePlayActivity>) {
        let joined = participants.subtracting([session.localParticipant]).count
        let before = sessionGuestCount
        sessionGuestCount = hostLinks.values.reduce(0) { total, link in
            total + (link.session === session ? joined : link.session.activeParticipants.subtracting([link.session.localParticipant]).count)
        }
        updateGuestCount()
        // Someone new hears what's on straight away, even if they don't ask.
        if sessionGuestCount > before {
            broadcast.resend()
            sendSnapshot()
        }
    }

    private func hostSessionEnded(_ key: ObjectIdentifier) {
        hostLinks.removeValue(forKey: key)?.cancel()
        sessionGuestCount = hostLinks.values.reduce(0) { $0 + $1.session.activeParticipants.subtracting([$1.session.localParticipant]).count }
        updateGuestCount()
        // Still offered by code: those guests carry on.
        guard hostLinks.isEmpty, codeHost == nil else { return }
        stopHosting()
    }

    private func stopHosting() {
        if role == .host { role = .idle }
        codeStatus = .off
        guestCount = 0
        sessionGuestCount = 0
        ledger = SharePlayLedger()
        gate = SharePlayGate()
        broadcast = SharePlayBroadcast()
        snapshotFollower?.cancel()
        snapshotFollower = nil
    }

    /// Tells the group what's on each time it changes.
    private func followPlayer() {
        guard snapshotFollower == nil, let player = model?.player else { return }
        snapshotFollower = Task { [weak self] in
            let snapshots = Observations { [weak self] in self?.currentSnapshot() }
            for await snapshot in snapshots {
                guard let self, let snapshot else { continue }
                // Songs from SharePlay that have played and gone are no longer marked. Set only
                // when that changes it: the snapshot reads the ledger, so setting it every time
                // would bring the snapshot straight back, forever.
                var pruned = ledger
                pruned.prune(keeping: snapshot.queuedIdentities.union(Set(player.upNext.map(\.songIdentity))))
                if pruned != ledger { ledger = pruned }
                sendSnapshot(snapshot)
            }
        }
    }

    private func sendSnapshot(_ snapshot: SharePlaySnapshot? = nil) {
        guard let snapshot = snapshot ?? currentSnapshot(), let next = broadcast.next(snapshot) else { return }
        for link in hostLinks.values {
            let messenger = link.messenger
            Task { try? await messenger.send(SharePlayMessage.snapshot(next)) }
        }
        codeHost?.broadcast(.snapshot(next))
    }

    /// What's on, as the group sees it.
    func currentSnapshot() -> SharePlaySnapshot? {
        guard let model else { return nil }
        let player = model.player
        let entry = { (track: PlayerTrack) in
            SharePlayTrack(
                id: track.id,
                title: track.title,
                artistName: track.artistName,
                artworkURL: Self.shareableArtwork(track.cover),
                isFromSharePlay: self.ledger.contains(track.songIdentity)
            )
        }
        return SharePlaySnapshot(
            nowPlaying: player.current.map(entry),
            isPlaying: player.isPlaying,
            upNext: player.upNext.prefix(SharePlaySnapshot.upNextLimit).map(entry),
            upNextCount: player.upNext.count,
            source: playsYourMusic ? .yourMusic : .appleMusic,
            isStation: player.context?.isStation == true,
            allowsExplicit: PlayPreferences.allowsExplicit
        )
    }

    /// Your own music is what's playing, or what will play.
    private var playsYourMusic: Bool {
        guard let model else { return false }
        if let current = model.player.current { return current.local != nil }
        return model.musicSource == .yourMusic
    }

    /// A guest said something, in Messages or by code; `answer` says something back to them
    /// alone.
    private func hostReceived(_ message: SharePlayMessage, from participant: UUID, answer: @escaping (SharePlayMessage) -> Void) {
        switch message {
        case .hello:
            guard let snapshot = currentSnapshot() else { return }
            answer(.snapshot(snapshot))
        case .add(let request):
            Task { await add(request, from: participant) { answer(.reply($0)) } }
        case .snapshot, .reply, .ended:
            // Only the host says these.
            break
        }
    }

    /// Adds a guest's song to Up Next, or says why not.
    func add(_ request: SharePlayAddRequest, from participant: UUID, reply: @escaping (SharePlayAddReply) -> Void) async {
        guard let model else { return }
        let player = model.player
        let answer = { (outcome: SharePlayAddOutcome) in reply(SharePlayAddReply(requestID: request.id, outcome: outcome)) }
        let queued = Set(([player.current].compactMap(\.self) + player.upNext).map(\.songIdentity))
        switch gate.check(request, from: participant, at: .now, queued: queued, isStation: player.context?.isStation == true) {
        case .ignore:
            return
        case .refuse(let refusal):
            answer(.refused(refusal))
            return
        case .accept:
            break
        }
        if let refusal = await findProblem(with: request.song) {
            gate.release(request, from: participant)
            answer(.refused(refusal))
            return
        }
        // Adding to a station replaces it (see `PlayerModel.enqueue`): the driver's radio would
        // stop for one passenger's song. So a station refuses, and says so on the guest's row.
        // Checked again here, since a station may have started while the song was looked up.
        guard player.context?.isStation != true else {
            gate.release(request, from: participant)
            answer(.refused(.station))
            return
        }
        let song = request.song
        player.enqueue(
            .history([HistorySong(songID: song.catalogID, title: song.title, artistName: song.artistName, albumTitle: song.albumTitle, artworkURL: song.artworkURL)]),
            next: request.placement == .next,
            title: song.title
        )
        if await arrives(song.identity) {
            ledger.record(song.identity)
            // After the player's own "Added to Queue", so this is what stays up.
            player.confirm(String(localized: "Added by SharePlay"))
            answer(.added(request.placement))
        } else {
            gate.release(request, from: participant)
            answer(.refused(.unavailable))
        }
    }

    /// Why the host's player couldn't play a song, found before it's asked to: a failure there
    /// would stop the driver with an alert about someone else's pick.
    private func findProblem(with song: SharePlaySong) async -> SharePlayRefusal? {
        guard let model else { return .unavailable }
        let player = model.player
        // Just switched between Apple Music and your music: the next thing added would
        // replace what's playing rather than join it.
        if let current = player.current, (current.local != nil) != (model.musicSource == .yourMusic) {
            return .unavailable
        }
        if player.isDemo { return nil }
        if model.musicSource == .yourMusic {
            let history = HistorySong(songID: song.catalogID, title: song.title, artistName: song.artistName, albumTitle: song.albumTitle)
            return model.yourMusic.track(for: history) == nil ? .notFound : nil
        }
        guard MusicAuthorization.currentStatus == .authorized else { return .unavailable }
        do {
            guard let found = try await MusicKitPlaybackService.songs(for: [song.catalogID]).first else { return .notFound }
            if found.contentRating == .explicit, !PlayPreferences.allowsExplicit { return .explicit }
            return nil
        } catch {
            return .unavailable
        }
    }

    /// Waits for a song to show up on or after the one playing: the player adds in the
    /// background and doesn't say when.
    private func arrives(_ identity: String) async -> Bool {
        guard let player = model?.player else { return false }
        for _ in 0..<32 {
            if player.current?.songIdentity == identity || player.upNext.contains(where: { $0.songIdentity == identity }) {
                return true
            }
            if player.problem != nil { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// A cover another iPhone can load: Apple Music's, never one from your server, whose
    /// address carries its password.
    static func shareableArtwork(_ cover: CoverArt) -> String? {
        let url: String? = switch cover {
        case .artwork(let artwork): artwork.url(width: 300, height: 300)?.absoluteString
        case .url(let address, _): address
        }
        guard let url, url.hasPrefix("https://"), !url.contains("/rest/") else { return nil }
        return url
    }

    // MARK: - Joining someone else's

    private func joinAsGuest(_ session: GroupSession<SharePlayActivity>) {
        if role == .host {
            // Someone else's invitation while hosting: stay the host.
            session.leave()
            return
        }
        leaveQuietly()
        let link = Link(session: session)
        guestLink = link
        resetGuest(joining: .sharePlay)
        link.tasks.append(Task { [weak self, weak link] in
            guard let link else { return }
            for await (message, _) in link.messenger.messages(of: SharePlayMessage.self) {
                self?.guestReceived(message)
            }
        })
        link.tasks.append(Task { [weak self] in
            for await state in session.$state.values {
                switch state {
                case .joined:
                    self?.sayHello()
                case .invalidated:
                    self?.guestSessionEnded()
                    return
                default:
                    break
                }
            }
        })
        session.join()
    }

    private func resetGuest(joining connection: GuestConnection) {
        sessionGuest = SharePlayGuest()
        sessionIsSlow = false
        guestConnection = connection
        role = .guest
        showsGuestPage = true
    }

    /// Asks the host for what's on until it answers: its side may still be getting ready.
    private func sayHello() {
        guard let link = guestLink else { return }
        let messenger = link.messenger
        link.tasks.append(Task { [weak self] in
            for attempt in 0..<30 {
                guard let self, sessionGuest.phase == .joining, !Task.isCancelled else { return }
                // Ten seconds without a word: likely one of the two is offline.
                sessionIsSlow = attempt >= 5
                try? await messenger.send(SharePlayMessage.hello)
                try? await Task.sleep(for: .seconds(2))
            }
        })
    }

    private func guestReceived(_ message: SharePlayMessage) {
        switch message {
        case .snapshot(let snapshot): sessionGuest.receive(snapshot)
        case .reply(let reply): sessionGuest.receive(reply)
        case .ended: guestSessionEnded()
        case .hello, .add: break
        }
    }

    // MARK: - Joining by code

    /// Joins the SharePlay whose code was scanned. Scanned while this iPhone hosts its own,
    /// it waits on whether to end that first (``pendingInvite``).
    func join(_ invite: SharePlayInvite) {
        // Its own code, scanned off its own screen or a photo of it.
        if invite == self.invite { return }
        if role == .guest, invite == guestInvite, guest.phase != .ended {
            showsGuestPage = true
            return
        }
        // Hosting with no one to leave behind, or waiting to come back: nothing to ask.
        if role == .host, guestCount == 0, hostLinks.isEmpty, !hadCodeGuests {
            endHosting()
        }
        if role == .host {
            pendingInvite = invite
            return
        }
        joinByCode(invite)
    }

    /// Ends this iPhone's own SharePlay, if it's still on, and joins the one whose code was
    /// scanned.
    func endHostingAndJoin() {
        guard let invite = pendingInvite else { return }
        pendingInvite = nil
        if role == .host { endHosting() }
        joinByCode(invite)
    }

    private func joinByCode(_ invite: SharePlayInvite) {
        leaveQuietly()
        guestInvite = invite
        resetGuest(joining: .code)
        let guest = SharePlayCodeGuest(invite: invite, relay: relay)
        codeGuest = guest
        #if DEBUG
        if demo != nil { return }
        #endif
        guest.start()
    }

    /// Sends a song to the host, once, however many times it's pressed.
    func add(_ song: SharePlaySong, placement: SharePlayPlacement) {
        #if DEBUG
        if let demo {
            var request: SharePlayAddRequest?
            pretendGuest { request = $0.add(song, placement: placement, at: .now) }
            if let request { demo.answer(request, in: self) }
            return
        }
        #endif
        if let codeGuest {
            codeGuest.add(song, placement: placement)
            return
        }
        guard let request = sessionGuest.add(song, placement: placement, at: .now) else { return }
        guard let messenger = guestLink?.messenger else {
            sessionGuest.failedToSend(request.id)
            return
        }
        Task {
            do {
                try await messenger.send(SharePlayMessage.add(request))
            } catch {
                sessionGuest.failedToSend(request.id)
            }
            // Gives up on it if the host never answers.
            try? await Task.sleep(for: .seconds(SharePlayGuest.answerTimeout))
            sessionGuest.expire(at: .now)
        }
    }

    /// Leaves someone else's SharePlay and closes its page. Their queue keeps what was added.
    func leave() {
        leaveQuietly()
        showsGuestPage = false
        if role == .guest { role = .idle }
    }

    private func leaveQuietly() {
        codeGuest?.stop()
        codeGuest = nil
        guestInvite = nil
        if let link = guestLink {
            link.cancel()
            link.session.leave()
            guestLink = nil
        }
        if role == .guest { role = .idle }
    }

    /// The host ended it: the page stays, saying so, until it's closed.
    private func guestSessionEnded() {
        guestLink?.cancel()
        guestLink = nil
        sessionGuest.end()
    }

    /// Closes the page of a SharePlay that has ended.
    func closeEnded() {
        showsGuestPage = false
        guestInvite = nil
        codeGuest?.stop()
        codeGuest = nil
        if role == .guest { role = .idle }
    }

    #if DEBUG
    /// For sample data's pretend sessions.
    func pretend(role: Role, guestCount: Int = 0, ledger: SharePlayLedger = SharePlayLedger()) {
        self.role = role
        self.guestCount = guestCount
        self.ledger = ledger
        if role == .guest { showsGuestPage = true }
    }

    func pretendGuest(_ change: (inout SharePlayGuest) -> Void) {
        if let codeGuest {
            codeGuest.pretend(change)
        } else {
            change(&sessionGuest)
        }
    }

    /// A guest who joined by code, looking for the host, or found it and lost it again.
    func pretendCode(isSlow: Bool = false, isReconnecting: Bool = false, needsLocalNetwork: Bool = false) {
        guestConnection = .code
        let guest = SharePlayCodeGuest(invite: SharePlayInvite(), relay: nil)
        guest.pretend({ _ in }, isSlow: isSlow, isReconnecting: isReconnecting, needsLocalNetwork: needsLocalNetwork)
        codeGuest = guest
    }
    #endif
}

private extension SharePlayController.CodeStatus {
    init(_ status: SharePlayCodeHost.Status) {
        self = switch status {
        case .starting: .starting
        case .ready: .ready
        case .needsLocalNetwork: .needsLocalNetwork
        case .failed: .failed
        }
    }
}
