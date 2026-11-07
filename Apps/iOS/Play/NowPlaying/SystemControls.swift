import SwiftUI
import MediaPlayer
import AVKit

/// The system volume slider, which follows the hardware buttons and the output device, drawn
/// as the scrubber above it is: a thin white track, no knob.
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
        tintColor = .white
        setMinimumVolumeSliderImage(Self.track(alpha: 0.7), for: .normal)
        setMaximumVolumeSliderImage(Self.track(alpha: 0.2), for: .normal)
        // Clear, but still the size of a fingertip to take hold of.
        setVolumeThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }, for: .normal)
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
    private static func track(alpha: CGFloat) -> UIImage {
        let side: CGFloat = 6
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor.white.withAlphaComponent(alpha).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: side / 2).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: side / 2, bottom: 0, right: side / 2))
    }
}

/// AirPlay and Bluetooth: the system's own picker, so every output the phone knows is there.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
