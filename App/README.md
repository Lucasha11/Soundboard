# Soundboard app target

## Status: not compiled

Everything in this directory was written on a machine with **Command Line Tools
only, no Xcode**. It has never been built, run, or rendered. Treat it as a
starting point that almost certainly needs small fixes on first build, not as
working code.

Everything the app depends on *is* compiled and checked: the engines, the
library, and the whole SwiftUI layer live in `../SoundboardKit` and type-check
against the macOS SDK. The composition root is in the package too
(`SoundboardComposition`), so the only untested code here is the `@main` shell
and two small views.

## Generating the project

```bash
brew install xcodegen
cd App && xcodegen generate && open Soundboard.xcodeproj
```

There is no `.xcodeproj` checked in on purpose. A hand-written `project.pbxproj`
could not be validated here, and a project file that will not open is worse than
none.

## Before it will look right

**Add the fonts.** The design uses Archivo and JetBrains Mono. Neither ships
with iOS. Drop the two variable `.ttf` files into this directory and confirm the
filenames match `UIAppFonts` in `Info.plist`. Without them SwiftUI silently
falls back to the system face and every metric in the design shifts.

**Expect to check the spacing.** The layout was transcribed from
`design/soundboard-iphone-mobile-handoff/project/Soundboard iPhone.dc.html` and
has never been seen on a screen.

## First launch behaviour

The library starts empty, so the grid shows the design's placeholder catalogue:
24 coloured tiles that are **silent**, because no media resolves for them. Real
sounds appear once clips are imported through `SoundboardComposition.importClip`.

Wiring a picker to that call is the next piece of work. `PHPickerViewController`
via `UIViewControllerRepresentable` is the route, and it needs no photo library
permission string because it runs out of process.
