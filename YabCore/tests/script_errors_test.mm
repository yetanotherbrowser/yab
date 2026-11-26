#import "../src/script_errors.h"
#include <cassert>
#include <cstdio>
int main() {
  @autoreleasepool {
    NSString* remove = @"Page.removeScriptToEvaluateOnNewDocument";
    NSString* missing = @"{\"message\":\"Script not found\",\"code\":-32000}";
    assert(ScriptRemovalAlreadyGone(remove, missing));
    assert(ScriptRemovalAlreadyGone(remove, @"{ \"code\": -32000, \"message\": \"Script not found\" }"));
    assert(!ScriptRemovalAlreadyGone(@"Page.addScriptToEvaluateOnNewDocument", missing));
    assert(!ScriptRemovalAlreadyGone(remove, @"{\"code\":-32000,\"message\":\"Session not found\"}"));
    assert(!ScriptRemovalAlreadyGone(remove, @"{\"code\":-32602,\"message\":\"Script not found\"}"));
    assert(!ScriptRemovalAlreadyGone(remove, @"{\"code\":\"-32000\",\"message\":\"Script not found\"}"));
    assert(!ScriptRemovalAlreadyGone(remove, @"[]"));
    assert(!ScriptRemovalAlreadyGone(remove, @"Script not found"));
    assert(!ScriptRemovalAlreadyGone(remove, nil));
    NSString* gone = @"{\"code\":-32001,\"message\":\"Session with given id not found.\"}";
    assert(!ScriptSessionErrorMatters(@"child", false, @"pending command failed"));
    assert(!ScriptSessionErrorMatters(@"child", true, gone));
    assert(!ScriptSessionErrorMatters(@"child", true, nil));
    assert(ScriptSessionErrorMatters(@"", false, gone));
    assert(ScriptSessionErrorMatters(@"", true, @"Renderer crashed"));
    assert(ScriptSessionErrorMatters(@"child", true, @"Renderer crashed"));
    assert(ScriptSessionErrorMatters(@"child", true, @"{\"code\":-32000,\"message\":\"Session with given id not found.\"}"));
    assert(ScriptSessionErrorMatters(@"child", true, @"[]"));
    // A gone target, and only that exact answer, removes its session (#883).
    assert(ScriptSessionGone(gone));
    assert(ScriptSessionGone(@"{ \"message\": \"Session with given id not found.\", \"code\": -32001 }"));
    assert(!ScriptSessionGone(@"{\"code\":-32000,\"message\":\"Session with given id not found.\"}"));
    assert(!ScriptSessionGone(@"{\"code\":-32001,\"message\":\"Other\"}"));
    assert(!ScriptSessionGone(@"Renderer crashed"));
    assert(!ScriptSessionGone(nil));
    // Bad order: child failure arrives after detachment, then main success.
    NSString* failure = nil;
    if (ScriptSessionErrorMatters(@"child", false, gone)) failure = gone;
    if (ScriptSessionErrorMatters(@"", true, nil)) failure = @"main failed";
    assert(failure == nil);
    // Runtime.enable is followed by stack capture off, and a refusal of it
    // (an engine without the method) never fails the agent's setup.
    assert([StackCaptureOff().first isEqualToString:@"Runtime.setMaxCallStackSizeToCapture"]);
    assert([StackCaptureOff().second[@"size"] isEqual:@0]);
    assert(StackCaptureOptional(@"Runtime.setMaxCallStackSizeToCapture"));
    assert(!StackCaptureOptional(@"Runtime.enable"));
    std::puts("script error classification: 28 checks passed");
  }
}
