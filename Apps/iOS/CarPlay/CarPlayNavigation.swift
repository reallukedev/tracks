import UIKit
import CarPlay
import os

/// Moving between screens in the car. CarPlay throws, and takes the app down with it, when a
/// screen is pushed twice, a second sheet is presented over the first, or a move fails with no
/// completion to report to. Every move goes through here: one at a time, each with a completion,
/// never past the depth CarPlay allows.
extension CarPlaySceneDelegate {
    /// The most screens an audio app's trail can hold, the tab bar included.
    static let deepest = 5

    /// How many screens can sit under Now Playing and still leave one above it, for Up Next or
    /// the album.
    static let deepestBeforeNowPlaying = deepest - 1

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "CarPlay")

    /// Pushes a screen. Already on the trail, or while another move is under way (a second tap
    /// before the first page opened), it's left alone. At CarPlay's depth, the trail starts again
    /// from the tab, under Now Playing when it was there.
    func push(_ template: CPTemplate, completion: (() -> Void)? = nil) {
        guard let interface, !isMoving, !interface.templates.contains(where: { $0 === template }) else {
            completion?()
            return
        }
        guard interface.templates.count >= Self.deepest else {
            move { done in self.pushStep(template, animated: true, then: done) } completion: { completion?() }
            return
        }
        let nowPlaying = CPNowPlayingTemplate.shared
        let keepsNowPlaying = template !== nowPlaying && interface.templates.contains { $0 === nowPlaying }
        move { done in
            interface.popToRootTemplate(animated: false) { _, error in
                Self.report(error, "pop to root")
                guard keepsNowPlaying else { return self.pushStep(template, animated: true, then: done) }
                self.pushStep(nowPlaying, animated: false) {
                    self.pushStep(template, animated: true, then: done)
                }
            }
        } completion: { completion?() }
    }

    /// Brings Now Playing up: back to it when it's already on the trail, since CarPlay won't
    /// take the same screen twice. Played from deep in a tab, it starts a fresh trail from the
    /// tab, leaving room above it.
    func showNowPlaying() {
        guard let interface, !isMoving else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interface.topTemplate === nowPlaying { return }
        if interface.templates.contains(where: { $0 === nowPlaying }) {
            move { done in
                interface.pop(to: nowPlaying, animated: true) { _, error in
                    Self.report(error, "pop to Now Playing")
                    done()
                }
            } completion: {}
            return
        }
        guard interface.templates.count >= Self.deepestBeforeNowPlaying else {
            move { done in self.pushStep(nowPlaying, animated: true, then: done) } completion: {}
            return
        }
        move { done in
            interface.popToRootTemplate(animated: false) { _, error in
                Self.report(error, "pop to root")
                self.pushStep(nowPlaying, animated: true, then: done)
            }
        } completion: {}
    }

    /// Goes back a screen.
    func popScreen() {
        guard let interface, !isMoving, interface.templates.count > 1 else { return }
        move { done in
            interface.popTemplate(animated: true) { _, error in
                Self.report(error, "pop")
                done()
            }
        } completion: {}
    }

    /// Shows a sheet, closing any sheet already up first: CarPlay shows one at a time.
    func present(_ template: CPTemplate) {
        guard let interface else { return }
        guard interface.presentedTemplate != nil else {
            interface.presentTemplate(template, animated: true) { _, error in Self.report(error, "present") }
            return
        }
        interface.dismissTemplate(animated: false) { [weak self] _, error in
            Self.report(error, "dismiss")
            guard let interface = self?.interface else { return }
            interface.presentTemplate(template, animated: true) { _, error in Self.report(error, "present") }
        }
    }

    /// Closes the sheet that's up, then does what's next.
    func dismissSheet(then next: (() -> Void)? = nil) {
        guard let interface, interface.presentedTemplate != nil else {
            next?()
            return
        }
        interface.dismissTemplate(animated: true) { _, error in
            Self.report(error, "dismiss")
            next?()
        }
    }

    /// An alert's OK: closes it.
    func okAction() -> CPAlertAction {
        CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
            self?.dismissSheet()
        }
    }

    // MARK: - Steps

    /// Runs a move, marked as under way until it's done, so a second can't start inside it.
    /// A move CarPlay never finishes is let go after a few seconds, so the car can't stay stuck.
    private func move(_ steps: (@escaping () -> Void) -> Void, completion: @escaping () -> Void) {
        isMoving = true
        moveID &+= 1
        let id = moveID
        var isDone = false
        let done = { [weak self] in
            guard !isDone else { return }
            isDone = true
            if self?.moveID == id { self?.isMoving = false }
            completion()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, moveID == id, isMoving else { return }
            Self.log.error("A CarPlay move didn't finish; letting it go")
            isMoving = false
        }
        steps(done)
    }

    private func pushStep(_ template: CPTemplate, animated: Bool, then next: @escaping () -> Void) {
        guard let interface, !interface.templates.contains(where: { $0 === template }) else { return next() }
        interface.pushTemplate(template, animated: animated) { _, error in
            Self.report(error, "push")
            next()
        }
    }

    private static func report(_ error: (any Error)?, _ what: String) {
        guard let error else { return }
        log.error("CarPlay couldn't \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}
