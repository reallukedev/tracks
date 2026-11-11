import SwiftUI

/// Music's waveform beside what's playing, its bars lighting in turn while it plays. Still
/// with Reduce Motion.
///
/// The bars are an AppKit or UIKit image view running the effect itself. SwiftUI's
/// `symbolEffect(_:options:isActive:)` updates the view graph every frame, and on the Mac every
/// update lays the window out again: one waveform on Listen Now kept the main thread over half
/// busy for as long as music played, and the app grew sluggish the longer it was open. On the
/// iPhone the same waveform on the crate's Tracks Radio cost 8% of a core while it played,
/// against nothing without it. Core Animation runs the platform's effect without SwiftUI
/// hearing about it.
struct PlayingWaveform: View {
    var isActive: Bool
    /// The bars' color. AppKit draws them on the Mac, where SwiftUI's foreground style doesn't
    /// reach, so it's given here; elsewhere it's applied as the foreground style.
    var color: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Laid out as the symbol itself would be, so it sits on a label's line the same way,
        // with the platform's bars drawn over the space it takes.
        Image(systemName: "waveform")
            .opacity(0)
            .overlay { MovingWaveform(isMoving: isActive && !reduceMotion, color: color) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now Playing")
    }
}

#if os(macOS)
import AppKit

private struct MovingWaveform: NSViewRepresentable {
    let isMoving: Bool
    let color: Color

    func makeNSView(context: Context) -> WaveformView {
        let view = WaveformView()
        view.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: WaveformView, context: Context) {
        let environment = context.environment
        let font = (environment.font ?? .body).resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: Self.weight(of: font))
        if view.symbolConfiguration != configuration {
            view.symbolConfiguration = configuration
        }
        view.contentTintColor = NSColor(cgColor: color.resolve(in: environment).cgColor)
        view.isMoving = isMoving
    }

    /// The space the symbol takes, with the bars centered in it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private static func weight(of font: NSFont) -> NSFont.Weight {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat).map { NSFont.Weight($0) } ?? .regular
    }
}

private final class WaveformView: NSImageView {
    var isMoving = false {
        didSet {
            if isMoving != oldValue { applyEffect() }
        }
    }

    // An effect added before the view is in a window doesn't run.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyEffect()
    }

    private func applyEffect() {
        removeAllSymbolEffects()
        if isMoving, window != nil {
            addSymbolEffect(.variableColor.iterative, options: .repeating)
        }
    }
}
#endif

#if os(iOS)
import UIKit

private struct MovingWaveform: UIViewRepresentable {
    let isMoving: Bool
    let color: Color

    func makeUIView(context: Context) -> WaveformView {
        let view = WaveformView(image: UIImage(systemName: "waveform"))
        view.contentMode = .center
        view.isAccessibilityElement = false
        // Drawn at the symbol's own size, never stretched to the space it's offered.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: WaveformView, context: Context) {
        let environment = context.environment
        let font = (environment.font ?? .body).resolve(in: environment.fontResolutionContext).ctFont as UIFont
        let configuration = UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: Self.weight(of: font))
        if view.preferredSymbolConfiguration != configuration {
            view.preferredSymbolConfiguration = configuration
        }
        view.tintColor = UIColor(cgColor: color.resolve(in: environment).cgColor)
        view.isMoving = isMoving
    }

    /// The space the symbol takes, with the bars centered in it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WaveformView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private static func weight(of font: UIFont) -> UIImage.SymbolWeight {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue
        let weights: [(UIFont.Weight, UIImage.SymbolWeight)] = [
            (.ultraLight, .ultraLight), (.thin, .thin), (.light, .light), (.regular, .regular),
            (.medium, .medium), (.semibold, .semibold), (.bold, .bold), (.heavy, .heavy), (.black, .black),
        ]
        return weights.min { abs($0.0.rawValue - weight) < abs($1.0.rawValue - weight) }?.1 ?? .regular
    }
}

private final class WaveformView: UIImageView {
    var isMoving = false {
        didSet {
            if isMoving != oldValue { applyEffect() }
        }
    }

    // An effect added before the view is in a window doesn't run.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyEffect()
    }

    private func applyEffect() {
        removeAllSymbolEffects()
        if isMoving, window != nil {
            addSymbolEffect(.variableColor.iterative, options: .repeating)
        }
    }
}
#endif
