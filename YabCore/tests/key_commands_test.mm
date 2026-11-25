// key_commands.h without CEF: a page's view hears Yab's editing commands
// with the key, and reads every other key as AppKit does.
//   clang++ -std=c++20 -fobjc-arc -framework AppKit -IYabCore/src \
//     YabCore/tests/key_commands_test.mm -o key-commands-test && ./key-commands-test
#include "key_commands.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #x); ++failures; } } while (0)

static NSMutableArray<NSString*>* heard;

// Chromium's view as far as a key goes: keyEvent: reads the key with
// interpretKeyEvents:, which it inherits from NSResponder, and keeps the
// commands and text that reading gives.
@interface RenderWidgetHostViewCocoa : NSView <NSTextInputClient>
@end
@implementation RenderWidgetHostViewCocoa
- (void)keyDown:(NSEvent*)event { [self interpretKeyEvents:@[ event ]]; }
- (void)doCommandBySelector:(SEL)selector { [heard addObject:NSStringFromSelector(selector)]; }
- (void)insertText:(id)text replacementRange:(NSRange)range { [heard addObject:[@"insert " stringByAppendingString:[text description]]]; }
- (void)setMarkedText:(id)text selectedRange:(NSRange)selected replacementRange:(NSRange)range {}
- (void)unmarkText {}
- (NSRange)selectedRange { return NSMakeRange(0, 0); }
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { return NO; }
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual { return nil; }
- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual { return NSZeroRect; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
@end

static NSEvent* Key(unsigned short code, NSString* characters, NSString* unmodified, NSEventModifierFlags flags) {
  return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
    windowNumber:0 context:nil characters:characters charactersIgnoringModifiers:unmodified isARepeat:NO keyCode:code];
}

int main() { @autoreleasepool {
  heard = [NSMutableArray array];
  CHECK([ParseKeyCommands(nil) isEqual:@[]]);
  CHECK([ParseKeyCommands(@[ @"moveToBeginningOfParagraph:", @"deleteForward:" ]) count] == 2);
  CHECK(!ParseKeyCommands(@"moveLeft:"));
  CHECK(!ParseKeyCommands(@[ @"moveLeft" ]));
  CHECK(!ParseKeyCommands(@[ @":" ]));
  CHECK(!ParseKeyCommands(@[ @"move left:" ]));
  CHECK(!ParseKeyCommands(@[ @"moveLeft:moveRight:" ]));
  CHECK(!ParseKeyCommands(@[ @1 ]));
  NSMutableArray* many = [NSMutableArray array];
  for (int i = 0; i < 64; ++i) [many addObject:@"moveRight:"];
  CHECK([ParseKeyCommands(many) count] == 64);
  [many addObject:@"moveRight:"];
  CHECK(!ParseKeyCommands(many));

  RenderWidgetHostViewCocoa* view = [RenderWidgetHostViewCocoa new];
  NSEvent* controlA = Key(0, @"\x01", @"\x01", NSEventModifierFlagControl);

  // The copy of ⌃A this process gets: AppKit reads it as no command.
  [view keyDown:controlA];
  CHECK([heard isEqual:@[ @"noop:" ]]);

  // ⌃A as Yab's context read it: the view hears the command, and nothing
  // from its own reading of the copy.
  [heard removeAllObjects];
  KeyDown(view, controlA, @[ @"moveToBeginningOfParagraph:" ]);
  CHECK([heard isEqual:@[ @"moveToBeginningOfParagraph:" ]]);

  // Two commands, in Yab's order (⌥↑ is two in AppKit's bindings).
  [heard removeAllObjects];
  KeyDown(view, Key(126, @"", @"", NSEventModifierFlagOption | NSEventModifierFlagFunction),
          @[ @"moveBackward:", @"moveToBeginningOfParagraph:" ]);
  CHECK([heard isEqual:(@[ @"moveBackward:", @"moveToBeginningOfParagraph:" ])]);

  // A key Yab sent with no command, and the same key afterwards: AppKit's
  // own reading, as before.
  for (NSArray* none in @[ @[], [NSNull null] ]) {
    [heard removeAllObjects];
    KeyDown(view, Key(7, @"x", @"x", 0), none == (id)[NSNull null] ? nil : none);
    CHECK([heard isEqual:@[ @"insert x" ]]);
  }
  [heard removeAllObjects];
  [view keyDown:Key(7, @"x", @"x", 0)];
  CHECK([heard isEqual:@[ @"insert x" ]]);

  // While a key with commands is being read, another key read meanwhile
  // (an input method's own) is AppKit's.
  [heard removeAllObjects];
  keyCommandsEvent = controlA;
  keyCommands = @[ @"moveToBeginningOfParagraph:" ];
  [view interpretKeyEvents:@[ Key(7, @"x", @"x", 0) ]];
  keyCommandsEvent = nil;
  keyCommands = nil;
  CHECK([heard isEqual:@[ @"insert x" ]]);

  // A key delivered from a nested event loop, before the outer key is read,
  // leaves the outer key its commands.
  [heard removeAllObjects];
  keyCommandsEvent = controlA;
  keyCommands = @[ @"moveToBeginningOfParagraph:" ];
  KeyDown(view, Key(7, @"x", @"x", 0), nil);
  [view interpretKeyEvents:@[ controlA ]];
  CHECK([heard isEqual:(@[ @"insert x", @"moveToBeginningOfParagraph:" ])]);
  keyCommandsEvent = nil;
  keyCommands = nil;

  // Every other responder keeps AppKit's reading.
  CHECK(class_getMethodImplementation(NSView.class, @selector(interpretKeyEvents:)) !=
        class_getMethodImplementation(RenderWidgetHostViewCocoa.class, @selector(interpretKeyEvents:)));

  if (failures) return 1;
  printf("PASS key_commands_test\n");
  return 0;
}}
