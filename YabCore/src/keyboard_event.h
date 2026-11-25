#ifndef YABCORE_KEYBOARD_EVENT_H_
#define YABCORE_KEYBOARD_EVENT_H_
#import <AppKit/AppKit.h>
#include <functional>
#include <vector>

struct QueuedKeyboardEvent {
  CGEventTimestamp stamp = 0;
  NSEventType type;
  unsigned short code = 0;
  NSEvent* __strong native = nil;
  // The editing commands Yab's input context read from a keydown (key_commands.h).
  NSArray<NSString*>* __strong commands = nil;
  std::function<void()> edit;
  std::function<void()> canceled;
  ~QueuedKeyboardEvent() { if (canceled) canceled(); }
};

static CGEventTimestamp KeyboardEventStamp(NSEvent* event) {
  return event.CGEvent ? CGEventGetTimestamp(event.CGEvent) : 0;
}

// An AppKit envelope is ours even if its original widget closes before
// dispatch. AppKit may copy NSEvents; CGEvent user data survives that copy.
// Only a matching retained payload may reach a view. Retired envelopes are
// consumed by the monitor instead of falling through to a reused window id.
static constexpr int64_t kHostedKeyboardEnvelope = 0x5961624b65797301;
static bool KeyboardEnvelopeOwned(NSEvent* event) {
  return event.CGEvent && CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUserData) == kHostedKeyboardEnvelope;
}
static NSEvent* KeyboardEnvelopeMark(NSEvent* event) {
  CGEventRef cg = event.CGEvent ? CGEventCreateCopy(event.CGEvent) : nullptr;
  if (!cg) return event;
  CGEventSetIntegerValueField(cg, kCGEventSourceUserData, kHostedKeyboardEnvelope);
  NSEvent* marked = [NSEvent eventWithCGEvent:cg];
  CFRelease(cg);
  return marked ?: event;
}

// The original native event, as Chromium's remote Cocoa transports it
// (ui/events/cocoa/cocoa_event_utils.mm). Its Unicode payload is part of the
// CGEvent, not just NSEvent.characters. AppKit's interpretKeyEvents reads it.
static NSEvent* KeyboardEventDecode(NSDictionary* params, NSEventType expected) {
  id bytes = params[@"event"];
  if (![bytes isKindOfClass:NSString.class] || [bytes length] > 16384) return nil;
  NSData* data = [[NSData alloc] initWithBase64EncodedString:bytes options:0];
  CGEventRef cg = data.length ? CGEventCreateFromData(kCFAllocatorDefault, (__bridge CFDataRef)data) : nullptr;
  if (!cg) return nil;
  CGEventType type = expected == NSEventTypeKeyDown ? kCGEventKeyDown :
      expected == NSEventTypeKeyUp ? kCGEventKeyUp : kCGEventFlagsChanged;
  // AppKit's characters are authoritative. Its CGEvent accessor may encode
  // only the physical key for a supplementary character. Reconcile that
  // representation before the native input context interprets the event.
  if (CGEventGetType(cg) == type && expected != NSEventTypeFlagsChanged) {
    NSString* text = params[@"characters"] ?: @"";
    std::vector<UniChar> units(text.length);
    if (!units.empty()) [text getCharacters:units.data() range:NSMakeRange(0, text.length)];
    CGEventKeyboardSetUnicodeString(cg, units.size(), units.data());
  }
  NSEvent* event = CGEventGetType(cg) == type ? [NSEvent eventWithCGEvent:cg] : nil;
  CFRelease(cg);
  return event.type == expected ? event : nil;
}

#endif
