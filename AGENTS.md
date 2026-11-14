<!-- BEGIN BACKSTAGE -->
<!-- Managed by Tandem. Edit these instructions in Tandem; changes made here are replaced. -->
## About This Project

- Type: SwiftUI, Xcode.
- About: A music app for iPhone and Mac that keeps a record of every song you play, including radio, and turns it into insights, mixes and stations. Optional Last.fm scrobbling; history syncs through your private iCloud.

## Build and Run

- Xcode: Tracks.xcodeproj. Build and run it with Tandem's MCP tools (mac_launch, sim_launch) to check your work without windows appearing.
- The shared Rust engine lives in `Engine/` (see `Engine/README.md`). Run `Engine/build-apple.sh` once after cloning and after any change there, before building the apps; it produces the `TracksEngine` package TracksCore links. Rust tests: `cargo test --workspace` in `Engine/`.
<!-- END BACKSTAGE -->
