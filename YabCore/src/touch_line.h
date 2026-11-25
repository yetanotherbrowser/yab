#ifndef YABCORE_TOUCH_LINE_H_
#define YABCORE_TOUCH_LINE_H_
#include <algorithm>
#include <cstdint>
#include <deque>

// A page's one finger (input.send's touch kinds), sent to Chromium one touch
// event at a time with Input.dispatchTouchEvent.
//
// Each touch event used to read the zoom and go out on its own, and was
// decided from the tab's state whenever its answers came back: a late answer
// let one gesture's event act on the next gesture, moves went out before
// Chromium had answered their start, and a start went out before the cancel
// ahead of it was answered. A tab's touch events now wait in one line. The
// next one is decided only once the one before it is answered, and it acts
// only on its own gesture. Moves waiting behind it merge into the latest, so
// a swipe does not fall behind the finger. The client's request is answered
// as its step joins the line, so nothing the client queues behind it waits
// for Chromium's touch answers.
//
// The zoom is read once a gesture, for its start. One finger never pinches,
// so the page's scale holds for the gesture; a zoom changed by other means in
// the middle of one applies from the next gesture on. Lifts have no point.
//
// A gesture stays on the tab's document its start went out on: once that
// document goes (Tab::documentGeneration moves), its next step goes out as a
// cancel and the rest of it is dropped. A start names no document, so one
// that waited in line while a navigation committed goes to the new document,
// as a mouse press queued then does.
//
// What Chromium 156 holds (content/browser/devtools/protocol/input_handler.cc
// at 156.0.8078.48): CreateWebTouchEvents records or forgets the contact in
// touch_points_ (lines 593-613) before the event is sent, and only then can
// the dispatch fail, with an internal error (1700-1702 no widget or view,
// 1739-1741 no target at the point, 802-804 the injector's widget gone). A
// lift with no points finds touch_points_ empty and is refused with "Must send
// a TouchStart first" (541-545), or clears it (601-613). A start while it
// holds contact 0 is taken as a move of it (263-268). So:
//  - a start may leave contact 0 held whatever Chromium answers: `held` is set
//    as the start goes out;
//  - a lift answered with success, an internal error or "Must send a
//    TouchStart first" leaves nothing held. Any other answer (the method not
//    found, the session gone, a timeout) proves nothing;
//  - no start goes out while `held`: a cancel goes first, the start waits for
//    its answer, and is refused if that answer does not prove the release;
//  - A failed start or an unproven end is followed at once by a cancel.
//    A cancel from a reset or in place of an end gets the same follow-up.
//    A lift of a gesture that is not going out (its start failed or was
//    refused or removed from the line) goes out as a cancel while contact 0
//    may be held and no other gesture is live. If the follow-up proves
//    nothing, the next lift or start can send another cancel.
namespace yabcore {

enum class TouchKind { kStart, kMove, kEnd, kCancel };

struct TouchStep {
  TouchKind kind = TouchKind::kMove;
  uint64_t gesture = 0;  // the client's number for the finger's gesture
  double x = 0, y = 0;   // page points; a lift has none
  bool cleared = false;  // a start's: the cancel ahead of it was answered
  bool replacesEnd = false;  // a cancel's: it erased an end from the line
};

struct TouchLine {
  enum class Next {
    kWait,    // a step is out, or none is waiting
    kClear,   // send a cancel of no step: ahead of the start in front, or for a contact left held
    kPlace,   // read the zoom for the start in front, then Placed() or NotPlaced()
    kSend,    // send `out`, taken off the line, as its kind
    kRefuse,  // `out`, a start, is refused while contact 0 may be held: nothing sent
    kDrop,    // `out` is a step of a gesture that is over: nothing sent
  };

  std::deque<TouchStep> waiting;
  bool busy = false;      // a step or a cancel of no step is out
  bool placing = false;   // the start in front is waiting for its zoom
  uint64_t placement = 0; // identifies the zoom read, even across hides
  bool held = false;      // Chromium may hold contact 0
  int owed = 0;           // cancels still to send unless the current release is proven
  uint64_t live = 0;      // the gesture whose steps go out; 0 for none
  uint64_t document = 0;  // the tab's document when its start went out
  double scale = 1;       // page points per CSS pixel, read for its start

  // A cancel drops its gesture's waiting steps. Decide still needs the
  // cancel if an earlier answer leaves a contact held with no live gesture.
  // A move replaces a waiting move just ahead of it.
  void Add(TouchStep step) {
    if (step.gesture <= interruptedThrough) return;
    if (step.kind == TouchKind::kCancel) {
      if (placing && waiting.front().gesture == step.gesture) placing = false;
      std::erase_if(waiting, [&](const TouchStep& queued) {
        if (queued.gesture != step.gesture) return false;
        if (queued.kind == TouchKind::kEnd || queued.replacesEnd) step.replacesEnd = true;
        return true;
      });
    }
    if (step.kind == TouchKind::kMove && !waiting.empty() && waiting.back().kind == TouchKind::kMove &&
        waiting.back().gesture == step.gesture) {
      waiting.back() = step;
      return;
    }
    waiting.push_back(step);
  }

  // A window change or hide can overtake steps still queued in the client.
  void ResetThrough(uint64_t gesture) {
    if (gesture <= interruptedThrough) return;
    interruptedThrough = gesture;
    interrupted = false;
    Interrupt();
  }

  // Drop every waiting step and invalidate any zoom read.
  // If a touch is already out, its answer can settle the hold before we cancel.
  void Interrupt() {
    // A closing tab can run this again on each answer. Keep the existing
    // allowance, including when an end or its replacement is already out.
    if (held && (!interrupted || !waiting.empty()) && !(busy && owed)) owed = 2;
    interrupted = true;
    waiting.clear();
    placing = false;
    live = 0;
  }

  // What comes next. `now` is the tab's document (Tab::documentGeneration).
  Next Decide(uint64_t now, TouchStep& out) {
    if (busy || placing) return Next::kWait;
    const bool start = !waiting.empty() && waiting.front().kind == TouchKind::kStart;
    if (start) live = 0;  // what is left of an earlier gesture is dropped
    if (held && (owed || (start && !waiting.front().cleared))) {
      if (owed) --owed;
      busy = true;
      if (start) waiting.front().cleared = true;
      return Next::kClear;
    }
    if (waiting.empty()) return Next::kWait;
    if (start) {
      if (held) return out = Take(), Next::kRefuse;
      placing = true;
      ++placement;
      return Next::kPlace;
    }
    out = Take();
    const bool followsEnd = out.kind == TouchKind::kEnd || out.replacesEnd;
    if (out.gesture != live) {
      // Its start failed or was refused: its lift lets go of what Chromium may hold.
      if (out.kind == TouchKind::kMove || !held || live) return Next::kDrop;
      out.kind = TouchKind::kCancel;
    } else if (document != now) {
      out.kind = TouchKind::kCancel;  // its document is gone
    }
    if (out.kind != TouchKind::kMove) live = 0;
    if (followsEnd) owed = 1;
    busy = true;
    return Next::kSend;
  }

  // An interrupted zoom read may answer while another start is in front.
  bool IsPlacing(uint64_t read) const { return placing && placement == read; }

  // A close can retain its tab. Consume the read even while it is closing,
  // so a later gesture cannot wait on a reply that already came back.
  bool AcceptPlacement(uint64_t read, bool canSend) {
    if (!IsPlacing(read)) return false;
    if (!canSend) Interrupt();
    return canSend;
  }

  // The zoom for the start in front was read. Send it on document `now`.
  TouchStep Placed(uint64_t now, double pointsPerPixel) {
    TouchStep out = Take();
    placing = false;
    interrupted = false;
    live = out.gesture, document = now, scale = pointsPerPixel, held = true, busy = true;
    return out;
  }

  // The zoom for the start in front could not be read: refuse it.
  void NotPlaced(TouchStep& out) { out = Take(), placing = false; }

  // Chromium answered what went out. `released`: the answer to a lift (or a
  // cancel of no step) proves it holds no contact.
  void Answered(TouchKind sent, bool ok, bool released) {
    busy = false;
    if (sent == TouchKind::kStart && !ok) {
      live = 0;
      if (!owed) owed = 1;
    }
    if (sent != TouchKind::kStart && sent != TouchKind::kMove && released) held = false, owed = 0;
  }

 private:
  uint64_t interruptedThrough = 0;
  bool interrupted = false;  // an empty line can be interrupted again while closing

  TouchStep Take() {
    TouchStep step = waiting.front();
    waiting.pop_front();
    return step;
  }
};

}  // namespace yabcore
#endif
