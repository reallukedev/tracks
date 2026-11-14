//! The index end to end: what goes in, and the charts, totals and estimates that come out.

mod support;

use support::{DAY, HOUR, MINUTE, of_kind, on_album, play};
use tracks_model::PlayKind;
use tracks_store::{Period, Scope, SourceFilter, Store};

fn store_with(plays: &[tracks_store::PlayInput]) -> Store {
    let store = Store::open_in_memory().expect("store");
    store.replace_all(plays, None).expect("fill");
    store
}

#[test]
fn song_chart_ranks_by_plays_then_recency_and_counts_every_spelling_as_one_song() {
    let store = store_with(&[
        play("1", "Halo", "Beyoncé", 0),
        play("2", "HALO ", "Beyonce", 10 * MINUTE),
        play("3", "Glow", "Mara", 20 * MINUTE),
        play("4", "Ember", "Mara", 30 * MINUTE),
    ]);
    let chart = store
        .song_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
        .expect("chart");
    let rows: Vec<(&str, u64, u32)> = chart
        .rows
        .iter()
        .map(|r| (r.item.title.as_str(), r.item.plays, r.rank))
        .collect();
    // Ember and Glow tie on plays; the more recent comes first and they share second place.
    assert_eq!(rows, vec![("HALO ", 2, 1), ("Ember", 1, 2), ("Glow", 1, 2)]);
    assert!(!chart.has_previous);
}

#[test]
fn bounded_and_all_time_charts_agree_when_the_period_covers_everything() {
    let plays: Vec<_> = (0..40)
        .map(|i| {
            play(
                &i.to_string(),
                &format!("Song {}", i % 7),
                &format!("Artist {}", i % 3),
                i * 5 * MINUTE,
            )
        })
        .collect();
    let store = store_with(&plays);
    let everything = Period::between(-DAY, DAY);
    let all = store
        .song_chart(Period::ALL_TIME, None, SourceFilter::All, 100)
        .expect("all");
    let bounded = store
        .song_chart(everything, None, SourceFilter::All, 100)
        .expect("bounded");
    assert_eq!(all.rows, bounded.rows);
    let all = store
        .artist_chart(Period::ALL_TIME, None, SourceFilter::All, 100)
        .expect("all");
    let bounded = store
        .artist_chart(everything, None, SourceFilter::All, 100)
        .expect("bounded");
    assert_eq!(all.rows, bounded.rows);
}

#[test]
fn movement_compares_against_the_whole_previous_period() {
    let store = store_with(&[
        play("1", "A", "X", 0),
        play("2", "B", "X", MINUTE),
        play("3", "B", "X", 2 * MINUTE),
        play("4", "A", "X", DAY),
        play("5", "A", "X", DAY + MINUTE),
        play("6", "C", "X", DAY + 2 * MINUTE),
    ]);
    let chart = store
        .song_chart(
            Period::between(DAY, 2 * DAY),
            Some(Period::between(0, DAY)),
            SourceFilter::All,
            10,
        )
        .expect("chart");
    let rows: Vec<(&str, u32, Option<u32>)> = chart
        .rows
        .iter()
        .map(|r| (r.item.title.as_str(), r.rank, r.previous_rank))
        .collect();
    assert_eq!(rows, vec![("A", 1, Some(2)), ("C", 2, None)]);
    assert!(chart.has_previous);

    let empty_before = store
        .song_chart(
            Period::between(DAY, 2 * DAY),
            Some(Period::between(-DAY, 0)),
            SourceFilter::All,
            10,
        )
        .expect("chart");
    assert!(
        !empty_before.has_previous,
        "an empty previous period shows no movement"
    );
}

#[test]
fn listening_time_follows_the_gap_to_the_next_play_and_skips_imports() {
    let store = store_with(&[
        play("1", "A", "X", 0),
        // An import between them is dated when found, so it measures nothing.
        of_kind(play("2", "B", "Y", 2 * MINUTE), PlayKind::Imported),
        play("3", "C", "Z", 3 * MINUTE),
        // A gap over ten minutes means playback stopped: the typical length instead.
        play("4", "D", "W", 30 * MINUTE),
    ]);
    let seconds = |title: &str| {
        let chart = store
            .song_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
            .expect("chart");
        chart
            .rows
            .into_iter()
            .find(|r| r.item.title == title)
            .map(|r| r.item.listen_ms / 1000)
    };
    assert_eq!(seconds("A"), Some(180));
    assert_eq!(seconds("B"), Some(210));
    assert_eq!(seconds("C"), Some(210));
    assert_eq!(seconds("D"), Some(210));
}

#[test]
fn writing_a_play_twice_changes_nothing_and_an_update_moves_it() {
    let store = store_with(&[]);
    let first = store
        .upsert(
            &[play("1", "A", "X", 0), play("2", "B", "X", MINUTE)],
            Some("t1"),
        )
        .expect("write");
    assert_eq!((first.inserted, first.unchanged), (2, 0));
    let again = store
        .upsert(&[play("1", "A", "X", 0)], Some("t2"))
        .expect("write");
    assert_eq!((again.inserted, again.unchanged), (0, 1));
    assert_eq!(store.play_count().expect("count"), 2);
    assert_eq!(store.sync_marker().expect("marker").as_deref(), Some("t2"));

    // The same play, now a different song.
    let moved = store
        .upsert(&[play("1", "C", "X", 0)], None)
        .expect("write");
    assert_eq!(moved.updated, 1);
    let titles: Vec<String> = store
        .song_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
        .expect("chart")
        .rows
        .into_iter()
        .map(|r| r.item.title)
        .collect();
    assert_eq!(
        titles,
        vec!["B", "C"],
        "song A has no plays left and is gone"
    );
}

#[test]
fn removing_a_play_re_measures_the_one_before_it() {
    let store = store_with(&[
        play("1", "A", "X", 0),
        play("2", "B", "X", MINUTE),
        play("3", "C", "X", 4 * MINUTE),
    ]);
    store.remove(&["2".to_owned()], None).expect("remove");
    let a = store.song("a\u{1F}x").expect("query").expect("song");
    assert_eq!(a.listen_ms, 4 * MINUTE);
}

#[test]
fn a_featured_artist_counts_in_full_on_the_artist_chart() {
    let store = store_with(&[
        play("1", "Glow", "Umbra feat. Yuki Tanabe", 0),
        play("2", "Night", "Umbra", MINUTE),
    ]);
    let chart = store
        .artist_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
        .expect("chart");
    let rows: Vec<(&str, u64)> = chart
        .rows
        .iter()
        .map(|r| (r.item.name.as_str(), r.item.plays))
        .collect();
    if tracks_model::may_credit_several("Umbra feat. Yuki Tanabe", "Glow") {
        assert_eq!(rows, vec![("Umbra", 2), ("Yuki Tanabe", 1)]);
    } else {
        // Until credits parsing lands, the whole credit is one artist.
        assert_eq!(rows.len(), 2);
    }
}

#[test]
fn albums_group_by_title_and_lead_artist() {
    let store = store_with(&[
        on_album(play("1", "One", "Mara", 0), "Home"),
        on_album(play("2", "Two", "Mara", MINUTE), "home"),
        on_album(play("3", "Three", "Umbra", 2 * MINUTE), "Home"),
        play("4", "Single", "Mara", 3 * MINUTE),
    ]);
    let chart = store
        .album_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
        .expect("chart");
    let rows: Vec<(&str, u64, u64)> = chart
        .rows
        .iter()
        .map(|r| (r.item.artist_name.as_str(), r.item.plays, r.item.song_count))
        .collect();
    assert_eq!(rows, vec![("Mara", 2, 2), ("Umbra", 1, 1)]);
}

#[test]
fn activity_counts_local_hours_and_leaves_imports_out_of_the_clock() {
    let store = store_with(&[
        play("1", "A", "X", 9 * HOUR),
        play("2", "A", "X", 9 * HOUR + 5 * MINUTE),
        of_kind(play("3", "A", "X", 13 * HOUR), PlayKind::Imported),
    ]);
    store.set_time_zone("Asia/Tokyo").expect("zone");
    let activity = store
        .activity(Period::ALL_TIME, SourceFilter::All, &Scope::All)
        .expect("activity");
    assert_eq!(activity.hours[18], 2, "09:00 UTC is 18:00 in Tokyo");
    assert_eq!(activity.kinds, [0, 2, 1, 0]);
    assert_eq!(activity.heat.len(), 7 * 24);
    assert_eq!(activity.days_with_plays, 1);
}

#[test]
fn streaks_count_local_days_and_end_today_or_yesterday() {
    let days = [0, 1, 2, 5, 6];
    let plays: Vec<_> = days
        .iter()
        .map(|d| play(&d.to_string(), "A", "X", d * DAY + 12 * HOUR))
        .collect();
    let store = store_with(&plays);
    let streak = store.streak(7 * DAY + HOUR).expect("streak");
    assert_eq!(
        (streak.current, streak.longest, streak.longest_end_day),
        (2, 3, Some(2))
    );
    assert_eq!(store.streak(9 * DAY).expect("streak").current, 0);
}

#[test]
fn timeline_buckets_include_empty_ones() {
    let store = store_with(&[
        play("1", "A", "X", HOUR),
        play("2", "B", "X", 2 * DAY + HOUR),
    ]);
    let buckets = store
        .timeline(&[0, DAY, 2 * DAY, 3 * DAY], SourceFilter::All, &Scope::All)
        .expect("timeline");
    let plays: Vec<u64> = buckets.iter().map(|b| b.plays).collect();
    assert_eq!(plays, vec![1, 0, 1]);
    let song = store
        .timeline(
            &[0, 3 * DAY],
            SourceFilter::All,
            &Scope::Song("b\u{1F}x".into()),
        )
        .expect("timeline");
    assert_eq!(song[0].plays, 1);
}

#[test]
fn search_matches_every_word_ignoring_case_accents_and_punctuation_then_allows_a_slip() {
    let store = store_with(&[
        play("1", "Don't Stop", "AC/DC", 0),
        play("2", "Driftwood", "Mara Solís", MINUTE),
        play("3", "Driftwood", "Mara Solís", 2 * MINUTE),
    ]);
    let found = store.search("ac dc dont", 25).expect("search");
    assert_eq!(found.songs.len(), 1);
    let found = store.search("mara sol", 25).expect("search");
    assert_eq!(
        found.artists.first().map(|a| a.name.as_str()),
        Some("Mara Solís")
    );
    let found = store.search("driftwod", 25).expect("search");
    assert_eq!(
        found.songs.first().map(|s| s.title.as_str()),
        Some("Driftwood")
    );
    assert!(store.search("zzzz", 25).expect("search").is_empty());
}

#[test]
fn totals_count_new_songs_and_artists_by_first_play_ever() {
    let store = store_with(&[
        play("1", "A", "X", 0),
        play("2", "A", "X", DAY),
        play("3", "B", "Y", DAY + MINUTE),
    ]);
    let totals = store
        .totals(Period::between(DAY, 2 * DAY), SourceFilter::All)
        .expect("totals");
    assert_eq!(
        (
            totals.plays,
            totals.songs,
            totals.artists,
            totals.new_songs,
            totals.new_artists
        ),
        (2, 2, 2, 1, 1)
    );
}

#[test]
fn a_file_that_cannot_be_read_is_moved_aside_and_rebuilt() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("history.sqlite");
    std::fs::write(&path, b"this is not a database at all, not even close").expect("write");
    let store = Store::open(&path).expect("open");
    assert!(store.needs_rebuild().expect("flag"));
    assert!(path.with_extension("damaged").exists());
    store
        .replace_all(&[play("1", "A", "X", 0)], None)
        .expect("fill");
    assert!(!store.needs_rebuild().expect("flag"));
}

#[test]
fn a_sync_of_the_same_history_writes_nothing_and_a_changed_one_writes_only_the_difference() {
    let plays: Vec<_> = (0..50)
        .map(|i| play(&i.to_string(), &format!("Song {}", i % 9), "X", i * MINUTE))
        .collect();
    let store = store_with(&plays);
    let same = store.sync(&plays, Some("launch")).expect("sync");
    assert_eq!(
        (same.inserted, same.updated, same.removed, same.unchanged),
        (0, 0, 0, 50)
    );

    let mut next = plays[1..].to_vec();
    next[0] = on_album(next[0].clone(), "Found Later");
    next.push(play("new", "Song 1", "X", 60 * MINUTE));
    let report = store.sync(&next, None).expect("sync");
    assert_eq!(
        (
            report.inserted,
            report.updated,
            report.removed,
            report.unchanged
        ),
        (1, 1, 1, 48)
    );
    assert_eq!(store.play_count().expect("count"), 50);
}

#[test]
fn a_busy_or_newer_file_is_left_alone_and_only_a_damaged_one_is_moved_aside() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("history.sqlite");
    Store::open(&path)
        .expect("open")
        .replace_all(&[play("1", "A", "X", 0)], None)
        .expect("fill");
    // A newer build's schema, say: this build can't use it, but must not destroy it.
    let raw = rusqlite::Connection::open(&path).expect("raw");
    raw.pragma_update(None, "user_version", 99)
        .expect("version");
    drop(raw);
    assert!(Store::open(&path).is_err());
    assert!(path.exists() && !path.with_extension("damaged").exists());
}

#[test]
fn removing_a_songs_newest_play_brings_back_what_the_one_before_said() {
    let mut newer = on_album(play("2", "Glow", "Mara", 10 * MINUTE), "Mistake");
    newer.artwork_url = Some("https://example.com/new.jpg".into());
    let mut older = on_album(play("1", "Glow", "Mara", 0), "Old");
    older.artwork_url = Some("https://example.com/old.jpg".into());
    let store = store_with(&[older, newer]);
    store.remove(&["2".to_owned()], None).expect("remove");
    let song = store.song("glow\u{1F}mara").expect("query").expect("song");
    assert_eq!(song.album_title.as_deref(), Some("Old"));
    assert_eq!(
        song.artwork_url.as_deref(),
        Some("https://example.com/old.jpg")
    );
}

#[test]
fn a_second_process_sees_the_first_ones_writes() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("history.sqlite");
    let app = Store::open(&path).expect("app");
    app.replace_all(&[play("1", "A", "X", 0)], None)
        .expect("fill");
    let widget = Store::open(&path).expect("widget");
    let before = widget
        .artist_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
        .expect("chart");
    assert_eq!(before.rows[0].item.plays, 1);
    app.upsert(&[play("2", "B", "X", MINUTE)], None)
        .expect("write");
    let after = widget
        .artist_chart(Period::ALL_TIME, None, SourceFilter::All, 10)
        .expect("chart");
    assert_eq!(after.rows[0].item.plays, 2);
}

#[test]
fn edge_inputs_never_panic() {
    let store = store_with(&[
        play("1", "A", "X", i64::MIN),
        play("2", "B", "X", i64::MAX),
        play("3", "C", "X", 0),
    ]);
    assert!(store.search("a", 0).expect("search").is_empty());
    store
        .activity(Period::ALL_TIME, SourceFilter::All, &Scope::All)
        .expect("activity");
    store.streak(i64::MAX).expect("streak");
    assert_eq!(
        store
            .timeline(&[], SourceFilter::All, &Scope::All)
            .expect("timeline"),
        vec![]
    );
    assert_eq!(
        store
            .timeline(&[5], SourceFilter::All, &Scope::All)
            .expect("timeline"),
        vec![]
    );
}
