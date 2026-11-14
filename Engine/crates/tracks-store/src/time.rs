//! Local calendar fields for Unix-millisecond times, fast enough to run over every play.

use jiff::Timestamp;
use jiff::tz::TimeZone;

const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;

/// Converts times to local hours and days. The zone's offset is remembered for the span
/// until its next transition (months, usually), so converting a whole history is plain
/// arithmetic after the first lookup in each span.
#[derive(Debug)]
pub struct LocalClock {
    zone: TimeZone,
    /// `[from, until)` in Unix milliseconds where `offset_ms` holds.
    from: i64,
    until: i64,
    offset_ms: i64,
}

/// A play's place on the local calendar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalTime {
    /// Days since 1970-01-01 in local time.
    pub day: i64,
    /// 0 to 23.
    pub hour: u8,
    /// 0 is Sunday, as Foundation's weekday 1.
    pub weekday: u8,
}

impl LocalClock {
    pub fn new(zone: TimeZone) -> Self {
        Self {
            zone,
            from: 1,
            until: 0,
            offset_ms: 0,
        }
    }

    fn offset_ms(&mut self, at_ms: i64) -> i64 {
        if at_ms < self.from || at_ms >= self.until {
            let Ok(ts) = Timestamp::from_millisecond(at_ms) else {
                return self.offset_ms;
            };
            self.offset_ms = i64::from(self.zone.to_offset(ts).seconds()) * 1000;
            // Valid from here to the next transition. Plays are read in time order, so the span
            // only needs to run forward; an earlier time just looks up again.
            self.from = at_ms;
            self.until = self
                .zone
                .following(ts)
                .next()
                .map_or(i64::MAX, |t| t.timestamp().as_millisecond());
        }
        self.offset_ms
    }

    pub fn local(&mut self, at_ms: i64) -> LocalTime {
        let local = at_ms.saturating_add(self.offset_ms(at_ms));
        let day = local.div_euclid(DAY_MS);
        let hour = (local.rem_euclid(DAY_MS) / HOUR_MS) as u8;
        // 1970-01-01 was a Thursday.
        let weekday = (day + 4).rem_euclid(7) as u8;
        LocalTime { day, hour, weekday }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_fields_follow_daylight_saving() {
        let zone = TimeZone::get("America/New_York").expect("zone");
        let mut clock = LocalClock::new(zone);
        // 2026-03-08 06:30 UTC is 01:30 EST; 07:30 UTC is 03:30 EDT, after the jump.
        let before = clock.local(1_772_951_400_000);
        let after = clock.local(1_772_955_000_000);
        assert_eq!((before.hour, after.hour), (1, 3));
        assert_eq!(before.weekday, 0, "a Sunday");
    }

    #[test]
    fn utc_epoch_is_a_thursday_at_midnight() {
        let mut clock = LocalClock::new(TimeZone::UTC);
        assert_eq!(
            clock.local(0),
            LocalTime {
                day: 0,
                hour: 0,
                weekday: 4
            }
        );
        assert_eq!(clock.local(-1).day, -1);
    }
}
