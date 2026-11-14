//! What can go wrong with a Last.fm call, and what each failure means for the caller.

/// A failed Last.fm call.
///
/// Transport failures (offline, a timeout) are the host's own errors and never appear here.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LastFmError {
    /// This build has no Last.fm application configured. Raised by the host.
    #[error("Last.fm is not configured in this build")]
    NotConfigured,
    /// Nobody has connected an account yet. Raised by the host.
    #[error("no Last.fm account is connected")]
    NotConnected,
    /// The user has not yet approved the token in their browser.
    #[error("the Last.fm token has not been authorised yet")]
    NotAuthorised,
    /// A status outside 2xx with no Last.fm error in the body.
    #[error("Last.fm answered HTTP {status}")]
    Http {
        /// The HTTP status code.
        status: u16,
    },
    /// Last.fm's own error code and message.
    #[error("Last.fm error {code}: {message}")]
    Service {
        /// Last.fm's error code.
        code: i64,
        /// Last.fm's message, empty when it sent none.
        message: String,
    },
    /// A body that isn't the JSON Last.fm sends, such as a captive portal's page.
    #[error("Last.fm's answer could not be read")]
    MalformedResponse,
}

/// Service codes worth trying again later: 11 service offline, 16 temporarily unavailable,
/// 29 rate limit.
const RETRYABLE_CODES: [i64; 3] = [11, 16, 29];

/// Service codes about the build's credentials or the account: 4 authentication failed,
/// 9 invalid session key, 10 invalid API key, 13 invalid signature, 14 and 15 token not
/// authorised or expired, 26 API key suspended.
const ACCOUNT_CODES: [i64; 7] = [4, 9, 10, 13, 14, 15, 26];

impl LastFmError {
    /// Whether trying again later could succeed.
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::Http { status } => *status == 429 || *status >= 500,
            Self::Service { code, .. } => RETRYABLE_CODES.contains(code),
            Self::NotConfigured
            | Self::NotConnected
            | Self::NotAuthorised
            | Self::MalformedResponse => false,
        }
    }

    /// Whether the failure is down to this build's credentials or the connected account
    /// rather than the scrobbles in the request.
    ///
    /// Not retryable, but not the songs' fault either: charging them an attempt would give up
    /// on a whole queue of listening because a session was revoked.
    pub fn is_account_problem(&self) -> bool {
        match self {
            Self::NotConfigured | Self::NotConnected | Self::NotAuthorised => true,
            Self::Service { code, .. } => ACCOUNT_CODES.contains(code),
            Self::Http { .. } | Self::MalformedResponse => false,
        }
    }

    /// Whether a failed scrobble request says something about the scrobbles in it, so each
    /// is charged an attempt.
    ///
    /// Only an error Last.fm itself sent back counts. An outage, a rate limit, the account,
    /// a proxy's bare 4xx or a page that isn't Last.fm's would fail any request.
    pub fn is_the_scrobbles_fault(&self) -> bool {
        matches!(self, Self::Service { .. }) && !self.is_retryable() && !self.is_account_problem()
    }
}

/// The result of reading a Last.fm response.
pub type Result<T, E = LastFmError> = std::result::Result<T, E>;
