import SwiftUI
import AppKit
import Observation
import TracksMusic

/// Owns what lives as long as the process, and starts it when the app finishes launching.
///
/// Startup used to hang off the main window's `.task`, which ran it again for every new
/// window (undoing a paused capture) and not at all when macOS restored no window at launch,
/// as it doesn't for an app that was quit with its window closed. Launch is the one moment
/// that happens exactly once, whatever windows there are.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// The process's one model, which Siri and Shortcuts reach as ``AppModel/shared``.
    let model = AppModel.shared
    let behaviour = MacAppBehaviour()
    /// Watches Music for the menu bar.
    let monitor = NowPlayingMonitor()
    /// Notices a run that ended without a quit, and gets the app reopened after one.
    let quitMonitor = UnexpectedQuitMonitor()

    /// Held while capture is running. See ``trackCaptureActivity()``.
    private var captureActivity: (any NSObjectProtocol)?

    /// SwiftUI's way to open the main window, kept by the windows that have it, so the Dock
    /// can bring the window back from here.
    static var openWindow: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so a problem later in launch still leaves a record of this run.
        quitMonitor.start(isDemoLaunch: model.isDemoLaunch)
        behaviour.applyActivationPolicy()
        trackCaptureActivity()
        Task { await model.startCapture() }
        NearbyMac.start(model)
        followTracksPlayer()
        watchSpaceBar()
    }

    /// A click on the Dock icon brings the main window back, as Music's does, even with the
    /// Mini Player open, when AppKit would count that as a window and do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let window = MainWindow.open
        guard window == nil || window?.isMiniaturized == true, let openWindow = Self.openWindow else { return true }
        MainWindow.bringForward(openWindow: openWindow)
        return false
    }

    // MARK: - Space

    private var spaceMonitor: Any?

    /// Space plays and pauses, in the main window and the Mini Player, as it does in Music.
    ///
    /// A key press in SwiftUI reaches only the view with focus, and on the Mac a page usually
    /// has none, so `onKeyPress` at the root never hears it. The app's own event stream does.
    /// Space still goes where it means something else: into a text field, to a sheet, to a
    /// control someone has moved to with the keyboard, and to Settings.
    private func watchSpaceBar() {
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.playsOrPauses(on: event) else { return event }
            self.model.player.togglePlayPause()
            return nil
        }
    }

    private func playsOrPauses(on event: NSEvent) -> Bool {
        guard event.keyCode == 49, !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              model.player.hasQueue,
              let window = event.window, window.isKeyWindow,
              window.attachedSheet == nil, window.sheetParent == nil
        else { return false }
        let identifier = window.identifier?.rawValue ?? ""
        // The menu bar's panel has its own Space, and Settings is for settings. Popovers from
        // the main window, Up Next and your devices, play and pause as the window does.
        let isMainWindowPopover = window.parent.map { MainWindow.isMain($0) } ?? false
        if identifier.contains("Settings")
            || (window is NSPanel && !identifier.hasPrefix(MiniPlayerWindow.id) && !isMainWindowPopover) {
            return false
        }
        switch window.firstResponder {
        case is NSText, is NSTextField, is NSButton, is NSSegmentedControl, is NSSlider, is NSPopUpButton:
            return false
        default:
            return true
        }
    }

    /// Pauses Music when Tracks starts playing, as any player on the Mac takes over from the
    /// one before it. A Mac has no audio session to do it, and two songs at once is nobody's
    /// idea of listening.
    ///
    /// Only on a start, and with Music's own `pause`, which does nothing to a Music that isn't
    /// playing: a start can be reported more than once, and a toggle would set Music going again.
    private func followTracksPlayer() {
        let player = model.player
        Task { [weak self] in
            for await isPlaying in Observations({ player.isPlaying }) {
                guard let self else { return }
                defer { tracksWasPlaying = isPlaying }
                guard isPlaying, !tracksWasPlaying, !model.isDemoLaunch else { continue }
                Task { [monitor] in
                    _ = await ScriptingQueue.run { MediaTransportControl.pause() }
                    await monitor.refresh()
                }
            }
        }
    }

    /// Whether Tracks’ player was playing at the last look, so only a start pauses Music.
    private var tracksWasPlaying = false

    /// Right-clicking Tracks in the Dock: the song playing and its controls, as Music's Dock
    /// menu has.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let player = model.player
        guard let track = player.current else { return nil }
        let menu = NSMenu()
        let song = NSMenuItem(title: String(localized: "\(track.title) by \(track.artistName)"), action: nil, keyEquivalent: "")
        song.isEnabled = false
        menu.addItem(song)
        menu.addItem(.separator())
        menu.addItem(dockItem(player.isPlaying ? String(localized: "Pause") : String(localized: "Play"), #selector(dockPlayPause)))
        menu.addItem(dockItem(String(localized: "Next"), #selector(dockNext)))
        if player.context?.isStation != true {
            menu.addItem(dockItem(String(localized: "Previous"), #selector(dockPrevious)))
        }
        return menu
    }

    private func dockItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dockPlayPause() { model.player.togglePlayPause() }
    @objc private func dockNext() { model.player.skipToNext() }
    @objc private func dockPrevious() { model.player.skipToPrevious() }

    /// Every quit on purpose passes through here, which is how the next launch tells a quit
    /// from a crash or from macOS ending the app.
    func applicationWillTerminate(_ notification: Notification) {
        quitMonitor.applicationWillTerminate()
        model.player.saveSession()
    }

    /// Declares the work the app is doing while capture is running, so that the system
    /// doesn't quietly kill it as it sits in the menu bar.
    ///
    /// An app with no window open counts as non-interactive, and macOS reclaims those first:
    /// on a nearly full disk, `deleted` asks RunningBoard to terminate the app so it can
    /// purge the container's caches (exit reason 0xBADDD15C, CacheDeleteAppContainerCaches).
    /// Nothing crashes and no report is written, so it reads as the app quitting at random
    /// hours or days after launch, with everything played from then on unrecorded. An
    /// activity raises the app's termination resistance, and rules out the sudden and
    /// automatic termination AppKit would otherwise allow.
    ///
    /// Not `.userInitiated`, which also holds off idle sleep: capture has no reason to keep
    /// the Mac awake, and stops when it sleeps anyway. Dropped while capture is paused, when
    /// being terminated costs the user nothing. Sudden and automatic termination stay off
    /// regardless (see ``UnexpectedQuitMonitor``), so a paused app that macOS ends reads as an
    /// unexpected quit rather than vanishing.
    private func trackCaptureActivity() {
        guard let capture = model.capture else { return }
        Task { [weak self] in
            for await isRunning in Observations({ capture.isRunning }) {
                guard let self else { return }
                switch (isRunning, captureActivity) {
                case (true, nil):
                    captureActivity = ProcessInfo.processInfo.beginActivity(
                        options: [.background, .suddenTerminationDisabled, .automaticTerminationDisabled],
                        reason: "Recording listening history"
                    )
                case (false, let activity?):
                    ProcessInfo.processInfo.endActivity(activity)
                    captureActivity = nil
                default:
                    break
                }
            }
        }
    }
}


