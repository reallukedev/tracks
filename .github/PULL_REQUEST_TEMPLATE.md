## What this changes

<!-- What changes for the person using Tracks, and why. Link the issue if there is one. -->

## How it was verified

<!--
What you ran, on what (simulator, iPhone, Mac, OS version), and what you saw.
Say what you couldn't verify, too. "It builds" is not "it works".
-->

## Checklist

- [ ] `cd TracksCore && swift test` passes
- [ ] `./build.sh ci` passes, or CI is green
- [ ] New logic in `TracksCore` has tests
- [ ] I ran the change, not only compiled it (and on the Mac, a signed build)
- [ ] Nothing here inflates a play count or plays music nobody hears
- [ ] `xcodegen generate` was run if files were added, moved or removed
- [ ] No personal team IDs, bundle identifiers or credentials in tracked files
- [ ] `docs/PlatformNotes.md` is updated if I measured something new about Apple's behaviour
