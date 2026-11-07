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

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                guard let self else { return }
                let moved = self.interfaces != nil && (online != self.isOnline || interfaces != self.interfaces)
                self.isOnline = online
                self.isExpensive = expensive
                self.interfaces = interfaces
                if moved, online { self.onChange?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.luke.tracks.network"))
    }

    deinit {
        monitor.cancel()
    }
}
