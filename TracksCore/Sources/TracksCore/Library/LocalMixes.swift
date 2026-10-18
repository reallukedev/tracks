import Foundation

extension LiveMix {
    /// Tracks Radio from your own music: the songs you play most, the likelier, and the ones
    /// you've never played as its new finds. Tuned, and fitted to the moment, as the Apple
    /// Music radio is.
    public static func tracksRadio(
        from tracks: [LocalTrack],
        history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        tuning: RadioTuning = .standard,
        moment: RadioMoment = .anytime,
        drives: DriveLog = DriveLog(),
        now: Date = .now,
        calendar: Calendar = .current,
        seed: UInt64
    ) -> LiveMix {
        let played = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
        let fit = RadioMomentFit(moment: moment, songs: played, drives: drives, now: now)
        let mostPlayed = mostPlayedThreshold(played.map(\.dates.count))
        let mix = local(
            tracks, played: played, metadata: history.songMetadata, signals: signals, now: now, seed: seed,
            newShare: fit.newShare(tuning.discovery.newShare), moment: moment,
            factor: { track, aggregate in
                let genre = track.genre ?? history.songMetadata[track.identity]?.genre
                let tuned = tuning.factor(genre: genre, lastHeard: aggregate?.lastHeard, now: now)
                guard let aggregate else { return tuned * fit.factor(newFindGenre: genre) }
                return tuned * freshness(lastHeard: aggregate.lastHeard, now: now)
                    * fit.factor(for: aggregate, genre: genre, recentSkips: signals.recentSkips(of: track.identity, now: now))
            },
            reason: { track, aggregate in
                let genre = track.genre ?? history.songMetadata[track.identity]?.genre
                return reason(for: aggregate, genre: genre, fit: fit, tuning: tuning, mostPlayed: mostPlayed, now: now)
            }
        )
        let yours = mix.candidates.filter { !$0.isNew }
        let new = mix.candidates.filter(\.isNew)
        let share = fit.newShare(firstListens(tuning.discovery.newShare, yourSongs: yours.count, hasNewFinds: !new.isEmpty))
        return LiveMix(candidates: balancedByArtist(yours) + balancedByArtist(new), newShare: share, moment: moment, seed: seed)
            .following(history, now: now)
    }

    /// A mood from your own music: the songs whose genre suits it, played ones by how much,
    /// the rest as new finds.
    /// - Parameter finds: songs found for the mood elsewhere, like ones that suit it, taken as
    ///   they are: a server's often have no genre to go by.
    public static func mood(
        _ mood: Mood,
        from tracks: [LocalTrack],
        finds: [LocalTrack] = [],
        history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        now: Date = .now,
        seed: UInt64
    ) -> LiveMix {
        let suited = tracks.filter { track in
            (track.genre ?? history.songMetadata[track.identity]?.genre).map { mood.suits(genre: $0) } ?? false
        }
        let played = MixBuilder.aggregate(history, signals: signals, now: now, calendar: .current)
        return local(
            suited + finds, played: played, metadata: history.songMetadata, signals: signals, now: now, seed: seed,
            newShare: finds.isEmpty ? 0.3 : 0.4
        ) { _, _ in 1 }
        .following(history, now: now)
    }

    /// A genre's station from your own music: your songs in it, played ones by how much and
    /// how lately, the ones you've never played as its new finds.
    public static func genre(
        _ genre: MusicGenre,
        from tracks: [LocalTrack],
        history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        now: Date = .now,
        calendar: Calendar = .current,
        seed: UInt64
    ) -> LiveMix {
        let inIt = tracks.filter { genre.contains(genre: $0.genre ?? history.songMetadata[$0.identity]?.genre) }
        let played = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
        return local(inIt, played: played, metadata: history.songMetadata, signals: signals, now: now, seed: seed, newShare: 0.25) { _, aggregate in
            aggregate.map { freshness(lastHeard: $0.lastHeard, now: now) } ?? 1
        }
        .following(history, now: now)
    }

    /// Handpicked from your own music: your picks, your songs like them, the ones you've never
    /// played among them as its new finds, and songs your servers call like them. See
    /// ``handpicked(_:from:signals:newFinds:newFindReasons:now:calendar:seed:)``.
    /// - Parameter finds: songs a server found like the picks, taken as like them whatever
    ///   their tags say: a server's often have no genre to go by.
    public static func handpicked(
        _ picks: [LocalTrack],
        from tracks: [LocalTrack],
        finds: [LocalTrack] = [],
        history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        now: Date = .now,
        calendar: Calendar = .current,
        seed: UInt64
    ) -> LiveMix {
        let seeds = picks.map { pick in
            let known = history.songMetadata[pick.identity]
            return AutoplaySeed(songIdentity: pick.identity, artistName: pick.artist, genre: pick.genre ?? known?.genre, releaseYear: pick.year ?? known?.releaseYear)
        }
        let affinity = AutoplayAffinity(seeds: seeds, history: history)
        let taste = TasteGraph(history: history, now: now)
        let close = closeness(toSeeds: picks.map(\.identity), in: taste)
        func likeness(_ track: LocalTrack) -> Double {
            let known = history.songMetadata[track.identity]
            return affinity.likeness(artistName: track.artist, genre: track.genre ?? known?.genre, releaseYear: track.year ?? known?.releaseYear)
                + seedCloseness * (close[track.identity] ?? 0)
        }
        let picked = Set(picks.map(\.identity))
        let found = Set(finds.map(\.identity))
        let scored = tracks
            .filter { !picked.contains($0.identity) && !found.contains($0.identity) }
            .map { (track: $0, likeness: likeness($0)) }
        var near = scored.filter { $0.likeness >= handpickedCloseLikeness }.map(\.track)
        if near.count < handpickedMinimum {
            near += scored
                .filter { $0.likeness < handpickedCloseLikeness && $0.likeness > AutoplayAffinity.floor }
                .sorted { $0.likeness > $1.likeness }
                .prefix(handpickedMinimum - near.count)
                .map(\.track)
        }
        let played = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
        let mix = local(
            near + finds.filter { !picked.contains($0.identity) }, played: played, metadata: history.songMetadata,
            signals: signals, now: now, seed: seed, newShare: 0.45
        ) { track, _ in
            found.contains(track.identity) ? max(1, likeness(track)) : likeness(track)
        }
        let yours = mix.candidates.filter { !$0.isNew }
        let typical = yours.map(\.weight).sorted().dropFirst(yours.count / 2).first ?? 1
        let byIdentity = Dictionary(played.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let rested = now.addingTimeInterval(-restPeriod)
        var seen = Set<String>()
        let pickCandidates: [Candidate] = picks.compactMap { track in
            guard seen.insert(track.identity).inserted else { return nil }
            let aggregate = byIdentity[track.identity]
            let song = aggregate.map { track.mixSong(plays: $0.dates.count, lastHeard: $0.lastHeard) } ?? track.mixSong()
            return Candidate(song: song, weight: typical, isResting: (aggregate?.lastHeard ?? .distantPast) >= rested, genre: track.genre)
        }
        let nearby = yours.count { $0.weight >= 0.5 }
        return LiveMix(
            candidates: pickCandidates + mix.candidates,
            newShare: nearby < handpickedFewClose ? 0.65 : 0.45,
            seed: seed
        )
        .following(history, now: now, graph: taste)
    }

    /// Autoplay from your own music: your songs like the last few played, the ones you've
    /// never played as its new finds. See ``autoplay(after:from:signals:newFinds:now:calendar:seed:)``.
    public static func autoplay(
        after seeds: [AutoplaySeed],
        from tracks: [LocalTrack],
        history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        now: Date = .now,
        calendar: Calendar = .current,
        seed: UInt64
    ) -> LiveMix {
        let affinity = AutoplayAffinity(seeds: seeds, history: history)
        let seedIdentities = Set(seeds.map(\.songIdentity))
        let taste = TasteGraph(history: history, now: now)
        let close = closeness(toSeeds: seedIdentities, in: taste)
        let played = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
        let others = tracks.filter { !seedIdentities.contains($0.identity) }
        let mix = local(others, played: played, metadata: history.songMetadata, signals: signals, now: now, seed: seed, newShare: 0.25) { track, _ in
            let known = history.songMetadata[track.identity]
            return affinity.likeness(artistName: track.artist, genre: track.genre ?? known?.genre, releaseYear: track.year ?? known?.releaseYear)
                * (1 + seedCloseness * (close[track.identity] ?? 0))
        }
        return LiveMix(candidates: mix.candidates, newShare: affinity.newShare(closeMatches: mix.candidates.filter { !$0.isNew }), seed: seed)
            .following(history, now: now, leaningToward: seeds.map(\.songIdentity), graph: taste)
    }

    /// Your songs as candidates: one per song, the file before a server's copy, played ones
    /// weighted as Tracks Radio weighs them, never-played ones as new finds.
    private static func local(
        _ tracks: [LocalTrack],
        played: [MixBuilder.Aggregate],
        metadata: [String: SongMetadata],
        signals: ListeningSignals,
        now: Date,
        seed: UInt64,
        newShare: Double,
        moment: RadioMoment = .anytime,
        factor: (LocalTrack, MixBuilder.Aggregate?) -> Double,
        reason: (LocalTrack, MixBuilder.Aggregate) -> Reason? = { _, _ in nil }
    ) -> LiveMix {
        let yourArtists = Set(played.map(\.song.artistKey))
        let played = Dictionary(played.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let rested = now.addingTimeInterval(-restPeriod)
        var seen = Set<String>()
        let candidates: [Candidate] = tracks
            .sorted { !$0.isFromServer && $1.isFromServer }
            .compactMap { track in
                guard seen.insert(track.identity).inserted, !signals.excludes(track.identity, now: now) else { return nil }
                let known = metadata[track.identity]
                let genre = track.genre ?? known?.genre
                if let aggregate = played[track.identity] {
                    return Candidate(
                        song: track.mixSong(plays: aggregate.dates.count, lastHeard: aggregate.lastHeard),
                        weight: weight(plays: aggregate.dates.count, lastHeard: aggregate.lastHeard, now: now) * factor(track, aggregate),
                        isResting: aggregate.lastHeard >= rested,
                        genre: genre,
                        releaseYear: track.year ?? known?.releaseYear,
                        reason: reason(track, aggregate)
                    )
                }
                let song = track.mixSong()
                return Candidate(
                    song: song, weight: factor(track, nil), isNew: true, genre: genre, releaseYear: track.year ?? known?.releaseYear,
                    reason: yourArtists.contains(song.artistKey) ? .newFromYourArtist : .newFind
                )
            }
        return LiveMix(candidates: candidates, newShare: newShare, moment: moment, seed: seed)
    }
}
