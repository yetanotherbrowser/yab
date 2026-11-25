#pragma once
// A key typed into a page's field reaches the page's view here as a copy,
// rebuilt from the key's CGEvent (KeyboardEventDecode). Chromium's view reads
// a key with interpretKeyEvents: and sends the editing commands it hears with
// the key (render_widget_host_view_cocoa.mm, keyEvent:wasKeyEquivalent:).
// This process reads the copy of a Control-letter key as noop:, its
// charactersIgnoringModifiers being the control character, so ⌃A, ⌃E and ⌃K
// reached the page as bare keys and did nothing. Yab's input context, the one
// the person types into, has read the key already; its commands come with the
// key, and the view hears them in place of its own reading of the copy.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// AppKit's names for the commands ("moveToBeginningOfParagraph:"): nil when
// the value is anything but a short list of them, empty when there is none.
static NSArray<NSString*>* ParseKeyCommands(id value) {
  if (!value) return @[];
  if (![value isKindOfClass:NSArray.class] || [value count] > 64) return nil;
  for (id name in value) {
    if (![name isKindOfClass:NSString.class] || [name length] < 2 || [name length] > 64 || ![name hasSuffix:@":"]) return nil;
    for (NSUInteger i = 0; i + 1 < [name length]; ++i) {
      unichar c = [name characterAtIndex:i];
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return nil;
    }
  }
  return value;
}

static NSEvent* keyCommandsEvent;
static NSArray<NSString*>* keyCommands;

static void InstallKeyCommands(Class view) {
  static bool installed = false;
  if (installed) return;
  installed = true;
  SEL interpret = @selector(interpretKeyEvents:);
  Method inherited = class_getInstanceMethod(view, interpret);
  using Interpret = void (*)(id, SEL, NSArray<NSEvent*>*);
  const Interpret appKit = (Interpret)method_getImplementation(inherited);
  IMP heard = imp_implementationWithBlock(^(id responder, NSArray<NSEvent*>* events) {
    if (keyCommands && events.firstObject == keyCommandsEvent) {
      for (NSString* name in keyCommands) [responder doCommandBySelector:NSSelectorFromString(name)];
      return;
    }
    appKit(responder, interpret, events);
  });
  // The view inherits interpretKeyEvents: from NSResponder: it gets its own,
  // and every other responder keeps AppKit's.
  if (!class_addMethod(view, interpret, heard, method_getTypeEncoding(inherited))) method_setImplementation(inherited, heard);
}

static void KeyDown(NSResponder* target, NSEvent* event, NSArray<NSString*>* commands) {
  NSEvent* outerEvent = keyCommandsEvent;
  NSArray<NSString*>* outerCommands = keyCommands;
  if (commands.count) {
    if (Class view = NSClassFromString(@"RenderWidgetHostViewCocoa")) InstallKeyCommands(view);
    keyCommandsEvent = event;
    keyCommands = commands;
  }
  [target keyDown:event];
  // A key delivered from a nested event loop leaves the outer key's commands.
  keyCommandsEvent = outerEvent;
  keyCommands = outerCommands;
}
