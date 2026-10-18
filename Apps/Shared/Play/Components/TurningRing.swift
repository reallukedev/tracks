import SwiftUI

/// A ring with a gap, turning: something's on its way, but how far along can't be told. Round a
/// play button while a song buffers, or where a download will show its progress once it starts.
/// Still, with Reduce Motion.
///
/// On the Mac the ring is a Core Animation layer turning by itself. A SwiftUI `repeatForever`
/// updates the view graph every frame, and on the Mac every update lays the whole window out
/// again, as ``PlayingWaveform`` found.
struct TurningRing: View {
    var diameter: CGFloat = 15
    var lineWidth: CGFloat = 2
    var color: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @State private var isTurning = false
    #endif

    var body: some View {
        #if os(macOS)
        TurningRingLayer(lineWidth: lineWidth, color: color, isTurning: !reduceMotion)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
        #else
        Circle()
            .trim(from: 0, to: TurningRingShape.length)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: TurningRingShape.period).repeatForever(autoreverses: false), value: isTurning)
            .onAppear { isTurning = true }
        #endif
    }
}

private enum TurningRingShape {
    /// How much of the circle is drawn; the rest is the gap.
    static let length: CGFloat = 0.7
    /// Seconds per turn.
    static let period: TimeInterval = 1
}

#if os(macOS)
import AppKit

private struct TurningRingLayer: NSViewRepresentable {
    let lineWidth: CGFloat
    let color: Color
    let isTurning: Bool

    func makeNSView(context: Context) -> RingView {
        let view = RingView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: RingView, context: Context) {
        view.update(
            lineWidth: lineWidth,
            color: NSColor(cgColor: color.resolve(in: context.environment).cgColor) ?? .secondaryLabelColor,
            isTurning: isTurning
        )
    }
}

private final class RingView: NSView {
    private let ring = CAShapeLayer()
    private var lineWidth: CGFloat = 2
    private var isTurning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineCap = .round
        ring.strokeEnd = TurningRingShape.length
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(lineWidth: CGFloat, color: NSColor, isTurning: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.cgColor
        ring.lineWidth = lineWidth
        CATransaction.commit()
        if lineWidth != self.lineWidth {
            self.lineWidth = lineWidth
            needsLayout = true
        }
        if isTurning != self.isTurning {
            self.isTurning = isTurning
            applyTurn()
        }
    }

    // Drawn over a button, which keeps the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ring.contentsScale = window?.backingScaleFactor ?? 2
    }

    // A layer taken out of a window can lose its animations.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTurn()
    }

    private func applyTurn() {
        let key = "turn"
        guard isTurning, window != nil else {
            ring.removeAnimation(forKey: key)
            return
        }
        guard ring.animation(forKey: key) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise: the layer's y axis points up.
        turn.toValue = -2 * Double.pi
        turn.duration = TurningRingShape.period
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: key)
    }
}
#endif
