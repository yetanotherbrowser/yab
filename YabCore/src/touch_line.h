#ifndef YABCORE_TOUCH_LINE_H_
#define YABCORE_TOUCH_LINE_H_
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
//  - contact 0 is never left held for a finger that is gone. A start that
//    fails, or an end that proves nothing, is followed at once by a cancel.
//    A lift of a gesture that is not going out (its start failed or was
//    refused) goes out as a cancel while contact 0 may be held. A cancel
//    that proves nothing is not sent again by itself: the next lift or start
//    sends the next one.
namespace yabcore {

enum class TouchKind { kStart, kMove, kEnd, kCancel };

struct TouchStep {
  TouchKind kind = TouchKind::kMove;
  uint64_t gesture = 0;  // the client's number for the finger's gesture
  double x = 0, y = 0;   // page points; a lift has none
  bool cleared = false;  // a start's: the cancel ahead of it was answered
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
  bool held = false;      // Chromium may hold contact 0
  bool owed = false;      // held with no gesture going out: a cancel goes next
  uint64_t live = 0;      // the gesture whose steps go out; 0 for none
  uint64_t document = 0;  // the tab's document when its start went out
  double scale = 1;       // page points per CSS pixel, read for its start

  // A step joins the line. A move right behind a waiting move of its gesture
  // takes that one's place.
  void Add(TouchStep step) {
    if (step.kind == TouchKind::kMove && !waiting.empty() && waiting.back().kind == TouchKind::kMove &&
        waiting.back().gesture == step.gesture) {
      waiting.back() = step;
      return;
    }
    waiting.push_back(step);
  }

  // What comes next. `now` is the tab's document (Tab::documentGeneration).
  Next Decide(uint64_t now, TouchStep& out) {
    if (busy) return Next::kWait;
    const bool start = !waiting.empty() && waiting.front().kind == TouchKind::kStart;
    if (start) live = 0;  // what is left of an earlier gesture is dropped
    if (held && (owed || (start && !waiting.front().cleared))) {
      owed = false, busy = true;
      if (start) waiting.front().cleared = true;
      return Next::kClear;
    }
    owed = false;
    if (waiting.empty()) return Next::kWait;
    if (start) {
      if (held) return out = Take(), Next::kRefuse;
      busy = true;
      return Next::kPlace;
    }
    out = Take();
    if (out.gesture != live) {
      // Its start failed or was refused: its lift lets go of what Chromium may hold.
      if (out.kind == TouchKind::kMove || !held || live) return Next::kDrop;
      out.kind = TouchKind::kCancel;
    } else if (document != now) {
      out.kind = TouchKind::kCancel;  // its document is gone
    }
    if (out.kind != TouchKind::kMove) live = 0;
    busy = true;
    return Next::kSend;
  }

  // The zoom for the start in front was read: send it, on the tab's document
  // `now`.
  TouchStep Placed(uint64_t now, double pointsPerPixel) {
    TouchStep out = Take();
    live = out.gesture, document = now, scale = pointsPerPixel, held = true, busy = true;
    return out;
  }

  // The zoom for the start in front could not be read: refuse it.
  void NotPlaced(TouchStep& out) { out = Take(), busy = false; }

  // Chromium answered what went out. `released`: the answer to a lift (or a
  // cancel of no step) proves it holds no contact.
  void Answered(TouchKind sent, bool ok, bool released) {
    busy = false;
    if (sent == TouchKind::kStart && !ok) live = 0, owed = true;
    if (sent == TouchKind::kEnd && !released) owed = true;
    if (sent != TouchKind::kStart && sent != TouchKind::kMove && released) held = false;
  }

 private:
  TouchStep Take() {
    TouchStep step = waiting.front();
    waiting.pop_front();
    return step;
  }
};

}  // namespace yabcore
#endif
