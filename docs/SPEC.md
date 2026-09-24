# How the spec was measured

The spec is five screenshots of the original app: Recorder, Recording list,
Settings, the Delete dialog and the Rename dialog. Every size, colour and font
in [`lib/src/ui/spec.dart`](../lib/src/ui/spec.dart) was measured from them.
This page explains how, so the numbers can be checked or re-measured.

## The reference phone

| | |
| --- | --- |
| Screen | 1440 × 3120 px |
| Density | 3.5× (560 dpi), so the screen is 411.43 × 891.43 dp |
| Status bar | 150 px (42.86 dp), black |
| Gesture bar | 56 px (16 dp), `#F1F1F3` |
| System font scale | ≈ 1.077 |

The density follows from the action bar, which is exactly 48 dp (168 px) tall.
The font scale was found by rendering known strings ("Remaining time:
9665:13:10", the list rows, the settings rows) in Roboto at candidate sizes.
Their **ink** widths were compared with the screenshots. Bounding boxes that
include the last glyph's side bearing gave 1.06, which was wrong. The golden
tests run with exactly this phone: `test/support/harness.dart` sets
`useReferenceDevice`.

## Method

1. **Edges and positions.** Row and column intensity profiles of each screenshot
   locate bar edges, dividers, icon ink boxes and text baselines. Values
   in `spec.dart` are in dp, which is px ÷ 3.5.
2. **Colours.** Flat areas were averaged over many pixels to cancel JPEG noise.
   Gradients (header, tab bar, action bar) were sampled row by row and are
   stored as gradient stops.
3. **Text.** The original ran on Roboto, the system font. Android's
   `TextView` sets the line box from the font's metrics (`includeFontPadding`),
   rounded up in physical pixels. For Roboto (per 2048 units): yMax 2163,
   ascent 1900, descent 500, |yMin| 555. Flutter rounds line heights to whole
   logical pixels instead. Over a list of rows that adds up to several pixels
   of drift. `AText` (`lib/src/ui/widgets/frame.dart`) reproduces Android's
   metrics: `AndroidFontMetrics` gives the height of a *n*-line TextView and
   the baseline of its first line, and a `Baseline` widget places the text on
   it. So text sits on the same baseline as the original at any font scale.
4. **Hairlines.** List dividers are one *physical* pixel, not one dp. The
   average row pitch in the list is 232.86 px, not a whole number of dp.
   Settings rows likewise carry a 1-physical-px divider under each 48 dp row.
5. **Verification.** `tool/compare_goldens.py` puts each golden render next to
   its screenshot and reports the mean absolute difference.
   `tool/align_check.py` cross-correlates a single element (an icon, a line
   of text) against the screenshot and reports its offset in px and dp. Most
   elements are 0 to 2 px (under 0.6 dp) away from the original.

Current mean absolute difference of the app area (status and gesture bars
excluded), on a 0 to 255 scale:

| Screen | Difference |
| --- | --- |
| Recorder | 7.1 (mostly the microphone grille's hole pattern) |
| Delete dialog | 3.2 |
| Rename dialog | 3.1 |
| Recording list | 4.2 |
| Settings | 4.0 |

The original's "no ads" badge (top left of the Recorder) and its "Remove ads"
settings row advertised a paid version. They are left out on purpose, and they
count toward the differences above.

## Key measurements

Sizes are in dp and fonts in sp. The full list is in `spec.dart`.

**Bars.** Header 48 dp, dark-red gradient, 18 sp bold title. Tab bar 75.43 dp:
the icons are centred 28.05 dp from its top, labels are 16 sp, the selected
icon is `#0572E7` and the selected label `#0000FE`. The list's action bar is
64.2 dp. Bar dividers are 0.857 dp, `#0B0000`.

**Recorder.** The timer box is 242.6 × 67.7 dp with a 4.5 dp radius and a
2.3 dp bevel. It is centred vertically in the body, 2.5 dp low. The timer
text is 45 sp. The microphone artwork is 148 × 253.14 dp. It stands 0.3 dp
above the box, 0.86 dp left of centre, and shrinks on short screens to keep
8 dp of room under the header. The record
and play buttons are centred 41 dp from the left and 42 dp from the right
edge. The level meter is 10 squares of 18.57 × 14.29 dp at a 21.43 dp pitch,
`#555555` off and `#5455FF` on, at least one lit. "Remaining time" is 12 sp.
The path at the bottom is 14 sp, at 48.44 dp, after a 19.7 dp floppy icon.

**Recording list.** Rows have 10 dp vertical padding and two 16 sp lines:
the name in white, then the date and size in `#C1C1C1`. Text starts at
53.7 dp, after the 32 × 36 dp glossy play button at 12.05 dp. The selected
row is `#FF8B00` and adds a Holo seek bar (`#33B5E5` thumb) with the
position under it.

**Settings.** The section headers ("Recorder", "More app") are 14 sp
`#DFDFDF` on the metal under 25 % white. Rows are 48 dp, with a 14 sp title
and a 14 sp `#E0E0E0` summary at 53.7 dp. Icons are centred at 32.3 dp.
The dividers are `#7A7978`.

**Delete dialog (Holo Light).** Inset 27.43 dp from the screen edges. The
title area is 68.57 dp: a 22 sp `#33B5E5` title after the grey warning
triangle, above a 2 dp blue rule. The message is 18 sp black. The button bar
is 58.85 dp with 0.571 dp `#DCDCDC` dividers. The scrim is 60 % black.

**Rename dialog (iOS style).** Inset 41.14 dp, 6.9 dp radius, `#DBDAD8`. The
16 sp title "Enter new file name" is 16.23 dp from the top. The 33.14 dp
white field has a 0.6 dp `#919191` border and 14 sp text. Below it are a
0.3 dp `#BEBDBB` rule and the Cancel/OK row (42.14 dp), inset 16 dp.

## Artwork

Everything is generated by the scripts in `tool/art/` at 4× density. Nothing
comes from the original APK.

- `brushed_metal.py`: a seamless tile. It reproduces the screenshots'
  horizontal brightness profile, streak contrast and correlation lengths.
- `microphone.py`: ray-casts the chrome capsule with a perforated grille,
  the band and the red light. Geometry was measured in reference pixels.
- `buttons.py`: the glossy record, stop, play, pause and list-play buttons.
- `app_icon.py`: the launcher and header icon (a red disc with a microphone
  and a long shadow), including Android adaptive and monochrome layers and the
  iOS icon set.
- `extract_glyphs.py`: icon outlines from Font Awesome 4.7, Ionicons 2.0.1 and
  Material Icons ([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)). The
  pencil, gear, list and back-chevron icons are drawn in code
  (`lib/src/ui/icons/app_icons.dart`), because no open icon font matched them.
