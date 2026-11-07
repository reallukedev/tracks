import Foundation

/// Where Louder at Speed stands, for its settings page to say.
public struct SpeedVolumeStanding: Sendable, Equatable {
    /// Tracks’ access to location, as Settings ▸ Privacy & Security ▸ Location Services has it.
    public enum Location: Sendable, Equatable {
        case notAsked
        case whileUsing
        case always
        /// Turned off for Tracks, or Location Services off altogether.
        case off
        /// Blocked by Screen Time or a profile, so it can't be changed here.
        case restricted
    }

    /// Tracks’ access to Motion & Fitness, which notices a drive when CarPlay isn't there to.
    public enum Motion: Sendable, Equatable {
        case notAsked
        case on
        case off
        /// No motion to sense, as on an iPad.
        case unavailable
    }

    public var isOn: Bool
    public var amount: SpeedVolumeAmount
    public var location: Location
    /// Precise Location on: Approximate Location has no speed in it.
    public var isPrecise: Bool
    public var motion: Motion
    /// Playing from Apple Music, whose level only iPhone's volume changes.
    public var isAppleMusic: Bool
    /// The audio is going to CarPlay right now.
    public var isOnCarPlay: Bool
    /// Following the car's speed right now: driving, with music on.
    public var isFollowing: Bool

    public init(
        isOn: Bool,
        amount: SpeedVolumeAmount = .moderate,
        location: Location,
        isPrecise: Bool = true,
        motion: Motion = .on,
        isAppleMusic: Bool = false,
        isOnCarPlay: Bool = false,
        isFollowing: Bool = false
    ) {
        self.isOn = isOn
        self.amount = amount
        self.location = location
        self.isPrecise = isPrecise
        self.motion = motion
        self.isAppleMusic = isAppleMusic
        self.isOnCarPlay = isOnCarPlay
        self.isFollowing = isFollowing
    }

    /// What's stopping it, most pressing first. Nil when nothing is.
    public var blocker: Blocker? {
        guard isOn else { return nil }
        switch location {
        case .notAsked: return .needsLocation
        case .off: return .locationOff
        case .restricted: return .locationRestricted
        case .whileUsing, .always: break
        }
        if !isPrecise { return .needsPreciseLocation }
        if isAppleMusic, isOnCarPlay { return .carSetsVolume }
        return nil
    }

    public enum Blocker: Sendable, Equatable {
        case needsLocation
        case locationOff
        case locationRestricted
        case needsPreciseLocation
        /// Apple Music over CarPlay: the car sets the volume, and Tracks can't reach it.
        case carSetsVolume
    }
}

/// The words for Louder at Speed's settings: its status line, its row on the Play page, and
/// the footers that say what each choice does.
public enum SpeedVolumeWords {
    /// The status line under the page's name.
    public static func status(_ standing: SpeedVolumeStanding) -> (line: String, tone: SettingsTone) {
        guard standing.isOn else {
            return (String(localized: "Turns your music up on the highway and down when you stop, so you can hear it at speed and talk at the lights."), .plain)
        }
        switch standing.blocker {
        case .needsLocation:
            return (String(localized: "Allow Location to start following your speed."), .attention)
        case .locationOff:
            return (String(localized: "Location is off for Tracks"), .attention)
        case .locationRestricted:
            return (String(localized: "Location isn’t available on this iPhone"), .attention)
        case .needsPreciseLocation:
            return (String(localized: "Needs Precise Location to see your speed"), .attention)
        case .carSetsVolume:
            return (String(localized: "Your car sets Apple Music’s volume over CarPlay"), .plain)
        case nil:
            return standing.isFollowing
                ? (String(localized: "On · following your speed now"), .plain)
                : (String(localized: "On · starts when you drive"), .plain)
        }
    }

    /// The row's value on the Play page.
    public static func rowValue(_ standing: SpeedVolumeStanding) -> String {
        guard standing.isOn else { return String(localized: "Off") }
        switch standing.blocker {
        case .needsLocation, .locationOff, .locationRestricted:
            return String(localized: "Needs Location")
        case .needsPreciseLocation:
            return String(localized: "Needs Precise Location")
        case .carSetsVolume, nil:
            return standing.isFollowing ? String(localized: "Driving") : amountTitle(standing.amount)
        }
    }

    /// Under the switch: how it works with what's playing.
    public static func switchFooter(_ standing: SpeedVolumeStanding) -> String {
        guard standing.isOn else {
            return String(localized: "Tracks follows the car’s speed from Location, only while you drive with music playing.")
        }
        guard standing.isAppleMusic else {
            return String(localized: "Your volume is what you hear on the highway, and Tracks brings the music down from there as you slow. Your volume buttons work as always.")
        }
        return standing.isOnCarPlay
            ? String(localized: "With Apple Music, Tracks moves iPhone’s volume, but over CarPlay the car keeps the volume to itself. Songs from Your Music follow your speed on CarPlay too.")
            : String(localized: "With Apple Music, Tracks moves iPhone’s volume. Change it whenever you like, and Tracks follows your speed from there. Over CarPlay, the car keeps the volume to itself.")
    }

    public static func amountTitle(_ amount: SpeedVolumeAmount) -> String {
        switch amount {
        case .slight: String(localized: "Slight")
        case .moderate: String(localized: "Moderate")
        case .strong: String(localized: "Strong")
        }
    }

    /// Each amount's line, under its name in the picker.
    public static func amountDetail(_ amount: SpeedVolumeAmount) -> String {
        switch amount {
        case .slight: String(localized: "A little quieter when you stop.")
        case .moderate: String(localized: "Quiet enough to talk when you stop.")
        case .strong: String(localized: "Much quieter when you stop, for a loud car.")
        }
    }

    /// Under the amounts: what the one chosen does, in numbers.
    /// - Parameter usesMiles: speeds in miles an hour, as in the US and the UK.
    public static func amountFooter(_ amount: SpeedVolumeAmount, usesMiles: Bool) -> String {
        let decibels = Int(amount.stoppedDecibels)
        return usesMiles
            ? String(localized: "Stopped, your music sits about \(decibels) dB under your highway volume, and it’s back to full by about 70 mph.")
            : String(localized: "Stopped, your music sits about \(decibels) dB under your highway volume, and it’s back to full by about 110 km/h.")
    }

    /// Under the access rows: what the access Tracks has lets it do.
    public static func accessFooter(_ standing: SpeedVolumeStanding) -> String {
        var lines: [String] = []
        switch standing.location {
        case .notAsked:
            lines.append(String(localized: "Tracks needs your speed, which comes from Location."))
        case .off:
            lines.append(String(localized: "Tracks needs your speed, which comes from Location. Turn it on in Settings ▸ Privacy & Security ▸ Location Services ▸ Tracks."))
        case .restricted:
            lines.append(String(localized: "Location is restricted on this iPhone, by Screen Time or a profile."))
        case .whileUsing:
            lines.append(String(localized: "It starts when you connect to CarPlay, or when Tracks is open as you set off. Change to Always to have it start with iPhone in a pocket or a bag."))
        case .always:
            lines.append(String(localized: "It starts whenever you drive with music playing, wherever iPhone is in the car."))
        }
        if standing.location == .whileUsing || standing.location == .always, !standing.isPrecise {
            lines.append(String(localized: "Approximate Location has no speed in it, so Precise Location needs to be on."))
        }
        if standing.motion == .off {
            lines.append(String(localized: "With Motion & Fitness off, only CarPlay counts as a drive."))
        }
        lines.append(String(localized: "Tracks uses only your speed, only while you drive, and your location never leaves this iPhone."))
        return lines.joined(separator: " ")
    }

    /// The Location row's value, in Settings' own words for each choice.
    public static func locationValue(_ location: SpeedVolumeStanding.Location) -> String {
        switch location {
        case .notAsked: String(localized: "Not Allowed Yet")
        case .whileUsing: String(localized: "While Using")
        case .always: String(localized: "Always")
        case .off: String(localized: "Off")
        case .restricted: String(localized: "Restricted")
        }
    }

    /// The Motion & Fitness row's value.
    public static func motionValue(_ motion: SpeedVolumeStanding.Motion) -> String? {
        switch motion {
        case .notAsked: String(localized: "Not Allowed Yet")
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        case .unavailable: nil
        }
    }

    /// Where along the road a speed is, for the curve's labels.
    public static func roadLabel(forSpeed metresPerSecond: Double) -> String {
        switch metresPerSecond {
        case ..<1.2: String(localized: "Stopped")
        case ..<20: String(localized: "Town")
        default: String(localized: "Highway")
        }
    }

    /// How the music sits at a level, for VoiceOver and the curve: "At your volume", "About
    /// 3 dB quieter".
    public static func levelPhrase(_ decibels: Double) -> String {
        let rounded = Int((-decibels).rounded())
        return rounded <= 0
            ? String(localized: "At your volume")
            : String(localized: "About \(rounded) dB quieter")
    }
}
