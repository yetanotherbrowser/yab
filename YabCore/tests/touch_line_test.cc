#include "touch_line.h"
#include <cstdio>

// A page's one finger goes to Chromium one touch event at a time, each acting
// only on its own gesture, never a start while Chromium may hold the last
// finger, and never contact 0 left held for a finger that is gone (#711).
using yabcore::TouchKind;
using yabcore::TouchLine;
using yabcore::TouchStep;
using Next = TouchLine::Next;

static int failures = 0;
#define CHECK(condition) \
  ((condition) ? (void)0 : (void)(++failures, fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition)))

// `id` names the step (its x); a lift keeps it too.
static TouchStep Step(TouchKind kind, uint64_t gesture, double id) {
  TouchStep step;
  step.kind = kind, step.gesture = gesture;
  step.x = id, step.y = 20;
  return step;
}
static constexpr TouchKind kStart = TouchKind::kStart, kMove = TouchKind::kMove, kEnd = TouchKind::kEnd,
                           kCancel = TouchKind::kCancel;

// A start out and answered with success on document 5.
static void Started(TouchLine& line, uint64_t gesture) {
  TouchStep out;
  line.Add(Step(kStart, gesture, 0));
  CHECK(line.Decide(5, out) == Next::kPlace);
  CHECK(line.Placed(5, 1).gesture == gesture);
  line.Answered(kStart, true, false);
}

// A swipe: each step waits for the answer before it, and moves waiting
// behind one merge into the latest.
static void Swipe() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  CHECK(line.Decide(5, out) == Next::kPlace);
  line.Add(Step(kMove, 1, 2));
  line.Add(Step(kMove, 1, 3));
  line.Add(Step(kEnd, 1, 4));
  line.Add(Step(kMove, 2, 5));  // after an end, and another gesture's: not merged
  CHECK(line.waiting.size() == 4);
  CHECK(line.Decide(5, out) == Next::kWait);
  out = line.Placed(5, 2.0);
  CHECK(out.x == 1 && out.kind == kStart);
  CHECK(line.held && line.live == 1 && line.scale == 2.0);
  CHECK(line.Decide(5, out) == Next::kWait);  // the start's answer is not back
  line.Answered(kStart, true, false);
  CHECK(line.Decide(5, out) == Next::kSend && out.x == 3 && out.kind == kMove);
  line.Answered(kMove, true, false);
  CHECK(line.Decide(5, out) == Next::kSend && out.x == 4 && out.kind == kEnd && line.live == 0);
  line.Answered(kEnd, true, true);
  CHECK(!line.held);
  // A step of a gesture that never started applies to nothing.
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 5);
  CHECK(line.Decide(5, out) == Next::kWait);
}

// A start Chromium answered with a failure may have left the finger held
// (Chromium records it before the dispatch can fail): a cancel goes at once,
// before the finger lifts, and the rest of the gesture is dropped.
static void FailedStartCancelsAtOnce() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  CHECK(line.Decide(5, out) == Next::kPlace);
  line.Placed(5, 1);
  line.Add(Step(kMove, 1, 2));
  line.Answered(kStart, false, false);
  CHECK(line.held && line.live == 0);
  CHECK(line.Decide(5, out) == Next::kClear);  // nothing waits for the lift
  line.Answered(kCancel, true, true);
  CHECK(!line.held);
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 2);
  line.Add(Step(kEnd, 1, 3));
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 3);  // released: nothing more to send
  CHECK(line.Decide(5, out) == Next::kWait);
}

// The finger lifts and no other swipe follows. If the cancel after the failed
// start proved nothing, the lift goes out as a cancel: nothing is left held
// waiting for a later start.
static void FailedStartThenLift() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  line.Decide(5, out), line.Placed(5, 1);
  line.Add(Step(kMove, 1, 2));
  line.Add(Step(kEnd, 1, 3));
  line.Answered(kStart, false, false);
  CHECK(line.Decide(5, out) == Next::kClear);
  line.Answered(kCancel, false, false);  // the session gone, a timeout: proves nothing
  CHECK(line.held);
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 2);
  CHECK(line.Decide(5, out) == Next::kSend && out.x == 3 && out.kind == kCancel);
  line.Answered(kCancel, true, true);
  CHECK(!line.held);
  CHECK(line.Decide(5, out) == Next::kWait);
}

// A cancel that proves nothing is not sent again by itself.
static void UnprovenCancelIsNotRepeated() {
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kEnd, 1, 1));
  CHECK(line.Decide(5, out) == Next::kSend && out.kind == kEnd);
  line.Answered(kEnd, false, false);
  CHECK(line.Decide(5, out) == Next::kClear);  // an end that proves nothing: a cancel at once
  line.Answered(kCancel, false, false);
  CHECK(line.held);
  CHECK(line.Decide(5, out) == Next::kWait);
  // The next start still cancels first.
  line.Add(Step(kStart, 2, 2));
  CHECK(line.Decide(5, out) == Next::kClear);
}

// A start refused because Chromium may still hold the last finger: its own
// lift lets go of it.
static void RefusedStartsLiftCancels() {
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kEnd, 1, 1));
  line.Decide(5, out), line.Answered(kEnd, false, false);
  line.Decide(5, out), line.Answered(kCancel, false, false);
  line.Add(Step(kStart, 2, 2));
  line.Add(Step(kMove, 2, 3));
  CHECK(line.Decide(5, out) == Next::kClear);
  CHECK(line.Decide(5, out) == Next::kWait);  // the start waits for the cancel's answer
  line.Answered(kCancel, false, false);  // refused before it took effect (the method not found)
  CHECK(line.Decide(5, out) == Next::kRefuse && out.x == 2);
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 3);
  line.Add(Step(kEnd, 2, 4));
  CHECK(line.Decide(5, out) == Next::kSend && out.x == 4 && out.kind == kCancel);
  line.Answered(kCancel, false, true);  // "Must send a TouchStart first"
  CHECK(!line.held);
  // The next start goes without a cancel ahead of it.
  line.Add(Step(kStart, 3, 5));
  CHECK(line.Decide(5, out) == Next::kPlace);
  CHECK(line.Placed(5, 1).x == 5);
}

// The page interrupted (hidden, out of its window) while a start's failure
// left the finger held: its cancel goes out.
static void InterruptionAfterFailedStart() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  line.Decide(5, out), line.Placed(5, 1);
  line.Answered(kStart, false, false);
  CHECK(line.Decide(5, out) == Next::kClear);
  line.Answered(kCancel, false, false);
  line.Add(Step(kCancel, 1, 2));
  CHECK(line.Decide(5, out) == Next::kSend && out.x == 2 && out.kind == kCancel);
}

// The page interrupted mid-gesture: the cancel goes out as it is, and its
// answer decides the hold.
static void InterruptionMidGesture() {
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kCancel, 1, 1));
  CHECK(line.Decide(5, out) == Next::kSend && out.kind == kCancel && line.live == 0);
  line.Answered(kCancel, true, true);
  CHECK(!line.held);
  CHECK(line.Decide(5, out) == Next::kWait);
}

// A lift of an older gesture never cancels the gesture going out.
static void StaleLiftLeavesTheLiveGesture() {
  TouchLine line;
  TouchStep out;
  Started(line, 2);
  line.Add(Step(kEnd, 1, 1));
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 1 && line.live == 2 && line.held);
}

// A start names no document and is never refused for one: a start that
// waited in line while the tab's document changed goes out, and so does one
// whose document changed while its zoom was read. Its gesture then stays on
// the document it went out on.
static void StartAfterTheDocumentChanged() {
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kEnd, 1, 1));
  CHECK(line.Decide(5, out) == Next::kSend && out.kind == kEnd);
  line.Answered(kEnd, true, true);
  line.Add(Step(kStart, 2, 2));
  line.Add(Step(kMove, 2, 3));
  CHECK(line.Decide(9, out) == Next::kPlace);
  out = line.Placed(10, 1);  // another document committed during the zoom read
  CHECK(out.kind == kStart && out.x == 2 && line.live == 2 && line.held);
  line.Answered(kStart, true, false);
  CHECK(line.Decide(10, out) == Next::kSend && out.kind == kMove && out.x == 3);
  line.Answered(kMove, true, false);
  line.Add(Step(kEnd, 2, 4));
  CHECK(line.Decide(10, out) == Next::kSend && out.kind == kEnd && out.x == 4);
}

// Its zoom could not be read: refused, nothing held, no cancel.
static void ZoomReadFails() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  line.Add(Step(kEnd, 1, 2));
  CHECK(line.Decide(5, out) == Next::kPlace);
  line.NotPlaced(out);
  CHECK(out.x == 1 && !line.held && !line.busy);
  CHECK(line.Decide(5, out) == Next::kDrop && out.x == 2);
  CHECK(line.Decide(5, out) == Next::kWait);
}

// The document goes in the middle of a gesture (Tab::documentGeneration
// moved: a navigation committed, or the client asked for one): its next step
// is its cancel, and the rest of it is dropped.
static void DocumentGoesMidGesture() {
  {
    TouchLine line;
    TouchStep out;
    Started(line, 1);
    line.Add(Step(kMove, 1, 1));
    line.Add(Step(kEnd, 1, 2));
    CHECK(line.Decide(6, out) == Next::kSend && out.kind == kCancel && out.x == 1);
    line.Answered(kCancel, true, true);
    CHECK(!line.held);
    CHECK(line.Decide(6, out) == Next::kDrop && out.x == 2);
    CHECK(line.Decide(6, out) == Next::kWait);
  }
  // The cancel proves nothing: the rest of the gesture's lift cancels again.
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kMove, 1, 1));
  line.Add(Step(kEnd, 1, 2));
  CHECK(line.Decide(6, out) == Next::kSend && out.kind == kCancel);
  line.Answered(kCancel, false, false);
  CHECK(line.Decide(6, out) == Next::kSend && out.kind == kCancel && out.x == 2);
}

int main() {
  Swipe();
  FailedStartCancelsAtOnce();
  FailedStartThenLift();
  UnprovenCancelIsNotRepeated();
  RefusedStartsLiftCancels();
  InterruptionAfterFailedStart();
  InterruptionMidGesture();
  StaleLiftLeavesTheLiveGesture();
  StartAfterTheDocumentChanged();
  ZoomReadFails();
  DocumentGoesMidGesture();
  if (failures) fprintf(stderr, "%d failed\n", failures);
  return failures ? 1 : 0;
}
