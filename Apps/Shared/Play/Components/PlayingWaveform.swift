import SwiftUI

/// Music's waveform beside what's playing, its bars lighting in turn while it plays. Still
/// with Reduce Motion.
///
/// On the Mac the bars are an AppKit image view running the effect itself. SwiftUI's
/// `symbolEffect(_:options:isActive:)` updates the view graph every frame, and on the Mac every
/// update lays the window out again: one waveform on Listen Now kept the main thread over half
/// busy for as long as music played, and the app grew sluggish the longer it was open. Core
/// Animation runs AppKit's effect without SwiftUI hearing about it.
struct PlayingWaveform: View {
    var isActive: Bool
    /// The bars' color. AppKit draws them on the Mac, where SwiftUI's foreground style doesn't
    /// reach, so it's given here; elsewhere it's applied as the foreground style.
    var color: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(macOS)
        // Laid out as the symbol itself would be, so it sits on a label's line the same way,
        // with AppKit's bars drawn over the space it takes.
        Image(systemName: "waveform")
            .opacity(0)
            .overlay { MovingWaveform(isMoving: isActive && !reduceMotion, color: color) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now Playing")
        #else
        Image(systemName: "waveform")
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive && !reduceMotion)
        #endif
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
