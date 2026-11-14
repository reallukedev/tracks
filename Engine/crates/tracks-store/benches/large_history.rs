//! The work that scales with history, on the same shape of library as the Swift app's
//! `LargeLibraryBenchmarks` (150,000 plays of 25,000 songs by 4,000 artists over five years),
//! plus a ten-year, 300,000-play library.
//!
//! `cargo bench -p tracks-store` (add `-- --quick` for a fast pass).

use std::time::Instant;

use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use tracks_model::{PlayKind, PlaySource};
use tracks_store::{Period, PlayInput, Scope, SourceFilter, Store};

const YEAR_MS: i64 = 365 * 86_400_000;
const NOW: i64 = 1_800_000_000_000;

struct Library {
    name: &'static str,
    plays: usize,
    years: i64,
}

const LIBRARIES: [Library; 2] = [
    Library {
        name: "150k plays, 5 years",
        plays: 150_000,
        years: 5,
    },
    Library {
        name: "300k plays, 10 years",
        plays: 300_000,
        years: 10,
    },
];

/// `SplitMix64`, so every run seeds the same library.
struct Rng(u64);

impl Rng {
    fn next_f64(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        ((z ^ (z >> 31)) >> 11) as f64 / (1u64 << 53) as f64
    }
}

fn seed(library: &Library) -> Vec<PlayInput> {
    const SONGS: f64 = 25_000.0;
    let mut rng = Rng(42);
    let span = library.years * YEAR_MS;
    let spacing = span / library.plays as i64;
    (0..library.plays)
        .map(|index| {
            // Skewed towards a few favourites, as real listening is.
            let song = (SONGS * rng.next_f64().powf(2.5)) as u64;
            let artist = song % 4_000;
            let kind = [PlayKind::Radio, PlayKind::OnDemand, PlayKind::Imported][index % 3];
            PlayInput {
                ext_id: format!("x-coredata://store/Capture/p{index}"),
                catalog_id: (1_000_000 + song).to_string(),
                song_key: (1_000_000 + song).to_string(),
                title: format!("Song {song} love"),
                artist_name: format!("Artist {artist}"),
                album_title: Some(format!("Album {}", song / 8)),
                artwork_url: Some(format!(
                    "https://is1-ssl.mzstatic.com/image/thumb/{}/300x300bb.jpg",
                    song / 8
                )),
                played_at: NOW - span + index as i64 * spacing,
                kind,
                source: PlaySource::AppleMusic,
                station_name: (kind == PlayKind::Radio).then(|| "Apple Music Chill".to_owned()),
            }
        })
        .collect()
}

fn benches(c: &mut Criterion) {
    for library in &LIBRARIES {
        let plays = seed(library);
        let dir = tempfile::tempdir().expect("dir");
        let store = Store::open(dir.path().join("history.sqlite")).expect("open");
        store.set_time_zone("Europe/London").expect("zone");

        let started = Instant::now();
        store.replace_all(&plays, None).expect("fill");
        println!("⏱ [{}] first fill: {:?}", library.name, started.elapsed());
        // Checkpointed, as the app does when it goes to the background.
        store.optimize().expect("optimize");
        let size = std::fs::metadata(dir.path().join("history.sqlite")).map_or(0, |m| m.len());
        println!(
            "⏱ [{}] file size: {:.1} MB",
            library.name,
            size as f64 / 1e6
        );

        let month = Period::between(NOW - YEAR_MS / 12, NOW);
        let last_month = Period::between(NOW - YEAR_MS / 6, NOW - YEAR_MS / 12);
        let year = Period::between(NOW - YEAR_MS, NOW);
        let last_year = Period::between(NOW - 2 * YEAR_MS, NOW - YEAR_MS);
        let all = SourceFilter::All;

        let mut group = c.benchmark_group(library.name);
        group.sample_size(20);
        let mut next = plays.len();
        group.bench_function("append one play", |b| {
            b.iter(|| {
                let mut play = plays[next % plays.len()].clone();
                play.ext_id = format!("new-{next}");
                play.played_at = NOW + next as i64 * 1000;
                next += 1;
                store.upsert(&[play], Some("marker")).expect("upsert")
            });
        });
        group.bench_function("append one play, then the all-time artist chart", |b| {
            b.iter(|| {
                let mut play = plays[next % plays.len()].clone();
                play.ext_id = format!("new-{next}");
                play.played_at = NOW + next as i64 * 1000;
                next += 1;
                store.upsert(&[play], None).expect("upsert");
                store
                    .artist_chart(Period::ALL_TIME, None, all, 100)
                    .expect("chart")
            });
        });
        for (label, period, previous) in [
            ("all time", Period::ALL_TIME, None),
            ("year", year, Some(last_year)),
            ("month", month, Some(last_month)),
        ] {
            group.bench_with_input(BenchmarkId::new("song chart", label), &period, |b, &p| {
                b.iter(|| store.song_chart(p, previous, all, 100).expect("chart"));
            });
            group.bench_with_input(BenchmarkId::new("artist chart", label), &period, |b, &p| {
                b.iter(|| store.artist_chart(p, previous, all, 100).expect("chart"));
            });
            group.bench_with_input(BenchmarkId::new("album chart", label), &period, |b, &p| {
                b.iter(|| store.album_chart(p, previous, all, 100).expect("chart"));
            });
            group.bench_with_input(BenchmarkId::new("totals", label), &period, |b, &p| {
                b.iter(|| store.totals(p, all).expect("totals"));
            });
            group.bench_with_input(BenchmarkId::new("activity", label), &period, |b, &p| {
                b.iter(|| store.activity(p, all, &Scope::All).expect("activity"));
            });
        }
        group.bench_function("streak", |b| b.iter(|| store.streak(NOW).expect("streak")));
        group.bench_function("search \"lo\"", |b| {
            b.iter(|| store.search("lo", 25).expect("search"));
        });
        group.bench_function("search \"song 12 love\"", |b| {
            b.iter(|| store.search("song 12 love", 25).expect("search"));
        });
        group.bench_function("search typo \"artst 123\"", |b| {
            b.iter(|| store.search("artst 123", 25).expect("search"));
        });
        group.bench_function("song profile timeline (2 years, weekly)", |b| {
            let weeks: Vec<i64> = (0..=104)
                .map(|w| NOW - 2 * YEAR_MS + w * 7 * 86_400_000)
                .collect();
            let scope = Scope::Song(tracks_model::song_key("Song 0 love", "Artist 0"));
            b.iter(|| store.timeline(&weeks, all, &scope).expect("timeline"));
        });
        group.bench_function("artist profile timeline (2 years, weekly)", |b| {
            let weeks: Vec<i64> = (0..=104)
                .map(|w| NOW - 2 * YEAR_MS + w * 7 * 86_400_000)
                .collect();
            let scope = Scope::Artist(tracks_model::folded("Artist 0"));
            b.iter(|| store.timeline(&weeks, all, &scope).expect("timeline"));
        });
        group.finish();
    }
}

criterion_group!(large_history, benches);
criterion_main!(large_history);
