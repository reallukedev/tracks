import Foundation

/// How Tracks Radio opens a listen started from nothing in particular: a few songs, each from a
/// different direction you listen in, to hear which one you're in the mood for before it
/// settles in.
///
/// Each genre family you play is a direction. It starts out as likely as your listening and
/// what has landed at this moment before make it (``RadioHabits``), and how sure that is. The
/// probe tries the directions most worth hearing about: ones you play a lot that haven't been
/// heard from much at this moment, rather than ones you never play. It alternates decades, and
/// tries new finds for their share, so one listen tells it about those too.
///
/// What the probe songs do counts double. Once it's done, every pick weighs each family by a
/// guess drawn from what's been heard so far (Thompson sampling): a family that landed comes
/// up more, one skipped less, and one barely heard from still gets its chances, less often as
/// the listen goes on. If every probe song is skipped, it tries directions it hasn't yet. A
/// song loved or asked for more like ends it at once.
struct RadioProbe: Sendable {
    struct Slot: Sendable {
        let identity: String
        let family: String?
        /// Nil until it has played or given way.
        var landed: Bool?
    }

    /// Songs it means to probe with. Grows by one for each try after a probe that's all skips.
    var planned: Int
    /// The slots, by position, that go to new finds.
    let newSlots: Set<Int>
    var slots: [Slot] = []
    var isOpen = true
    /// Songs added after a probe that's all skips.
    var extended = 0
    var decades: Set<Int> = []

    var families: Set<String> { Set(slots.compactMap(\.family)) }

    /// Songs in the probe, at most, for a library of many genres.
    static let length = 5
    /// More tries, at most, when nothing in the probe lands.
    static let mostExtra = 4
    /// A genre family needs this share of the radio to be a direction worth trying.
    static let leastShare = 0.03
    /// A family that landed less often than this at this moment isn't tried in the probe,
    /// only later if nothing else lands.
    static let leastLanded = 0.4

    /// The plan for a radio of these families, as shares of its songs.
    /// - Parameters:
    ///   - heard: songs heard at this moment before, by ``RadioHabits``: the more, the shorter
    ///     the probe, since it already knows what lands then.
    /// - Returns: nil when there's too little to choose between: a small library, or one
    ///   whose songs are nearly all one genre.
    static func plan(shares: [String: Double], yourSongs: Int, heard: Double, newShare: Double, hasNewFinds: Bool) -> RadioProbe? {
        guard yourSongs >= 20 else { return nil }
        let eligible = shares.values.filter { $0 >= leastShare }
        // The number of genres the radio really plays: two even ones count as two, one at
        // nine tenths and a scattering of others as barely more than one.
        let effective = 1 / max(0.0001, eligible.reduce(0) { $0 + $1 * $1 })
        var planned = min(length, eligible.count, Int(effective.rounded(.up)) + 1)
        let sure = min(1, heard / 40)
        planned = Int((Double(planned) * (1 - 0.5 * sure)).rounded())
        guard planned >= 2 else { return nil }
        let newCount = hasNewFinds ? Int((Double(planned) * newShare).rounded()) : 0
        let newSlots = Set([2, 4, 3, 1].filter { $0 < planned }.prefix(newCount))
        return RadioProbe(planned: planned, newSlots: newSlots)
    }
}

// MARK: - Drawing guesses

/// A Beta distribution's mean and spread, and draws from it: how likely a song in a direction
/// is to land, as far as it's known.
struct LandingOdds: Sendable {
    let alpha: Double
    let beta: Double

    /// Before anything is heard: most songs you know get let play, so a little over half,
    /// and as sure as four songs would make it.
    static let prior = LandingOdds(alpha: 2.4, beta: 1.6)

    init(alpha: Double, beta: Double) {
        self.alpha = alpha
        self.beta = beta
    }

    init(_ tally: RadioHabits.Tally) {
        self.init(alpha: Self.prior.alpha + tally.landed, beta: Self.prior.beta + tally.missed)
    }

    var mean: Double { alpha / (alpha + beta) }

    var spread: Double {
        let total = alpha + beta
        return (alpha * beta / (total * total * (total + 1))).squareRoot()
    }

    func draw(using random: inout some RandomNumberGenerator) -> Double {
        let x = Self.gamma(alpha, using: &random)
        let y = Self.gamma(beta, using: &random)
        return x + y > 0 ? x / (x + y) : mean
    }

    /// Marsaglia and Tsang's method.
    private static func gamma(_ shape: Double, using random: inout some RandomNumberGenerator) -> Double {
        if shape < 1 {
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &random)
            return gamma(shape + 1, using: &random) * pow(u, 1 / shape)
        }
        let d = shape - 1.0 / 3
        let c = 1 / (9 * d).squareRoot()
        while true {
            var x: Double
            var v: Double
            repeat {
                x = normal(using: &random)
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &random)
            if log(u) < 0.5 * x * x + d - d * v + d * log(v) { return d * v }
        }
    }

    private static func normal(using random: inout some RandomNumberGenerator) -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &random)
        let u2 = Double.random(in: 0..<1, using: &random)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
