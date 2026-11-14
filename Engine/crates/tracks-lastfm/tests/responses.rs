//! Reading Last.fm's answers, quirks included, and what each failure means.

mod common;

use common::{client, ok, session};
use tracks_lastfm::{
    HttpResponse, LastFmError, Scrobble, ScrobbleOutcome, Session, parse_now_playing,
    parse_scrobbles, parse_session, parse_token,
};

/// A two-scrobble batch as Last.fm sends it: an array, codes as strings, the second
/// ignored for being too old.
const BATCH_WITH_ONE_IGNORED: &str = r##"{"scrobbles":{"scrobble":[{"artist":{"corrected":"0","#text":"BANKS"},"album":{"corrected":"0","#text":"Off With Her Head"},"track":{"corrected":"0","#text":"Love Is Unkind"},"ignoredMessage":{"code":"0","#text":""},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000000"},{"artist":{"corrected":"0","#text":"Mk.gee"},"album":{"corrected":"0","#text":""},"track":{"corrected":"0","#text":"You"},"ignoredMessage":{"code":"3","#text":"Timestamp too old"},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000060"}],"@attr":{"ignored":1,"accepted":1}}}"##;

/// One scrobble comes back as a lone object, not an array of one.
const SINGLE: &str = r##"{"scrobbles":{"scrobble":{"artist":{"corrected":"0","#text":"BANKS"},"album":{"corrected":"0","#text":""},"track":{"corrected":"0","#text":"Love Is Unkind"},"ignoredMessage":{"code":"0","#text":""},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000000"},"@attr":{"ignored":0,"accepted":1}}}"##;

fn ignored(code: i64, message: &str) -> ScrobbleOutcome {
    ScrobbleOutcome::Ignored {
        code,
        message: message.to_owned(),
    }
}

#[test]
fn a_token_is_read_from_the_response() {
    assert_eq!(parse_token(&ok(r#"{"token":"abc"}"#)), Ok("abc".to_owned()));
}

#[test]
fn a_session_carries_the_username_and_key() {
    let json = r#"{"session":{"name":"example","key":"sk-123","subscriber":0}}"#;
    assert_eq!(
        parse_session(&ok(json)),
        Ok(Session::new("example", "sk-123"))
    );
}

#[test]
fn an_unapproved_token_reports_not_authorised_rather_than_a_service_error() {
    let json = r#"{"error":14,"message":"This token has not been authorized"}"#;
    assert_eq!(parse_session(&ok(json)), Err(LastFmError::NotAuthorised));
}

#[test]
fn an_expired_token_stays_a_service_error() {
    let json = r#"{"error":15,"message":"This token has expired"}"#;
    assert_eq!(
        parse_session(&HttpResponse::new(403, json)),
        Err(LastFmError::Service {
            code: 15,
            message: "This token has expired".to_owned()
        })
    );
}

#[test]
fn a_service_error_in_the_body_wins_over_the_http_status() {
    let json = r#"{"error":13,"message":"Invalid method signature supplied"}"#;
    assert_eq!(
        parse_token(&HttpResponse::new(400, json)),
        Err(LastFmError::Service {
            code: 13,
            message: "Invalid method signature supplied".to_owned()
        })
    );
}

#[test]
fn a_service_error_arrives_even_with_http_200() {
    let json = r#"{"error":29,"message":"Rate Limit Exceeded"}"#;
    let error = parse_now_playing(&ok(json)).expect_err("an error");
    assert!(error.is_retryable());
}

#[test]
fn an_error_with_no_message_has_an_empty_one() {
    assert_eq!(
        parse_now_playing(&ok(r#"{"error":11}"#)),
        Err(LastFmError::Service {
            code: 11,
            message: String::new()
        })
    );
}

#[test]
fn a_bare_failure_status_is_an_http_error() {
    assert_eq!(
        parse_now_playing(&HttpResponse::new(503, "<html>Bad gateway</html>")),
        Err(LastFmError::Http { status: 503 })
    );
}

#[test]
fn a_200_that_isnt_json_is_unreadable_not_a_success() {
    assert_eq!(
        parse_now_playing(&ok("<html><body>Sign in to Wi-Fi</body></html>")),
        Err(LastFmError::MalformedResponse)
    );
}

#[test]
fn a_200_that_is_json_but_not_an_object_is_unreadable() {
    assert_eq!(
        parse_token(&ok("[1,2]")),
        Err(LastFmError::MalformedResponse)
    );
}

#[test]
fn a_session_answer_of_the_wrong_shape_is_unreadable() {
    assert_eq!(
        parse_session(&ok(r#"{"session":{"name":"x"}}"#)),
        Err(LastFmError::MalformedResponse)
    );
}

#[test]
fn each_entry_in_a_batch_gets_its_own_outcome_in_the_order_sent() {
    let scrobbles = [
        Scrobble::new("BANKS", "Love Is Unkind", 1_700_000_000),
        Scrobble::new("Mk.gee", "You", 1_700_000_060),
    ];
    let submission = client()
        .scrobble(&scrobbles, &session())
        .expect("a request");
    assert_eq!(
        submission.parse(&ok(BATCH_WITH_ONE_IGNORED)),
        Ok(vec![
            ScrobbleOutcome::Accepted,
            ignored(3, "Timestamp too old")
        ])
    );
}

#[test]
fn a_single_scrobbles_object_is_read_like_a_batch_of_one() {
    assert_eq!(
        parse_scrobbles(&ok(SINGLE), 1),
        Ok(vec![ScrobbleOutcome::Accepted])
    );
}

#[test]
fn codes_sent_as_numbers_are_read_too() {
    let json = r##"{"scrobbles":{"scrobble":[{"ignoredMessage":{"code":0,"#text":""}},{"ignoredMessage":{"code":1,"#text":"Artist name failed filter"}}],"@attr":{"ignored":1,"accepted":1}}}"##;
    assert_eq!(
        parse_scrobbles(&ok(json), 2),
        Ok(vec![
            ScrobbleOutcome::Accepted,
            ignored(1, "Artist name failed filter")
        ])
    );
}

#[test]
fn entries_that_cant_be_lined_up_count_as_taken_when_none_were_ignored() {
    let json = r#"{"scrobbles":{"@attr":{"ignored":"0","accepted":"2"}}}"#;
    assert_eq!(
        parse_scrobbles(&ok(json), 2),
        Ok(vec![ScrobbleOutcome::Accepted; 2])
    );
}

/// Last.fm took the batch. Treating it as unreadable sent it again, scrobbling every
/// accepted entry twice.
#[test]
fn entries_that_cant_be_lined_up_still_count_as_taken_when_some_were_ignored() {
    let json = r#"{"scrobbles":{"scrobble":{},"@attr":{"ignored":1,"accepted":1}}}"#;
    assert_eq!(
        parse_scrobbles(&ok(json), 2),
        Ok(vec![ScrobbleOutcome::Accepted; 2])
    );
}

#[test]
fn a_response_without_a_scrobbles_report_is_unreadable() {
    assert_eq!(
        parse_scrobbles(&ok("{}"), 2),
        Err(LastFmError::MalformedResponse)
    );
}

#[test]
fn only_the_daily_limit_and_a_future_timestamp_are_worth_sending_again() {
    let retryable: Vec<i64> = (0..10)
        .filter(|&code| ignored(code, "").is_retryable())
        .collect();
    assert_eq!(retryable, [4, 5]);
    assert!(!ScrobbleOutcome::Accepted.is_retryable());
}

#[test]
fn rate_limits_and_outages_are_retryable() {
    for error in [
        LastFmError::Http { status: 429 },
        LastFmError::Http { status: 500 },
        LastFmError::Http { status: 503 },
        LastFmError::Service {
            code: 11,
            message: String::new(),
        },
        LastFmError::Service {
            code: 16,
            message: String::new(),
        },
        LastFmError::Service {
            code: 29,
            message: String::new(),
        },
    ] {
        assert!(error.is_retryable(), "{error:?}");
        assert!(!error.is_account_problem(), "{error:?}");
        assert!(!error.is_the_scrobbles_fault(), "{error:?}");
    }
}

#[test]
fn credential_and_session_failures_are_account_problems_not_retryable() {
    let account: Vec<i64> = (0..40)
        .filter(|&code| {
            LastFmError::Service {
                code,
                message: String::new(),
            }
            .is_account_problem()
        })
        .collect();
    assert_eq!(account, [4, 9, 10, 13, 14, 15, 26]);
    for error in [
        LastFmError::NotConfigured,
        LastFmError::NotConnected,
        LastFmError::NotAuthorised,
    ] {
        assert!(error.is_account_problem());
        assert!(!error.is_retryable());
    }
}

#[test]
fn only_a_last_fm_rejection_of_the_request_is_the_scrobbles_fault() {
    let invalid_parameters = LastFmError::Service {
        code: 6,
        message: "Invalid parameters".to_owned(),
    };
    assert!(invalid_parameters.is_the_scrobbles_fault());
    for error in [
        LastFmError::Http { status: 400 },
        LastFmError::Http { status: 404 },
        LastFmError::MalformedResponse,
        LastFmError::Service {
            code: 9,
            message: String::new(),
        },
    ] {
        assert!(!error.is_the_scrobbles_fault(), "{error:?}");
        assert!(!error.is_retryable(), "{error:?}");
    }
}
