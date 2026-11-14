use std::fmt;
use std::str::FromStr;

/// A stored value this version doesn't know.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unknown value `{0}`")]
pub struct UnknownValue(pub String);

/// How a song came to be in the history. The raw values are the ones the Swift app stores.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum PlayKind {
    /// Heard on a radio station.
    Radio = 0,
    /// Played on demand.
    OnDemand = 1,
    /// Read from Apple Music's recently played list, dated when found rather than when played.
    Imported = 2,
    /// Read from the connected Last.fm account's scrobbles.
    LastFm = 3,
}

impl PlayKind {
    pub const ALL: [Self; 4] = [Self::Radio, Self::OnDemand, Self::Imported, Self::LastFm];

    /// Whether the play's time is when it played. Imports are dated when they were found.
    pub const fn time_is_known(self) -> bool {
        !matches!(self, Self::Imported)
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Radio => "radio",
            Self::OnDemand => "onDemand",
            Self::Imported => "imported",
            Self::LastFm => "lastFM",
        }
    }

    pub const fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Radio),
            1 => Some(Self::OnDemand),
            2 => Some(Self::Imported),
            3 => Some(Self::LastFm),
            _ => None,
        }
    }
}

impl FromStr for PlayKind {
    type Err = UnknownValue;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|kind| kind.as_str() == s)
            .ok_or_else(|| UnknownValue(s.to_owned()))
    }
}

impl fmt::Display for PlayKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Where a play's music came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum PlaySource {
    /// Apple Music, and every play kept before Tracks knew the difference.
    #[default]
    AppleMusic = 0,
    /// Files and servers Tracks plays itself.
    YourMusic = 1,
}

impl PlaySource {
    /// Reads a stored value: nothing, or anything this version doesn't know, is Apple Music.
    pub fn from_stored(raw: Option<&str>) -> Self {
        match raw {
            Some("yourMusic") => Self::YourMusic,
            _ => Self::AppleMusic,
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AppleMusic => "appleMusic",
            Self::YourMusic => "yourMusic",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_round_trip_through_their_stored_values() {
        for kind in PlayKind::ALL {
            assert_eq!(kind.as_str().parse::<PlayKind>(), Ok(kind));
            assert_eq!(PlayKind::from_u8(kind as u8), Some(kind));
        }
        assert!("someday".parse::<PlayKind>().is_err());
    }

    #[test]
    fn unknown_sources_count_as_apple_music() {
        assert_eq!(PlaySource::from_stored(None), PlaySource::AppleMusic);
        assert_eq!(
            PlaySource::from_stored(Some("vinyl")),
            PlaySource::AppleMusic
        );
        assert_eq!(
            PlaySource::from_stored(Some("yourMusic")),
            PlaySource::YourMusic
        );
    }
}
