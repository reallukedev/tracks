import Foundation
import TracksCore

/// The song playing here, offered to your other devices through Handoff: in the Dock on a
/// Mac, and the app switcher on iPhone and iPad. Picking it up there plays it from the same
/// moment, and pauses it here when this device is nearby to ask.
@MainActor
final class NowPlayingHandoff: NSObject, NSUserActivityDelegate {
    static let storageKey = "offersHandoff"
    static var isOn: Bool { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true }

    /// Listed under `NSUserActivityTypes` in both apps' Info.plist.
    static var activityType: String { (Bundle.main.bundleIdentifier ?? "com.luke.tracks") + ".playing" }

    private nonisolated static let stateKey = "state"
    private nonisolated static let deviceKey = "device"

    /// What's playing now, read again as another device picks it up, so a seek since the
    /// last change is where it carries on from.
    private let current: () -> NearbyState?
    private let deviceName: String
    private var activity: NSUserActivity?
    private var offered: NearbyState?

    init(deviceName: String, current: @escaping () -> NearbyState?) {
        self.deviceName = deviceName
        self.current = current
    }

    /// Offers the song while it plays, and stops offering it when it doesn't. Called as
    /// often as the player changes; Handoff hears only when the song or its place does.
    func update() {
        guard Self.isOn, let state = current(), state.hasSong, state.isPlaying else {
            activity?.invalidate()
            activity = nil
            offered = nil
            return
        }
        if let offered, offered.isSame(as: state) { return }
        offered = state
        let activity = activity ?? NSUserActivity(activityType: Self.activityType)
        activity.title = [state.title, state.artist].compactMap(\.self).joined(separator: " · ")
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif
        activity.delegate = self
        fill(activity, with: state)
        if self.activity == nil {
            self.activity = activity
            activity.becomeCurrent()
        } else {
            activity.needsSave = true
        }
    }

    private func fill(_ activity: NSUserActivity, with state: NearbyState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        activity.userInfo = [Self.stateKey: data, Self.deviceKey: deviceName]
    }

    nonisolated func userActivityWillSave(_ userActivity: NSUserActivity) {
        // Read on the main actor; written here, on whichever thread Handoff asks from.
        let read = { @MainActor [weak self] () -> (Data, String)? in
            guard let self, let state = self.current(), state.hasSong,
                  let data = try? JSONEncoder().encode(state)
            else { return nil }
            return (data, self.deviceName)
        }
        let fresh = Thread.isMainThread
            ? MainActor.assumeIsolated { read() }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { read() } }
        guard let (data, name) = fresh else { return }
        userActivity.userInfo = [Self.stateKey: data, Self.deviceKey: name]
    }

    /// The song another device offered, and its name.
    static func song(from activity: NSUserActivity) -> (state: NearbyState, device: String)? {
        guard activity.activityType == activityType,
              let data = activity.userInfo?[stateKey] as? Data,
              let state = try? JSONDecoder().decode(NearbyState.self, from: data), state.hasSong
        else { return nil }
        return (state, activity.userInfo?[deviceKey] as? String ?? String(localized: "Your Other Device"))
    }
}
