import TracksCore
import SwiftUI
import UIKit

/// Settings ▸ Play ▸ Louder at Speed: the switch, how much the music changes, and the access it
/// needs. Pushed from the Play page's Driving row.
///
/// As Settings ▸ Wi-Fi does, the switch sits under the name and everything else appears once
/// it's on: the curve of the music against the road with the amount under it, and what Location
/// and Motion & Fitness let it do.
struct SpeedVolumePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private var speedVolume: SpeedVolume { .shared }

    var body: some View {
        let standing = standing
        let status = SpeedVolumeWords.status(standing)
        ScrollViewReader { proxy in
        Form {
            SettingsHero(
                "Louder at Speed",
                subtitle: status.tone.apply(to: Text(status.line)),
                systemImage: "gauge.with.dots.needle.67percent",
                tint: SpeedCurve.tint
            )

            Section {
                Toggle("Louder at Speed", isOn: Binding(get: { speedVolume.isOn }, set: speedVolume.setOn))
            } footer: {
                Text(SpeedVolumeWords.switchFooter(standing))
                    .contentTransition(.opacity)
            }

            if standing.isOn {
                amountSection(standing)
                accessSection(standing)
                    .id(Self.accessID)
            }
        }
        #if DEBUG
        // -TracksSettingsScroll access opens the page at Access, for screenshots.
        .task {
            guard UserDefaults.standard.string(forKey: "TracksSettingsScroll") == "access" else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo(Self.accessID, anchor: .top)
        }
        #endif
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: standing.isOn)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: standing.location)
        .settingsPage("Louder at Speed")
    }

    private static let accessID = "access"

    private var standing: SpeedVolumeStanding {
        speedVolume.standing(motion: model.player.drive.access, isAppleMusic: !model.player.setsOwnLevel)
    }

    // MARK: - Amount

    private func amountSection(_ standing: SpeedVolumeStanding) -> some View {
        Section {
            SpeedCurve(amount: standing.amount, now: now)
            Picker("Amount", selection: Binding(get: { speedVolume.amount }, set: speedVolume.setAmount)) {
                ForEach(SpeedVolumeAmount.allCases) { amount in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SpeedVolumeWords.amountTitle(amount))
                        Text(SpeedVolumeWords.amountDetail(amount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .tag(amount)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Amount")
        } footer: {
            Text(SpeedVolumeWords.amountFooter(standing.amount, usesMiles: Self.usesMiles))
                .contentTransition(.opacity)
        }
    }

    /// Where you are on the curve, while a drive is being followed.
    private var now: (speed: Double, level: Double)? {
        guard speedVolume.isFollowing, let speed = speedVolume.speed else { return nil }
        return (speed, speedVolume.level)
    }

    /// Roads signed in miles an hour: the US and the UK.
    private static var usesMiles: Bool {
        Locale.current.measurementSystem == .us || Locale.current.region == .unitedKingdom
    }

    // MARK: - Access

    private func accessSection(_ standing: SpeedVolumeStanding) -> some View {
        Section {
            LabeledContent("Location", value: SpeedVolumeWords.locationValue(standing.location))
            if !standing.isPrecise, standing.location == .whileUsing || standing.location == .always {
                LabeledContent("Precise Location", value: String(localized: "Off"))
            }
            if let motion = SpeedVolumeWords.motionValue(standing.motion) {
                LabeledContent("Motion & Fitness", value: motion)
            }
            accessButton(standing)
        } header: {
            Text("Access")
        } footer: {
            Text(SpeedVolumeWords.accessFooter(standing))
                .contentTransition(.opacity)
        }
    }

    /// The one thing to do about access, if there's anything: ask, change to Always, or go to
    /// Settings for what only Settings can change.
    @ViewBuilder
    private func accessButton(_ standing: SpeedVolumeStanding) -> some View {
        switch standing.location {
        case .notAsked:
            Button("Allow Location…") { speedVolume.askForLocation() }
        case .off:
            Button("Open Settings…", action: openSettings)
        case .restricted:
            EmptyView()
        case .whileUsing, .always:
            if !standing.isPrecise || standing.motion == .off {
                Button("Open Settings…", action: openSettings)
            } else if standing.location == .whileUsing {
                Button("Change to Always…") {
                    // iPhone asks once. After that, only Settings can change it.
                    if !speedVolume.askForAlways() { openSettings() }
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
