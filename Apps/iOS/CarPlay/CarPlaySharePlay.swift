import UIKit
import CarPlay
import TracksCore

/// SharePlay in the car: a code on the car's screen for passengers to scan with their iPhone's
/// Camera, which opens Tracks on their iPhone to add songs to Up Next here.
///
/// It opens from the top of Up Next, where the songs they add will go, as the phone's SharePlay
/// sits in Up Next's header. The code works while its page is open, and for as long as anyone
/// who scanned it stays, so there's nothing to turn on and nothing left on by mistake. Under
/// the code, the songs passengers have added, and End SharePlay once anyone has joined.
extension CarPlaySceneDelegate {
    /// Up Next's first row: SharePlay, and who's joined.
    func sharePlayRow() -> CPListItem {
        let sharePlay = SharePlayController.shared
        let detail = sharePlay.role == .host ? SharePlayWords.people(sharePlay.guestCount) : String(localized: "Let passengers add songs")
        let image = CarPlayImages.symbol("shareplay", side: CPListItem.maximumImageSize.height, scale: scale)
        let row = CPListItem(text: String(localized: "SharePlay"), detailText: detail, image: image, accessoryImage: nil, accessoryType: .disclosureIndicator)
        row.handler = { [weak self] _, completion in
            self?.showSharePlay()
            completion()
        }
        return row
    }

    /// What Up Next's SharePlay row shows, to redraw it when it changes.
    static var sharePlayRowState: String {
        let sharePlay = SharePlayController.shared
        return "\(sharePlay.role == .host).\(sharePlay.guestCount).\(sharePlay.ledger.identities.sorted())"
    }

    func showSharePlay() {
        guard interface != nil, sharePlayPage == nil else { return }
        let sharePlay = SharePlayController.shared
        sharePlay.start(model: model)
        sharePlay.showCode(on: .car)
        let page = CPListTemplate(title: String(localized: "SharePlay"), sections: [], assistantCellConfiguration: nil)
        page.listHeader = sharePlayHeader()
        sharePlayPage = page
        // Fills in the rest, and keeps it current.
        watchSharePlay()
        // CarPlay takes five screens at most: this deep, the page starts a fresh trail from Now
        // Playing, which it goes back to.
        push(page) { [weak self] in
            // Didn't make it on screen (another move under way): let it go, code and all.
            guard let self, sharePlayPage === page, interface?.templates.contains(where: { $0 === page }) != true else { return }
            sharePlayPageGone()
        }
    }

    /// Keeps the page current: the code, who's joined, what they've added. Closes it once
    /// SharePlay has ended, from here or on the phone.
    private func watchSharePlay() {
        sharePlayWatch?.cancel()
        let sharePlay = SharePlayController.shared
        let player = model.player
        sharePlayWatch = Task { [weak self] in
            let changes = Observations {
                SharePlayPageKey(
                    status: sharePlay.codeStatus,
                    invite: sharePlay.invite,
                    isHosting: sharePlay.role == .host,
                    guests: sharePlay.guestCount,
                    added: sharePlay.ledger.identities,
                    songs: ([player.current].compactMap(\.self) + player.upNext).map(\.id)
                )
            }
            for await key in changes {
                guard let self, sharePlayPage != nil else { return }
                guard key.isHosting else {
                    closeSharePlayPage()
                    return
                }
                await updateSharePlayPage()
            }
        }
    }

    private struct SharePlayPageKey: Equatable {
        let status: SharePlayController.CodeStatus
        let invite: SharePlayInvite?
        let isHosting: Bool
        let guests: Int
        let added: Set<String>
        let songs: [String]
    }

    /// Closes the page, trying again a moment later if CarPlay is busy (a sheet going away).
    /// Gone from the trail some other way, it's let go here.
    private func closeSharePlayPage(attempt: Int = 0) {
        guard let page = sharePlayPage, let interface else { return }
        guard let index = interface.templates.firstIndex(where: { $0 === page }), index > 0 else {
            sharePlayPageGone()
            return
        }
        let retry = { [weak self] (closed: Bool, _: Error?) in
            guard !closed, attempt < 3 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.closeSharePlayPage(attempt: attempt + 1)
            }
        }
        if interface.topTemplate === page {
            interface.popTemplate(animated: true, completion: retry)
        } else {
            interface.pop(to: interface.templates[index - 1], animated: true, completion: retry)
        }
    }

    /// The page left the screen for good: popped, or the trail rebuilt without it.
    func sharePlayPageGone() {
        sharePlayWatch?.cancel()
        sharePlayWatch = nil
        sharePlayPage = nil
        SharePlayController.shared.hideCode(on: .car)
    }

    private func updateSharePlayPage() async {
        guard let page = sharePlayPage else { return }
        page.listHeader = sharePlayHeader()
        let sections = await sharePlaySections()
        guard sharePlayPage === page else { return }
        page.updateSections(sections)
    }

    // MARK: - The code

    private func sharePlayHeader() -> CPListTemplateDetailsHeader {
        let sharePlay = SharePlayController.shared
        let side = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
        let title: String
        let subtitle: String
        let body: [String]
        let image: UIImage
        switch sharePlay.codeStatus {
        case .needsLocalNetwork:
            image = CarPlayImages.placeholder(symbol: "network.slash", side: side.width, scale: scale)
            title = String(localized: "Local Network Is Off")
            subtitle = String(localized: "Passengers can't join by code")
            body = [
                String(localized: "When you've stopped, turn on Local Network for Tracks in Settings on iPhone."),
                String(localized: "Turn on Local Network for Tracks in Settings."),
            ]
        case .failed:
            image = CarPlayImages.placeholder(symbol: "qrcode", side: side.width, scale: scale)
            title = String(localized: "Getting the Code Ready")
            subtitle = String(localized: "Trying again…")
            body = []
        case .off, .starting, .ready:
            image = sharePlayCodeImage(side: side.width)
            title = String(localized: "Scan to Add Songs")
            subtitle = SharePlayWords.people(sharePlay.guestCount)
            body = SharePlayCodeImage.isForEveryone ? [
                String(localized: "Passengers point their iPhone's Camera at this code to add songs to Up Next."),
                String(localized: "Scan with iPhone Camera to add songs."),
            ] : [
                String(localized: "Passengers point their iPhone's Camera at this code to add songs to Up Next. They'll need Tracks."),
                String(localized: "Scan with iPhone Camera to add songs. Needs Tracks."),
            ]
        }
        return CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: image),
            title: title,
            subtitle: subtitle,
            bodyVariants: body.map { NSAttributedString(string: $0) },
            actionButtons: []
        )
    }

    /// The code, drawn once for each invite.
    private func sharePlayCodeImage(side: CGFloat) -> UIImage {
        guard let invite = SharePlayController.shared.invite else {
            return CarPlayImages.placeholder(symbol: "qrcode", side: side, scale: scale)
        }
        if let drawn = sharePlayCode, drawn.invite == invite, drawn.image.size.width == side {
            return drawn.image
        }
        let image = SharePlayCodeImage.image(for: invite, side: side, scale: scale, cornerRadius: side * 0.06)
        sharePlayCode = (invite, image)
        return image
    }

    // MARK: - What passengers added

    private func sharePlaySections() async -> [CPListSection] {
        let sharePlay = SharePlayController.shared
        let player = model.player
        var sections: [CPListSection] = []
        let songs = ([player.current].compactMap(\.self) + player.upNext).filter { sharePlay.ledger.contains($0.songIdentity) }
        if !songs.isEmpty {
            let side = CPListItem.maximumImageSize.height
            var rows: [CPListItem] = []
            for track in songs.prefix(20) {
                let row = CPListItem(text: track.title, detailText: track.artistName, image: await cover(for: track, side: side))
                row.isPlaying = track.id == player.current?.id
                row.isExplicitContent = track.isExplicit
                row.handler = { [weak self] _, completion in
                    if let index = player.upNext.firstIndex(where: { $0.id == track.id }) {
                        player.jump(toUpNext: index)
                    }
                    completion()
                    self?.showNowPlaying()
                }
                rows.append(row)
            }
            sections.append(CPListSection(items: rows, header: String(localized: "Added by Passengers"), sectionIndexTitle: nil))
        } else if sharePlay.guestCount > 0 {
            let row = CPListItem(text: String(localized: "Songs passengers add show up here."), detailText: nil)
            row.isEnabled = false
            sections.append(CPListSection(items: [row], header: String(localized: "Added by Passengers"), sectionIndexTitle: nil))
        }
        if sharePlay.guestCount > 0 {
            let end = CPListItem(text: String(localized: "End SharePlay"), detailText: nil, image: CarPlayImages.symbol("xmark.circle", side: CPListItem.maximumImageSize.height, scale: scale))
            end.handler = { [weak self] _, completion in
                completion()
                self?.confirmEndSharePlay()
            }
            sections.append(CPListSection(items: [end]))
        }
        return sections
    }

    private func confirmEndSharePlay() {
        let count = SharePlayController.shared.guestCount
        let message = count == 1
            ? String(localized: "The passenger who joined can't add more songs. Songs already added stay in Up Next.")
            : String(localized: "The \(count) passengers who joined can't add more songs. Songs already added stay in Up Next.")
        let sheet = CPActionSheetTemplate(title: String(localized: "End SharePlay?"), message: message, actions: [
            CPAlertAction(title: String(localized: "End SharePlay"), style: .destructive) { [weak self] _ in
                // Once the sheet has gone, so the page can close under nothing.
                self?.dismissSheet {
                    SharePlayController.shared.endHosting()
                }
            },
            CPAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
                self?.dismissSheet()
            },
        ])
        present(sheet)
    }
}
