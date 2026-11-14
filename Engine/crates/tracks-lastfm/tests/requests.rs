//! The requests the client builds, read back the way Last.fm will read them.

mod common;

use std::collections::BTreeMap;

use common::{client, fields, session};
use tracks_lastfm::{BATCH_LIMIT, ENDPOINT, HttpRequest, Method, Scrobble, Session, md5_hex};

/// Checks the signature by hand rather than through `sign`, so a signer that skipped some
/// fields can't agree with itself: everything sent but `format` and the signature, name and
/// value in name order, then the secret.
fn assert_signed(sent: &BTreeMap<String, String>) {
    let mut signable = sent.clone();
    assert_eq!(signable.remove("format").as_deref(), Some("json"));
    let signature = signable.remove("api_sig").expect("a signature");
    let joined: String = signable
        .iter()
        .flat_map(|(k, v)| [k.as_str(), v.as_str()])
        .collect();
    assert_eq!(signature, md5_hex(&format!("{joined}SECRET")));
}

fn keys(sent: &BTreeMap<String, String>) -> Vec<&str> {
    sent.keys().map(String::as_str).collect()
}

#[test]
fn every_call_is_a_form_post_to_the_api_with_the_user_agent() {
    let request = client().auth_get_token();
    assert_eq!(request.method, Method::Post);
    assert_eq!(request.url, ENDPOINT);
    assert_eq!(
        request.header("content-type"),
        Some("application/x-www-form-urlencoded")
    );
    assert_eq!(request.header("User-Agent"), Some("Tracks/1.0 (test)"));
}

#[test]
fn a_two_scrobble_batch_matches_the_swift_client_byte_for_byte() {
    let scrobbles = [
        Scrobble::new(
            "C+C Music Factory",
            "Gonna Make You Sweat (Everybody Dance Now)",
            1_700_000_000,
        )
        .with_album("Gonna Make You Sweat"),
        Scrobble::new(
            "Beyonc\u{E9}",
            "Me & You = Us; \u{6771}\u{4EAC} #1 100%",
            1_700_000_240,
        ),
    ];
    let submission = client()
        .scrobble(&scrobbles, &Session::new("listener", "sk-123"))
        .expect("a request");
    assert_eq!(
        std::str::from_utf8(&submission.request.body).expect("utf-8"),
        "album%5B0%5D=Gonna%20Make%20You%20Sweat&api_key=KEY&api_sig=8e3e490f053862b412e5d871a67a5246\
         &artist%5B0%5D=C%2BC%20Music%20Factory&artist%5B1%5D=Beyonc%C3%A9&format=json\
         &method=track.scrobble&sk=sk-123&timestamp%5B0%5D=1700000000&timestamp%5B1%5D=1700000240\
         &track%5B0%5D=Gonna%20Make%20You%20Sweat%20(Everybody%20Dance%20Now)\
         &track%5B1%5D=Me%20%26%20You%20%3D%20Us;%20%E6%9D%B1%E4%BA%AC%20%231%20100%25"
    );
    assert_eq!(submission.sent, 2);
}

#[test]
fn scrobbles_are_sent_indexed_and_the_indices_are_signed() {
    let scrobbles = [
        Scrobble::new("BANKS", "Love Is Unkind", 1_700_000_000).with_album("Off With Her Head"),
        Scrobble::new("Mk.gee", "You", 1_700_000_060),
    ];
    let sent = fields(
        &client()
            .scrobble(&scrobbles, &session())
            .expect("a request")
            .request,
    );

    assert_eq!(
        keys(&sent),
        [
            "album[0]",
            "api_key",
            "api_sig",
            "artist[0]",
            "artist[1]",
            "format",
            "method",
            "sk",
            "timestamp[0]",
            "timestamp[1]",
            "track[0]",
            "track[1]",
        ]
    );
    assert_eq!(sent["track[1]"], "You");
    assert_eq!(sent["timestamp[0]"], "1700000000");
    assert_signed(&sent);
}

#[test]
fn an_empty_album_is_left_out_rather_than_sent_blank() {
    let scrobbles = [Scrobble::new("A", "B", 1).with_album("")];
    let sent = fields(
        &client()
            .scrobble(&scrobbles, &session())
            .expect("a request")
            .request,
    );
    assert!(!sent.contains_key("album[0]"));
}

#[test]
fn an_empty_batch_is_not_a_request() {
    assert!(client().scrobble(&[], &session()).is_none());
}

#[test]
fn a_batch_over_the_limit_sends_the_first_fifty() {
    let scrobbles: Vec<Scrobble> = (0..BATCH_LIMIT + 7)
        .map(|index| Scrobble::new("A", format!("Song {index}"), index as i64))
        .collect();
    let submission = client()
        .scrobble(&scrobbles, &session())
        .expect("a request");
    let sent = fields(&submission.request);

    assert_eq!(submission.sent, BATCH_LIMIT);
    assert_eq!(sent["track[49]"], "Song 49");
    assert!(!sent.contains_key("track[50]"));
}

#[test]
fn now_playing_carries_the_song_and_session() {
    let sent =
        fields(&client().update_now_playing("BANKS", "Gimme", Some("The Altar"), &session()));
    assert_eq!(sent["method"], "track.updateNowPlaying");
    assert_eq!(sent["artist"], "BANKS");
    assert_eq!(sent["track"], "Gimme");
    assert_eq!(sent["album"], "The Altar");
    assert_eq!(sent["sk"], "sk-1");
    assert_signed(&sent);
}

#[test]
fn the_history_request_is_signed_uses_the_session_and_asks_for_the_range() {
    let sent =
        fields(&client().recent_tracks(&session(), Some(1_700_000_000), Some(1_700_003_600), 200));
    assert_eq!(sent["method"], "user.getRecentTracks");
    assert_eq!(sent["user"], "listener");
    assert_eq!(sent["sk"], "sk-1");
    assert_eq!(sent["limit"], "200");
    assert_eq!(sent["page"], "1");
    assert_eq!(sent["from"], "1700000000");
    assert_eq!(sent["to"], "1700003600");
    assert_signed(&sent);
}

#[test]
fn the_history_page_size_is_capped_and_an_open_range_sends_no_bounds() {
    let sent = fields(&client().recent_tracks(&session(), None, None, 1_000));
    assert_eq!(sent["limit"], "200");
    assert!(!sent.contains_key("from"));
    assert!(!sent.contains_key("to"));
}

#[test]
fn the_session_exchange_sends_the_token() {
    let sent = fields(&client().auth_get_session("tok"));
    assert_eq!(sent["method"], "auth.getSession");
    assert_eq!(sent["token"], "tok");
    assert_signed(&sent);
}

#[test]
fn track_info_is_autocorrected_and_names_the_account_only_when_given() {
    let request: HttpRequest = client().track_info("Gold Digger", "Kanye West", Some("listener"));
    let sent = fields(&request);
    assert_eq!(sent["method"], "track.getInfo");
    assert_eq!(sent["autocorrect"], "1");
    assert_eq!(sent["username"], "listener");
    assert_signed(&sent);

    let anonymous = fields(&client().track_info("Gold Digger", "Kanye West", None));
    assert!(!anonymous.contains_key("username"));
}

#[test]
fn similar_tracks_asks_for_the_limit() {
    let sent = fields(&client().similar_tracks("Gold Digger", "Kanye West", 6));
    assert_eq!(sent["method"], "track.getSimilar");
    assert_eq!(sent["limit"], "6");
    assert_eq!(sent["autocorrect"], "1");
}

#[test]
fn the_approval_link_encodes_the_token() {
    let url = client().authorisation_url("a b&c=d");
    assert_eq!(
        url,
        "https://www.last.fm/api/auth/?api_key=KEY&token=a%20b%26c%3Dd"
    );
}

#[test]
fn neither_the_secret_nor_the_session_key_is_printed_in_debug_output() {
    let printed = format!("{:?} {:?}", client(), session());
    assert!(!printed.contains("SECRET"));
    assert!(!printed.contains("sk-1"));
}
