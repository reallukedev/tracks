# Tools

## The app icon

The icon lives in `Apps/Shared/Resources/AppIcon.icon`, an Icon Composer document, so the
system can render it with Liquid Glass and produce the dark, clear and tinted variants on
its own. Open it in Icon Composer (it ships with Xcode) to change it. Both apps use the same
file.

It's three white arcs on a violet-to-pink gradient: progress rings for the statistics, and
the grooves of a record. The artwork is plain SVG in `AppIcon.icon/Assets`, so it diffs
cleanly.

`export-icon.sh` renders it to `images/icon.png` for the README:

```
./Tools/export-icon.sh
```

## Screenshots

`screenshots.sh` builds the Debug apps and captures the App Store and README screenshots
from sample data:

```
./Tools/screenshots.sh            # writes to build/screenshots, and the README's to images/
```

It launches each app with `-TracksDemoData YES`, which fills an in-memory store with invented
listening and never touches real history, iCloud or Last.fm, plus the Debug-only launch
arguments in `Apps/Shared/App/LaunchScene.swift` that open a given tab, section or page.
iPhone images come out at App Store sizes. The Mac shots need Screen Recording
permission for your terminal (System Settings › Privacy & Security)

Add `-TracksDemoLive YES` to a Debug demo launch and a sample song finishes every five
seconds, which is the quickest way to see how the screens animate as listening arrives.

## App Store frames

`AppStoreScreenshots/` turns raw captures into the framed App Store sets, laid out the way
Apple lays out its own: on iPhone, a plain light field, a two-line caption in the app's accent
(the idea in Semibold, the specifics in Regular) and one natural titanium iPhone in the lower
four fifths, the same size and place in every frame; on Mac, the window full bleed under a thin
caption band. The one flourish is the first iPhone frame, where the Play page's Cover Flow crate
carries on past the phone in the app's own mix tiles, redrawn from its cover recipe.

```
./Tools/AppStoreScreenshots/capture.sh           # raw screens into build/raw2 and build/raw3
python3 Tools/AppStoreScreenshots/render.py      # framed PNGs into build/app-store
```

Each set is drawn as one wide page (`iphone.html`, `mac.html`) and cut into frames, so the
whole set can be judged side by side. Copy, scenes and layout live in the `frames` list in
each page. The output is
1320 × 2868 for iPhone, the 6.9" size App Store Connect asks for, and 2880 × 1800 for the
Mac, flattened to RGB. A 1284 × 2778 copy of each iPhone frame also goes to
`build/app-store/iphone-6.5`, for the optional 6.5" slot, which rejects the 6.9" size.
Rendering needs Playwright's Chromium (`pip install playwright && playwright install
chromium`) and the SF Pro fonts from developer.apple.com/fonts.
