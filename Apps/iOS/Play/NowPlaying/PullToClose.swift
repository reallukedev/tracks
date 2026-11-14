import SwiftUI
import UIKit

/// Now Playing's slide up and its pull down to close, as Music's: the player comes up from the
/// foot of the screen, keeps up with the finger when it's pulled, rounds its corners as it
/// comes away from the screen's, and a flick or a long enough pull sends it off the bottom at
/// the speed it was let go.
///
/// The player is presented and dismissed without the system's animations, and moved here
/// instead. While a presentation animates, UIKit ignores touches: a pull just after opening,
/// or a tap on the mini player just after closing, did nothing and had to be made again.
///
/// It's moved by its presentation's view rather than in SwiftUI: moved in SwiftUI, every frame
/// of a pull laid the whole player out again, and rounding it there drew its moving background
/// again offscreen, both on the main thread.
struct PullToClose: ViewModifier {
    /// Waits for the player's own gestures to give up first, as Up Next's list needs to scroll.
    /// Otherwise the pull runs alongside them: waiting for the cover's double tap to fail held
    /// the pull back for its first 35 points, which then arrived all at once.
    let yields: Bool
    /// Changes when the player asks to close, from its close button.
    let closeRequests: Int
    /// Changes when the mini player is tapped while this slides away, to bring it back.
    let reopenRequests: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far down the player is. It starts below the screen and slides up.
    @State private var pull = PresentationMover.offscreen
    /// Where the finger was when the pull took hold, so the player doesn't jump to meet it.
    @State private var origin: CGFloat?
    @State private var isClosing = false
    /// Resets when a pull ends, however it ends: one the system cancels doesn't call `onEnded`.
    @GestureState private var isPulling = false

    func body(content: Content) -> some View {
        content
            .background {
                // Touches pass to the app beneath while it slides away, so the mini player can
                // be tapped at once rather than land on the player going past it.
                PresentationMover(offset: pull, passesTouches: isClosing) { reached in
                    // Off the screen: closed with nothing left to show.
                    guard isClosing, reached == PresentationMover.offscreen else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { dismiss() }
                }
            }
            .gesture(pullGesture, isEnabled: yields)
            .simultaneousGesture(pullGesture, isEnabled: !yields)
            .interactiveDismissDisabled()
            .task {
                // A turn of the run loop first, so the player is in its window, below the
                // screen, before it starts up.
                await Task.yield()
                withAnimation(reduceMotion ? nil : Self.slide) { pull = 0 }
            }
            .onChange(of: closeRequests) { close(velocity: 0) }
            .onChange(of: reopenRequests) {
                guard isClosing else { return }
                isClosing = false
                withAnimation(reduceMotion ? nil : Self.slide) { pull = 0 }
            }
            .onChange(of: isPulling) { _, isPulling in
                guard !isPulling, origin != nil else { return }
                origin = nil
                settle(to: 0, velocity: 0)
            }
    }

    private static let slide = Animation.interpolatingSpring(duration: 0.42, bounce: 0)

    private var pullGesture: some Gesture {
        // Measured on the screen, which stays put while the player moves under the finger.
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($isPulling) { _, isPulling, _ in isPulling = true }
            .onChanged { value in
                guard !isClosing else { return }
                let down = value.translation.height
                if origin == nil {
                    // Only a pull that's mostly downward; sideways is the scrubber's.
                    guard down > 0, down > abs(value.translation.width) else { return }
                    origin = down
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { pull = max(0, down - (origin ?? 0)) }
            }
            .onEnded { value in
                guard let start = origin else { return }
                origin = nil
                let projected = value.predictedEndTranslation.height - start
                let velocity = value.velocity.height
                // A flick down closes it however short, a long pull however slow, and a pull
                // that's turned back up stays open.
                if velocity > -100, pull > 120 || projected > 180 || velocity > 350 {
                    close(velocity: velocity)
                } else {
                    settle(to: 0, velocity: velocity)
                }
            }
    }

    /// Off the bottom of the screen at the finger's speed, or the slide's own pace.
    private func close(velocity: CGFloat) {
        guard !isClosing else { return }
        guard !reduceMotion else { return dismiss() }
        isClosing = true
        settle(to: PresentationMover.offscreen, velocity: max(velocity, 0))
    }

    private func settle(to target: CGFloat, velocity: CGFloat) {
        // A spring's starting speed is given as a share of the distance it has to go, here
        // about a screen's height at most.
        let distance = min(target, 900) - pull
        let speed = abs(distance) > 1 ? min(max(velocity / distance, -30), 30) : 0
        withAnimation(reduceMotion ? nil : .interpolatingSpring(duration: 0.38, bounce: 0, initialVelocity: speed)) {
            pull = target
        }
    }
}

extension View {
    /// Slides the presentation this is in up, and closes it on a pull down or when
    /// `closeRequests` changes. See ``PullToClose``.
    func pullToClose(yields: Bool = false, closeRequests: Int = 0, reopenRequests: Int = 0) -> some View {
        modifier(PullToClose(yields: yields, closeRequests: closeRequests, reopenRequests: reopenRequests))
    }
}

/// Moves the presented view it's in down by `offset`, rounding its corners while it's away.
/// `onMoved` once it's there: SwiftUI's own completion comes at once, as nothing of its own
/// moves.
private struct PresentationMover: UIViewRepresentable {
    let offset: CGFloat
    let passesTouches: Bool
    let onMoved: @MainActor (CGFloat) -> Void

    /// Just below the foot of the screen, whatever its height.
    static let offscreen: CGFloat = .greatestFiniteMagnitude

    /// About the screen's own corners on Face ID iPhones. Only seen while pulled, once the
    /// player's top is well away from them.
    private static let radius: CGFloat = 56

    func makeUIView(context: Context) -> MoverView {
        let view = MoverView()
        view.isUserInteractionEnabled = false
        view.offset = offset
        return view
    }

    func updateUIView(_ view: MoverView, context: Context) {
        view.offset = offset
        guard let presented = view.presentedRoot else { return }
        presented.presentationContainer?.isUserInteractionEnabled = !passesTouches
        let y = Self.position(offset, in: presented)
        guard presented.transform.ty != y else { return }
        // With the transaction's animation, so letting go springs back as SwiftUI's would.
        context.animate {
            Self.place(presented, at: y)
        } completion: {
            Task { @MainActor in onMoved(offset) }
        }
    }

    fileprivate static func position(_ offset: CGFloat, in presented: UIView) -> CGFloat {
        offset == offscreen ? presented.bounds.height + 40 : offset
    }

    fileprivate static func place(_ presented: UIView, at y: CGFloat) {
        presented.layer.cornerCurve = .continuous
        presented.layer.masksToBounds = true
        presented.transform = CGAffineTransform(translationX: 0, y: y)
        presented.layer.cornerRadius = y > 0 ? radius : 0
    }

    /// Puts the player where it should be the moment it's in its window, before it's first
    /// drawn, so it never shows at the top before sliding up.
    final class MoverView: UIView {
        var offset: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let presented = presentedRoot else { return }
            UIView.performWithoutAnimation {
                PresentationMover.place(presented, at: PresentationMover.position(offset, in: presented))
            }
        }
    }
}

private extension UIView {
    /// The root view of the presentation this view is in.
    var presentedRoot: UIView? {
        sequence(first: next, next: { $0?.next })
            .prefix { $0 != nil }
            .lazy
            .compactMap { $0 as? UIViewController }
            .first { $0.presentingViewController != nil }?
            .view
    }

    /// The presentation's outermost view, the one in the window.
    var presentationContainer: UIView? {
        sequence(first: self, next: \.superview).first { $0.superview is UIWindow }
    }
}
