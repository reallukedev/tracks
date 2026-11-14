//! The scrobble queue's decisions: what each answer costs the rows, and which imports
//! Last.fm already has.

use tracks_lastfm::{
    AfterBatch, BATCH_LIMIT, FailureAction, IgnoredScrobble, ImportedPlay, LastFmError,
    ScrobbleOutcome, ScrobbledTrack, already_scrobbled, failure_action, import_check_from,
    settle_batch,
};

const BASE: i64 = 1_700_000_000;
const DAY: f64 = 24.0 * 60.0 * 60.0;

fn ignored(code: i64) -> ScrobbleOutcome {
    ScrobbleOutcome::Ignored {
        code,
        message: String::new(),
    }
}

#[test]
fn an_import_last_fm_already_has_from_another_device_is_found() {
    let imports = [
        ImportedPlay::new(1, "Love Is Unkind", "BANKS", BASE + 3 * 3600),
        ImportedPlay::new(2, "You", "Mk.gee", BASE + 3 * 3600),
    ];
    let history = [ScrobbledTrack::new("Love Is Unkind", "BANKS", BASE)];
    assert_eq!(already_scrobbled(&imports, &history, DAY), [1]);
}

#[test]
fn a_scrobble_only_accounts_for_one_import_of_the_same_song() {
    let imports = [
        ImportedPlay::new(1, "You", "Mk.gee", BASE),
        ImportedPlay::new(2, "You", "Mk.gee", BASE),
    ];
    let history = [ScrobbledTrack::new("you", "MK.GEE", BASE - 60)];
    assert_eq!(already_scrobbled(&imports, &history, DAY).len(), 1);
}

#[test]
fn a_scrobble_outside_the_window_or_after_the_import_found_it_is_another_play() {
    let imports = [ImportedPlay::new(1, "You", "Mk.gee", BASE)];
    let earlier = [ScrobbledTrack::new("You", "Mk.gee", BASE - 60)];
    let later = [ScrobbledTrack::new("You", "Mk.gee", BASE + 60)];
    assert_eq!(already_scrobbled(&imports, &earlier, 30.0), [] as [i32; 0]);
    assert_eq!(already_scrobbled(&imports, &later, DAY), [] as [i32; 0]);
}

#[test]
fn the_history_check_reads_from_a_window_before_the_earliest_import() {
    let imports = [
        ImportedPlay::new(1, "A", "B", BASE + 500),
        ImportedPlay::new(2, "C", "D", BASE),
    ];
    assert_eq!(import_check_from(&imports, DAY), Some(BASE - 86_400));
    assert_eq!(import_check_from::<u8>(&[], DAY), None);
}

#[test]
fn an_ignored_scrobble_is_given_up_on_with_the_reason_and_the_rest_are_sent() {
    let settled = settle_batch(
        &["one", "two", "three"],
        &[
            ScrobbleOutcome::Accepted,
            ignored(3),
            ScrobbleOutcome::Accepted,
        ],
    );
    assert_eq!(settled.accepted, ["one", "three"]);
    assert_eq!(
        settled.given_up,
        [(
            "two",
            IgnoredScrobble {
                code: 3,
                message: String::new()
            }
        )]
    );
    assert_eq!(settled.held_back, None);
    assert_eq!(settled.next, AfterBatch::Done);
}

#[test]
fn a_scrobble_held_back_by_the_daily_limit_stays_owed_and_backs_off() {
    let settled = settle_batch(&["one", "two"], &[ScrobbleOutcome::Accepted, ignored(5)]);
    assert_eq!(settled.accepted_count(), 1);
    assert_eq!(settled.given_up, []);
    assert_eq!(settled.held_back.map(|held| held.code), Some(5));
    assert_eq!(settled.next, AfterBatch::BackOff);
}

#[test]
fn a_full_batch_asks_for_the_next_and_a_short_one_finishes() {
    let full: Vec<usize> = (0..BATCH_LIMIT).collect();
    let accepted = vec![ScrobbleOutcome::Accepted; BATCH_LIMIT];
    assert_eq!(settle_batch(&full, &accepted).next, AfterBatch::NextBatch);
    assert_eq!(
        settle_batch(&full[..3], &accepted[..3]).next,
        AfterBatch::Done
    );
}

#[test]
fn a_failure_that_isnt_the_scrobbles_fault_leaves_them_untouched() {
    for error in [
        Some(LastFmError::Http { status: 503 }),
        Some(LastFmError::Http { status: 429 }),
        Some(LastFmError::Http { status: 403 }),
        Some(LastFmError::Http { status: 404 }),
        Some(LastFmError::Service {
            code: 11,
            message: "Service Offline".to_owned(),
        }),
        Some(LastFmError::Service {
            code: 16,
            message: String::new(),
        }),
        Some(LastFmError::Service {
            code: 29,
            message: "Rate Limit Exceeded".to_owned(),
        }),
        Some(LastFmError::Service {
            code: 9,
            message: "Invalid session key".to_owned(),
        }),
        Some(LastFmError::MalformedResponse),
        None,
    ] {
        assert_eq!(
            failure_action(error.as_ref()),
            FailureAction::BackOff,
            "{error:?}"
        );
    }
}

#[test]
fn a_request_last_fm_rejects_outright_charges_the_rows() {
    let invalid = LastFmError::Service {
        code: 6,
        message: "Invalid parameters".to_owned(),
    };
    assert_eq!(failure_action(Some(&invalid)), FailureAction::ChargeRows);
}
