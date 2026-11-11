import SwiftUI
import MediaPlayer
import AVKit

/// The system volume slider, which follows the hardware buttons and the output device, drawn
/// as the scrubber above it is: a thin track in the player's ink, no knob.
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> CenteredVolumeView {
        CenteredVolumeView(frame: .zero)
    }

    func updateUIView(_ view: CenteredVolumeView, context: Context) {}
}

/// The volume view with its slider through the middle of its whole width.
///
/// `MPVolumeView` lays its slider along its own top edge and leaves room at the end for a
/// route button it no longer shows, so the track sat high and short of the speakers either
/// side of it, out of line with the scrubber above.
final class CenteredVolumeView: MPVolumeView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // Clear, but still the size of a fingertip to take hold of.
        setVolumeThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }, for: .normal)
        drawTrack()
        // White on a dark background, near black on a light one, as the player's type is.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CenteredVolumeView, _) in
            view.drawTrack()
        }
    }

    private func drawTrack() {
        let ink = UIColor.playerInk.resolvedColor(with: traitCollection)
        tintColor = ink
        setMinimumVolumeSliderImage(Self.track(ink.withAlphaComponent(0.7)), for: .normal)
        setMaximumVolumeSliderImage(Self.track(ink.withAlphaComponent(0.2)), for: .normal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        let height = super.volumeSliderRect(forBounds: bounds).height
        return CGRect(x: bounds.minX, y: (bounds.midY - height / 2).rounded(), width: bounds.width, height: height)
    }

    /// A capsule the scrubber's height, stretched along its middle.
    private static func track(_ colour: UIColor) -> UIImage {
        let side: CGFloat = 6
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            colour.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: side / 2).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: side / 2, bottom: 0, right: side / 2))
    }
}

/// AirPlay and Bluetooth: the system's own picker, so every output the phone knows is there.
/// It lights up while the sound is elsewhere, and VoiceOver says where.
struct RoutePicker: UIViewRepresentable {
    /// Clear, laid over a row that draws its own look and opens the picker when tapped.
    var isHidden = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        if isHidden {
            view.tintColor = .clear
            view.activeTintColor = .clear
        } else {
            view.tintColor = UIColor.playerInk.withAlphaComponent(0.7)
            view.activeTintColor = .playerInk
            context.coordinator.follow(view)
        }
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}

    static func dismantleUIView(_ view: AVRoutePickerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Names the speakers in the button's VoiceOver value as the route changes. A route
    /// change is a notification, so this costs nothing while nothing changes.
    @MainActor
    final class Coordinator {
        private var observer: NSObjectProtocol?

        func follow(_ view: AVRoutePickerView) {
            let describe: @MainActor () -> Void = { [weak view] in
                view?.accessibilityValue = SpeakerRouteObserver.currentRoute.map { $0.names.formatted(.list(type: .and)) }
            }
            describe()
            // Never `.main`: the audio session posts this from its own queue (see
            // AppModel.followSpeakers).
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
                Task { @MainActor in describe() }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

extension UIColor {
    /// The player's type: white in its dark look, black in its light one.
    static let playerInk = UIColor { $0.userInterfaceStyle == .light ? .black : .white }
}
