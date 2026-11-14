//! The retry backoff and the scrobble threshold.

use proptest::prelude::*;
use tracks_lastfm::RetryBackoff;
use tracks_lastfm::policy::{
    MAXIMUM_REQUIRED_PLAYBACK, NOT_PLAYED_ENOUGH_REASON, TOO_SHORT_REASON, is_held_from_scrobbling,
    required_playback, should_scrobble,
};

const T0: f64 = 1_800_000_000.0;

/// The delay set by each failure in a row, each recorded at `T0`.
fn delays(count: usize, mut backoff: RetryBackoff) -> Vec<f64> {
    (0..count)
        .map(|_| {
            backoff.record_failure(T0);
            backoff.not_before().map_or(f64::NAN, |at| at - T0)
        })
        .collect()
}

#[test]
fn a_fresh_backoff_allows_anything() {
    let backoff = RetryBackoff::default();
    assert_eq!(backoff.failures(), 0);
    assert_eq!(backoff.not_before(), None);
    assert!(backoff.allows(f64::MIN));
    assert!(backoff.allows(T0));
}

#[test]
fn the_wait_doubles_with_each_failure_in_a_row_up_to_fifteen_minutes() {
    assert_eq!(
        delays(9, RetryBackoff::default()),
        [30.0, 60.0, 120.0, 240.0, 480.0, 900.0, 900.0, 900.0, 900.0]
    );
}

#[test]
fn each_wait_is_measured_from_that_failure_not_the_last_waits_end() {
    let mut backoff = RetryBackoff::default();
    backoff.record_failure(T0);
    backoff.record_failure(T0 + 5.0);
    assert_eq!(backoff.not_before(), Some(T0 + 65.0));
    assert_eq!(backoff.failures(), 2);
}

#[test]
fn the_gate_opens_exactly_at_the_end_of_the_wait() {
    let mut backoff = RetryBackoff::default();
    backoff.record_failure(T0);
    assert!(!backoff.allows(T0 + 29.999));
    assert!(backoff.allows(T0 + 30.0));
    assert!(backoff.allows(T0 + 31.0));
}

#[test]
fn many_failures_in_a_row_never_overflow_the_maximum() {
    for count in [100, 10_000] {
        let mut backoff = RetryBackoff::default();
        for _ in 0..count {
            backoff.record_failure(T0);
        }
        assert_eq!(backoff.not_before(), Some(T0 + 900.0));
        assert_eq!(backoff.failures(), count);
    }
}

#[test]
fn reset_clears_the_wait_and_the_next_failure_starts_over() {
    let mut backoff = RetryBackoff::default();
    for _ in 0..4 {
        backoff.record_failure(T0);
    }
    backoff.reset();
    assert_eq!(backoff, RetryBackoff::default());

    backoff.record_failure(T0);
    assert_eq!(backoff.not_before(), Some(T0 + 30.0));
}

#[test]
fn custom_limits_double_and_cap_the_same_way() {
    assert_eq!(delays(3, RetryBackoff::new(10.0, 25.0)), [10.0, 20.0, 25.0]);
    assert_eq!(delays(3, RetryBackoff::new(30.0, 5.0)), [5.0, 5.0, 5.0]);
}

#[test]
fn a_zero_initial_wait_always_allows() {
    let mut backoff = RetryBackoff::new(0.0, 900.0);
    for _ in 0..5 {
        backoff.record_failure(T0);
        assert!(backoff.allows(T0));
    }
}

#[test]
fn tracks_of_thirty_seconds_or_less_never_scrobble() {
    for duration in [1.0, 29.0, 30.0] {
        assert!(!should_scrobble(duration, duration), "{duration}");
    }
}

#[test]
fn a_short_track_scrobbles_at_half_its_length() {
    assert!(should_scrobble(200.0, 100.0));
    assert!(!should_scrobble(200.0, 99.0));
}

#[test]
fn a_long_track_scrobbles_at_four_minutes_not_at_half() {
    assert!(should_scrobble(1_200.0, 240.0));
    assert!(!should_scrobble(1_200.0, 239.0));
}

#[test]
fn an_unknown_length_is_taken_as_four_minutes() {
    for duration in [None, Some(0.0), Some(-5.0), Some(f64::NAN)] {
        assert_eq!(required_playback(duration), Some(120.0), "{duration:?}");
    }
}

#[test]
fn the_requirement_is_half_the_length_capped_at_four_minutes() {
    for (duration, expected) in [
        (30.5, 15.25),
        (31.0, 15.5),
        (200.0, 100.0),
        (480.0, 240.0),
        (481.0, 240.0),
        (36_000.0, 240.0),
        (f64::INFINITY, 240.0),
    ] {
        assert_eq!(
            required_playback(Some(duration)),
            Some(expected),
            "{duration}"
        );
    }
}

#[test]
fn only_the_policys_own_reasons_mark_a_play_as_held() {
    assert!(is_held_from_scrobbling(None, Some(TOO_SHORT_REASON)));
    assert!(is_held_from_scrobbling(
        None,
        Some(NOT_PLAYED_ENOUGH_REASON)
    ));
    assert!(!is_held_from_scrobbling(Some(1), Some(TOO_SHORT_REASON)));
    assert!(!is_held_from_scrobbling(None, Some("Too old")));
    assert!(!is_held_from_scrobbling(None, None));
}

proptest! {
    #[test]
    fn the_requirement_is_positive_at_most_the_cap_and_at_most_half_the_track(duration in 30.001_f64..1e7) {
        let required = required_playback(Some(duration)).expect("long enough");
        prop_assert!(required > 0.0);
        prop_assert!(required <= MAXIMUM_REQUIRED_PLAYBACK);
        prop_assert!(required <= duration / 2.0);
    }

    #[test]
    fn the_wait_never_shrinks_while_failures_continue(count in 1_usize..64) {
        let waits = delays(count, RetryBackoff::default());
        prop_assert!(waits.windows(2).all(|pair| pair[0] <= pair[1]));
        prop_assert!(waits.iter().all(|&wait| (30.0..=900.0).contains(&wait)));
    }
}
