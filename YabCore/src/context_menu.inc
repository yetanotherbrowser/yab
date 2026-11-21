// Page context menus, included by core.mm after the shared wire helpers.
// Chrome builds the menu for the hidden producer window; Yab draws its own
// menu at the page point instead and answers through this continuation.
#include "include/cef_context_menu_handler.h"

struct PageMenu {
  std::string tab;
  NSString* token;
  CefRefPtr<CefRunContextMenuCallback> callback;
  std::set<int> commands;
};
static std::map<std::string, PageMenu> pageMenus;

// chrome/app/chrome_command_ids.h, Chromium 156.0.8078.96.
static const int kExtensionCommandFirst = 49000, kExtensionCommandLast = 49999;
static const int kChromeCommandCopy = 50150, kChromeCommandCut = 50151, kChromeCommandPaste = 50152;
static const int kChromeCommandSelectAll = 50156;
// Save Image As: Chrome fetches the picture from the frame that shows it,
// with that page as referrer, the image Accept header and the cached copy
// (RenderViewContextMenu::ExecSaveAs). CefBrowserHost::StartDownload sends
// none of that, and a site that checks the referrer refuses it (row 1611).
static const int kChromeCommandSaveImageAs = 50120;
static const int kChromeCommandSpellingWhileTyping = 41107, kChromeCommandAddToDictionary = 41110;
// A video's or a sound's own rows (RenderViewContextMenu::AppendMediaItems
// and AppendVideoItems): Loop, Show all controls and Picture in picture.
// Chrome runs them on the element pressed (MediaPlayerAction) and checks
// each from the player's state (media_flags); Picture in picture then goes
// out as a page's own request does, into Yab's floating window.
static const int kChromeCommandPictureInPicture = 50137, kChromeCommandLoop = 50140, kChromeCommandControls = 50141;
// And a video's frame (kContextMenuSaveVideoFrameAs, kContextMenuCopyVideoFrame).
static const int kChromeCommandSaveVideoFrameAs = 50130, kChromeCommandCopyVideoFrame = 50133;
static bool MediaCommand(int command) {
  return command == kChromeCommandLoop || command == kChromeCommandControls || command == kChromeCommandPictureInPicture ||
         command == kChromeCommandSaveVideoFrameAs || command == kChromeCommandCopyVideoFrame;
}

static void CancelPageMenu(const std::string& tab) {
  auto found = pageMenus.find(tab);
  if (found == pageMenus.end()) return;
  auto callback = found->second.callback;
  pageMenus.erase(found);
  callback->Cancel();
}
// Only rows Yab may forward: Chrome's own edit commands and Save Image As
// it offers here, and extension items (chrome.contextMenus) with submenus.
// A DevTools frontend's rows are all its own (Reveal in Sources, Copy selector...).
// `spelling` takes Chrome's spelling rows, at the top of the menu or in its Spell
// check submenu, and `media` a video's or a sound's: Yab places them itself.
static NSArray* MenuRows(CefRefPtr<CefMenuModel> model, std::set<int>& commands, NSMutableArray* spelling, NSMutableArray* media,
                         bool every = false, int depth = 0) {
  NSMutableArray* rows = [NSMutableArray new];
  if (!model || depth > 3) return rows;
  for (size_t i = 0; i < model->GetCount() && i < 200; i++) {
    int command = model->GetCommandIdAt(i);
    auto type = model->GetTypeAt(i);
    if (type == MENUITEMTYPE_SEPARATOR || !model->IsVisibleAt(i)) continue;
    bool extension = every || (command >= kExtensionCommandFirst && command <= kExtensionCommandLast);
    if (!every && (command == kChromeCommandAddToDictionary || command == kChromeCommandSpellingWhileTyping)) {
      if (model->IsEnabledAt(i)) {
        commands.insert(command);
        [spelling addObject:@{@"command": @(command), @"checked": @(model->IsCheckedAt(i))}];
      }
      continue;
    }
    if (!every && MediaCommand(command)) {
      if (model->IsEnabledAt(i)) commands.insert(command);
      [media addObject:@{@"command": @(command), @"enabled": @(model->IsEnabledAt(i)), @"checked": @(model->IsCheckedAt(i))}];
      continue;
    }
    NSArray* children = type == MENUITEMTYPE_SUBMENU ? MenuRows(model->GetSubMenuAt(i), commands, spelling, media, every, depth + 1) : @[];
    if (!extension && !children.count) {
      if (depth == 0 && (command == kChromeCommandCopy || command == kChromeCommandCut || command == kChromeCommandPaste ||
          command == kChromeCommandSelectAll || command == kChromeCommandSaveImageAs) && model->IsEnabledAt(i)) commands.insert(command);
      continue;
    }
    if (type != MENUITEMTYPE_SUBMENU) commands.insert(command);
    [rows addObject:@{@"command": @(command), @"label": Str(model->GetLabelAt(i)),
                      @"enabled": @(model->IsEnabledAt(i)), @"checked": @(model->IsCheckedAt(i)),
                      @"extension": @(extension), @"rows": children}];
  }
  return rows;
}
static bool OpenPageMenu(Tab* tab, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                         CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) {
  if (!tab || tab->closing || tab->internal || !tab->adopted) { callback->Cancel(); return true; }
  CancelPageMenu(tab->id);
  PageMenu menu{tab->id, NSUUID.UUID.UUIDString, callback, {}};
  NSMutableArray* spelling = [NSMutableArray new], *media = [NSMutableArray new];
  NSArray* extensions = MenuRows(model, menu.commands, spelling, media, tab->devToolsFrontend);
  std::vector<CefString> suggestions;
  params->GetDictionarySuggestions(suggestions);
  NSMutableArray* words = [NSMutableArray new];
  for (const auto& word : suggestions) if (words.count < 8) [words addObject:Str(word)];
  NSMutableArray* chrome = [NSMutableArray new];
  for (int command : menu.commands) if (command >= 50000) [chrome addObject:@(command)];
  int flags = params->GetTypeFlags();
  Event(@"menu.open", tab, @{@"request": menu.token, @"x": @(params->GetXCoord()), @"y": @(params->GetYCoord()),
    @"link": Str(params->GetLinkUrl()), @"unfilteredLink": Str(params->GetUnfilteredLinkUrl()),
    @"source": Str(params->GetSourceUrl()), @"media": @(params->GetMediaType()),
    @"hasImage": @(params->HasImageContents()), @"title": Str(params->GetTitleText()),
    @"selection": Str(params->GetSelectionText()), @"editable": @(params->IsEditable()),
    @"editFlags": @(params->GetEditStateFlags()), @"frame": Str(params->GetFrameUrl()),
    @"page": Str(params->GetPageUrl()), @"mainFrame": @(frame && frame->IsMain()),
    @"typeFlags": @(flags), @"misspelled": Str(params->GetMisspelledWord()),
    @"suggestions": words, @"spelling": spelling, @"mediaRows": media, @"mediaFlags": @(params->GetMediaStateFlags()), @"chrome": chrome, @"extensions": extensions, @"devToolsFrontend": @(tab->devToolsFrontend)});
  pageMenus.emplace(tab->id, std::move(menu));
  return true;
}
// A picture's pixels for Yab: Copy Image, Copy Text and ⌘F's words in
// pictures (#1991). ⌘F asks for up to thirty at once, and each answer used to
// stop the rest of Chromium twice over:
// - the encoding: this callback comes on the UI thread, which carries every
//   page's input and loads, and a full-size PNG took it for as long as the
//   picture was big. CefImage may be used on any browser thread, so it is
//   encoded on a queue of its own and only the answer comes back here.
// - the bytes: base64 in the JSON wire every page's requests share, megabytes
//   each, read in order, so a scroll's or a script's answer waited behind
//   them (a photograph's PNG was past the wire's 4 MB and refused anyway).
//   Asked with delivery "file" they go into a file of the client's own user,
//   as the native PDF's do (print_find.inc), and the wire carries its path;
//   the client reads and removes it. Chromium keeps bulk bytes off its
//   control channel the same way (mojo data pipes and shared memory).
// A reader asks for a bounded size and JPEG, as Chromium's own image requests
// for Lens do (ChromeRenderFrameObserver::RequestImageForContextNode).
class ImageBytes : public CefDownloadImageCallback {
  NSString* request_;
  bool jpeg_, file_;
 public:
  ImageBytes(NSString* request, bool jpeg, bool file) : request_(request), jpeg_(jpeg), file_(file) {}
  void OnDownloadImageFinished(const CefString&, int status, CefRefPtr<CefImage> image) override {
    NSString* request = request_;
    bool jpeg = jpeg_, file = file_;
    CefRefPtr<CefImage> held = image;
    static dispatch_queue_t queue = dispatch_queue_create("yabcore.image-bytes", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{ @autoreleasepool {
      int width = 0, height = 0;
      CefRefPtr<CefBinaryValue> bytes;
      if (held && !held->IsEmpty()) bytes = jpeg ? held->GetAsJPEG(1, 90, width, height) : held->GetAsPNG(1, true, width, height);
      size_t size = bytes ? bytes->GetSize() : 0;
      NSString* error = nil;
      NSDictionary* result = nil;
      NSString* key = jpeg ? @"jpeg" : @"png";
      if (!size || size > 64 * 1024 * 1024) error = [NSString stringWithFormat:@"No image (HTTP %d)", status];
      else if (file) {
        NSMutableData* data = [NSMutableData dataWithLength:size];
        bytes->GetData(data.mutableBytes, size, 0);
        NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"yab-image-%@.%@", NSUUID.UUID.UUIDString, jpeg ? @"jpg" : @"png"]];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        bool wrote = fd >= 0;
        for (size_t at = 0; wrote && at < size;) {
          ssize_t n = write(fd, (const char*)data.bytes + at, size - at);
          if (n < 0 && errno == EINTR) continue;
          if (n <= 0) wrote = false; else at += (size_t)n;
        }
        if (fd >= 0) close(fd);
        if (wrote) result = @{@"file": path, @"format": key, @"width": @(width), @"height": @(height)};
        else { unlink(path.fileSystemRepresentation); error = @"Image file could not be written"; }
      } else if ((size + 2) / 3 * 4 > kMaxMessage - 64 * 1024) error = @"Image too large for the wire";
      else {
        NSMutableData* data = [NSMutableData dataWithLength:size];
        bytes->GetData(data.mutableBytes, size, 0);
        result = @{key: [data base64EncodedStringWithOptions:0], @"width": @(width), @"height": @(height)};
      }
      dispatch_async(dispatch_get_main_queue(), ^{ Reply(request, result, error); });
    } });
  }
  IMPLEMENT_REFCOUNTING(ImageBytes);
};
static bool ContextMenuRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"menu.reply"]) {
    auto found = pageMenus.find(tab.id);
    if (found == pageMenus.end() || ![found->second.token isEqual:S(p, @"request")]) {
      Reply(request, nil, @"No matching page menu"); return true;
    }
    NSNumber* command = [p[@"command"] isKindOfClass:NSNumber.class] ? p[@"command"] : nil;
    // Only a row this menu offered can be run. Anything else cancels.
    bool offered = command && found->second.commands.count(command.intValue);
    auto callback = found->second.callback;
    pageMenus.erase(found);
    Reply(request, @{@"ran": @(offered)});
    if (offered) callback->Continue(command.intValue, EVENTFLAG_NONE); else callback->Cancel();
    return true;
  }
  if ([method isEqual:@"page.download"] || [method isEqual:@"page.imageData"]) {
    NSURL* url = [NSURL URLWithString:S(p, @"url")];
    NSString* scheme = url.scheme.lowercaseString;
    if (!url || !([scheme isEqual:@"http"] || [scheme isEqual:@"https"] || [scheme isEqual:@"data"] || [scheme isEqual:@"blob"])) {
      Reply(request, nil, @"A web URL is required"); return true;
    }
    if ([method isEqual:@"page.download"]) {
      // CEF's download handler then asks Yab for the destination as usual.
      tab.browser->GetHost()->StartDownload(Key(S(p, @"url"))); Reply(request); return true;
    }
    // maxPixels: the longest side wanted, in pixels; Chromium scales the
    // picture down in the page's renderer. CEF multiplies the size it is
    // given by ui::GetScaleForMaxSupportedResourceScaleFactor(), 2 on a Mac
    // whatever its screens (a 1x farm Mac got 3000 for 2400). 0, or none:
    // the picture as it is.
    int pixels = [p[@"maxPixels"] isKindOfClass:NSNumber.class] ? std::clamp([p[@"maxPixels"] intValue], 0, 16384) : 0;
    uint32_t largest = pixels ? (uint32_t)std::max(1, pixels / 2) : 0;
    tab.browser->GetHost()->DownloadImage(Key(S(p, @"url")), false, largest, false,
                                          new ImageBytes(request, [S(p, @"format") isEqual:@"jpeg"], [S(p, @"delivery") isEqual:@"file"]));
    return true;
  }
  if ([method isEqual:@"page.replaceMisspelling"]) {
    NSString* word = S(p, @"text");
    if (!word.length || word.length > 200) { Reply(request, nil, @"A word is required"); return true; }
    tab.browser->GetHost()->ReplaceMisspelling(Key(word)); Reply(request); return true;
  }
  return false;
}
