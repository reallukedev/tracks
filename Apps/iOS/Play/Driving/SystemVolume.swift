import AVFoundation
import MediaPlayer
import TracksCore
import UIKit

/// iPhone's own volume, for Louder at Speed with Apple Music, whose level only the system can
/// change.
///
/// It starts from the volume you have and moves it in whole half-steps, never more than once a
/// second, so the changes are few and small. Pressing the volume buttons is always yours: the
/// volume you pick becomes the one for the speed you're at, and Tracks follows on from there.
@MainActor
final class SystemVolume {
    /// The volume you'd set, at the level Louder at Speed was at. Nil until the first reading
    /// after it starts, or after the audio moves somewhere else.
    private var anchor: SystemVolumeAnchor?
    /// The volume as last seen, to tell your changes from Tracks’.
    private var lastSeen: Double?
    private var lastSet = Date.distantPast
    /// The one way an app can move the volume: the slider in the system's volume view. Kept in
    /// the window, out of sight, so iPhone doesn't show its volume display for Tracks’ changes.
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))

    /// Changes smaller than half a step aren't made: too small to hear over a road.
    private static let smallestChange = SystemVolumeAnchor.step / 2

    var volume: Double { Double(AVAudioSession.sharedInstance().outputVolume) }

    /// The audio is going to CarPlay, where the car sets the volume and apps can't.
    static var isOnCarPlay: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// Starts again from the volume as it is: for a new drive, or the audio moving to other
    /// speakers, which keep their own volume.
    func forget() {
        anchor = nil
        lastSeen = nil
        // Left in the window, it would keep iPhone's volume display away for your own
        // presses too, everywhere in Tracks, long after the drive. `set` puts it back.
        volumeView.removeFromSuperview()
    }

    /// Takes the volume as it is to be right for this level. For the first reading of a drive.
    func anchor(at decibels: Double) {
        let volume = volume
        anchor = SystemVolumeAnchor(volume: volume, at: decibels)
        lastSeen = volume
    }

    var isAnchored: Bool { anchor != nil }

    /// Moves the volume to where this level puts it.
    func follow(_ decibels: Double) {
        guard var anchor else { return }
        let now = volume
        // A second for iPhone to settle on a change before it's read back as yours.
        guard Date.now.timeIntervalSince(lastSet) > 1 else { return }
        if let lastSeen, abs(now - lastSeen) > 0.004 {
            // You changed it: that's the volume for the speed you're at now.
            anchor = SystemVolumeAnchor(volume: now, at: decibels)
            self.anchor = anchor
            self.lastSeen = now
            return
        }
        let wanted = anchor.volume(at: decibels)
        guard abs(wanted - now) >= Self.smallestChange else { return }
        set(wanted)
    }

    private func set(_ value: Double) {
        attach()
        guard let slider = volumeView.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
        lastSet = .now
        slider.setValue(Float(value), animated: false)
        slider.sendActions(for: .valueChanged)
        // The system may round to its own steps: what it settles on is what counts as Tracks’.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            lastSeen = volume
        }
    }

    /// Puts the volume view in a window, the first time it's needed.
    private func attach() {
        guard volumeView.window == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .windows.first
        volumeView.alpha = 0.001
        volumeView.isUserInteractionEnabled = false
        volumeView.accessibilityElementsHidden = true
        window?.addSubview(volumeView)
    }
}
