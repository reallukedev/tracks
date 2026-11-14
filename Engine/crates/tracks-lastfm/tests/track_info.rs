//! What Last.fm knows about a song.

mod common;

use common::ok;
use tracks_lastfm::{
    SimilarTrack, TrackInfo, parse_similar_tracks, parse_track_info, plain_summary, useful_tags,
};

const GOLD_DIGGER: &str = r#"{"track":{"name":"Gold Digger","url":"https://www.last.fm/music/Kanye+West/_/Gold+Digger","listeners":"1963166","playcount":"17988257","userplaycount":"42",
 "toptags":{"tag":[{"name":"Hip-Hop"},{"name":"rap"},{"name":"Kanye West"},{"name":"hip hop"},{"name":"pop"},{"name":"2005"},{"name":"party"},{"name":"soul"}]},
 "wiki":{"summary":"\"Gold Digger\" is a song by Kanye West &amp; Jamie Foxx. <a href=\"http://www.last.fm/music/Kanye+West/_/Gold+Digger\">Read more on Last.fm</a>."}}}"#;

#[test]
fn counts_arrive_as_strings_the_summary_loses_its_link_and_the_tags_lose_the_noise() {
    let info = parse_track_info(&ok(GOLD_DIGGER), "Gold Digger", "Kanye West")
        .expect("readable")
        .expect("known");

    assert_eq!(
        info,
        TrackInfo {
            listeners: Some(1_963_166),
            scrobbles: Some(17_988_257),
            your_scrobbles: Some(42),
            tags: ["Hip-Hop", "Rap", "Pop", "2005", "Party"]
                .map(str::to_owned)
                .to_vec(),
            summary: Some("\"Gold Digger\" is a song by Kanye West & Jamie Foxx.".to_owned()),
            url: Some("https://www.last.fm/music/Kanye+West/_/Gold+Digger".to_owned()),
            similar: Vec::new(),
        }
    );
}

#[test]
fn a_song_last_fm_doesnt_know_is_none_not_an_error() {
    let not_found = ok(r#"{"error":6,"message":"Track not found"}"#);
    assert_eq!(parse_track_info(&not_found, "Nothing", "Nobody"), Ok(None));
    assert_eq!(parse_similar_tracks(&not_found), Ok(Vec::new()));
}

#[test]
fn other_errors_still_fail() {
    let busy = ok(r#"{"error":29,"message":"Rate limit"}"#);
    assert!(parse_track_info(&busy, "a", "b").is_err());
    assert!(parse_similar_tracks(&busy).is_err());
}

#[test]
fn a_lone_tag_object_is_read_as_one_tag() {
    let body = r#"{"track":{"toptags":{"tag":{"name":"shoegaze"}}}}"#;
    let info = parse_track_info(&ok(body), "Song", "Artist")
        .expect("readable")
        .expect("known");
    assert_eq!(info.tags, ["Shoegaze"]);
    assert!(!info.is_empty());
}

#[test]
fn a_track_with_nothing_to_show_is_empty() {
    let body = r#"{"track":{"listeners":"0","toptags":{"tag":[]}}}"#;
    let info = parse_track_info(&ok(body), "Song", "Artist")
        .expect("readable")
        .expect("known");
    assert!(info.is_empty());
}

#[test]
fn a_summary_thats_only_the_link_is_no_summary() {
    assert_eq!(
        plain_summary(r#" <a href="https://www.last.fm/x">Read more on Last.fm</a>"#),
        None
    );
}

#[test]
fn a_summary_loses_inner_tags_and_entities_but_keeps_a_lone_angle_bracket() {
    assert_eq!(
        plain_summary("<b>Bold</b> &lt;3 &#39;quoted&#39;&nbsp;x <> y"),
        Some("Bold <3 'quoted' x <> y".to_owned())
    );
}

#[test]
fn only_the_last_link_is_cut() {
    assert_eq!(
        plain_summary(r#"See <a href="a">this</a> and more. <a href="b">Read more</a>"#),
        Some("See this and more.".to_owned())
    );
}

#[test]
fn tags_are_capitalised_the_way_foundation_does_when_all_lowercase() {
    let tags = useful_tags(
        &["80s pop", "rock'n'roll", "under_score", "MiXeD", "  r&b  "],
        "x",
        "y",
    );
    assert_eq!(
        tags,
        ["80S Pop", "Rock'n'roll", "Under_Score", "MiXeD", "R&B"]
    );
}

#[test]
fn tags_stop_at_five() {
    let tags = useful_tags(&["a", "b", "c", "d", "e", "f"], "x", "y");
    assert_eq!(tags.len(), 5);
}

#[test]
fn similar_songs_read_a_lone_entry_as_well_as_a_list() {
    let one =
        r#"{"similartracks":{"track":{"name":"Touch the Sky","artist":{"name":"Kanye West"}}}}"#;
    assert_eq!(
        parse_similar_tracks(&ok(one)),
        Ok(vec![SimilarTrack {
            title: "Touch the Sky".to_owned(),
            artist_name: "Kanye West".to_owned()
        }])
    );
}

#[test]
fn similar_songs_are_each_listed_once_however_cased_and_blanks_dropped() {
    let many = r#"{"similartracks":{"track":[{"name":"Touch the Sky","artist":{"name":"Kanye West"}},{"name":"touch the sky","artist":{"name":"kanye west"}},{"name":"","artist":{"name":"X"}},{"name":"Stronger","artist":{"name":"Kanye West"}}]}}"#;
    let titles: Vec<String> = parse_similar_tracks(&ok(many))
        .expect("readable")
        .into_iter()
        .map(|track| track.title)
        .collect();
    assert_eq!(titles, ["Touch the Sky", "Stronger"]);
}

#[test]
fn track_info_serialises_with_the_swift_cache_keys() {
    let info = TrackInfo {
        your_scrobbles: Some(3),
        similar: vec![SimilarTrack {
            title: "T".to_owned(),
            artist_name: "A".to_owned(),
        }],
        ..TrackInfo::default()
    };
    let json = serde_json::to_value(&info).expect("serialisable");
    assert_eq!(json["yourScrobbles"], 3);
    assert_eq!(json["similar"][0]["artistName"], "A");
}
