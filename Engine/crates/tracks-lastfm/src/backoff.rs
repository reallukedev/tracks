//! How long to leave a service alone after it failed for a reason that isn't any one
//! song's fault.

/// A wait that doubles with each failure in a row, from `initial` up to `maximum`, and that
/// any success clears.
///
/// The queues drain on every observation. Without a pause, a server that's down gets a
/// request from every poll, and a rate limit never gets the quiet it asks for. Times are
/// Unix seconds as `f64`; the caller supplies the clock.
#[derive(Debug, Clone, PartialEq)]
pub struct RetryBackoff {
    initial: f64,
    maximum: f64,
    failures: u32,
    not_before: Option<f64>,
}

impl Default for RetryBackoff {
    /// 30 seconds, doubling to 15 minutes.
    fn default() -> Self {
        Self::new(30.0, 15.0 * 60.0)
    }
}

impl RetryBackoff {
    /// A backoff with these limits, in seconds.
    pub fn new(initial: f64, maximum: f64) -> Self {
        Self {
            initial,
            maximum,
            failures: 0,
            not_before: None,
        }
    }

    /// Failures since the last success.
    pub fn failures(&self) -> u32 {
        self.failures
    }

    /// Nothing is tried before this. `None` when the last attempt worked.
    pub fn not_before(&self) -> Option<f64> {
        self.not_before
    }

    /// Whether it's time to try again.
    pub fn allows(&self, now: f64) -> bool {
        self.not_before.is_none_or(|not_before| now >= not_before)
    }

    /// Records a failure at `now`; the wait is measured from it.
    pub fn record_failure(&mut self, now: f64) {
        self.failures = self.failures.saturating_add(1);
        // Capped so the power can't overflow however long the outage.
        let doublings = (self.failures - 1).min(20);
        let delay = self
            .maximum
            .min(self.initial * f64::from(1_u32 << doublings));
        self.not_before = Some(now + delay);
    }

    /// Clears the wait after a success.
    pub fn reset(&mut self) {
        self.failures = 0;
        self.not_before = None;
    }
}
