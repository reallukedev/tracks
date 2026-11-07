import Foundation

/// How long to leave a service alone after it failed for a reason that isn't any one song's
/// fault: no network, a server error, a rate limit, a token MusicKit couldn't issue.
///
/// The queues drain on every observation, which on the Mac is every ten seconds. Without a
/// pause, a server that's down gets a request from every poll for as long as it stays down,
/// and a rate limit never gets the quiet it's asking for.
///
/// The wait doubles with each failure in a row, from `initial` up to `maximum`, and any
/// success clears it.
struct RetryBackoff: Sendable, Equatable {
    var initial: TimeInterval = 30
    var maximum: TimeInterval = 15 * 60

    /// Failures since the last success.
    private(set) var failures = 0
    /// Nothing is tried before this. Nil when the last attempt worked.
    private(set) var notBefore: Date?

    /// Whether it's time to try again.
    func allows(at now: Date) -> Bool {
        guard let notBefore else { return true }
        return now >= notBefore
    }

    mutating func recordFailure(at now: Date) {
        failures += 1
        let delay = min(maximum, initial * pow(2, Double(min(failures - 1, 20))))
        notBefore = now.addingTimeInterval(delay)
    }

    mutating func reset() {
        failures = 0
        notBefore = nil
    }
}
