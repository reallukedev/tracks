import Foundation
import Network
import Observation

/// Whether the iPhone is online, and on a metered connection, so server music that isn't
/// downloaded can be shown as out of reach.
@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOnline = true
    /// Cellular, or a hotspot: where downloads wait unless allowed.
    private(set) var isExpensive = false

    /// Called when the connection comes back or moves, from Wi-Fi to cellular or one network
    /// to another: a server only reachable on one of them may have come or gone.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// The interfaces in use at the last look, so a path updated with nothing new is let be.
    @ObservationIgnored private var interfaces: [String]?
    @ObservationIgnored private var settling: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                guard let self else { return }
                let moved = self.interfaces != nil && (online != self.isOnline || interfaces != self.interfaces)
                if online != self.isOnline { self.isOnline = online }
                if expensive != self.isExpensive { self.isExpensive = expensive }
                self.interfaces = interfaces
                if moved { self.settle(online: online) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.luke.tracks.network"))
    }

    /// Passes a move on once the path has held still for a moment. Walking out of Wi-Fi
    /// flips between networks a few times in a second, and each move asks every server again.
    private func settle(online: Bool) {
        settling?.cancel()
        settling = nil
        guard online else { return }
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.isOnline else { return }
            self.settling = nil
            self.onChange?()
        }
    }

    deinit {
        monitor.cancel()
    }
}
