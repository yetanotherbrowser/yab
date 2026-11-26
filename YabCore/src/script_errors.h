#pragma once
#import <Foundation/Foundation.h>
#include <cstdlib>
#include <utility>

// Renderer/session changes can discard document-start registrations before
// the next install removes their IDs. Removing an absent registration is
// already complete. Do not suppress add failures or other protocol errors.
static inline bool ScriptRemovalAlreadyGone(NSString* method, NSString* error) {
  if (![method isEqualToString:@"Page.removeScriptToEvaluateOnNewDocument"] || !error) return false;
  NSData* data = [error dataUsingEncoding:NSUTF8StringEncoding];
  id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![value isKindOfClass:NSDictionary.class]) return false;
  id code = value[@"code"], message = value[@"message"];
  return [code isKindOfClass:NSNumber.class] && [code intValue] == -32000 &&
         [message isKindOfClass:NSString.class] && [message isEqualToString:@"Script not found"];
}

// The target behind a CDP session is gone: Chromium's answer to a command
// sent on a session whose frame or worker has detached.
static inline bool ScriptSessionGone(NSString* error) {
  if (!error) return false;
  NSData* data = [error dataUsingEncoding:NSUTF8StringEncoding];
  id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![value isKindOfClass:NSDictionary.class]) return false;
  id code = value[@"code"], message = value[@"message"];
  return [code isKindOfClass:NSNumber.class] && [code intValue] == -32001 &&
         [message isKindOfClass:NSString.class] && [message isEqualToString:@"Session with given id not found."];
}

// A multi-target install/appearance update must not fail the main document
// when an iframe disappears during its outstanding CDP commands. Definitions
// remain on the tab and ScriptAttach installs them in replacement targets.
// Keep every main-session error and errors from a still-live child target.
static inline bool ScriptSessionErrorMatters(NSString* session, bool attached, NSString* error) {
  if (!error) return false;
  if (!session.length) return true;
  if (!attached) return false;
  // The error can arrive before Target.detachedFromTarget.
  return !ScriptSessionGone(error);
}

// Runtime.enable, which Yab's agent needs for its worlds and bindings, also
// sets V8's stack capture to 200 frames for the whole renderer: every Error
// made and every exception thrown through a verbose TryCatch then records a
// detailed stack trace (V8Debugger::setMaxCallStackSizeToCapture,
// Isolate::CaptureAndSetErrorStack), on every page and every frame, the
// extensions' content scripts in them too. Chrome with DevTools closed
// captures none, and nothing in Yab reads those traces. V8 offers this call
// to an agent that drives a page and wants none of that overhead
// (bit.ly/v8-cheaper-inspector-stack-traces); a DevTools window the person
// opens enables its own Runtime and gets its 200 frames back, as in Chromium.
// Sent right after each Runtime.enable. Optional: an engine without it
// keeps the old behaviour, it never fails the agent's setup.
static inline std::pair<NSString*, NSDictionary*> StackCaptureOff() {
  return {@"Runtime.setMaxCallStackSizeToCapture", @{@"size": @0}};
}
// YAB_CEF_V8_STACKS=1 keeps V8's 200 frames, for an A/B on one build.
static inline bool StackCaptureKept() { return getenv("YAB_CEF_V8_STACKS") != nullptr; }
static inline bool StackCaptureOptional(NSString* method) {
  return [method isEqualToString:@"Runtime.setMaxCallStackSizeToCapture"];
}

// Evaluations bind thrown objects even with returnByValue. Synchronous throws
// may bind the same object twice, once in result and once in exceptionDetails.
// A normal caller keeps explicit by-reference results (file fields, window
// proxies); a response arriving after its caller left has no such owner.
static inline NSArray<NSString*>* ScriptResultObjects(NSDictionary* result, bool discarded = false) {
  if (![result isKindOfClass:NSDictionary.class]) return @[];
  NSDictionary* details = [result[@"exceptionDetails"] isKindOfClass:NSDictionary.class] ? result[@"exceptionDetails"] : nil;
  if (!details && !discarded) return @[];
  NSMutableArray<NSString*>* objects = [NSMutableArray new];
  for (id remote in @[result[@"result"] ?: NSNull.null, details[@"exception"] ?: NSNull.null]) {
    if (![remote isKindOfClass:NSDictionary.class]) continue;
    id object = remote[@"objectId"];
    if ([object isKindOfClass:NSString.class] && [object length] && ![objects containsObject:object]) [objects addObject:object];
  }
  return objects;
}
