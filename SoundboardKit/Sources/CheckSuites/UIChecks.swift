import Foundation
import SoundboardUI

/// The design's behaviour, checked without a screen.
///
/// What is verifiable here is the state machine, not the pixels: which pad tap
/// means fire, which means clear, and which opens the fill sheet. That ordering
/// is invisible in a static mockup and is exactly where a faithful-looking
/// implementation goes wrong.
@MainActor
enum UIChecks {
    static func run() {
        Check.suite("DesignTokens - transcribed from the design file") {
            // Spot checks against literal values in Soundboard iPhone.dc.html.
            // A drift here means the implementation and the spec disagree.
            Check.expectEqual(DS.Metrics.deviceSize.width, 402, "device frame width matches the design's hint-size")
            Check.expectEqual(DS.Metrics.deviceSize.height, 874, "device frame height matches")
            Check.expectEqual(DS.Metrics.padSize, 126, "pads are the size that fits eight on one screen")
            Check.expectEqual(DS.Metrics.padCount, 8, "the board holds eight pads")
            Check.expectEqual(DS.Metrics.exploreGridColumns, 4, "Explore is four tiles across")
            Check.expectEqual(DS.Metrics.boardGridColumns, 2, "the board is two pads across")
            Check.expectEqual(DS.Metrics.tilesPerSection, 12, "twelve tiles between ads")
            Check.expectEqual(DS.Metrics.sweepDuration, 1.45, "the pill sweep runs 1.45s")
            Check.expectEqual(DS.Metrics.fireHoldDuration, 1.7, "the playing state holds 1.7s")
        }

        Check.suite("BoardModel - catalogue and layout") {
            let model = BoardModel(catalogue: SampleCatalogue.tiles)
            Check.expectEqual(SampleCatalogue.tiles.count, 24, "the catalogue holds 24 clips")

            // Twelve tiles, an ad, twelve more, an ad.
            Check.expectEqual(model.exploreSections.count, 2, "Explore splits into two sections")
            Check.expectEqual(model.exploreSections[0].count, 12, "the first section holds twelve tiles")
            Check.expectEqual(model.exploreSections[1].count, 12, "the second section holds twelve tiles")

            Check.expectEqual(model.pads.count, 8, "the board shows eight pads")
            Check.expect(model.pads.allSatisfy { $0 != nil }, "every pad starts filled with a popular combo")
            Check.expectEqual(SampleCatalogue.tiles[0].durationLabel, "0:02", "durations render as the design writes them")
        }

        Check.suite("BoardModel - firing") {
            nonisolated(unsafe) var fired: [String] = []
            let model = BoardModel(
                catalogue: SampleCatalogue.tiles,
                onFire: { fired.append($0.id) }
            )
            let tile = SampleCatalogue.tiles[3]

            model.fire(tile)
            Check.expectEqual(fired, ["e3"], "firing a tile reaches the engine")
            Check.expect(model.isFiring("e3"), "the fired tile shows its lime ring")
            Check.expect(!model.isFiring("e0"), "no other tile lights up")
            Check.expectEqual(model.nowPlayingTitle, "toaster fanfare", "the pill names the clip")

            // The sweep restarts per tap. An animation re-run toward a value it
            // already holds does nothing, so without this a second tap inside
            // the hold window leaves the bar parked where the first left it.
            let first = model.fireSequence
            model.fire(SampleCatalogue.tiles[4])
            Check.expect(model.fireSequence > first, "every fire advances the sweep sequence")
            Check.expectEqual(model.nowPlayingTitle, "gremlin giggle", "the pill follows the newest fire")
        }

        Check.suite("BoardModel - a pad tap means three different things") {
            nonisolated(unsafe) var fired: [String] = []
            let model = BoardModel(
                catalogue: SampleCatalogue.tiles,
                onFire: { fired.append($0.id) }
            )

            // 1. Filled pad, not editing: fire it.
            model.tapPad(2)
            Check.expectEqual(fired, ["e2"], "tapping a filled pad fires it")
            Check.expect(!model.isSheetOpen, "firing opens no sheet")

            // 2. Filled pad, editing: clear it, and do not fire.
            model.toggleEditing()
            Check.expectEqual(model.editLabel, "Done", "the button offers the way out of edit mode")
            model.tapPad(2)
            Check.expectEqual(fired, ["e2"], "clearing a pad does not also fire it")
            Check.expect(model.pads[2] == nil, "the pad is now empty")

            // 3. Empty pad: open the fill sheet. This holds in edit mode and
            // out of it, because a plus that does nothing until you find the
            // right mode reads as broken.
            model.tapPad(2)
            Check.expect(model.isSheetOpen, "tapping an empty pad opens the fill sheet while editing")
            Check.expectEqual(model.slotLabel, "PAD 3 OF 8", "the sheet names the pad, one-indexed")
            model.closeSheet()

            model.toggleEditing()
            Check.expectEqual(model.editLabel, "Edit board", "the button returns to its resting label")
            model.tapPad(2)
            Check.expect(model.isSheetOpen, "tapping an empty pad opens the sheet outside edit mode too")
            Check.expectEqual(fired.count, 1, "an empty pad never fires")

            model.fillOpenSlot()
            Check.expect(!model.isSheetOpen, "choosing a clip closes the sheet")
            Check.expect(model.pads[2] != nil, "the pad is filled again")
        }

        Check.suite("BoardModel - tabs and edit mode") {
            let model = BoardModel(catalogue: SampleCatalogue.tiles, startTab: .board)
            Check.expectEqual(model.tab, .board, "the start tab is honoured")

            model.toggleEditing()
            Check.expect(model.isEditing, "edit mode turns on")
            Check.expect(model.hintText.contains("Tap a pad to clear it"), "the hint explains edit mode")

            // Leaving the board drops edit mode. Coming back to a board that is
            // silently armed, where the next tap deletes a pad, is a trap.
            model.select(tab: .explore)
            Check.expect(!model.isEditing, "leaving the board leaves edit mode")
            model.select(tab: .board)
            Check.expect(!model.isEditing, "returning to the board is never silently armed")
            Check.expect(model.hintText.contains("most fired combos"), "the resting hint describes the starting set")

            let noAds = BoardModel(catalogue: SampleCatalogue.tiles, showAds: false)
            Check.expect(!noAds.showAds, "ads can be switched off, as the design's prop allows")
        }
    }
}
