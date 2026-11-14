//! Reading the account's history back, keeping each play once, and walking it page by page.

mod common;

use std::collections::HashSet;

use common::ok;
use tracks_lastfm::{
    HistoryProgress, HttpResponse, KnownPlay, LastFmError, MISSING_ARTWORK_ID, MergeWindows,
    PageStep, ScrobbleHistoryPage, ScrobbledTrack, history_retry_delay, new_plays,
    parse_recent_tracks,
};
use tracks_model::{PlayKind, song_key};

const START: i64 = 1_700_000_000;

fn at(minutes: i64) -> i64 {
    START + minutes * 60
}

fn scrobble(title: &str, minutes: i64) -> ScrobbledTrack {
    ScrobbledTrack::new(title, "An Artist", at(minutes))
}

fn titles(page: &ScrobbleHistoryPage) -> Vec<&str> {
    page.scrobbles
        .iter()
        .map(|track| track.title.as_str())
        .collect()
}

#[test]
fn a_page_reads_names_album_cover_and_time_and_says_how_many_there_are() {
    let body = r##"{"recenttracks": {
        "track": [
            {"artist": {"#text": "Sevens"}, "name": "Café", "album": {"#text": "Late"},
             "image": [{"size": "small", "#text": "https://lastfm.example/34s/a.jpg"},
                       {"size": "extralarge", "#text": "https://lastfm.example/300x300/a.jpg"}],
             "date": {"uts": "1700000600", "#text": "14 Nov 2023"}},
            {"artist": {"#text": "Sevens"}, "name": "Early", "album": {"#text": ""},
             "date": {"uts": "1700000000"}}
        ],
        "@attr": {"user": "listener", "page": "1", "perPage": "200", "totalPages": "3", "total": "412"}
    }}"##;

    let page = parse_recent_tracks(&ok(body)).expect("a page");

    assert_eq!(page.total, 412);
    assert_eq!(page.total_pages, 3);
    assert_eq!(
        page.scrobbles,
        [
            ScrobbledTrack {
                title: "Caf\u{E9}".to_owned(),
                artist_name: "Sevens".to_owned(),
                album_title: Some("Late".to_owned()),
                artwork_url: Some("https://lastfm.example/300x300/a.jpg".to_owned()),
                played_at: 1_700_000_600,
            },
            ScrobbledTrack::new("Early", "Sevens", 1_700_000_000),
        ]
    );
}

#[test]
fn the_song_playing_now_is_left_out() {
    let body = r##"{"recenttracks": {"track": [
        {"artist": {"#text": "A"}, "name": "Now", "@attr": {"nowplaying": "true"}},
        {"artist": {"#text": "A"}, "name": "Then", "date": {"uts": "1700000000"}}
    ]}}"##;
    assert_eq!(
        titles(&parse_recent_tracks(&ok(body)).expect("a page")),
        ["Then"]
    );
}

#[test]
fn a_single_scrobble_arrives_as_an_object_with_a_numeric_date() {
    let body = r##"{"recenttracks": {
        "track": {"artist": {"#text": "A"}, "name": "Only", "date": {"uts": 1700000000}},
        "@attr": {"total": "1", "totalPages": "1"}
    }}"##;
    assert_eq!(
        titles(&parse_recent_tracks(&ok(body)).expect("a page")),
        ["Only"]
    );
}

#[test]
fn extended_artist_objects_are_read_by_name() {
    let body = r#"{"recenttracks": {"track": [
        {"artist": {"name": "Extended", "url": "x"}, "name": " Song ", "date": {"uts": "1"}}
    ]}}"#;
    let page = parse_recent_tracks(&ok(body)).expect("a page");
    assert_eq!(page.scrobbles, [ScrobbledTrack::new("Song", "Extended", 1)]);
}

#[test]
fn a_scrobble_with_a_blank_title_or_artist_is_skipped() {
    let body = r##"{"recenttracks": {"track": [
        {"artist": {"#text": "  "}, "name": "No artist", "date": {"uts": "1"}},
        {"artist": {"#text": "A"}, "name": "\n", "date": {"uts": "2"}},
        {"artist": {"#text": "A"}, "name": "Kept", "date": {"uts": "3"}}
    ]}}"##;
    assert_eq!(
        titles(&parse_recent_tracks(&ok(body)).expect("a page")),
        ["Kept"]
    );
}

#[test]
fn an_account_with_no_scrobbles_reads_as_an_empty_page() {
    let body = r#"{"recenttracks": {"track": [], "@attr": {"total": "0", "totalPages": "0"}}}"#;
    assert_eq!(
        parse_recent_tracks(&ok(body)),
        Ok(ScrobbleHistoryPage::default())
    );
}

#[test]
fn an_answer_without_recent_tracks_is_malformed() {
    assert_eq!(
        parse_recent_tracks(&ok(r#"{"user": {}}"#)),
        Err(LastFmError::MalformedResponse)
    );
}

#[test]
fn a_history_error_is_reported_as_last_fm_sent_it() {
    let response = HttpResponse::new(200, r#"{"error": 29, "message": "Rate limit exceeded"}"#);
    let error = parse_recent_tracks(&response).expect_err("an error");
    assert!(error.is_retryable());
}

fn cover(images: &str) -> Option<String> {
    let body = format!(
        r#"{{"recenttracks": {{"track": {{"artist": "A", "name": "S", "date": {{"uts": "1"}}, "image": {images}}}}}}}"#
    );
    parse_recent_tracks(&ok(&body)).expect("a page").scrobbles[0]
        .artwork_url
        .clone()
}

#[test]
fn last_fms_grey_star_and_blank_urls_are_not_covers() {
    let star = format!(
        r##"[{{"#text": "https://lastfm.freetls.fastly.net/i/u/300x300/{MISSING_ARTWORK_ID}.png"}}]"##
    );
    assert_eq!(cover(&star), None);
    assert_eq!(cover(r##"[{"#text": ""}]"##), None);
}

#[test]
fn the_largest_non_blank_cover_wins_and_only_web_urls_count() {
    assert_eq!(
        cover(
            r##"[{"#text": "https://x/small.jpg"}, {"#text": "https://x/large.jpg"}, {"#text": ""}]"##
        ),
        Some("https://x/large.jpg".to_owned())
    );
    assert_eq!(cover(r##"[{"#text": "file:///etc/passwd"}]"##), None);
}

mod duplicates {
    use super::*;

    fn known(title: &str, minutes: i64, kind: PlayKind) -> KnownPlay {
        KnownPlay {
            key: song_key(title, "An Artist"),
            played_at: at(minutes),
            kind,
        }
    }

    fn plays(
        scrobbles: &[ScrobbledTrack],
        known: &[KnownPlay],
        forgotten: &HashSet<String>,
    ) -> Vec<String> {
        new_plays(scrobbles, known, forgotten, MergeWindows::default())
            .iter()
            .map(|track| format!("{}@{}", track.title, (track.played_at - START) / 60))
            .collect()
    }

    #[test]
    fn new_scrobbles_come_back_oldest_first() {
        assert_eq!(
            plays(&[scrobble("B", 30), scrobble("A", 0)], &[], &HashSet::new()),
            ["A@0", "B@30"]
        );
    }

    #[test]
    fn a_play_tracks_scrobbled_itself_is_skipped() {
        let result = plays(
            &[scrobble("A", 0)],
            &[known("A", 0, PlayKind::Radio)],
            &HashSet::new(),
        );
        assert_eq!(result, [] as [String; 0]);
    }

    #[test]
    fn a_row_of_the_same_song_counts_by_the_merge_windows() {
        for (kind, minutes_after, is_skipped, why) in [
            (
                PlayKind::OnDemand,
                4,
                true,
                "another app's scrobble of a play Tracks kept",
            ),
            (
                PlayKind::OnDemand,
                -4,
                true,
                "the same, the other way round",
            ),
            (
                PlayKind::Radio,
                11,
                false,
                "outside the window: a second play",
            ),
            (
                PlayKind::Imported,
                180,
                true,
                "recovered from Recently Played three hours on",
            ),
            (
                PlayKind::Imported,
                -30,
                false,
                "an import found before this play can't be it",
            ),
            (PlayKind::LastFm, 5, true, "already imported"),
        ] {
            let result = plays(
                &[scrobble("A", 0)],
                &[known("A", minutes_after, kind)],
                &HashSet::new(),
            );
            assert_eq!(result.is_empty(), is_skipped, "{why}");
        }
    }

    #[test]
    fn one_song_scrobbled_twice_inside_the_window_is_kept_once() {
        let scrobbles = [scrobble("A", 0), scrobble("A", 3), scrobble("A", 30)];
        assert_eq!(plays(&scrobbles, &[], &HashSet::new()), ["A@0", "A@30"]);
    }

    #[test]
    fn another_song_at_the_same_time_is_kept() {
        let result = plays(
            &[scrobble("B", 0)],
            &[known("A", 0, PlayKind::Radio)],
            &HashSet::new(),
        );
        assert_eq!(result, ["B@0"]);
    }

    #[test]
    fn the_same_song_spelt_differently_is_the_same_play() {
        let shouted = ScrobbledTrack::new("CAFE", "an artist", at(1));
        let result = plays(
            &[shouted],
            &[known("Caf\u{E9}", 0, PlayKind::Radio)],
            &HashSet::new(),
        );
        assert_eq!(result, [] as [String; 0]);
    }

    #[test]
    fn a_song_you_removed_stays_out() {
        let forgotten = HashSet::from([song_key("A", "An Artist")]);
        assert_eq!(
            plays(&[scrobble("A", 0), scrobble("B", 5)], &[], &forgotten),
            ["B@5"]
        );
    }
}

mod walk {
    use super::*;

    /// A Last.fm account serving `user.getRecentTracks` from a list, `page_size` at a time.
    struct Server {
        scrobbles: Vec<ScrobbledTrack>,
        page_size: usize,
    }

    impl Server {
        fn page(&self, after: Option<i64>, before: i64) -> ScrobbleHistoryPage {
            let mut range: Vec<ScrobbledTrack> = self
                .scrobbles
                .iter()
                .filter(|track| {
                    after.is_none_or(|after| track.played_at >= after) && track.played_at <= before
                })
                .cloned()
                .collect();
            range.sort_by_key(|track| std::cmp::Reverse(track.played_at));
            let total = range.len();
            range.truncate(self.page_size);
            ScrobbleHistoryPage {
                scrobbles: range,
                total: total as i64,
                total_pages: total.div_ceil(self.page_size) as i64,
            }
        }
    }

    /// One walk as the host runs it, writing what's new into `store`. Stops early after
    /// `fail_after` pages, as a dropped connection would.
    fn walk(
        progress: &mut HistoryProgress,
        server: &Server,
        store: &mut Vec<ScrobbledTrack>,
        now: i64,
        fail_after: Option<usize>,
    ) -> Result<(), ()> {
        let range = progress.walk_start(now);
        let mut before = range.before;
        let mut pages = 0;
        loop {
            if fail_after == Some(pages) {
                return Err(());
            }
            let page = server.page(range.after, before);
            pages += 1;
            let known: Vec<KnownPlay> = store
                .iter()
                .map(|track| KnownPlay {
                    key: track.key(),
                    played_at: track.played_at,
                    kind: PlayKind::LastFm,
                })
                .collect();
            let fresh = new_plays(
                &page.scrobbles,
                &known,
                &HashSet::new(),
                MergeWindows::default(),
            );
            let added = fresh.len() as u64;
            store.extend(fresh);
            match progress.record_page(&page, before, added) {
                PageStep::Next { before: next } => before = next,
                PageStep::Done => break,
            }
        }
        progress.finish_walk();
        Ok(())
    }

    /// A run: an unfinished walk is finished first, then walked again for what's new.
    fn run(
        progress: &mut HistoryProgress,
        server: &Server,
        store: &mut Vec<ScrobbledTrack>,
        now: i64,
    ) {
        let resumes = progress.is_unfinished();
        walk(progress, server, store, now, None).expect("no failure");
        if resumes {
            walk(progress, server, store, now, None).expect("no failure");
        }
        progress.finish_run(now);
    }

    fn sorted_titles(store: &[ScrobbledTrack]) -> Vec<String> {
        let mut titles: Vec<String> = store.iter().map(|track| track.title.clone()).collect();
        titles.sort();
        titles
    }

    fn songs(count: i64) -> Vec<ScrobbledTrack> {
        (0..count)
            .map(|index| scrobble(&format!("Song {index}"), index * 10))
            .collect()
    }

    #[test]
    fn the_whole_history_is_read_page_by_page() {
        let server = Server {
            scrobbles: songs(5),
            page_size: 2,
        };
        let mut progress = HistoryProgress::new("listener");
        let mut store = Vec::new();

        run(&mut progress, &server, &mut store, at(1_000));

        assert_eq!(sorted_titles(&store), sorted_titles(&songs(5)));
        assert_eq!(progress.imported_through, Some(at(40)));
        assert_eq!(progress.imported, 5);
        assert!(!progress.is_unfinished());
        assert_eq!(progress.last_finished, Some(at(1_000)));
    }

    #[test]
    fn a_later_sync_only_asks_for_whats_new() {
        let mut server = Server {
            scrobbles: vec![scrobble("Old", 0), scrobble("Older", -10)],
            page_size: 2,
        };
        let mut progress = HistoryProgress::new("listener");
        let mut store = Vec::new();
        run(&mut progress, &server, &mut store, at(1_000));

        server.scrobbles.push(scrobble("New", 60));
        assert_eq!(progress.walk_start(at(2_000)).after, Some(at(0)));
        run(&mut progress, &server, &mut store, at(2_000));

        assert_eq!(sorted_titles(&store), ["New", "Old", "Older"]);
        assert_eq!(progress.imported, 3);
    }

    #[test]
    fn a_run_that_fails_part_way_carries_on_from_there_next_time() {
        let mut server = Server {
            scrobbles: songs(6),
            page_size: 2,
        };
        let mut progress = HistoryProgress::new("listener");
        let mut store = Vec::new();

        assert!(walk(&mut progress, &server, &mut store, at(1_000), Some(1)).is_err());
        assert!(progress.is_unfinished());
        assert_eq!(store.len(), 2);

        // Something new arrives while it's stopped: the resumed run picks it up too.
        server.scrobbles.push(scrobble("Newer", 100));
        run(&mut progress, &server, &mut store, at(1_000));

        let mut expected = sorted_titles(&songs(6));
        expected.push("Newer".to_owned());
        expected.sort();
        assert_eq!(sorted_titles(&store), expected);
        assert!(!progress.is_unfinished());
        assert_eq!(progress.imported_through, Some(at(100)));
        assert_eq!(progress.imported, 7);
    }

    #[test]
    fn a_page_all_in_one_second_still_moves_on() {
        let server = Server {
            scrobbles: (0..3)
                .map(|index| ScrobbledTrack::new(format!("Same second {index}"), "A", START))
                .collect(),
            page_size: 2,
        };
        let mut progress = HistoryProgress::new("listener");
        let page = server.page(None, START);
        assert_eq!(
            progress.record_page(&page, START, 2),
            PageStep::Next { before: START - 1 }
        );
    }

    #[test]
    fn an_empty_page_ends_the_walk_without_moving_progress() {
        let mut progress = HistoryProgress::new("listener");
        assert_eq!(
            progress.record_page(&ScrobbleHistoryPage::default(), START, 0),
            PageStep::Done
        );
        assert_eq!(progress, HistoryProgress::new("listener"));
    }

    #[test]
    fn another_account_starts_from_nothing() {
        let mut other = HistoryProgress::new("someone else");
        other.imported_through = Some(at(0));
        assert_eq!(
            HistoryProgress::for_account(Some(other.clone()), "listener"),
            HistoryProgress::new("listener")
        );
        assert_eq!(
            HistoryProgress::for_account(Some(other.clone()), "someone else"),
            other
        );
    }
}

#[test]
fn a_busy_history_page_is_retried_after_two_four_then_eight_seconds_then_given_up() {
    let delays: Vec<Option<f64>> = (1..=4).map(history_retry_delay).collect();
    assert_eq!(delays, [Some(2.0), Some(4.0), Some(8.0), None]);
}
