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
  line.Answered(kCancel, false, false);
  CHECK(line.Decide(5, out) == Next::kClear);  // the lift went out as a cancel
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

// A page leaving its window sends a cancel. If the start is still waiting
// for zoom, the whole gesture goes away and the old read cannot place a new one.
static void CancelWhileReadingZoom() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  CHECK(line.Decide(5, out) == Next::kPlace);
  const auto read = line.placement;
  line.Add(Step(kMove, 1, 2));
  line.Add(Step(kCancel, 1, 3));
  CHECK(!line.IsPlacing(read) && !line.held);
  CHECK(line.Decide(5, out) == Next::kDrop && out.kind == kCancel);
  CHECK(line.Decide(5, out) == Next::kWait);
  line.Add(Step(kStart, 2, 4));
  CHECK(line.Decide(5, out) == Next::kPlace);
  CHECK(!line.IsPlacing(read) && line.IsPlacing(line.placement));
  CHECK(line.Placed(5, 1).x == 4);
}

// A cancel can also drop a start queued behind an earlier gesture's answer.
static void CancelWhileStartIsQueued() {
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kEnd, 1, 1));
  CHECK(line.Decide(5, out) == Next::kSend);
  line.Add(Step(kStart, 2, 2));
  line.Add(Step(kMove, 2, 3));
  line.Add(Step(kStart, 3, 4));
  line.Add(Step(kCancel, 2, 5));
  line.Answered(kEnd, true, true);
  CHECK(line.Decide(5, out) == Next::kPlace);
  CHECK(line.Placed(5, 1).gesture == 3);
}

// Gesture 2 never starts. Its interruption still has to release the
// contact left over from gesture 1 if the cancel in flight proves nothing.
static void InterruptQueuedStartDuringCleanup() {
  enum Action { cancel, reset, hide, retainedClose };
  for (auto action : {cancel, reset, hide, retainedClose}) {
    for (bool released : {false, true}) {
      TouchLine line;
      TouchStep out;
      Started(line, 1);
      line.Add(Step(kEnd, 1, 1));
      CHECK(line.Decide(5, out) == Next::kSend);
      line.Answered(kEnd, false, false);
      CHECK(line.Decide(5, out) == Next::kClear);
      line.Answered(kCancel, false, false);
      line.Add(Step(kStart, 2, 2));
      CHECK(line.Decide(5, out) == Next::kClear);
      line.Add(Step(kMove, 2, 3));
      line.Add(Step(kCancel, 2, 4));
      if (action == reset || action == retainedClose) line.ResetThrough(2);
      if (action == hide || action == retainedClose) line.Interrupt();
      CHECK(line.Decide(5, out) == Next::kWait);
      line.Answered(kCancel, released, released);
      if (action == retainedClose) line.Interrupt();  // pump still sees a closing tab
      const Next next = line.Decide(5, out);
      if (!released) {
        CHECK(action == cancel ? next == Next::kSend && out.kind == kCancel : next == Next::kClear);
        if (next == Next::kSend || next == Next::kClear) line.Answered(kCancel, true, true);
      } else {
        CHECK(action == cancel ? next == Next::kDrop : next == Next::kWait);
      }
      CHECK(!line.held && line.Decide(5, out) == Next::kWait);
    }
  }
}

// The previous gesture can still be live when the queued start is canceled.
// If its queued end then fails, the canceled gesture still gets a chance to
// release the contact. If the previous gesture stays live, leave it alone.
static void CancelQueuedStartWhilePreviousGestureIsLive() {
  for (bool lift : {false, true}) {
    TouchLine line;
    TouchStep out;
    Started(line, 1);
    line.Add(Step(kMove, 1, 1));
    CHECK(line.Decide(5, out) == Next::kSend);
    if (lift) line.Add(Step(kEnd, 1, 2));
    line.Add(Step(kStart, 2, 3));
    line.Add(Step(kCancel, 2, 4));
    line.Answered(kMove, true, false);
    if (lift) {
      CHECK(line.Decide(5, out) == Next::kSend && out.kind == kEnd);
      line.Answered(kEnd, false, false);
      CHECK(line.Decide(5, out) == Next::kClear);
      line.Answered(kCancel, false, false);
      CHECK(line.Decide(5, out) == Next::kSend && out.kind == kCancel && out.gesture == 2);
      line.Answered(kCancel, true, true);
      CHECK(!line.held);
    } else {
      CHECK(line.Decide(5, out) == Next::kDrop && out.kind == kCancel);
      CHECK(line.held && line.live == 1);
    }
    CHECK(line.Decide(5, out) == Next::kWait);
  }
}

static void HideWhileReadingZoom() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  CHECK(line.Decide(5, out) == Next::kPlace);
  const auto read = line.placement;
  line.Add(Step(kMove, 1, 2));
  line.Add(Step(kEnd, 1, 3));
  line.Interrupt();
  CHECK(!line.IsPlacing(read) && !line.held);
  CHECK(line.Decide(5, out) == Next::kWait);
  Started(line, 2);
}

static void InterruptWhileMoveIsOut() {
  for (bool hide : {false, true}) {
    TouchLine line;
    TouchStep out;
    Started(line, 1);
    line.Add(Step(kMove, 1, 1));
    CHECK(line.Decide(5, out) == Next::kSend);
    line.Add(Step(kMove, 1, 2));
    if (hide) {
      line.Add(Step(kStart, 2, 3));
      line.Interrupt();
    } else {
      line.Add(Step(kCancel, 1, 3));
    }
    CHECK(line.Decide(5, out) == Next::kWait);
    line.Answered(kMove, true, false);
    const Next next = line.Decide(5, out);
    CHECK(hide ? next == Next::kClear : next == Next::kSend && out.kind == kCancel);
    line.Answered(kCancel, true, true);
    CHECK(!line.held && line.Decide(5, out) == Next::kWait);
  }
}

// A lift in flight can prove release and save a redundant cancel on hide.
static void HideWhileEndIsOut() {
  TouchLine line;
  TouchStep out;
  Started(line, 1);
  line.Add(Step(kEnd, 1, 1));
  CHECK(line.Decide(5, out) == Next::kSend);
  line.Interrupt();
  line.Answered(kEnd, true, true);
  CHECK(!line.held && line.Decide(5, out) == Next::kWait);
}

// Reparenting resets a lifted swipe while its move is still out. A helper
// hide or a native close that keeps the tab can erase the same queued lift.
static void ResetReplacesQueuedEnd() {
  enum Action { reparent, hide, retainedClose };
  enum Release { first, followUp, neither };
  for (auto action : {reparent, hide, retainedClose}) {
    for (auto release : {first, followUp, neither}) {
      TouchLine line;
      TouchStep out;
      Started(line, 1);
      line.Add(Step(kMove, 1, 1));
      CHECK(line.Decide(5, out) == Next::kSend && out.kind == kMove);
      line.Add(Step(kEnd, 1, 2));
      if (action != hide) line.ResetThrough(1);
      if (action != reparent) line.Interrupt();
      CHECK(line.waiting.empty() && line.Decide(5, out) == Next::kWait);
      line.Answered(kMove, true, false);
      if (action == retainedClose) line.Interrupt();  // pump still sees a closing tab
      CHECK(line.Decide(5, out) == Next::kClear);
      line.Answered(kCancel, false, release == first);
      if (action == retainedClose) line.Interrupt();
      if (release != first) {
        CHECK(line.held && line.Decide(5, out) == Next::kClear);
        line.Answered(kCancel, release == followUp, release == followUp);
        if (action == retainedClose) line.Interrupt();
      }
      CHECK(line.held == (release == neither));
      CHECK(line.Decide(5, out) == Next::kWait);
    }
  }
}

// A queued cancel can erase the lift, or the lift itself can go out as a
// cancel after navigation. Both keep the lift's one follow-up cancel.
static void CancelInPlaceOfEnd() {
  for (bool navigation : {false, true}) {
    TouchLine line;
    TouchStep out;
    Started(line, 1);
    line.Add(Step(kMove, 1, 1));
    CHECK(line.Decide(5, out) == Next::kSend && out.kind == kMove);
    line.Add(Step(kEnd, 1, 2));
    if (!navigation) {
      line.Add(Step(kCancel, 1, 3));
      line.Add(Step(kCancel, 1, 4));  // replacing the cancel also keeps the lift's follow-up
    }
    line.Answered(kMove, true, false);
    const auto now = navigation ? 6 : 5;
    CHECK(line.Decide(now, out) == Next::kSend && out.kind == kCancel);
    line.Answered(kCancel, false, false);
    CHECK(line.Decide(now, out) == Next::kClear);
    line.Answered(kCancel, false, false);
    CHECK(line.held && line.Decide(now, out) == Next::kWait);
  }
}

// A lifted gesture can have its start, move and end waiting on zoom. A
// reparent retires all three, including old steps that arrive after reset.
static void ResetWhileReadingZoom() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  CHECK(line.Decide(5, out) == Next::kPlace);
  const auto old = line.placement;
  line.Add(Step(kMove, 1, 2));
  line.Add(Step(kEnd, 1, 3));
  line.ResetThrough(1);
  CHECK(!line.AcceptPlacement(old, true));
  line.Add(Step(kStart, 1, 4));
  line.Add(Step(kMove, 1, 5));
  line.Add(Step(kCancel, 1, 6));
  CHECK(line.waiting.empty() && line.Decide(5, out) == Next::kWait);
  Started(line, 2);
  line.ResetThrough(1);
  CHECK(line.live == 2 && line.held && !line.owed);
}

// Once a zoom reply is consumed during close, a retained tab must be able
// to place a fresh start. A late callback cannot act on that new placement.
static void ZoomReplyDuringClose() {
  TouchLine line;
  TouchStep out;
  line.Add(Step(kStart, 1, 1));
  line.Add(Step(kMove, 1, 2));
  CHECK(line.Decide(5, out) == Next::kPlace);
  const auto closing = line.placement;
  CHECK(!line.AcceptPlacement(closing, false));
  CHECK(line.waiting.empty() && !line.placing && !line.busy && !line.held);
  line.Add(Step(kStart, 2, 3));
  CHECK(line.Decide(5, out) == Next::kPlace);
  CHECK(!line.AcceptPlacement(closing, true));
  CHECK(line.AcceptPlacement(line.placement, true));
  CHECK(line.Placed(5, 1).gesture == 2);
}

static void RetainedCloseRejectsLateSteps() {
  TouchLine line;
  TouchStep out;
  // The client queued the reset before the batch, while gesture 2 was
  // still waiting on the client. Native commit then clears the line.
  line.ResetThrough(2);
  line.Interrupt();
  // Native close retained the tab. Neither old start can place here.
  for (uint64_t gesture : {1, 2}) {
    line.Add(Step(kStart, gesture, 1));
    line.Add(Step(kMove, gesture, 2));
    line.Add(Step(kEnd, gesture, 3));
  }
  CHECK(line.waiting.empty() && line.Decide(6, out) == Next::kWait);
  Started(line, 3);
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
  CancelWhileReadingZoom();
  CancelWhileStartIsQueued();
  InterruptQueuedStartDuringCleanup();
  CancelQueuedStartWhilePreviousGestureIsLive();
  HideWhileReadingZoom();
  InterruptWhileMoveIsOut();
  HideWhileEndIsOut();
  ResetReplacesQueuedEnd();
  CancelInPlaceOfEnd();
  ResetWhileReadingZoom();
  ZoomReplyDuringClose();
  RetainedCloseRejectsLateSteps();
  StaleLiftLeavesTheLiveGesture();
  StartAfterTheDocumentChanged();
  ZoomReadFails();
  DocumentGoesMidGesture();
  if (failures) fprintf(stderr, "%d failed\n", failures);
  return failures ? 1 : 0;
}
