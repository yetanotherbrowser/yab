# Space switching

A user wrote in Yab: "switching between spaces in Arc is super fluid; that
was really the only thing that felt off for me". This page is what Arc does,
measured frame by frame, what Yab did before, and what it does now.

## How Arc was measured

Arc 1.167.0 on the built-in 3024×1964 screen of main, 2026-10-04, four
spaces (the user's own; nothing in Arc was opened, read or changed, and Arc
was left on the space it was on).

- Screen recorded at 60 fps: `ffmpeg -f avfoundation -framerate 60
  -capture_cursor 0 -pixel_format bgr0 -use_wallclock_as_timestamps 1 -i
  "6:none"`, frames extracted with `-fps_mode passthrough -frame_pts 1
  -enc_time_base 0.001`, only after 45 s without input and behind a
  screenSaver-level countdown; focus given back after each take.
- Keys posted to Arc with `CGEventPostToPid` while it was in front; clicks
  and two-finger swipes as HID events: scroll-wheel events with
  `isContinuous`, scroll phases began/changed/ended and momentum phases,
  point deltas checked first in a test window (AppKit read exactly the
  deltas sent).
- Where the sidebar's contents are, per frame: a row of each space cut from
  a settled frame and matched along x in every frame (normalized squared
  error, 1 px = 0.5 pt), times on uniform 60 fps. Springs fitted by grid
  search over response, damping and start velocity.
- Six takes, 40 key presses, clicks and swipes. The recordings, the event
  logs and the scripts stay on main in `~/Movies/yab-space-switching-arc/`
  (they show the user's tabs, so they are not in the repository).

## Arc, measured

**The ways in.** Spaces menu (read through Accessibility): Next Space ⌥⌘→,
Previous Space ⌥⌘←, one item per space on ⌃1…⌃4; the space icons at the
sidebar's foot; two fingers sideways over the sidebar. ⌥⌘→ on the last
space goes round to the first, and ⌥⌘← on the first to the last.

**What moves.** The space's own part of the sidebar (its name, pinned tabs
and tabs) is one page in a row of pages, each exactly as wide as the
sidebar: 226 pt here, measured as the distance between two spaces' pages
in the same frame (452 px). Pages are opaque, side by side, no gap, no
fade, no scale. The favorites grid, the window controls and address field
at the top and the icon bar at the foot stay put.

**Keys, menu, clicks.** The row slides on one spring, whatever the
distance: ⌃4 from space 2 slides two pages through space 3, ⌥⌘→ from the
last slides three pages back to the first. Fitted on 12 landings:

| Fit | response | damping | rms |
|---|---|---|---|
| ⌃3 (s2) | 0.21 s | 1.00 | 6 px of 456 |
| click on an icon (s3) | 0.23 s | 0.94 | 3.3 pt |
| let go past halfway, held (s4, 4 takes) | 0.21 to 0.26 s | 0.90 to 0.98 | 0.2 to 2.7 pt |
| let go moving (s4, 3 takes) | 0.18 to 0.20 s | 1.00 to 1.05 | 0.2 to 3.2 pt |
| snap back (s3, s4, 5 takes) | 0.19 to 0.23 s | 0.92 to 1.05 | 0.2 to 1.3 pt |

A critically damped spring of response 0.20 s fits all of them: half the
way in 50 ms, 90 % in 120 ms, 99 % in 200 ms, never past the target (no
overshoot in any take, to the pixel). ⌃4 then ⌃3 70 ms apart (s5): the row
turns smoothly toward the new target, keeping its speed (spring retarget).

**The color.** Each space has its own theme; the sidebar's color goes from
one to the other in step with where the row is: at 35 % of the way in a
held swipe the color was 36 to 41 % of the way (purple (20,14,30) toward
gray (31,31,31)), and it comes back with the row on a snap back.

**The page.** The web page switches in one frame, no cross-fade, on the
same frame the row starts to land (key, click, or the fingers lifting
past the rule below). While the fingers hold, the old page stays.

**Two fingers.**

- The row moves half as far as the fingers: 40, 80, 120, 160, 300 pt of
  scrolling moved it 19.5, 39.5, 59.5, 79.5, 149 pt. It follows them
  directly, without smoothing; it stops on the frame the moves stop.
- At most one page a gesture, and only toward a space that exists: past
  that it gives a little. 200 pt toward a next space that isn't there (the
  last space) moved the row 14 pt, back on the spring when let go. Fitted:
  `(1 − 1 / (x · 0.15 / W + 1)) · W` for `x` the half of the fingers' travel
  past the end and `W` the page.
- Let go **while moving**, even at 7 pt/s 2 % of the way, the row goes on
  the way it was going: to the next space if going forward, back to the
  start if coming back (past halfway and coming back at 100 pt/s: back).
- Let go **held still**: to whichever space shows more. 44 %, 48 %, 50.4 %
  went back; 51.8 %, 55 %, 66 % went on.
- Momentum events after the lift change nothing; the gesture decides on
  "ended". A gesture whose first move is all zero isn't taken (its
  direction is read from the first move).
- First movement on screen came 70 to 90 ms after the first event, the same
  for keys and clicks (screen capture and Arc together); the row lands
  70 to 95 ms after the lift.

## Yab before (main, dd5a34ce)

Filmed with `evals/space-switching/film.py` (ScreenCaptureKit on the
probe's window, farm job 4ea1138a5d6442f7 on adhd), the same inputs as for
Arc through `bench pace space-step` and `space-swipe`.

- **Keys:** the old rows went at once; the new ones came in from 24 pt to
  the right, starting at 35 % opacity, over about 110 ms
  (24, 15, 8, 8, 3, 1, 0 pt a frame); the window's color crossed over in
  170 ms, linear. Nothing slid out, nothing slid a page.
- **Two fingers:** the rows moved 1:1 with the fingers up to 110 pt and
  faded out by two thirds of the way; the next space's rows faded up 24 pt
  from their place, drawn under them by SwiftUI. Let go past 40 % of 110 pt
  (44 pt of fingers), or past 15 % with a flick, and the space came;
  otherwise everything went back on a SwiftUI spring.
- **Rule:** 160 pt held still went to the next space (Arc: back); 40 pt let
  go drifting slowly came back (Arc: next). At the last space the swipe
  went round to the first (Arc: gives 14 pt and comes back).
- **Main thread:** every move of the fingers was a SwiftUI pass over the
  column (the rows' offset and opacity, the capsule's words, the coming
  rows), 4 to 8 ms each, about 300 to 420 ms of main-thread CPU per swipe;
  a key switch 107 to 120 ms over its second, with one 48 to 56 ms pass.

![Yab before, ⌃N: the old rows gone at once, the new ones in from 24 pt](shots/space-switching/yab-before-key.png)

## Yab now

`SpacePager.swift` (the row of pages), `SpacePaging.swift` (the numbers and
rules, unit-tested in `SpacePagingTests`), `PagedSpace` in `Side.swift` (a
space's pins and rows drawn for a page), `ColumnView` in `Peek.swift` (the
band pictured and masked), the hooks in `Browser.switchSpace` and
`SpaceSwipe` (`Spaces.swift`), the window's color on the same spring
(`SpaceWash`, `WindowBackdropView.setCover`).

- **One row of pages.** When a change starts, the space's own band of the
  column (its pins and rows, from under the plate to over the foot) is
  pictured once from the column host's own layers (3.7 to 9.5 ms) and the
  column's live drawing of that band is masked out. The spaces beside it
  are drawn by hosts of their own (`PagedSpace`, the column's own row
  views) one column width to either side, all in one clipped view moved by
  one `sublayerTransform`. The lights, plate, foot and capsule stay live
  and still, as Arc's top bar and icons do. When the spring has landed the
  pages and the mask go: the live column under them is that space at rest.
- **Keys, menu, the tray, the dots.** All go through `switchSpace`: the row
  slides past every space between (⌃4 from the first goes past the second
  and third; Next from the last goes back past all of them), on a
  `CASpringAnimation` of stiffness 987 and damping 62.8 (response 0.2 s,
  critically damped) that the render server plays while the main thread
  lays the new space out under the mask. A second change while one lands
  adds an additive spring from where the row is drawn, so it turns without
  a jolt.
- **Two fingers.** The row moves by half the fingers' travel, at most one
  space, with Arc's give past it (`SpacePaging.offset`); each move is one
  transform set with actions off, no SwiftUI pass. The window's color is
  the next space's as far as the row has gone. Let go: moving faster than
  5 pt/s, on the way it went; held, to whichever space shows more
  (`SpacePaging.landing`). The landing spring starts at the fingers' speed.
  The space's page switches the moment the fingers lift, as Arc's does.
- **Swipes no longer go round** from the last space to the first; Next and
  Previous (and ⌃N) still do, as Arc's do.
- The tabs-on-top strip keeps its own swipe (`SpacePull`), unchanged.

Filmed with the same inputs, farm job `0b44816e58c84b8e` on adhd
(ScreenCaptureKit frames, and where the render server drew the row,
sampled 120 times a second: `bench pace` returns it as `pager_track`).

| Take | Arc | Yab before | Yab now |
|---|---|---|---|
| 160 pt held, let go | back | next space | back |
| 300 pt held, let go | next (66 %) | next | next (66 %) |
| 60 pt in 0.1 s | next | next | next |
| 40 pt drifting, let go moving | next | back | next |
| 160 pt back from the second space | back | first space | back |
| 200 pt past the last space | gives 14 pt, back | goes round to the first | gives 14.1 pt, back |
| rows per point of fingers | 0.5 | 1, up to 110 pt, fading | 0.5 |
| key: slide | 226 pt page, spring | 24 pt, 110 ms, old rows cut | 228 pt page, spring |
| landing 50 / 90 / 99 % | 50 / 120 / 200 ms | (24 pt in ~110 ms) | 49 / 116 / 216 ms (key), 51 / 118 / 201 (⌃ three on), 65 / 132 / 215 (let go) |

![Next space by key: Arc, Yab before and after, and the spring](shots/space-switching/key.svg)

![Let go past halfway, held: points still to go](shots/space-switching/land.svg)

![Two fingers 160 pt, held, let go](shots/space-switching/drag.svg)

![Yab now, ⌃N](shots/space-switching/yab-after-key.png)

![Yab now, 300 pt held and let go: the color as far as the row](shots/space-switching/yab-after-swipe-300.png)

Arc's key curve leads Yab's by about a frame at the start: its first
frame in the recording is already 28 % of the way, which a spring from rest
reaches only in its second frame, so either its start fell between two
captured frames or it starts with some speed; from 100 ms on the two lie
within 3 pt.

### Main thread

`bench pace`, main-thread CPU over the whole take (the take's own length),
before (job `4ea1138a5d6442f7`) and now (job `0b44816e58c84b8e`), both on
adhd with the same world:

| Take | before ms | now ms | before Minstr | now Minstr |
|---|---|---|---|---|
| ⌃N | 107.5 | 121.9 | 412 | 513 |
| ⌃N again | 120.3 | 140.5 | 462 | 603 |
| 160 pt held | 328.2 | 225.5 | 1103 | 429 |
| 300 pt held, goes on | 418.0 | 394.1 | 1066 | 821 |
| flick | 147.6 | 135.3 | 540 | 508 |
| slow drift | 244.4 | 175.3 | 607 | 570 |
| 160 pt back | 373.9 | 194.5 | 1047 | 404 |
| past the last | 342.7 | 223.5 | 1007 | 348 |

While the fingers move, the main thread no longer has a pass over 4 ms:
before there was one of 4 to 8 ms for nearly every frame of the drag (20 to
40 a swipe); now there is one of 22 to 28 ms as the fingers start (the
band pictured and the next space's page laid out) and the switch itself
when they let go past the rule (58 to 63 ms, as before). A key costs
14 to 20 ms more than before, the picture and the page, in its first pass
(64 to 67 ms, was 48 to 56); the slide starts after that pass, about
80 ms after the key, as the old arrival did after its own.

### Not matched, or not proven

- Arc goes through the colors of the spaces it passes on a jump of several;
  Yab crosses straight from the first color to the last.
- A second key while the row lands turns it on an added spring; Arc does
  the same (s5), but Yab's turn was not filmed.
- Arc's latency (70 to 90 ms from event to first moved frame, capture
  included) and Yab's (about 80 ms from the bench's act to the first drawn
  move, plus a frame with the fingers) were measured on different paths
  and are not compared closely.
- Momentum after the fingers lift is ignored, as in Arc; a real trackpad
  was not used, only posted scroll events with phases.
- Mail's space as a page, the tabs-on-top strip and Reduce Motion (no
  slide, the space changes when the fingers lift) were not filmed.

## 0.0.8: the card stayed empty under the fingers

A user filmed 0.0.8 (build 202610040248, which has the row of pages) next
to Arc: under two fingers the space's pins, folder and tabs slid a little
and faded out within about 80 ms, the column then stayed empty but for the
lights and the address for as long as the fingers moved, and the next
space came only once they lifted, fading in. Arc draws both spaces from
the first move.

**Cause.** The column was put away and brought out over the page by the
edge, as a card (`sidebar.shut` on, the edge's peek), a state many keep.
`SpacePager.allowed` took only the docked column (`!prefs.sideShut`), so
`grab` refused every move and the swipe fell back to the old way
(`SpacePull`): the rows under the fingers and fading out by two thirds of
110 pt. What used to come up under them, the next space's rows
(`SpaceComing`), had been taken out with the row of pages, so nothing
came: the column was blank until the switch on lifting brought the new
rows in on ⌃N's arrival. Every probe world before was docked, so the
films and the bench passed. `evals/space-switching/rich.py` reproduces it:
on main every card state reports `refused: column put away` and no pages
up mid-swipe, the docked ones page.

**Fix.**

- The card slides as the docked column does (`SpacePaging.slides`, unit
  tested), whether it is there by key or by two fingers. Whether it is
  out is read from the browser (`sideShut`, `sidePeek`), not from the
  column view, whose word comes with SwiftUI's next pass.
- The band is the card's own, in from the window's edges, the pages laid
  from the card's top (`PagerStage` `top`), the card's hairline down
  either edge left live (`PagerStage.rim`).
- The card paints its ground itself (`Column.ground`: color, gradient,
  grain and, when see-through, a frost), and the band's mask cuts it out.
  The picture is taken without it (`ColumnView.grounds`: the bare layers
  as big as the card in its own layer, before the column's own). Drawn by
  `render(in:)` the frost came out an opaque gray, the card far darker
  than on screen; and a ground carried by each page left a light seam
  between two see-through pages as they slid. So the ground is laid back
  once, still, under the row (`PagedGround`), and the next space's over
  it as far as the row has gone, landing on the row's spring, as Arc's
  color goes. Where that ground can't be found, each page carries its own.
- A card that goes past the edge while the row is up takes the pages down
  first (`ColumnView.slide`).
- A page wears its own space's color as its ink's tone, docked too.
- A swipe the pages can't come up for (Reduce Motion, a column not laid
  out yet) no longer fades the rows to nothing: they stay, and the space
  changes when the fingers lift past 40 % of 110 pt, or 15 % flicked, one
  space and never round.
- `bench pager` says why the pages wouldn't come up (`refused`) and how
  much of each half of the band is drawn (`ink`) while they are up;
  `film.py` takes `RICH=1` for a world like the user's.

**Measured.** `RICH=1 film.py` on adhd, ScreenCaptureKit on the probe's
window: four spaces, twelve pins and a folder in the first, one tab in
the second, a see-through color with grain, the card out by the edge.
Before: main at fd832865 (farm job `c694380370454e65`); after: job
`5bebf2bfd9524000`. Where the first space's page is drawn, found in each
frame by matching it along x; "empty" is a band with nothing but its
ground in it.

| Take | before | after |
|---|---|---|
| 300 pt held, let go | rows gone by 0.5 s, empty until the lift at 1.9 s | row at -22, -47, -70, -95, -120, -146, -150 pt (half the fingers), both pages drawn |
| 60 pt flick | empty from 0.2 s to the switch | row -25 pt, then lands on the next space by 0.46 s |
| 160 pt held, let go (snap back) | empty, then the next space | row to -80 pt, back to the first space |
| main thread, 300 / flick / 160 | 543 / 227 / 456 ms | 531 / 252 / 232 ms |
| frames dropped, 300 / flick / 160 | 1 / 2 / 1 | 2 / 2 / 1 |

The pages come up in one main-thread pass of 29 to 33 ms about 20 ms
after the first move (the picture, the ground, the next space laid out);
the switch at the lift is the same 64 to 83 ms pass as before.
`rich.py` on the same build: every state pages, docked and card, one tab
or many, after a key, after the column went away and back, after the tabs
went on top and back. On main the five card states fall back.



## The card's color, on the row's spring

A user filmed the column brought out over the page as a card while
switching spaces (2026-10-04, 120 fps): the rows slid, but the card's
color did not go with them. On ⌃N the whole card, plate, rows and foot,
went from one color to the other over about 300 ms, held still for some
60 ms in the middle (the switch's own pass) and landed after the row; in
its place, the same switch turned the color in about 130 ms in step with
the slide.

**Cause.** The card painted its ground in SwiftUI (`BackdropFill` under
`Column`), so a new space's color reached it with SwiftUI's next pass and
eased on `Toned`'s animation, `Motion.quick` on the main thread, which the
switch's pass stopped. Only the band under the rows turned on the row's
spring (the pager's grounds); the plate and the foot did not.

**Fix.** The card's color, gradient and grain are Core Animation layers
(`CardGround`, `CardGroundView` in `SpaceWash.swift`), the frost still
SwiftUI's under them. `SpaceWash` turns them in the same calls, with the
same curves, as the window's backdrop and wash: the fingers' share as they
move, the row's spring when it lands, and the new space's paint put on in
the switch's own frame. The ground under the row while the pages are up
is one of these too, made by the stage itself (a new SwiftUI host made its
view only after the switch had turned the others). The picture of the band
leaves out the page's dimming, which had made the band a step darker than
the rest of the card while the pages were up. And two opaque colors now
cross straight in the window too (`WindowBackdropView.overClear`): the
coating gave way under an opaque color, so the glass's gray came up
between them, 0.57 of the way falling to 0.34 as the fingers let go.

**Measured.** `evals/space-switching/color.py` on adhd, `bench film`
(Yab's own layers as the render server has them), two spaces in two
opaque colors, docked and as a card; in each frame the most common color
of the plate, the empty end of the band and the foot, as a share of the
way from one space's color to the other's. Before: job
`c65da40408134c62`; after: job `98b17e75cc98413d`.

| ⌃N, ms after the key | docked | card before: plate, band | card after: plate, band |
|---|---|---|---|
| ~50 | 0 | 0, 0 | 0, 0 |
| ~70 to 85 | 0.23 to 0.26 | **1.00**, 0.09 | 0.28, 0.28 |
| ~105 to 130 | 0.57 to 0.62 | 1.00, 0.40 | 0.70, 0.70 |
| ~145 to 180 | 0.79 to 0.92 | 1.00, 0.77 | 0.92, 0.92 |
| ~230 | 0.98 | 1.00, 1.00 | 0.98, 0.98 |

| Take | card plate vs its band, same frame, before / after | card vs docked, after |
|---|---|---|
| ⌃N | 0.92 / 0.00 | 0.01 |
| ⌃N back | 1.04 / 0.00 | 0.04 |
| 300 pt held, let go | 0.66 / 0.00 | 0.07 |
| 160 pt held, back | 0.43 / 0.00 | 0.02 |
| 60 pt flick | 0.87 / 0.00 | 0.04 |

"Card vs docked" is the largest difference from the docked column's
curve, read between its frames, the card's take moved in time (within
50 ms) to where it lies closest: the two are different takes.

## 0.0.13: the row stayed held after the fingers lifted

A user came back to Yab (2026-10-07, 0.0.13 build 202610070817) to find
the column, brought out over the page as a card, drawn wrong: its pins and
rows stood a few points off to one side, cut by the card's edge, with
nothing beyond them, past the first space toward the right, past mail
toward the left. Once the card itself had gone past the edge and the band
of rows stayed over the page alone. Docking the column didn't help; only
changing the space did.

**Cause.** The row of pages (`SpacePager`) was up and held: two fingers
had taken it a rubber band's stretch past the first or last space, and
their lift never came. `SpaceSwipe` let the row go only when a gesture's
end reached the column's own window; anything else left `holding` on, the
pictured row over the column and the column's own drawing of the band
masked under it, until a change of space (`turn`) took it down. The likely
way to lose the lift, not reproduced with a real trackpad: a swipe of
three fingers to another desktop that begins as two over the column hands
its end to a window on the other desktop. And the pages came down with the
card only on the pass where the card left; pages held over a card stayed
over the docked column, laid for the card.

**Fix.** While fingers hold the row, anything that says they are gone lets
it go as a still lift would (`SpacePager.lost`): Yab leaving the front or
coming back to it, the column's window out of sight or closed, the desktop
changed, a click, fingers down anew (a scroll's `mayBegin` or `began`),
and a gesture's end or momentum that SpaceSwipe, in the column's window,
didn't take. The pages come down whenever the column, as SwiftUI lays it,
is no longer out or no longer the shape they were laid for
(`SpacePager.settle`). The strip's tabs, tabs on top, go back on fingers
down anew after an end that never came.

**Measured.** `evals/space-switching/lost-lift.py` (bench `spacetray`
`swipe lift=false` holds the row with no end sent; `touch`, `click` and
`desktop` say the fingers went).

## 0.0.17: a switch with many tabs waited before the row moved

A user wrote on Oct 9 that switching spaces lags once the spaces hold many
tabs. The row of pages slid on its spring as it should, but only from the
commit that ended the switch's run-loop pass, after the space on screen
was pictured, the next space's page was made (a SwiftUI host with every
row in it) and the window was laid out for the new space: 175 to 290 ms on
main from the key to the row's first move, 240 to 325 ms on adhd.

**Fix.** The row and the window's color set off first: once the pages are
up, the spring and the color crossing are committed (`Browser.setOff`,
`CATransaction.flush()`), and the switch lays the page and the column out
under the moving row; a let-go flushes its spring the same way. A space's
page is made once and kept while what it draws is the same
(`SpacePager.made`), drawn as the space stood rather than redrawn on each
write of the switch, and makes only the rows the band shows.

**Measured.** `evals/space-switching/many.py` (30, 80, 150 tabs a space;
key, swipe, tabs on top; `BUDGET_MS` for the row's start, `HELD_MS` for
the main thread): the row now starts 37 to 62 ms after a key and 36 to 68
ms after a let-go, was 175 to 286 and 103 to 184. The numbers and what is
still slow are in docs/evidence/space-switch-2026-10-09.md.

## 0.0.19: swipes over the column stopped working after a while

Two reports on 0.0.19 (#98, #100): two fingers sideways over the column
didn't change the space; "works for some time after quit and open but fails
after that". The row came up a few points and went back, every swipe, until
a relaunch.

**Cause.** The lost-lift guard of 0.0.13 (`SpacePager.heard`, a local
monitor) lets the row go on fingers down anew, a scroll's began. A
trackpad's began carries the fingers' first move, and SpaceSwipe takes the
row with that very event. Every local monitor hears every event, the
catch's taking it or not, in an order AppKit changes as monitors come and
go. With SpacePager's monitor after the catch's, it heard the began that
had just taken the row as new fingers and let it go 7 points out; the rest
of the swipe moved nothing. Which order a run had turned over during use:
on adhd one run failed from launch and came right after ⌘T, another worked
until the first page scroll and failed from then on. The bench's own swipe
sends an empty began, so the row was taken on the first move after it and
no eval met the bug.

**Fix.** The row keeps when the move that took it was made
(`SpacePager.grab(_:by:)`); a scroll from then or before is the same
fingers (`SpacePager.parting`). A later began, a click, Yab going away still
let it go.

**Measured.** `evals/space-switching/stops.py` swipes with real HID events
(`hand.py`: phases, a began carrying the first move, the glide after) over
the column first and after each of a run of ordinary things, and reads the
row's trace (`bench pager` `swipe_trace`). SpacePagingTests holds the rule.

## 0.32: the column showed the space it left as the row landed

A user wrote (#181, build 202610181940): "Spaces flicker while swiping
between them".

**Filmed.** `evals/space-switching/flicker.py`: four spaces in four colors,
eight tabs each, each space's front page its own color, the far two asleep;
light and dark, with glass off, on, and on in every other space; real
swipes at the HID tap (`hand.py`) through every space and back, a slow one,
and Next Space by key; every frame through ScreenCaptureKit, read as a
10 px grid (`grid.swift`) and checked for a run of up to four frames unlike
the frames either side while those agree (blink), a page or ground off the
line between where it starts and lands, and an empty column. Storyboards
per take (`board.swift`), flagged frames rimmed in red.

On main before the fix (m4, job `c07d317bb62e4639`, base build f777c254),
20 of the 48 takes blinked: one or two frames (17 to 33 ms) after the row
had landed, the column at rest showed the rows and name of the space just
left, on the new space's ground and over its page, then the new space's
rows again. In light and dark, glass off and on, swipes and keys alike; the
takes with glass in every other space did not (why was not looked into).

**Cause.** With the AppKit column the row of spaces is the live pages in
one clip moved by a transform (`ColumnPages`). On landing, `endSlide()`
took the transform off in a transaction of its own and only then laid the
landed space's page at no offset (`sync()`). It runs from the landing
spring's completion, where no transaction is open, so its commit went to
the render server alone: the row at rest, the page left still at no offset
and the landed one a page to the side, for a frame or two until the next
commit brought `sync()`'s frames.

**Fix.** `sync()` runs inside `endSlide()`'s transaction: the transform
comes off and the landed page stands in place in one commit.

**After** (same job, this tree): 0 findings in all 48 takes.

## #282: a mouse's wheel sideways over the column did nothing

A user wrote: in Arc and Dia, scrolling sideways with a mouse anywhere over
the sidebar switches spaces; in Yab (0.33.3) it didn't.

**Cause.** The column's catch (`SpaceSwipe.Catch`) took only events with
precise deltas and a trackpad's phases (began, changed, ended). A clicking
wheel's notch has neither, and a smooth mouse's moves (Logitech's smooth
scrolling and the like) come precise but with no phase: both were let
through to the rows, which don't scroll sideways, over every part of the
column (pins, name, folders, rows, empty room, foot).

**Arc, measured** (1.167, adhd, `evals/space-wheel/arc_wheel.py`, jobs
`3f2bb0ca6bef44a4` and `1c8b1da301d143cb`): real HID wheel events posted at
the sidebar, the space read through Arc's AppleScript, each case three
times.

| Input over the sidebar | Arc |
|---|---|
| one notch, either way, from any space | nothing, the row doesn't move (3/3) |
| two notches 16, 30 or 50 ms apart | next space, at the second notch (3/3 each) |
| two notches 80 ms apart | nothing (3/3) |
| three notches 30 ms apart, five 30 ms apart | one space |
| four notches 50 ms apart | one space (2/3) |
| one event of 2 or 3 lines | next space at once |
| shift with two vertical notches 16 ms apart | next space (3/3) |
| two notches the other way from the second space | back to the first |
| past the last space, before the first | nothing, no wrap |
| a smooth mouse's 5 moves of 2 points, no phase | next space |
| one vertical event of 3 lines down | next space (3/3), up: nothing; two of them 16 ms apart: nothing |

The space comes on the same slide as a key's (a frame strip 0.2 s after two
notches shows the row mid-slide). Arc's sidebar is a paging scroll view, and
its vertical turns are a quirk of that: Yab doesn't copy them.

**Fix.** `SpaceWheel` (unit-tested in `SpaceWheelTests`): over the column,
a wheel move with no gesture phase that is more sideways than up or down
(shift with a clicking wheel counts as sideways) is the column's. Moves
closer together than 65 ms are one push; a push turns one space when it has
added up to 2 lines (a clicking wheel) or 10 points (a smooth one), and
nothing more until a pause (changed in #822, below). The turn is `switchSpace`, a key's slide, never
round past the ends. Up or down stays the rows' scroll and ends any push.

The first probe runs turned the space over the pins, name, folder and foot
every time but over the rows only now and then: the catch's taking a notch
(its monitor returning nil) did not keep it from the rows' scroll view,
since every local monitor hears an event whichever took it, so the rows
took the first notch too and held the wheel's latch (`WheelLatch`), and
when the latch's monitor came before the catch's the second notch went
straight to the rows and the catch never saw it. Now the rows leave a
sideways wheel move alone (`RowsScroll.scrollWheel`), and a latch held by
them lets a sideways line go on.
The island (the player) keeps its own swipe. `bench spacewheel` posts the
same events for probes; `evals/space-wheel/yab_wheel.py` plays every case
over each part of the column before (the wheel let through) and after.

## Tabs across the top: Dia's turn (feedback #254)

With Sidebar Off a change of space follows Dia's strip, filmed at 60 fps on
m4 (Dia 1.52, three profiles; `evals/dia-top-spaces`, artifact
https://claude.ai/artifact/7crDwopz32R96iz1GuYahY) and built as the
prototype's "Yab, improved" (`StripTurn` in SpaceFoot.swift):

- The space's capsule is a plate of its own after back, forward and
  reload: the emoji and the name, no chevron, 16 points before the first
  tab.
- One critically damped spring, ω 26 rad/s (Dia's capsule edge, fitted
  over five takes: ω 23 to 28.5, ζ 0.96 to 1.08), carries the plate's
  width, the tabs after it (`LeadSlide`), the window's color (SpaceWash,
  `clearOnStrip`) and the name, which comes in from the side the space lies
  on as the old one goes out the other (`StripCarousel`). SwiftUI draws it
  for 0.27 s (99.3%); the plate and the tabs are laid out at the new
  space's place once and only drawn on the way (`CapsulePlate`,
  `LeadSlide`), not laid out again every frame.
- The page and the tabs are the new space's in the switch's own pass; the
  new tabs come up 24 points from the side over 140 ms while the old row
  goes 16 points the other way, gone by 78 ms (`StripArrival`,
  `StripComing`). Begun in that pass (`StripTurns`), not a frame behind:
  a frame behind, the strip stood empty through the switch's long pass.
- Two fingers over the capsule: names as a carousel under the fingers,
  the old tabs going 40 points with them and fading, the next space's
  coming up from 35% of the way, the color mixing (`SpacePull`, reach 420).
  Let go, any way toward a neighbor (more than 3%) brings it at once,
  carried on from where the fingers left everything; no way round the
  ends, where the name gives up to 12% and springs back. ⌃1 to ⌃9 and
  ⌃← ⌃→ (round the ends) are as before.

Dia's own stalls are left out: its 88 to 127 ms before anything moves, the
capsule empty for 50 ms, the cut tabs, the 150 to 300 ms wait after the
fingers lift and the 450 ms after a menu pick.

**Measured** (`evals/dia-top-spaces/perf_ab.sh`, base b9a52a58, `bench
pace` main thread per key, medians): on renderer-2, three rounds of eight
switches, the first frame after the key 54 to 59 ms before and 37 to 41 ms
now; the whole switch 156 to 163 ms before and 167 to 168 ms now, the
spring drawn 70 ms longer than the old 0.2 s curve. On adhd, filmed at the
same time (`ab.sh`): 65 and 61 ms, 156 and 159 ms. The shortcuts were read
again four times a switch (`Hotkeys`, now once). Make Default's menu item
asking LaunchServices on every redraw was fixed on main meanwhile
(`Links.isDefault`, 58bbe41a).

**Played in Core Animation** (StripLayers.swift, 2026-10-29). On main of
that day the SwiftUI turn above cost the switch 30 ms more than main's own
(`perf_ab.sh` on adhd: 163 to 166 ms against 135 to 137), each part drawn
10 to 45 ms of the main thread, the tabs' slide the most; and the strip
waited out the window's 70 to 90 ms pass behind the page, so the old row
showed for two frames at the new row's arrival offset before it went.

The strip is now in an `NSHostingView` of its own (`StripHost`). A switch
pictures it before writing anything and sets the turn off from that picture
at once, with the page put up first (PageStills): the plate springs to the
new name's width, the names turn, the old row rides the plate's edge and
dims, in a layer-hosting view over the host, by the render server. Once the
window's pass has laid the strip out for the new space it is pictured again
and the new row comes in on the plate's edge as the old one goes; the turn
lands when its last animation does and the strip itself shows. Set off
after the writes, its flush laid the whole window out first; picturing the
host while it was hidden by its alpha drew nothing; a completion block set
after the animations fired at once. The SwiftUI turn remains for the bench
(`strip-turn` cut `layers`) and when a picture can't be made.

Films (`ab.sh`, adhd and m4): the strip moves in the frame the page
changes, 19 to 29 ms after the key against main's 80 to 90; the new row is
in by 85 to 130 ms; settled by 230 to 300 ms, as Dia (265 to 300).
`perf_ab.sh` on adhd, three rounds of eight switches, medians: 141, 141 and
133 ms on main, 123, 118 and 115 ms with the turn.

Not verified: a real trackpad (posted scroll events), hover in dark
(the pointer state was not caught in that film).

## #822: a mouse's side wheel skipped several spaces

The reporter's mouse has a thumb wheel: one steady turn went two or three
spaces, and only a turn of just the right size went one.

**Cause.** A push ended at any gap longer than 65 ms, and every new push
could turn the space again. A hand turning a wheel on leaves 80 to 150 ms
between notches, so one turn was cut into several pushes, each of which
added up to 2 lines or 10 points and turned a space.

**Fix.** The 65 ms rule (`SpaceWheel.Rule.gather`) now holds only before
the first turn, so a stray notch still turns nothing. Once the space has
turned, the push goes on while moves come within 200 ms of each other
(`quiet`), and it turns nothing for 250 ms (`hold`). Moves after that add
up again for the next space, so turning on and on repeats the way a held
key does: one space at once, then one per hold. A move the other way, or a
pause longer than `quiet`, starts a new push that turns at once.
`SpaceWheelTests` plays a hand's uneven turn, a long steady turn and the
cases at the edges of each rule.

## Two fingers sideways, then up or down: the old space scrolled

Reported with the side-wheel fix: a swipe sideways over the column, halfway
to the next space, that drifted up or down scrolled the rows of the space
being left, and the column seemed stuck.

**Cause.** The column's catch never took an event. Its monitor returned
`self?.heard(event) ?? event`; optional chaining folds `heard`'s nil (the
event taken) into the nil of a catch that is gone, and the `??` handed the
event back. A debug build's log of two such swipes (`taken` false for all
323 events the catch judged, 314 of them while it held the row of spaces)
had 705 moves with fingers down and 188 of the glide after reach the rows'
scroll view through the window's own dispatch. Sideways moves did nothing
there; the drift up or down scrolled the rows.

**Fix.** The monitor returns what `heard` returns. A sideways swipe's
moves are the catch's alone, its drift with them, and so are the glide's
after the fingers lift (`SwipeGlide`), until the glide ends or fingers come
down again. A mouse's side buttons over the column now only turn the space,
as their comment always said.

**Its end.** With the catch really taking events, a swipe could reach the
rows only in part. A began with no move in it (the bench's swipe and
`hand.py`'s send one) goes on to the rows before the catch knows which way
the fingers go, and their scroll view opens a gesture. When the moves after
it went sideways the catch took them and the end too, and the rows were
left in a gesture that never closed. Now the catch still takes a sideways
began, which owes the rows nothing, but when the rows heard the began it
hands them the swipe's end or cancel (`SwipeEnd`). The space turns as
before: the catch acts on the end, then lets it through. The glide after
stays held back (`SwipeGlide`). The row of spaces is let go once: the catch
releases SpacePager before returning the end, and if SpacePager's monitor
hears the end first, it only lets go later, after checking that the same
swipe still holds the row (`SpacePager.parting`).
