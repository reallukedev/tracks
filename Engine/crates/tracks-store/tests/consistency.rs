//! Whatever order plays arrive in, and however they're edited or removed, the index must
//! end exactly where a rebuild from the final history would: same estimates, same rollups.

mod support;

use std::collections::BTreeMap;

use proptest::prelude::*;
use support::{MINUTE, of_kind, on_album, play};
use tracks_model::PlayKind;
use tracks_store::{Period, PlayInput, SourceFilter, Store};

#[derive(Debug, Clone)]
enum Op {
    Upsert(Vec<PlayInput>),
    Remove(Vec<String>),
    /// The host's whole history, as a launch sends it.
    Sync(Vec<PlayInput>),
}

fn arb_play() -> impl Strategy<Value = PlayInput> {
    (0u8..30, 0u8..6, 0u8..3, 0i64..400, 0u8..10).prop_map(|(id, song, artist, minute, kind)| {
        // Spellings differ by case, so the name an artist shows can change as plays come and go.
        let artist = if artist == 2 && song % 2 == 0 {
            "ARTIST 1".to_owned()
        } else {
            format!("Artist {artist}")
        };
        // The same song spelled, filed and resolved differently from play to play, so what it
        // shows depends on which of its plays is newest.
        let title = if id % 4 == 0 {
            format!("SONG {song}")
        } else {
            format!("Song {song}")
        };
        let mut p = on_album(
            play(&id.to_string(), &title, &artist, minute * MINUTE / 2),
            &format!("Album {}", (song + id % 2) % 3),
        );
        p.artwork_url = (id % 3 != 0).then(|| format!("https://example.com/{id}.jpg"));
        p.catalog_id = if id % 5 == 0 {
            String::new()
        } else {
            format!("{song}")
        };
        // Mostly on demand, sometimes an import, which the estimate skips.
        of_kind(
            p,
            if kind == 0 {
                PlayKind::Imported
            } else {
                PlayKind::OnDemand
            },
        )
    })
}

fn arb_op() -> impl Strategy<Value = Op> {
    prop_oneof![
        3 => prop::collection::vec(arb_play(), 1..6).prop_map(Op::Upsert),
        1 => prop::collection::vec((0u8..30).prop_map(|id| id.to_string()), 1..4).prop_map(Op::Remove),
        1 => prop::collection::vec(arb_play(), 0..30).prop_map(Op::Sync),
    ]
}

type Fingerprint = (
    Vec<(String, u64, i64, i64, i64)>,
    Vec<(String, String, u64, i64)>,
    Vec<(String, u64)>,
    Vec<(String, u64)>,
    tracks_store::PeriodTotals,
);

fn fingerprint(store: &Store) -> Fingerprint {
    let songs = store
        .song_chart(Period::ALL_TIME, None, SourceFilter::All, u32::MAX)
        .expect("songs")
        .rows
        .into_iter()
        .map(|r| {
            (
                r.item.identity,
                r.item.plays,
                r.item.listen_ms,
                r.item.first_at,
                r.item.last_at,
            )
        })
        .collect();
    let artists = store
        .artist_chart(Period::ALL_TIME, None, SourceFilter::All, u32::MAX)
        .expect("artists")
        .rows
        .into_iter()
        .map(|r| (r.item.identity, r.item.name, r.item.plays, r.item.listen_ms))
        .collect();
    let albums = store
        .album_chart(Period::ALL_TIME, None, SourceFilter::All, u32::MAX)
        .expect("albums")
        .rows
        .into_iter()
        .map(|r| (r.item.identity, r.item.plays))
        .collect();
    // New songs and artists depend on first plays, which the cached lookups hold.
    let totals = store
        .totals(Period::between(0, 200 * MINUTE), SourceFilter::All)
        .expect("totals");
    // The bounded path reads the plays themselves, so it checks every estimate.
    let bounded = store
        .song_chart(
            Period::between(i64::MIN / 2, i64::MAX / 2),
            None,
            SourceFilter::All,
            u32::MAX,
        )
        .expect("bounded")
        .rows
        .into_iter()
        .map(|r| {
            (
                r.item.identity,
                u64::try_from(r.item.listen_ms).unwrap_or(0),
            )
        })
        .collect();
    (songs, artists, bounded, albums, totals)
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 200, ..ProptestConfig::default() })]

    #[test]
    fn incremental_writes_end_where_a_rebuild_does(ops in prop::collection::vec(arb_op(), 1..25)) {
        let incremental = Store::open_in_memory().expect("store");
        let mut truth: BTreeMap<String, PlayInput> = BTreeMap::new();
        for op in ops {
            match op {
                Op::Upsert(plays) => {
                    incremental.upsert(&plays, None).expect("upsert");
                    for p in plays { truth.insert(p.ext_id.clone(), p); }
                }
                Op::Remove(ids) => {
                    incremental.remove(&ids, None).expect("remove");
                    for id in ids { truth.remove(&id); }
                }
                Op::Sync(plays) => {
                    incremental.sync(&plays, None).expect("sync");
                    truth.clear();
                    // The first of a repeated id wins, as in a rebuild.
                    for p in plays { truth.entry(p.ext_id.clone()).or_insert(p); }
                }
            }
            // Reading between writes fills the caches, which later writes must refresh.
            let _ = fingerprint(&incremental);
        }
        let rebuilt = Store::open_in_memory().expect("store");
        let all: Vec<PlayInput> = truth.into_values().collect();
        rebuilt.replace_all(&all, None).expect("rebuild");

        prop_assert_eq!(incremental.play_count().expect("count"), all.len() as u64);
        prop_assert_eq!(fingerprint(&incremental), fingerprint(&rebuilt));
    }
}
