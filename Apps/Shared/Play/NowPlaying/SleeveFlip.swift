import SwiftUI

/// A record sleeve you can turn over: the cover on the front, your history with the song on
/// the back, as a pass in Wallet turns over to its details.
///
/// The turn is the one flourish on Now Playing, so it only happens when asked for: a click on
/// the Mac, a double tap on iPhone, where a single tap on the cover is often the start of the
/// swipe that closes the player, or the Your History button on either. Under Reduce Motion the
/// two sides cross-fade in place.
struct SleeveFlip<Front: View, Back: View>: View {
    let showsBack: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let angle = showsBack && !reduceMotion ? 180.0 : 0
        ZStack {
            front
                .modifier(SleeveSide(angle: angle, isBack: false, fades: reduceMotion, showsBack: showsBack))
                .accessibilityHidden(showsBack)
            back
                // Drawn turned, so it reads the right way round once the sleeve has turned.
                .rotation3DEffect(.degrees(reduceMotion ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .modifier(SleeveSide(angle: angle, isBack: true, fades: reduceMotion, showsBack: showsBack))
                .accessibilityHidden(!showsBack)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.12), value: showsBack)
    }
}

/// Shows one side while it faces front: the front until the sleeve is edge-on, the back after.
/// Animatable, so the swap happens at the edge of the turn rather than at either end of it.
private struct SleeveSide: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool
    /// Reduce Motion: no turn, just a cross-fade between the sides.
    let fades: Bool
    let showsBack: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let isShowing = fades ? showsBack == isBack : (angle >= 90) == isBack
        content
            .opacity(isShowing ? 1 : 0)
            .allowsHitTesting(isShowing)
    }
}
