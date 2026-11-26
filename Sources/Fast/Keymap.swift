import AppKit
import Carbon.HIToolbox
import SwiftUI
import WebKit

// Which keys do what, and the keys someone chose instead. Raycast's way:
// every command has the key it comes with, any of them can be given
// another or none, and Settings › Shortcuts is where that is done. The
// menus and the key monitor both read from here, so a key changed there
// is the key the menu shows and the key the window answers to at once.

/// A keystroke: its modifiers and its key, the key as the ASCII layout
/// names it. On a non-Latin layout ⌘T is still t and not е, the way the
/// menus themselves match it, so a key recorded on one layout works on
/// every other.
struct Hotkey: Hashable {
    /// A lowercased character, "t", "[", "=", or a name for a key with no
    /// character of its own: ↩, ⇥, ⌫, ⌦, ←, →, ↑, ↓, space, home, end,
    /// pageup, pagedown, f1 to f15.
    let key: String
    let flags: NSEvent.ModifierFlags

    static let carried: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// F1 to F20: nothing is typed with them, so one alone may be a
    /// shortcut.
    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// Held with ⌘, ⌃ or ⌥, or an F key: a press that never types.
    var commands: Bool { !flags.intersection([.command, .option, .control]).isEmpty || isFunctionKey }

    init(_ key: String, _ flags: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.flags = flags.intersection(Self.carried)
    }

    /// What was pressed, whatever layout typed it: the first of `readings`.
    init?(_ event: NSEvent) {
        guard let first = Self.readings(event).first else { return nil }
        self = first
    }

    /// Every keystroke a press can be, the likeliest first, read the way
    /// macOS reads a menu's key: by the character the layout in use types,
    /// ⌘ through the layout's own ⌘ keys ("Dvorak - QWERTY ⌘" types
    /// QWERTY there), and on a layout that isn't ASCII, Russian, Hebrew or
    /// Greek, through the ASCII-capable layout picked last, so ⌘T is t
    /// and not е, and mail's J is j. The top row's keys are digits by
    /// where they sit (⌘1 on AZERTY), a key with no ASCII character (ü on
    /// German) is its place on a US keyboard, and a mark typed with ⇧ or
    /// ⌥ is the mark too: ? on AZERTY's ⇧, is ⇧/, [ on German's ⌥5 is [.
    static func readings(_ event: NSEvent, on board: KeyBoard = .current) -> [Hotkey] {
        // A text command can arrive while currentEvent is a mouse or app
        // event. AppKit raises an exception if keyCode is read from those.
        guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return [] }
        let code: UInt16
        if event.type == .keyDown || event.type == .keyUp {
            code = board.code(for: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                              flags: event.modifierFlags)
        } else {
            code = event.keyCode
        }
        return readings(code: code, flags: event.modifierFlags, on: board)
    }

    static func readings(code: UInt16, flags: NSEvent.ModifierFlags, on board: KeyBoard) -> [Hotkey] {
        let flags = flags.intersection(carried)
        let named = KeyLayout.named[code]
        // Return, the arrows, F keys: nothing to read but the key.
        if let named, Int(named) == nil { return [Hotkey(named, flags)] }
        var out: [Hotkey] = []
        func add(_ hotkey: Hotkey) { if !out.contains(hotkey) { out.append(hotkey) } }
        add(Hotkey(named ?? board.key(code, command: flags.contains(.command)) ?? KeyLayout.key(code) ?? "keycode\(code)", flags))
        for mark in board.marks(code, flags) {
            if let base = unshifted[mark] {
                add(Hotkey(base, flags.subtracting([.shift, .option]).union(.shift)))
            } else {
                add(Hotkey(mark, flags.subtracting([.shift, .option])))
            }
        }
        return out
    }

    /// The first reading of a press that something answers to, and what.
    static func first<T>(_ event: NSEvent, _ answer: (Hotkey) -> T?) -> (Hotkey, T)? {
        for reading in readings(event) {
            if let found = answer(reading) { return (reading, found) }
        }
        return nil
    }

    /// Whether a press is this keystroke, in any of its readings.
    func heard(in event: NSEvent) -> Bool {
        Self.readings(event).contains(self)
    }

    /// The key a mark is typed on with ⇧ on a US keyboard: ? is /.
    static let unshifted: [String: String] = Dictionary(uniqueKeysWithValues: shifted.map { ($0.value, $0.key) })

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(flags.rawValue)
    }

    static func == (a: Hotkey, b: Hotkey) -> Bool { a.key == b.key && a.flags == b.flags }

    /// ⌃⌥⇧⌘ and the key, one cap each, in the order menus print them.
    var caps: [String] { Self.caps(key, flags) }

    /// The caps run together, "⌥⌘Y", as a tooltip or a line of text says it.
    var text: String { caps.joined() }

    static func caps(_ key: String?, _ flags: NSEvent.ModifierFlags) -> [String] {
        // ⇧ and a digit or a mark alone is the mark it types, as people
        // say it: # and ! in mail, not ⇧3 and ⇧1.
        if flags == .shift, let key, let mark = shifted[key] { return [mark] }
        var out: [String] = []
        if flags.contains(.control) { out.append("⌃") }
        if flags.contains(.option) { out.append("⌥") }
        if flags.contains(.shift) { out.append("⇧") }
        if flags.contains(.command) { out.append("⌘") }
        guard let key, !key.isEmpty else { return out }
        out.append(face(key))
        return out
    }

    /// What the ASCII layout's digits and marks type with ⇧.
    static let shifted: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    /// How a key is written on its cap.
    static func face(_ key: String) -> String {
        let named: [String: String] = [
            "space": "Space", "home": "Home", "end": "End", "pageup": "Page Up", "pagedown": "Page Down", "esc": "esc",
            // What an extension's command keeps, as WebKit hands it over.
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            " ": "Space", "\r": "↩", "\t": "⇥",
        ]
        if let name = named[key] { return name }
        if key.hasPrefix("keycode"), let code = UInt16(key.dropFirst(7)) { return "Key \(code)" }
        if key.count > 1, key.hasPrefix("f"), Int(key.dropFirst()) != nil { return key.uppercased() }
        return key.count == 1 ? key.uppercased() : key.capitalized
    }

    // MARK: - kept as text

    /// "⌥⌘y": the modifiers as their symbols, then the key. What
    /// Store.settings keeps, and what the settings search reads.
    var stored: String {
        Self.caps(nil, flags).joined() + key
    }

    init?(stored: String) {
        var flags: NSEvent.ModifierFlags = []
        var rest = Substring(stored)
        while let first = rest.first, let flag = Self.symbols[first] {
            flags.insert(flag)
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        self.init(String(rest), flags)
    }

    /// App Shortcuts' own writing: @ ⌘, $ ⇧, ~ ⌥, ^ ⌃, then the key.
    init?(userKey value: String) {
        var flags: NSEvent.ModifierFlags = []
        var rest = Substring(value)
        let marks: [Character: NSEvent.ModifierFlags] = ["@": .command, "$": .shift, "~": .option, "^": .control]
        while let first = rest.first, let flag = marks[first] {
            flags.insert(flag)
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        let named: [String: String] = [
            "\u{1b}": "esc", "\r": "↩", "\t": "⇥", "\u{8}": "⌫", "\u{7f}": "⌫", " ": "space",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
        ]
        let key = String(rest)
        // A capital is the letter with ⇧.
        if key.count == 1, let c = key.first, c.isUppercase { flags.insert(.shift) }
        // App Shortcuts stores the character that was typed: kept as it is
        // when ASCII, as a press is read (Hotkey.readings); a digit on the
        // top row where AZERTY types & there; else the ASCII layout's key
        // under it, t for a non-Latin layout's е, resolved while the layout is known.
        let physical: String
        if let name = named[key] {
            physical = name
        } else if key.count == 1 {
            if let name = KeyLayout.keyName(for: key.lowercased()) {
                physical = name
            } else {
                return nil
            }
        } else {
            physical = key
        }
        self.init(physical, flags)
    }

    private static let symbols: [Character: NSEvent.ModifierFlags] = [
        "⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command,
    ]

    /// Keys as someone would type them in a filter: "⌘Y", "⌘ y", "cmd y",
    /// "opt+cmd+y", or only the modifiers, "⌥⌘". The caps as one line, in
    /// the menus' order, or nil for words that don't name a keystroke.
    static func typed(_ text: String) -> String? {
        let words: [String: NSEvent.ModifierFlags] = [
            "cmd": .command, "command": .command, "opt": .option, "option": .option, "alt": .option,
            "ctrl": .control, "control": .control, "shift": .shift,
        ]
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        var symbol = false
        let parts = text.lowercased().split { $0 == " " || $0 == "+" }
        for (index, part) in parts.enumerated() {
            var rest = Substring(part)
            while let first = rest.first, let flag = symbols[first] {
                flags.insert(flag)
                symbol = true
                rest = rest.dropFirst()
            }
            if rest.isEmpty { continue }
            if let flag = words[String(rest)] {
                flags.insert(flag)
            } else if index == parts.count - 1, rest.count == 1 || KeyLayout.names.contains(String(rest)) {
                key = String(rest)
            } else {
                return nil
            }
        }
        // A word alone, "shift", is a word: only a keystroke with a
        // modifier drawn as its symbol, or two parts or more, is keys.
        guard !flags.isEmpty, symbol || parts.count > 1 else { return nil }
        return caps(key.isEmpty ? nil : key, flags).joined()
    }

    /// Whether caps run together name a key as well as its modifiers.
    static func isWhole(_ text: String) -> Bool {
        text.last.map { symbols[$0] == nil } ?? false
    }

    // MARK: - in the menus

    /// The key as SwiftUI's menus take it.
    var menu: KeyboardShortcut? {
        let special: [String: KeyEquivalent] = [
            "↩": .return, "⇥": .tab, "space": .space, "⌫": .delete, "⌦": .deleteForward, "esc": .escape,
            "←": .leftArrow, "→": .rightArrow, "↑": .upArrow, "↓": .downArrow,
            "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
        ]
        let equivalent: KeyEquivalent
        if let named = special[key] {
            equivalent = named
        } else if key.count > 1, key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...35).contains(n),
                  let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            equivalent = KeyEquivalent(Character(scalar))
        } else if key.count == 1, let character = key.first {
            equivalent = KeyEquivalent(character)
        } else {
            return nil
        }
        var modifiers: SwiftUI.EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

/// Names for macOS key codes: the keys with no character by their code,
/// and every other key by where it sits on a US keyboard, which is what a
/// press is read as only when its layout types nothing ASCII there
/// (Hotkey.readings).
enum KeyLayout {

    /// Keys with no character of their own, by their key code, and the top
    /// row's digits by where they sit: on AZERTY the 1 key types & without
    /// shift, and ⌘1 and ⌘0 are still ⌘1 and ⌘0 there (ContentView.digits).
    static let named: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        36: "↩", 76: "↩", 48: "⇥", 49: "space", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
    ]

    static let physical: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        24: "=", 27: "-", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
    ]

    /// ISO has one more typing key. Its name comes from the layout, never
    /// from an ANSI position; AppKit can exchange it with the grave key.
    static let isoCodes: Set<UInt16> = [UInt16(kVK_ISO_Section), UInt16(kVK_ANSI_Grave)]
    static let typingCodes = Set(physical.keys).union([UInt16(kVK_ISO_Section)])

    static let names: Set<String> = Set(named.values)

    static func key(_ code: UInt16) -> String? {
        if let name = named[code] { return name }
        if let name = physical[code] { return name }
        return "keycode\(code)"
    }

    /// The key code that types this character on the current ASCII layout,
    /// for the bench, which presses keys by what they say, and the hot key
    /// for the whole Mac, which macOS hears by its code.
    static func code(for key: String, on board: KeyBoard = .current) -> UInt16? {
        // Return and keypad Enter share ↩. The main Return key is the
        // canonical one for a global hotkey; Dictionary iteration is not.
        if let named = named.filter({ $0.value == key }).map(\.key).min() { return named }
        if let typed = board.code(typing: key) { return typed }
        if let physical = physical.filter({ $0.value == key }).map(\.key).min() { return physical }
        if key.hasPrefix("keycode") { return UInt16(key.dropFirst(7)) }
        return nil
    }

    /// The key a character kept by macOS App Shortcuts names, as a press
    /// of it is read: a top-row digit by where it sits, an ASCII character
    /// as itself, any other the ASCII layout's character on its key. Its
    /// key is found on the active layout, or, if that changed since the
    /// shortcut was made, where every installed layout that types it agrees.
    static func keyName(for character: String, on board: KeyBoard = .current) -> String? {
        let active = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        var found = code(typing: character, in: build(from: active))
        if found == nil {
            let sources = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
            let codes = Set(sources.compactMap { source -> UInt16? in
                guard TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil else { return nil }
                return code(typing: character, in: build(from: source))
            })
            if codes.count == 1 { found = codes.first }
        }
        return keyName(for: character, at: found, on: board)
    }

    static func keyName(for character: String, at code: UInt16?, on board: KeyBoard) -> String? {
        if let code, let digit = named[code], Int(digit) != nil { return digit }
        if character.unicodeScalars.allSatisfy({ $0.isASCII }) { return character }
        guard let code else { return nil }
        return board.key(code, command: false) ?? key(code)
    }

    static func code(typing character: String, in layout: [UInt16: String]) -> UInt16? {
        let candidates = layout.filter { $0.value == character }.map(\.key)
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    /// What each key types with nothing held, on the given layout, or on
    /// the ASCII-capable one in use: the layout picked now, if it is one,
    /// else the one picked last that was.
    static func build(from source: TISInputSource?) -> [UInt16: String] {
        let source = source ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var out: [UInt16: String] = [:]
        data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Only canonical typing positions: keypad digits can emit the
            // same glyph as the top row but do not represent that shortcut.
            let typingCodes = Self.typingCodes.union(named.compactMap { Int($0.value) == nil ? nil : $0.key })
            for code in typingCodes {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars
                )
                guard status == noErr, length > 0 else { continue }
                let text = String(utf16CodeUnits: chars, count: length).lowercased()
                // Control characters are keys with names, taken above.
                guard let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { continue }
                out[code] = text
            }
        }
        return out
    }

    /// A layout by its id, "com.apple.keylayout.Russian", installed or not.
    static func source(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

}

/// The layouts a press is read on (Hotkey.readings): the one in use, and
/// the ASCII-capable one macOS falls back on for keys while it isn't.
struct KeyBoard {
    /// The layout in use, its key table as UCKeyTranslate takes it.
    let layout: Data?
    /// Whether it types ASCII: US, ABC, AZERTY, QWERTZ, Dvorak do;
    /// Russian, Ukrainian, Hebrew, Greek don't.
    let typesASCII: Bool
    /// The ASCII-capable layout picked last, the same as `layout` while
    /// that is one.
    let ascii: Data?
    let keyboardType: UInt32

    init(layout: Data?, typesASCII: Bool, ascii: Data?, keyboardType: UInt32 = UInt32(LMGetKbdType())) {
        self.layout = layout
        self.typesASCII = typesASCII
        self.ascii = typesASCII ? layout : ascii
        self.keyboardType = keyboardType
    }

    /// A layout by its id, "com.apple.keylayout.Russian", with the ASCII
    /// layout beside it ABC unless said: the tests' way to press keys on any
    /// layout whatever the Mac has picked.
    init?(_ id: String, ascii: String = "com.apple.keylayout.ABC", keyboardType: UInt32 = UInt32(LMGetKbdType())) {
        guard let source = KeyLayout.source(id), let data = Self.data(source) else { return nil }
        let fallback = KeyLayout.source(ascii).flatMap(Self.data)
        self.init(layout: data, typesASCII: Self.typesASCII(source), ascii: fallback, keyboardType: keyboardType)
    }

    /// The layouts as they are now. Read once per layout picked: a key
    /// asks only which one that is.
    static var current: KeyBoard {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        let keyboardType = UInt32(LMGetKbdType())
        let id = [source, fallback].map(Self.id).joined(separator: " ") + " \(keyboardType)"
        if let kept, kept.id == id { return kept.board }
        let board = KeyBoard(layout: data(source), typesASCII: typesASCII(source), ascii: data(fallback), keyboardType: keyboardType)
        kept = (id, board)
        return board
    }
    private static var kept: (id: String, board: KeyBoard)?

    private static func id(_ source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func data(_ source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func typesASCII(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    /// AppKit's ISO key codes can disagree with UCKeyTranslate's two
    /// positions. Use the event's character to choose between them, with
    /// Shift still held and Option ignored, just as that event spells it.
    func code(for code: UInt16, charactersIgnoringModifiers: String?, flags: NSEvent.ModifierFlags) -> UInt16 {
        guard KeyLayout.isoCodes.contains(code), let character = charactersIgnoringModifiers,
              !character.isEmpty else { return code }
        let modifiers: UInt32 = flags.contains(.shift) ? UInt32(shiftKey) : 0
        if type(code, modifiers, on: layout)?.lowercased() == character.lowercased() { return code }
        return KeyLayout.isoCodes.sorted().first {
            type($0, modifiers, on: layout)?.lowercased() == character.lowercased()
        } ?? code
    }

    /// The key's character with nothing held but ⌘, as a menu matches it,
    /// lowercased; ISO's two positions also keep their own non-ASCII marks.
    func key(_ code: UInt16, command: Bool) -> String? {
        let modifiers = command ? UInt32(cmdKey) : 0
        // A layout that isn't ASCII has ⌘ keys of its own that are (a Cyrillic
        // layout's are QWERTY's); without ⌘ its keys are the ASCII layout's,
        // even the marks it types elsewhere (its / sits where ` does).
        if typesASCII || command,
           let typed = Self.printable(type(code, modifiers, on: layout), asciiOnly: !typesASCII || !KeyLayout.isoCodes.contains(code)) {
            return typed.lowercased()
        }
        guard !typesASCII else { return nil }
        return Self.printable(type(code, modifiers, on: ascii), asciiOnly: !KeyLayout.isoCodes.contains(code))?.lowercased()
    }

    /// The marks a key types with the ⇧ and ⌥ held, on the layout in use
    /// and the ASCII one: ? from ⇧, on AZERTY, [ from ⌥5 on German.
    func marks(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> [String] {
        var modifiers: UInt32 = 0
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        var out: [String] = []
        for data in typesASCII ? [layout] : [layout, ascii] {
            // Under ⌘ a layout drops ⇧, so marks are read without it; but
            // where it has ⌘ keys of its own (Dvorak - QWERTY ⌘, a non-Latin layout),
            // what it types without ⌘ isn't what ⌘ was pressed with.
            if flags.contains(.command), type(code, UInt32(cmdKey), on: data) != type(code, 0, on: data) { continue }
            guard let mark = Self.printable(type(code, modifiers, on: data)),
                  let scalar = mark.unicodeScalars.first, mark.unicodeScalars.count == 1,
                  !CharacterSet.alphanumerics.contains(scalar), scalar != " ", !out.contains(mark) else { continue }
            out.append(mark)
        }
        return out
    }

    /// The key code that types this character with nothing held, on the
    /// ASCII layout; the lowest when two do.
    func code(typing character: String) -> UInt16? {
        let codes = KeyLayout.typingCodes.filter {
            Self.printable(type($0, 0, on: ascii), asciiOnly: !KeyLayout.isoCodes.contains($0))?.lowercased() == character
        }
        return codes.min()
    }

    private static func printable(_ text: String?, asciiOnly: Bool = true) -> String? {
        guard let text, !text.isEmpty,
              text.unicodeScalars.allSatisfy({
                  (!asciiOnly || $0.isASCII) && $0.value >= 0x21 && $0.value != 0x7F
                      && !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return nil }
        return text
    }

    /// What a key types on a layout with these Carbon modifiers held, dead
    /// keys typed as their marks.
    func type(_ code: UInt16, _ modifiers: UInt32, on data: Data?) -> String? {
        guard let data else { return nil }
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xFF, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

// MARK: - what the keys do

/// Every key the browser answers to, in the groups the menus keep them in.
/// Words, not menu titles: what the key does, said the way you'd ask for it.
enum Shortcut {
    /// What a key can be given to. The raw value is what the choice is kept
    /// under, so a case is never renamed.
    enum Action: String, CaseIterable {
        case newWindow, blankWindow, closeWindow, newTab, privateTab, closeTab, reopen, nextTab, previousTab, duplicate, mute, stopLoading
        case recentTab, recentTabReverse, backArrow, forwardArrow
        case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9
        case space1, space2, space3, space4, space5, space6, space7, space8, space9
        case sendSpace1, sendSpace2, sendSpace3, sendSpace4, sendSpace5, sendSpace6, sendSpace7, sendSpace8, sendSpace9
        case openAddress, copyAddress, pasteAndGo, pasteAndMatchStyle, bookmark, keepTab
        case folderWithTabs, newTabInFolder
        case copyMarkdownLink
        case sharePage
        case back, forward, reload, hardReload, find, findNext, findPrevious, reader, darkPage, float, fillForm
        case translatePage
        case hide, zoomIn, zoomOut, actualSize, print, inspector, console, inspectElement
        case peekTab, peekSplit, peekClose
        case sidebarTabs, column, closeChat, moveToProject, bookmarksBar, addressBar, extensions, history, downloads, bookmarks, passwords, settings
        case snippets
        case clipboard, emoji, autofill, chats, routines, boostStore, now, purchases
        case mail
        case sendFeedback
        case mailCommands, mailAccountAll, mailAccount1, mailAccount2, mailAccount3, mailAccount4, mailAccount5, mailAccount6, mailAccount7, mailAccount8, mailAccount9
        case mailCopyChip, mailRewrite, mailSend, mailSendLater, mailBack, mailForward
        case mailNew, mailOpen, mailNext, mailPrevious, mailReply, mailDone, mailRemind, mailDoIt, mailKeep, mailUnread, mailWake, mailSearch
        case mailUndo, mailUndoCommand, mailPick1, mailPick2, mailPick3, mailWriteDraft
        case mailStar, mailTrash, mailSpam, mailMute, mailNotDone
        case mailSelect, mailSelectDown, mailSelectUp, mailSelectBelow, mailSelectAll
        case mailOnlyUnread, mailOnlyStarred, mailOnlyUnanswered, mailKeys
        case mailReplyAll, mailForwardMail, mailBcc, mailSubject
        case mailOpenFile, mailSaveFile, mailRemindNoReply
        case mailUnsubscribe, mailBlock, mailZero, mailBulk
        case mailAttach
        case mailLabel, mailMove, mailUnlabel
        case mailFrom, mailBold, mailItalic, mailUnderline, mailBullets, mailNumbers, mailQuote
        case mailSummarize
        case mailSnippet
        case mailAccept, mailMaybe, mailDecline, mailSlots
        case mailVIP
        case muteCall, joinMeeting, openMeetingThread
        case newSmallWindow, showYab, smallSpace, spaceDelete
        case fieldActions, fieldFilter, fieldPin, fieldPage, fieldSecond, fieldReveal, fieldCode, fieldShow, fieldEdit, fieldNew, fieldDelete, fieldClear
        case fieldCopy, fieldAlternate, fieldAhead, fieldMove, fieldForget, fieldDone, fieldAbout, fieldDo
        case fieldFavorite, fieldFavoriteUp, fieldFavoriteDown
        case answerSend, answerRewrite, answerInsert, answerCopy, answerAsk, answerPick1, answerPick2, answerPick3
        case callMic, callCamera, callShare, agentTakeWheel, agentHandBack, agentStop, agentAsk, feedbackSend, welcomeBack, confirmDanger
        case agentChoice1, agentChoice2, agentChoice3, agentChoice4, agentChoice5, agentChoice6, agentChoice7, agentChoice8, agentChoice9
        case pageCopyMarkdown, pageCopyFile
        case fieldAnswerAgain, fieldAnswerModel, fieldAnswerCopy, fieldAnswerTask
        case selectionCopy, selectionRetry
        case captureSave, captureWhole
        case chatDone, chatDoneKeep
        case devMode, devSheet, measure, jsonView
        case capture
        case pin, rename, closeOthers, closeBefore, closeAfter, moveLeft, moveRight, moveToWindow, pickAll, split, nextSpace, previousSpace
    }

    /// `mailWords`: a draft's words with the keyboard, where the marks' keys
    /// are theirs (⌘U Underline) and anywhere else mail's (⌘U Unsubscribe).
    enum Context: Hashable { case browser, small, space, field, fieldAnswer, answer, call, agent, capture, chat, mail, mailWords, feedback, welcome, confirmation, pageCopy }

    /// Keys heard from every app (GlobalKey), not only while Yab is in front.
    static let global: Set<Action> = [.newSmallWindow, .showYab]

    static func context(_ action: Action) -> Context {
        switch action {
        case .smallSpace: return .small
        case .spaceDelete: return .space
        case .mailCommands, .mailAccountAll, .mailAccount1, .mailAccount2, .mailAccount3, .mailAccount4, .mailAccount5,
             .mailAccount6, .mailAccount7, .mailAccount8, .mailAccount9, .mailCopyChip, .mailRewrite, .mailSend,
             .mailSendLater, .mailBack, .mailForward, .mailNew, .mailOpen, .mailNext, .mailPrevious, .mailReply,
             .mailDone, .mailRemind, .mailDoIt, .mailKeep, .mailUnread, .mailWake, .mailSearch, .mailUndo,
             .mailUndoCommand, .mailPick1, .mailPick2, .mailPick3, .mailWriteDraft,
             .mailStar, .mailTrash, .mailSpam, .mailMute, .mailNotDone,
             .mailSelect, .mailSelectDown, .mailSelectUp, .mailSelectBelow, .mailSelectAll,
             .mailOnlyUnread, .mailOnlyStarred, .mailOnlyUnanswered, .mailKeys,
             .mailReplyAll, .mailForwardMail, .mailBcc, .mailSubject, .mailOpenFile, .mailSaveFile, .mailRemindNoReply,
             .mailUnsubscribe, .mailBlock, .mailZero, .mailBulk, .mailAttach,
             .mailLabel, .mailMove, .mailUnlabel, .mailFrom, .mailSummarize, .mailSnippet,
             .mailAccept, .mailMaybe, .mailDecline, .mailSlots, .mailVIP: return .mail
        case .mailBold, .mailItalic, .mailUnderline, .mailBullets, .mailNumbers, .mailQuote: return .mailWords
        case .fieldAnswerAgain, .fieldAnswerModel, .fieldAnswerCopy, .fieldAnswerTask: return .fieldAnswer
        case .selectionCopy, .selectionRetry: return .agent
        case .captureSave, .captureWhole: return .capture
        case .chatDone, .chatDoneKeep: return .chat
        case .fieldActions, .fieldFilter, .fieldPin, .fieldPage, .fieldSecond, .fieldReveal, .fieldCode,
             .fieldShow, .fieldEdit, .fieldNew, .fieldDelete, .fieldClear,
             .fieldCopy, .fieldAlternate, .fieldAhead, .fieldMove, .fieldForget, .fieldDone, .fieldAbout, .fieldDo,
             .fieldFavorite, .fieldFavoriteUp, .fieldFavoriteDown: return .field
        case .answerSend, .answerRewrite, .answerInsert, .answerCopy, .answerAsk,
             .answerPick1, .answerPick2, .answerPick3: return .answer
        case .callMic, .callCamera, .callShare: return .call
        case .agentTakeWheel, .agentHandBack, .agentStop, .agentAsk,
             .agentChoice1, .agentChoice2, .agentChoice3, .agentChoice4, .agentChoice5,
             .agentChoice6, .agentChoice7, .agentChoice8, .agentChoice9: return .agent
        case .feedbackSend: return .feedback
        case .welcomeBack: return .welcome
        case .confirmDanger: return .confirmation
        case .pageCopyMarkdown, .pageCopyFile: return .pageCopy
        default: return .browser
        }
    }

    static func numbered(_ prefix: String, _ number: Int) -> Action? { Action(rawValue: prefix + String(number)) }

    struct Item: Identifiable {
        /// Nil for a key the key monitor keeps to itself, drawn without a
        /// recorder: ⌃Tab, ⌘1 to ⌘9.
        let action: Action?
        let does: String
        /// Said after "Already", when another wants its key.
        let taken: String
        /// The key it comes with. Nil for one that comes without any.
        let key: Hotkey?
        /// The caps of a fixed one, which may be more than one keystroke.
        var fixed: [[String]] = []
        /// The keystrokes a fixed one answers to, so no other is given them.
        var holds: [Hotkey] = []

        var id: String { action?.rawValue ?? does }

        init(_ action: Action, _ does: String, _ taken: String, _ key: Hotkey?) {
            self.action = action
            self.does = does
            self.taken = taken
            self.key = key
        }

        init(fixed caps: [[String]], _ does: String, _ taken: String, holds: [Hotkey]) {
            action = nil
            self.does = does
            self.taken = taken
            key = nil
            fixed = caps
            self.holds = holds
        }
    }

    struct Group: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    private static func k(_ key: String, _ flags: NSEvent.ModifierFlags = .command) -> Hotkey { Hotkey(key, flags) }

    static let all: [Group] = [
        Group(title: "Tabs", items: [
            Item(.newWindow, "New window", "opens a new window", k("n")),
            // Arc's ⌃⌘N is New Folder with Tabs here, Finder's and Dia's:
            // no key unless one is chosen (BlankWindow.swift).
            Item(.blankWindow, "Blank window, its tabs in no space", "opens a blank window", nil),
            Item(.closeWindow, "Close window", "closes the window", k("w", [.command, .shift])),
            Item(.newTab, "New tab, or find an open one, a setting, anything", "opens a new tab", k("t")),
            // Dia's: the folder the tab in front is in.
            Item(.newTabInFolder, "New tab in this tab’s folder", "opens a new tab in the folder", k("t", [.option, .command])),
            Item(.privateTab, "New private tab", "opens a private tab", k("n", [.shift, .command])),
            Item(.closeTab, "Close tab", "closes the tab", k("w")),
            Item(.reopen, "Reopen closed tab", "reopens a closed tab", k("t", [.shift, .command])),
            Item(.recentTab, "Last tab, hold the key to pick another", "goes to the last tab", k("⇥", .control)),
            Item(.recentTabReverse, "Previous recent tab", "goes to the previous recent tab", k("⇥", [.control, .shift])),
            Item(.nextTab, "Next tab", "goes to the next tab", k("]", [.shift, .command])),
            Item(.previousTab, "Previous tab", "goes to the previous tab", k("[", [.shift, .command])),
            // Duplicating has no key unless one is chosen.
            Item(.duplicate, "Duplicate tab", "duplicates the tab", nil),
            // No key, as Arc's favorites have none: ⇧⌘D is the address
            // bar's, Arc's Show Toolbar (feedback #323).
            Item(.pin, "Pin or unpin tab", "pins the tab", nil),
            // ⌘D keeps the tab, or releases it, as Arc's ⌘D pins a tab to
            // its sidebar (feedback #154).
            Item(.keepTab, "Keep tab, or release it", "keeps or releases the selected tabs", k("d")),
            // Finder's New Folder with Selection, and Dia's.
            Item(.folderWithTabs, "New folder with the selected tabs", "makes a folder of the selected tabs", k("n", [.control, .command])),
            Item(.rename, "Rename tab, or change a pin's letter", "renames the tab", k("r", [.control, .command])),
            Item(.split, "Split view, or put the halves apart", "splits the view", k("\\", [.control, .command])),
            Item(.moveLeft, "Move tab left", "moves the tab left", k("←", [.option, .shift, .command])),
            Item(.moveRight, "Move tab right", "moves the tab right", k("→", [.option, .shift, .command])),
            Item(.moveToWindow, "Move tab to a new window", "moves the tab to a new window", k("n", [.option, .shift, .command])),
            Item(.pickAll, "Pick every tab", "picks every tab", k("a", [.shift, .command])),
            Item(.closeOthers, "Close other tabs", "closes the other tabs", k("w", [.option, .command])),
            Item(.closeBefore, "Close tabs before this one", "closes the tabs before this one", nil),
            Item(.closeAfter, "Close tabs after this one", "closes the tabs after this one", nil),
            Item(.mute, "Mute or unmute tab", "mutes the tab", k("m", [.shift, .command])),
        ] + (1...9).map { n in Item(numbered("tab", n)!, "Go to tab \(n)\(n == 9 ? " (last)" : "")", "goes to tab \(n)", k(String(n))) }),
        Group(title: "Calls", items: [
            Item(.muteCall, "Mute or unmute the call, from any tab", "mutes the call", k("m", [.control, .command])),
            Item(.joinMeeting, "Join the next meeting on your calendar", "joins the next meeting", k("j", [.control, .command])),
            Item(.openMeetingThread, "Open what is open with the next meeting’s people", "opens the meeting’s thread",
                 k("o", [.control, .command])),
        ]),
        Group(title: "Address", items: [
            Item(.openAddress, "Open address", "opens the address", k("l")),
            Item(.copyAddress, "Copy URL", "copies the page's URL", k("c", [.shift, .command])),
            Item(.copyMarkdownLink, "Copy as a Markdown link", "copies a Markdown link", k("c", [.option, .shift, .command])),
            Item(.pasteAndGo, "Paste and go", "pastes and goes", k("v", [.shift, .command])),
            Item(.pasteAndMatchStyle, "Paste and Match Style", "pastes without formatting", k("v", [.option, .shift, .command])),
            // No key unless one is chosen: ⌘D keeps the tab, as in Arc, and
            // neither Arc nor Chrome has another key for a bookmark.
            Item(.bookmark, "Bookmark this page", "bookmarks the page", nil),
            // Tabs › Share Page…, the picker its menu item opens. No key
            // unless one is chosen: the reporter gave Arc's Share ⌃S
            // (register 2675), which no Yab default holds.
            Item(.sharePage, "Share this page", "shares the page", nil),
        ]),
        Group(title: "Page", items: [
            Item(.back, "Back", "goes back", k("[")),
            Item(.forward, "Forward", "goes forward", k("]")),
            Item(.backArrow, "Back with the arrow", "goes back", k("←")),
            Item(.forwardArrow, "Forward with the arrow", "goes forward", k("→")),
            Item(.reload, "Reload", "reloads the page", k("r")),
            Item(.stopLoading, "Stop loading", "stops loading", k(".")),
            Item(.hardReload, "Reload without the cache", "reloads without the cache", k("r", [.shift, .command])),
            Item(.find, "Find on page", "finds on the page", k("f")),
            Item(.findNext, "Find next", "finds the next one", k("g")),
            Item(.findPrevious, "Find previous", "finds the one before", k("g", [.shift, .command])),
            Item(.reader, "Reading mode", "opens reading mode", k("r", [.option, .command])),
            // No key out of the box.
            Item(.translatePage, "Translate the page, or show the original", "translates the page", nil),
            // Dark Reader's own keys for "this site" (DarkPages.swift).
            Item(.darkPage, "Dark page, or the site kept light", "darkens the page", k("d", [.option, .shift])),
            Item(.float, "Float a video", "floats a video", k("p", [.shift, .command])),
            Item(.fillForm, "Fill the form on this page", "fills the form", Hotkey("↩", .option)),
            Item(.hide, "Hide part of a page", "hides part of a page", k("h", [.shift, .command])),
            Item(.zoomIn, "Zoom in", "zooms in", k("+")),
            Item(.zoomOut, "Zoom out", "zooms out", k("-")),
            Item(.actualSize, "Actual size", "sets the actual size", k("0")),
            Item(.print, "Print", "prints", k("p")),
            Item(.capture, "Capture part of a page", "captures part of the page", k("2", [.shift, .command])),
            Item(.inspector, "Developer tools", "opens developer tools", k("i", [.option, .command])),
            Item(.console, "JavaScript console", "opens the JavaScript console", k("j", [.option, .command])),
            Item(.inspectElement, "Inspect an element", "inspects an element", k("c", [.option, .command])),
            Item(.devMode, "Developer Mode for this site", "toggles Developer Mode", k("d", .control)),
            Item(.devSheet, "A local page's errors and network", "shows errors and network", k("k", [.option, .command])),
            Item(.measure, "Rulers on a local page", "measures the page", k("u", [.option, .command])),
            Item(.jsonView, "Show JSON as text or as a tree", "switches how JSON shows", nil),
            Item(.peekTab, "Keep a peek as a tab", "keeps a peek as a tab", k("o")),
            Item(.peekSplit, "Open a peek beside the page", "opens a peek beside the page", k("o", [.shift, .command])),
            // Esc by default, and only while a peek is open: given another key,
            // Esc goes on to the page in the peek, to close what it opened.
            Item(.peekClose, "Put a peek away", "puts the peek away", Hotkey("esc", [])),
            Item(fixed: [["esc"]], "Put the page back, or close what is open", "puts the page back",
                 holds: [Hotkey("esc", [])]),
        ]),
        Group(title: "Window", items: [
            Item(.newSmallWindow, "Open a small window from any app", "opens a small window", k("n", [.option, .command])),
            // No key out of the box: every good pair is some app's already
            // (⌥Space ChatGPT's, ⌃Space the input source's).
            Item(.showYab, "Bring Yab to the front from any app", "brings Yab to the front", nil),
            Item(.smallSpace, "Open a small window in another space", "opens another space", k("o", [.option, .command])),
            Item(.sidebarTabs, "Tabs in a sidebar", "puts the tabs in a sidebar", k("s", [.shift, .command])),
            Item(.column, "Show or hide the sidebar or the tab bar", "shows or hides the sidebar or the tab bar", k("s")),
            Item(.closeChat, "Show or hide the chat column", "shows or hides the chat", Hotkey("esc", .shift)),
            // Raycast's is ⌃⌘M, which is Mute Call here.
            Item(.moveToProject, "Move the chat in the column to a project", "moves the chat to a project", k("p", [.control, .command])),
            // ⇧⌘B (feedback #160); ⌃⌘B, its
            // key before, still answers (Shortcut.also). In a draft ⇧⌘B is
            // Bcc: mail hears it first.
            Item(.bookmarksBar, "Show or hide the bookmarks bar", "shows or hides the bookmarks bar", k("b", [.shift, .command])),
            // ⇧⌘D, Arc's View › Show Toolbar: the address row over the
            // page, the sidebar kept (feedback #323).
            Item(.addressBar, "Show or hide the address bar", "shows or hides the address bar", k("d", [.shift, .command])),
            Item(.extensions, "Site controls and extensions", "opens Site Controls", k("e")),
            Item(.history, "History", "opens History", k("y")),
            Item(.downloads, "Downloads", "opens Downloads", k("j", [.shift, .command])),
            Item(.bookmarks, "Bookmarks", "opens Bookmarks", k("b", [.option, .command])),
            Item(.passwords, "Passwords", "opens Passwords", k("l", [.option, .command])),
            Item(.snippets, "Snippets, into the box you are typing in", "opens Snippets", k(";")),
            // Discoverable and recordable without claiming an existing key.
            Item(.clipboard, "Clipboard History", "opens Clipboard History", nil),
            Item(.emoji, "Emoji", "opens Emoji", nil),
            Item(.autofill, "Autofill, cards and addresses", "opens Autofill", nil),
            Item(.chats, "Chats", "opens Chats", nil),
            Item(.routines, "Routines", "opens Routines", nil),
            Item(.boostStore, "Store, boosts and plugins", "opens Store", nil),
            Item(.now, "Now", "opens Now", nil),
            Item(.purchases, "Purchases, subscriptions and orders", "opens Purchases", nil),
            Item(.mail, "Mail, and back to your tabs", "opens Mail", k("i", [.shift, .command])),
            Item(.settings, "Settings", "opens Settings", k(",")),
            // Chrome's Help › Report an Issue… key, and in every place of
            // Yab's: a page, the field, the chat, Settings (feedback #385).
            Item(.sendFeedback, "Send feedback, from anywhere in Yab", "opens Send Feedback", k("i", [.option, .shift])),
            Item(.nextSpace, "Next space", "goes to the next space", k("→", [.control, .command])),
            Item(.previousSpace, "Previous space", "goes to the previous space", k("←", [.control, .command])),
        ] + (1...9).map { n in Item(numbered("space", n)!, "Go to space \(n)", "goes to space \(n)", Hotkey(String(n), .control)) }
          + (1...9).map { n in Item(numbered("sendSpace", n)!, "Send tab to space \(n)", "sends a tab to space \(n)", Hotkey(String(n), [.control, .shift])) }),
        // In the order ? lists them too (MailField): moving through mail, what
        // is done to a thread, picking threads, narrowing the list, going to
        // another, writing, then the keys with ⌘.
        Group(title: "Mail", items: [
            Item(.mailOpen, "Open the selected message", "opens the selected message", Hotkey("o", [])),
            Item(.mailNext, "Next Mail item", "goes to the next Mail item", Hotkey("j", [])),
            Item(.mailPrevious, "Previous Mail item", "goes to the previous Mail item", Hotkey("k", [])),
            Item(.mailSearch, "Search Mail", "searches Mail", Hotkey("/", [])),
            Item(.mailReply, "Reply to a message", "replies to a message", Hotkey("r", [])),
            // ↩ in a thread; in the list it opens the thread, whatever is chosen here.
            Item(.mailReplyAll, "Reply to everyone on a message", "replies to everyone", Hotkey("↩", [])),
            Item(.mailForwardMail, "Forward a message", "forwards a message", Hotkey("f", [])),
            Item(.mailDone, "Mark a message done", "marks a message done", Hotkey("e", [])),
            Item(.mailNotDone, "Mark a message not done, back in the inbox", "marks a message not done", Hotkey("e", .shift)),
            Item(.mailRemind, "Remind me about a message", "sets a Mail reminder", Hotkey("h", [])),
            Item(.mailStar, "Star a message, or unstar it", "stars a message", Hotkey("s", [])),
            Item(.mailTrash, "Move a message to the Trash, or out of it", "moves a message to the Trash", Hotkey("3", .shift)),
            Item(.mailSpam, "Mark a message as spam, or not spam", "marks a message as spam", Hotkey("1", .shift)),
            Item(.mailMute, "Mute a message, or unmute it", "mutes a message", Hotkey("m", .shift)),
            Item(.mailUnsubscribe, "Unsubscribe from a message's mailing list", "unsubscribes from a list", k("u")),
            // In ⌘K, with no key until one is given here.
            Item(.mailBlock, "Block a message's sender", "blocks a sender", nil),
            Item(.mailLabel, "Label a message, or take a label off", "labels a message", Hotkey("l", [])),
            Item(.mailMove, "Move a message to a label, out of the inbox", "moves a message to a label", Hotkey("v", [])),
            Item(.mailUnlabel, "Remove the label of the list you are in", "removes a label", Hotkey("y", [])),
            // In ⌘K, with no key until one is given here.
            Item(.mailVIP, "Add a message's sender to VIP, or take them off", "adds a sender to VIP", nil),
            Item(.mailDoIt, "Do the message's task", "does the message's task", Hotkey("d", [])),
            // In ⌘K and under ⌘J, with no key until one is given here.
            Item(.mailSummarize, "Summarize the selected messages, or the open one", "summarizes messages", nil),
            Item(.mailKeep, "Keep a message", "keeps a message", Hotkey("p", [])),
            Item(.mailUnread, "Mark a message unread", "marks a message unread", Hotkey("u", [])),
            Item(.mailWake, "Wake a message", "wakes a message", Hotkey("w", [])),
            Item(.mailUndo, "Undo the last Mail action", "undoes a Mail action", Hotkey("z", [])),
            Item(.mailUndoCommand, "Undo the last Mail action with Command", "undoes a Mail action", k("z")),
            // A message's files, a chip each under its words.
            Item(.mailOpenFile, "Open a message's first attachment or link", "opens an attachment or link", k("o")),
            Item(fixed: [["Space"]], "Look at the chosen attachment with Quick Look", "looks at an attachment", holds: []),
            Item(fixed: [["↩"]], "Open the chosen attachment in its app", "opens an attachment", holds: []),
            Item(.mailSaveFile, "Save the chosen attachment to Downloads", "saves an attachment", k("s")),
            Item(.mailSelect, "Select a message, or let it go", "selects a message", Hotkey("x", [])),
            Item(.mailSelectDown, "Select the next message too", "selects the next message too", Hotkey("j", .shift)),
            Item(.mailSelectUp, "Select the previous message too", "selects the previous message too", Hotkey("k", .shift)),
            Item(.mailSelectBelow, "Select this message and every one below it", "selects every message below", k("a")),
            Item(.mailSelectAll, "Select every message in the list", "selects every message", k("a", [.shift, .command])),
            Item(fixed: [["esc"]], "Let the selection go, or show the whole list again", "lets the selection go", holds: []),
            Item(.mailOnlyUnread, "Show only unread messages", "shows only unread messages", Hotkey("u", .shift)),
            Item(.mailOnlyStarred, "Show only starred messages", "shows only starred messages", Hotkey("s", .shift)),
            Item(.mailOnlyUnanswered, "Show only messages you haven't written in", "shows only messages without your reply", Hotkey("r", .shift)),
            Item(.mailZero, "Get Me To Zero: mark the inbox done", "gets the inbox to zero", nil),
            Item(.mailBulk, "Show bulk actions, to take one back", "shows bulk actions", nil),
            // An invitation over a thread (MailCalendar).
            Item(.mailAccept, "Accept an invitation", "accepts an invitation", Hotkey("a", [])),
            Item(.mailMaybe, "Answer maybe to an invitation", "answers maybe to an invitation", Hotkey("m", [])),
            Item(.mailDecline, "Decline an invitation", "declines an invitation", Hotkey("n", [])),
            // G and the key after it: no key of its own to change, and G is
            // given to nothing else in mail.
            // The column's lists and splits in its order, empty splits passed by.
            Item(fixed: [["⇥"]], "Next list in the Mail column", "goes to the next Mail list", holds: []),
            Item(fixed: [["⇧", "⇥"]], "Previous list in the Mail column", "goes to the previous Mail list", holds: []),
            Item(fixed: [["G"]], "Go to a Mail list, with the key after G", "goes to a Mail list", holds: [Hotkey("g", [])]),
        ] + MailGo.places.map { place in
            Item(fixed: [["G"], place.key.caps], "Go to " + place.name, "goes to " + place.name, holds: [])
        } + [
            Item(.mailNew, "Write a new message", "writes a new message", Hotkey("c", [])),
            Item(.mailWriteDraft, "Ask to write an empty reply", "starts writing a Mail reply", Hotkey("space", [])),
            Item(.mailRewrite, "Rewrite a Mail draft", "rewrites a Mail draft", k("j")),
            Item(.mailSend, "Send a Mail draft", "sends a Mail draft", k("↩")),
            Item(.mailSendLater, "Send a Mail draft later", "sends a Mail draft later", k("↩", [.shift, .command])),
            Item(.mailBcc, "Add Bcc to a Mail draft", "adds Bcc to a Mail draft", k("b", [.shift, .command])),
            Item(.mailSubject, "Change a Mail draft's subject", "changes a Mail draft's subject", k("s", [.shift, .command])),
            Item(.mailRemindNoReply, "Remind me if nobody replies to a Mail draft", "sets a Mail reminder if no reply", k("h", [.shift, .command])),
            Item(.mailAttach, "Attach files to a Mail draft", "attaches files to a Mail draft", k("u", [.shift, .command])),
            // Shown when the account sends as more than one address (MailSendAs).
            Item(.mailFrom, "Change the address a Mail draft goes from", "changes a Mail draft's From", k("f", [.shift, .command])),
            Item(.mailSnippet, "Insert a snippet into a Mail draft", "inserts a snippet", k(";")),
            // The list's ⇧⌘A selects every message; in a draft, the same key
            // is free slots: keys go by what is in front (Keymap.apart).
            Item(.mailSlots, "Insert free slots into a Mail draft", "inserts free slots into a Mail draft", k("a", [.shift, .command])),
            Item(.mailCopyChip, "Copy the selected Mail chip or code", "copies the selected Mail chip or code", k("c")),
            Item(.mailCommands, "Show Mail commands", "shows Mail commands", k("k")),
            Item(.mailKeys, "Show Mail's keys", "shows Mail's keys", Hotkey("/", .shift)),
            Item(.mailBack, "Go back in Mail", "goes back in Mail", k("[")),
            Item(.mailForward, "Go forward in Mail", "goes forward in Mail", k("]")),
            Item(.mailAccountAll, "Show every Mail account", "shows every Mail account", k("0")),
        ] + (1...9).map { n in Item(numbered("mailAccount", n)!, "Show Mail account \(n)", "shows Mail account \(n)", k(String(n))) }
          + (1...3).map { n in Item(numbered("mailPick", n)!, "Choose prepared reply \(n)", "chooses prepared reply \(n)", Hotkey(String(n), [])) }),
        // While a draft's words have the keyboard, and only then: anywhere
        // else in mail the same keys are mail's (⌘U is Unsubscribe in the list).
        Group(title: "Mail Formatting", items: [
            Item(.mailBold, "Bold the chosen words of a Mail draft", "bolds a Mail draft's words", k("b")),
            Item(.mailItalic, "Italicize the chosen words of a Mail draft", "italicizes a Mail draft's words", k("i")),
            Item(.mailUnderline, "Underline the chosen words of a Mail draft", "underlines a Mail draft's words", k("u")),
            Item(.mailBullets, "Make a bulleted list in a Mail draft", "makes a bulleted list in a Mail draft", k("8", [.shift, .command])),
            Item(.mailNumbers, "Make a numbered list in a Mail draft", "makes a numbered list in a Mail draft", k("7", [.shift, .command])),
            Item(.mailQuote, "Quote lines of a Mail draft", "quotes lines of a Mail draft", k("9", [.shift, .command])),
        ]),
        Group(title: "Field", items: [
            Item(.spaceDelete, "Delete selected space", "deletes a space", k("⌫")),
            Item(.fieldActions, "Show actions for the selected row", "shows row actions", k("k")),
            Item(.fieldAbout, "Show the About menu", "shows the About menu", k("k", [.shift, .command])),
            Item(.fieldFilter, "Cycle the place filter", "cycles the filter", k("p")),
            Item(.fieldPin, "Pin or unpin the selected clip or emoji", "pins a clip or emoji", k("p", [.command, .shift])),
            Item(.fieldPage, "Open the selected page", "opens the page", k("o")),
            Item(.fieldSecond, "Copy the secondary value", "copies the secondary value", k("c", [.command, .shift])),
            Item(.fieldReveal, "Reveal the selected file", "reveals the file", k("r", [.command, .shift])),
            Item(.fieldCode, "Copy the one-time code", "copies the code", k("c", [.command, .option])),
            Item(.fieldShow, "Show or hide the selected secret", "shows a secret", k("y")),
            Item(.fieldEdit, "Edit the selected item", "edits the item", k("e")),
            Item(.fieldNew, "Create a new card", "creates a card", k("n")),
            Item(.fieldDelete, "Delete the selected item", "deletes the item", Hotkey("x", .control)),
            Item(.fieldClear, "Clear unpinned items", "clears unpinned items", Hotkey("x", [.control, .shift])),
            Item(.fieldCopy, "Copy, open in a background tab, or Do It on a Now row", "copies, opens behind or does it", k("↩")),
            // ⌥↩ opens the place in Split View, as Arc's command bar; on a Now
            // row it is Later, on a clip Plain Text. Removing the key here
            // takes ⌥-click in the field's list with it (Browser.clickWay).
            Item(.fieldAlternate, "Open in Split View, or a row's alternate action", "opens in Split View or takes the alternate action", Hotkey("↩", .option)),
            Item(.fieldAhead, "Open field result in a new tab", "opens in a new tab", k("↩", [.command, .shift])),
            Item(.fieldMove, "Open top search result, or move a tab here", "opens the top result or moves the tab here", Hotkey("↩", .shift)),
            Item(.fieldForget, "Delete the selected history item", "deletes it from history", Hotkey("⌫", .shift)),
            Item(.fieldDone, "Mark the selected suggestion done", "marks it done", Hotkey("⌫", [])),
            Item(.fieldDo, "Have the agent do the selected Now row", "hands it to the agent", k("j")),
            // Kept in the field's root (FieldFavorites); ⇧⌘F is Mail's
            // From only in Mail's own place, never in the plain field.
            Item(.fieldFavorite, "Add the selected row to Favorites, or remove it", "adds to Favorites", k("f", [.shift, .command])),
            Item(.fieldFavoriteUp, "Move the selected favorite up", "moves a favorite up", k("↑", [.option, .command])),
            Item(.fieldFavoriteDown, "Move the selected favorite down", "moves a favorite down", k("↓", [.option, .command])),
        ]),
        Group(title: "Answer", items: [
            Item(.answerSend, "Send an agent draft, or finish its answer", "sends the draft or puts the answer away", k("↩")),
            Item(.answerRewrite, "Rewrite an agent draft", "rewrites the draft", k("r")),
            Item(.answerInsert, "Insert an agent answer", "inserts the answer", k("v", [.command, .shift])),
            Item(.answerCopy, "Copy an agent answer", "copies the answer", k("c")),
            Item(.answerAsk, "Ask about an agent answer", "asks about the answer", k("j")),
            Item(.answerPick1, "Choose answer option 1", "chooses option 1", k("1")),
            Item(.answerPick2, "Choose answer option 2", "chooses option 2", k("2")),
            Item(.answerPick3, "Choose answer option 3", "chooses option 3", k("3")),
        ]),
        Group(title: "Field Answer", items: [
            Item(.fieldAnswerAgain, "Try a field answer again", "tries the field answer again", k("r")),
            Item(.fieldAnswerModel, "Change a field answer's model", "changes the field answer's model", k("r", [.shift, .command])),
            Item(.fieldAnswerCopy, "Copy a field answer", "copies the field answer", k("c", [.shift, .command])),
            Item(.fieldAnswerTask, "Send a field answer to an agent", "sends the field answer to an agent", k("↩")),
        ]),
        Group(title: "Selection", items: [
            Item(.selectionCopy, "Copy an agent selection result", "copies the selection result", k("c")),
            Item(.selectionRetry, "Retry an agent selection", "retries the selection", k("r")),
        ]),
        Group(title: "Capture", items: [
            Item(.captureSave, "Save a capture", "saves a capture", k("s")),
            Item(.captureWhole, "Capture the whole page", "captures the whole page", Hotkey("f", [])),
        ]),
        Group(title: "Chat", items: [
            Item(.chatDone, "Finish the chat", "finishes the chat", k("↩")),
            Item(.chatDoneKeep, "Finish the chat and keep it open", "finishes and keeps the chat open", k("↩", [.option, .command])),
        ]),
        Group(title: "Other Windows", items: [
            Item(.callMic, "Toggle call microphone", "toggles the microphone", k("d")),
            Item(.callCamera, "Toggle call camera", "toggles the camera", k("e")),
            Item(.callShare, "Share screen in a call", "shares the screen", nil),
            Item(.agentTakeWheel, "Take over from an agent", "takes over", k(".")),
            Item(.agentStop, "Stop agent on this tab", "stops the agent", k(".", [.shift, .command])),
            Item(.agentHandBack, "Hand back to an agent", "hands back", k("↩")),
            Item(.agentAsk, "Ask an agent about this page", "asks the agent", k("j")),
            Item(.feedbackSend, "Send feedback", "sends feedback", k("↩")),
            Item(.welcomeBack, "Go back during welcome", "goes back", k("[")),
            Item(.confirmDanger, "Confirm a destructive action", "confirms the action", k("↩")),
        ] + (1...9).map { n in Item(numbered("agentChoice", n)!, "Choose agent option \(n)", "chooses agent option \(n)", Hotkey(String(n), [])) }),
        Group(title: "Page Copy", items: [
            // No keys of their own unless chosen: a bare letter after ⌘A was
            // taken from the page, Gmail's F among them. The pill's parts
            // are pressed instead.
            Item(.pageCopyMarkdown, "Copy selected page as Markdown", "copies Markdown", nil),
            Item(.pageCopyFile, "Save selected page for an agent", "saves the page", nil),
        ]),
    ]

    static let items: [Item] = all.flatMap(\.items)

    /// What stays yab's before a page has its turn at the key, whatever
    /// key it has now (ContentView.pageFirst): what makes, closes and moves
    /// between tabs, reload, wanted most on a
    /// page too busy or too stuck to hand anything back, ⇧⌘V, which no page
    /// has a use for, Copy URL and Copy Markdown Link, which Arc and Dia
    /// keep over Docs' word count and Gmail's Cc (register #376), and
    /// reading mode and the inspector, which were never the page's. The
    /// sidebar (⌘S) and Back and Forward (⌘[ ⌘]) are Arc's ahead of the page
    /// too: on a page that keeps every ⌘ key (evals/reserved-keys) Arc 1.172
    /// put its sidebar away on ⌘S whatever the page did with it, and went
    /// back and forward on ⌘[ ⌘] the page never heard, where they had been
    /// the page's first with "Again to hide the sidebar" in the corner. ⌘F, ⌘G and ⌘Y stay the page's first, as in Arc and
    /// Chrome.
    /// ⌘← and ⌘→ stay first, but only outside text, where they move the
    /// caret (ContentView.perform).
    static let first: Set<Action> = [
        .column, .back, .forward,
        .newWindow, .closeWindow, .newTab, .newTabInFolder, .reopen, .privateTab, .closeTab, .closeOthers, .closeBefore, .closeAfter, .nextTab, .previousTab, .recentTab, .recentTabReverse, .openAddress, .pasteAndGo, .copyAddress, .copyMarkdownLink,
        .backArrow, .forwardArrow, .reload, .stopLoading, .hardReload, .fillForm, .closeChat, .reader, .inspector, .console, .inspectElement, .devMode, .devSheet, .measure, .capture,
        .sendFeedback, .nextSpace, .previousSpace,
        .clipboard, .emoji, .autofill, .chats, .routines, .boostStore, .now, .purchases,
        .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9,
        .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9,
        .sendSpace1, .sendSpace2, .sendSpace3, .sendSpace4, .sendSpace5, .sendSpace6, .sendSpace7, .sendSpace8, .sendSpace9,
    ]

    /// The same browser-first decision the key monitor uses after custom
    /// bindings resolve. A secondary alias such as F12 still lets the page
    /// have its existing turn before the browser.
    static func reservesPageKey(_ action: Action, readAs hotkey: Hotkey?) -> Bool {
        first.contains(action) && hotkey.flatMap { also[$0] } == nil
    }

    /// A second key an action answers to unless its key was taken away
    /// on purpose, and while nothing else was given this one (`Keymap.alias`):
    /// F12 for the inspector, the page having it first (github.dev and web IDEs go to a definition on F12);
    /// ⌃⌘B for the bookmarks bar, its key until ⇧⌘B took over (feedback
    /// #160), so the hands that learned it keep it.
    static let also: [Hotkey: Action] = [Hotkey("f12", []): .inspector, Hotkey("b", [.control, .command]): .bookmarksBar]

    /// The same for the field's own keys, heard where the field asks
    /// (Keymap.matches): ⇧⌦, fn⇧⌫ on a laptop, is Chrome's key for a
    /// suggestion taken out of the list and the history (#2017: it did
    /// nothing here, only ⇧⌫ did).
    static let fieldAlso: [Hotkey: Action] = [Hotkey("⌦", .shift): .fieldForget]

    /// Each action's menu item, by its title, the name System Settings'
    /// App Shortcuts knows it by (see Hotkeys).
    private static let fixedTitles: [Action: String] = [
        .newWindow: "New Window", .blankWindow: "Blank Window", .closeWindow: "Close Window", .newTab: "New Tab", .privateTab: "New Private Window", .closeTab: "Close Tab", .reopen: "Reopen Closed Tab",
        .nextTab: "Next Tab", .previousTab: "Previous Tab", .duplicate: "Duplicate Tab", .mute: "Mute Tab",
        .openAddress: "Open Address…", .copyAddress: "Copy URL", .copyMarkdownLink: "Copy Markdown Link", .sharePage: "Share Page\u{2026}", .pasteAndGo: "Paste and Go", .pasteAndMatchStyle: "Paste and Match Style", .keepTab: "Keep Tab", .folderWithTabs: "New Folder with Tabs", .newTabInFolder: "New Tab in Folder", .bookmark: "Add This Page",
        .back: "Back", .forward: "Forward", .reload: "Reload Page", .stopLoading: "Stop Loading", .hardReload: "Reload Without Cache",
        .find: "Find on Page…", .findNext: "Find Next", .findPrevious: "Find Previous", .reader: "Reading Mode", .translatePage: "Translate Page", .darkPage: "Dark Page",
        .float: "Float Video", .hide: "Hide Elements…", .zoomIn: "Zoom In",
        .zoomOut: "Zoom Out", .actualSize: "Actual Size", .print: "Print…", .inspector: "Developer Tools",
        .console: "JavaScript Console", .inspectElement: "Inspect Element", .devMode: "Developer Mode", .devSheet: "Errors and Network", .measure: "Measure", .jsonView: "Show JSON as Text", .capture: "Capture…",
        .peekTab: "Open Peek as Tab", .peekSplit: "Open Peek in Split View",
        .peekClose: "Close Peek",
        .sidebarTabs: "Show Tabs in Sidebar", .column: "Hide Sidebar", .closeChat: "Hide Chat", .moveToProject: "Move to Project\u{2026}", .bookmarksBar: "Show Bookmarks Bar",
        .addressBar: "Show Address Bar", .extensions: "Site Controls", .history: "Search History",
        .downloads: "Search Downloads", .bookmarks: "Show Bookmarks", .passwords: "Passwords", .settings: "Settings…", .mail: "Mail",
        .agentStop: "Stop Agent",
        .sendFeedback: "Send Feedback…",
        .muteCall: "Mute Call", .joinMeeting: "Join Next Meeting", .openMeetingThread: "Open Meeting Thread",
        .pin: "Pin Tab", .rename: "Rename Tab…", .split: "Split View", .moveLeft: "Move Tab Left", .moveRight: "Move Tab Right",
        .moveToWindow: "Move Tab to New Window", .pickAll: "Pick All Tabs", .closeOthers: "Close Other Tabs",
    ]

    /// Layout-dependent labels still have stable action ids and accept both
    /// names in App Shortcuts after the layout changes.
    static var titles: [Action: String] {
        let sidebar = Store.settings.object(forKey: "sidebar") as? Bool
            ?? (Store.settings.string(forKey: "manner") == "side")
        return titles(sidebar: sidebar)
    }

    static func titles(sidebar: Bool) -> [Action: String] {
        var out = fixedTitles
        out[.closeBefore] = sidebar ? "Close Tabs Above" : "Close Tabs to the Left"
        out[.closeAfter] = sidebar ? "Close Tabs Below" : "Close Tabs to the Right"
        return out
    }

    static let titled: [String: Action] = {
        var out = Dictionary(uniqueKeysWithValues: fixedTitles.map { ($1, $0) })
        for sidebar in [false, true] {
            out[titles(sidebar: sidebar)[.closeBefore]!] = .closeBefore
            out[titles(sidebar: sidebar)[.closeAfter]!] = .closeAfter
        }
        return out
    }()

    static let byAction: [Action: Item] = Dictionary(
        uniqueKeysWithValues: items.compactMap { item in item.action.map { ($0, item) } }
    )

    /// What macOS or every Mac app keeps: never offered, not even twice.
    static let system: Set<Hotkey> = [
        k("q"), k("h"), k("h", [.option, .command]), k("m"), k("m", [.option, .command]),
        k("⇥"), k("⇥", [.shift, .command]), k("`"), k("`", [.shift, .command]),
        k("space"), k("space", [.option, .command]), k("space", [.control, .command]),
        Hotkey("space", .control), Hotkey("space", [.control, .option]),
        k("3", [.shift, .command]), k("4", [.shift, .command]), k("5", [.shift, .command]), k("6", [.shift, .command]),
        k("q", [.control, .command]), k("esc", [.option, .command]), k("/", [.shift, .command]),
        k("f", [.control, .command]),
    ]

    /// Of those, what an action may still take from macOS, as Arc and Dia
    /// let it: ⌘` and ⇧⌘`, macOS's walk through an app's windows, for
    /// the tab switcher (feedback #148). Taken, they walk tabs instead.
    static let fromMac: [Action: Set<Hotkey>] = [
        .recentTab: [k("`"), k("`", [.shift, .command])],
        .recentTabReverse: [k("`"), k("`", [.shift, .command])],
    ]

    /// Of those, the ones an item of yab's own menus holds, by the item's
    /// title as App Shortcuts names it. macOS keeps such a key only while
    /// the item has it: give Hide Yab other keys in System Settings ›
    /// Keyboard › App Shortcuts and ⌘H is as free as any other key
    /// (register 2989).
    @MainActor static var menuHeld: [String: Hotkey] {
        let appMenu = NSApp?.mainMenu?.items.first?.submenu
        let hide = appMenu?.items.first { $0.action == #selector(NSApplication.hide(_:)) }?.title
            ?? "Hide " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Yab")
        return [hide: k("h")]
    }

    /// The keys of `held` whose item App Shortcuts (`userKeys`, title to
    /// keys in its own writing) gave other keys.
    static func givenBack(by userKeys: [String: String], held: [String: Hotkey]) -> Set<Hotkey> {
        Set(held.compactMap { title, key in
            guard let value = userKeys[title], Hotkey(userKey: value) != key else { return nil }
            return key
        })
    }

    /// What App Shortcuts has given back now, set by Keymap.take(system:)
    /// on the main thread whenever App Shortcuts are read again.
    nonisolated(unsafe) static var givenBack: Set<Hotkey> = []

    /// macOS keeps this key from `action` (from every action, without one).
    static func kept(_ hotkey: Hotkey, from action: Action?) -> Bool {
        system.contains(hotkey) && !givenBack.contains(hotkey)
            && !(action.flatMap { fromMac[$0]?.contains(hotkey) } ?? false)
    }
}

// MARK: - the keys as chosen

/// The key each action answers to now. What someone chose is kept as one
/// dictionary in Store.settings: no entry is the key it comes with, an
/// empty one is none at all.
@MainActor
final class Keymap {
    static let shared = Keymap()
    private static let storeKey = "shortcuts"

    private(set) var chosen: [String: String]
    /// One per action, for its menu item and its row to watch, so a key
    /// changed wakes the two that show it and not every one of them.
    private var slots: [Shortcut.Action: KeySlot] = [:]
    /// Each keystroke's action, for the key monitor, rebuilt on a change.
    private var owners: [Hotkey: Shortcut.Action] = [:]
    private var current: [Shortcut.Action: Hotkey] = [:]
    private var commandSlots: [Command: KeySlot] = [:]
    private var commandCurrent: [Command: Hotkey] = [:]
    /// Settings' search rows for the shortcuts, with the keys as they are.
    private(set) var index: [SettingsItem] = []

    /// Keys System Settings' App Shortcuts gave a menu item of yab's: AppKit
    /// shows and matches them over the item's own, so they are the keys,
    /// ahead of any chosen here.
    private var system: [Shortcut.Action: Hotkey] = [:]

    /// A recorder is listening: every key is its, not the window's.
    var recording = false
    /// What the recorder said last, for the bench to read back.
    var said = ""

    private init() {
        chosen = Store.settings.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
        for action in Shortcut.Action.allCases { slots[action] = KeySlot() }
        for command in CommandHotkeys.commands { commandSlots[command] = KeySlot() }
        Startup.stage("keymap") { rebuild() }
    }

    func slot(for command: Command) -> KeySlot { commandSlots[command.shortcutCommand]! }
    func keys(for command: Command) -> Hotkey? { commandCurrent[command.shortcutCommand] }
    func isDefault(command: Command) -> Bool { chosen[command.shortcutID] == nil }

    func set(_ key: Hotkey?, forCommand command: Command) {
        guard CommandHotkeys.commands.contains(command.shortcutCommand),
              key.map({ Self.valid($0, for: .duplicate) }) ?? true else { return }
        chosen[command.shortcutID] = key == command.defaultHotkey ? nil : key?.stored ?? ""
        save()
    }

    func reset(command: Command) {
        if let key = command.defaultHotkey, let clash = clash(key, forCommand: command) {
            let displaced = Self.holders(of: key, for: nil, in: current)
            switch clash {
            case .refused: return
            case .taken(_, let free): free()
            }
            // Restore a displaced action's default if it is free, as the
            // ordinary action rows do, rather than leaving it unbound.
            for action in displaced {
                guard let fallback = Shortcut.byAction[action]?.key,
                      !Self.conflicts(action, fallback, .duplicate, key),
                      !current.contains(where: { Self.conflicts($0.key, $0.value, action, fallback) }),
                      !commandCurrent.contains(where: { Self.conflicts(.duplicate, $0.value, action, fallback) }) else { continue }
                chosen[action.rawValue] = nil
            }
        }
        chosen[command.shortcutID] = nil
        save()
    }

    func clash(_ key: Hotkey, forCommand command: Command) -> Clash? {
        clash(key, for: nil as Shortcut.Action?, commandAction: command.shortcutCommand)
    }

    /// Lookup is separate from availability: an unavailable binding falls
    /// through, without trying another interpretation or a legacy key.
    func hasCommand(_ key: Hotkey) -> Bool {
        commandCurrent.values.contains { Self.keysOverlap($0, key) }
    }

    private func firstOwner(in readings: [Hotkey]) -> Hotkey? {
        readings.first { action(for: $0) != nil || hasCommand($0) }
    }

    func command(for event: NSEvent) -> Command? { command(for: Hotkey.readings(event)) }

    func command(for readings: [Hotkey]) -> Command? {
        guard let key = firstOwner(in: readings) else { return nil }
        return commandCurrent.first { Self.keysOverlap($0.value, key) }?.key
    }

    @discardableResult func run(_ command: Command, in browser: Browser) -> Bool {
        guard let available = CommandHotkeys.available(command, in: browser) else { return false }
        if browser.fieldShowing { browser.close() }
        available.run(in: browser)
        return true
    }

    /// Resolve commands and actions in one priority order. Commands use the
    /// browser context, so page-first, global and modal owners still conflict.
    struct Resolution {
        var actions: [Shortcut.Action: Hotkey] = [:]
        var commands: [Command: Hotkey] = [:]
    }

    static func resolveAll(chosen: [String: String], system: [Shortcut.Action: Hotkey] = [:]) -> Resolution {
        struct Candidate {
            var action: Shortcut.Action?
            var command: Command?
            let key: Hotkey
            let priority: Int
            let order: Int
        }
        var candidates = bindings(chosen: chosen, system: system).map {
            Candidate(action: $0.action, key: $0.key, priority: $0.priority, order: $0.order)
        }
        for (order, command) in CommandHotkeys.commands.enumerated() {
            let saved = chosen[command.shortcutID]
            if saved == "" { continue }
            let key = saved.flatMap { Hotkey(stored: $0) } ?? command.defaultHotkey
            guard let key, valid(key, for: .duplicate) else { continue }
            candidates.append(Candidate(command: command, key: key, priority: saved == nil ? 1 : 2,
                                        order: Shortcut.items.count + order))
        }
        var result = Resolution()
        for candidate in candidates.sorted(by: { $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority }) {
            let context = candidate.action ?? .duplicate
            guard !result.actions.contains(where: { conflicts($0.key, $0.value, context, candidate.key) }),
                  !result.commands.contains(where: { conflicts(.duplicate, $0.value, context, candidate.key) }) else { continue }
            if let action = candidate.action { result.actions[action] = candidate.key }
            if let command = candidate.command { result.commands[command] = candidate.key }
        }
        return result
    }

    func slot(_ action: Shortcut.Action) -> KeySlot { slots[action]! }

    func keys(_ action: Shortcut.Action) -> Hotkey? {
        guard let key = current[action] else { return nil }
        if action == .pasteAndMatchStyle, chosen[action.rawValue] == nil, system[action] == nil {
            var extensionKeys: [Hotkey] = []
            if #available(macOS 15.4, *) {
                let owner = Extensions.here
                extensionKeys = owner.contexts.flatMap { id, context in
                    context.commands.compactMap { command -> Hotkey? in
                        guard !ExtensionCommands.off(id, command.id), let key = command.activationKey else { return nil }
                        return Hotkey(key, command.modifierFlags)
                    }
                }
                extensionKeys += owner.asleep.flatMap { id in
                    (owner.tipFacts[id]?.keys ?? []).filter { !ExtensionCommands.off(id, $0.command) }.map(\.hotkey)
                }
                // And the keys Chrome gave the commands of those that run in Chromium.
                extensionKeys += (ChromiumExtensionCommands.native(for: owner)?.items ?? []).filter(\.enabled).flatMap { item in
                    item.commands.compactMap { ExtensionCommands.off(item.id, $0.name) ? nil : $0.hotkey }
                }
            }
            return Self.pasteStyleKey(key, chosen: chosen, system: system,
                                      quickActions: QuickActions.shared, extensionKeys: extensionKeys)
        }
        return key
    }

    /// An existing saved Quick Action owns its key before this new default.
    /// An explicit later user choice keeps the ordinary recorder policy.
    static func pasteStyleKey(_ key: Hotkey, chosen: [String: String],
                              system: [Shortcut.Action: Hotkey], quickActions: QuickActions,
                              extensionKeys: [Hotkey] = []) -> Hotkey? {
        if chosen[Shortcut.Action.pasteAndMatchStyle.rawValue] == nil,
           system[.pasteAndMatchStyle] == nil,
           quickActions.action(for: key) != nil || extensionKeys.contains(key) { return nil }
        return key
    }

    func matches(_ event: NSEvent, _ action: Shortcut.Action) -> Bool {
        matches(Hotkey.readings(event), action)
    }

    func matches(_ readings: [Hotkey], _ action: Shortcut.Action) -> Bool {
        guard let key = keys(action) else { return false }
        if heard(readings) == key { return true }
        // Its second key (`Shortcut.fieldAlso`), while it keeps its own
        // and nothing was given that one.
        return chosen[action.rawValue] == nil
            && readings.contains { Shortcut.fieldAlso[$0] == action && !bound.contains($0) }
    }

    /// The first reading of a press that is some action's key, anywhere:
    /// a mark's reading is heard only when the key itself is nobody's, so
    /// ⌘1 on AZERTY (⌘&) is never ⇧⌘7 too.
    func heard(_ readings: [Hotkey]) -> Hotkey? {
        readings.first { bound.contains($0) } ?? readings.first
    }
    private var bound: Set<Hotkey> = []

    /// Which action a press is, by the first of its readings that is one
    /// (Hotkey.readings), and the keystroke it was read as.
    func action(for event: NSEvent) -> (hotkey: Hotkey, action: Shortcut.Action)? {
        guard let key = firstOwner(in: Hotkey.readings(event)), let action = action(for: key) else { return nil }
        return (hotkey: key, action: action)
    }

    /// The same for an action whose key came from App Shortcuts.
    func systemBrowserAction(for event: NSEvent) -> Shortcut.Action? {
        guard let found = action(for: event), systemBrowserAction(for: found.hotkey) == found.action else { return nil }
        return found.action
    }

    /// App Shortcuts as macOS keeps them, title to keys in its own writing
    /// (Hotkeys.userKeys): read again whenever they may have changed.
    func take(system raw: [String: String]) {
        var given: [Shortcut.Action: Hotkey] = [:]
        let normalized = Hotkeys.normalizedUserKeys(raw, visibleTitles: Shortcut.titles)
        for (action, title) in Shortcut.titles {
            if let value = normalized[title], let hotkey = Hotkey(userKey: value) { given[action] = hotkey }
        }
        let givenBack = Shortcut.givenBack(by: raw, held: Shortcut.menuHeld)
        guard given != system || givenBack != Shortcut.givenBack else { return }
        system = given
        Shortcut.givenBack = givenBack
        rebuild()
    }

    func isDefault(_ action: Shortcut.Action) -> Bool { chosen[action.rawValue] == nil }

    /// Which action a keystroke is, if any. ⌘+ on a keyboard where + is
    /// shift and = is also Zoom In, as it has always been, while Zoom In
    /// keeps its own key.
    func action(for hotkey: Hotkey) -> Shortcut.Action? {
        if let action = Self.mappedBrowserAction(for: hotkey, owners: owners) {
            if action == .pasteAndMatchStyle, keys(action) == nil { return nil }
            return action
        }
        guard !commandCurrent.values.contains(where: { Self.keysOverlap($0, hotkey) }) else { return nil }
        return Self.alias(hotkey, chosen: chosen)
    }

    /// The action a second key (`Shortcut.also`) stands for, once no
    /// action owns that key: any but one whose key was emptied on purpose
    /// (""). One that lost its main key to a key chosen for another, as
    /// the bookmarks bar does to ⇧⌘B chosen elsewhere, keeps the second.
    static func alias(_ hotkey: Hotkey, chosen: [String: String]) -> Shortcut.Action? {
        guard let action = Shortcut.also[hotkey], chosen[action.rawValue] != "" else { return nil }
        return action
    }

    static func mappedBrowserAction(for hotkey: Hotkey, owners: [Hotkey: Shortcut.Action]) -> Shortcut.Action? {
        if let action = owners[hotkey] { return action }
        if hotkey.key == "=" {
            return owners[Hotkey("+", hotkey.flags)] ?? owners[Hotkey("+", hotkey.flags.subtracting(.shift))]
        }
        return nil
    }

    /// Only a currently active browser action whose key came from macOS App
    /// Shortcuts. Callers can give that explicit external choice priority
    /// over an older selection command or extension without changing either
    /// saved binding. Uses the same =/+ lookup order as normal dispatch.
    func systemBrowserAction(for hotkey: Hotkey) -> Shortcut.Action? {
        Self.systemBrowserAction(for: hotkey, owners: owners, current: current, system: system)
    }

    static func systemBrowserAction(for hotkey: Hotkey, owners: [Hotkey: Shortcut.Action],
                                    current: [Shortcut.Action: Hotkey],
                                    system: [Shortcut.Action: Hotkey]) -> Shortcut.Action? {
        guard let action = mappedBrowserAction(for: hotkey, owners: owners), Shortcut.context(action) == .browser,
              let assigned = current[action], system[action] == assigned else { return nil }
        return action
    }

    func set(_ hotkey: Hotkey?, for action: Shortcut.Action) {
        guard hotkey.map({ Self.valid($0, for: action) }) ?? true else { return }
        let fallback = Shortcut.byAction[action]?.key
        if hotkey == fallback {
            chosen[action.rawValue] = nil
        } else {
            chosen[action.rawValue] = hotkey?.stored ?? ""
        }
        // A key given the small window is a key wanted from every app: the
        // switch in Small Window comes on with it, or the key would do
        // nothing anywhere but here.
        if action == .newSmallWindow, hotkey != nil { Self.wantSmallKey() }
        save()
    }

    static func wantSmallKey(in store: UserDefaults = Store.settings) {
        if let prefs = Links.browser?.prefs {
            if !prefs.smallKey { prefs.smallKey = true }
        } else {
            store.set(true, forKey: LinkWindow.hotkeyKey)
        }
    }

    func reset(_ action: Shortcut.Action) {
        if let key = Shortcut.byAction[action]?.key {
            for command in CommandHotkeys.commands {
                if let current = commandCurrent[command], Self.conflicts(action, key, .duplicate, current) {
                    chosen[command.shortcutID] = ""
                }
            }
        }
        // Several independent contexts may own the same changed key. Free
        // every one before restoring this default, without changing a key
        // that macOS App Shortcuts owns outside Yab's settings.
        if let fallback = Shortcut.byAction[action]?.key {
            let displaced = Self.displacedByReset(action, in: current)
            if !displaced.contains(where: { system[$0] == current[$0] }) {
                let set = Set(displaced)
                var kept = current.filter { $0.key != action && !set.contains($0.key) }
                kept[action] = fallback
                for other in displaced {
                    let theirs = Shortcut.byAction[other]?.key
                    let free = theirs.map { key in
                        !kept.contains { Self.conflicts($0.key, $0.value, other, key) }
                    } ?? true
                    chosen[other.rawValue] = free ? nil : ""
                    if free, let theirs { kept[other] = theirs }
                }
            }
        }
        chosen[action.rawValue] = nil
        save()
    }

    static func displacedByReset(_ action: Shortcut.Action,
                                 in current: [Shortcut.Action: Hotkey]) -> [Shortcut.Action] {
        guard let fallback = Shortcut.byAction[action]?.key else { return [] }
        return Shortcut.items.compactMap(\.action).filter { other in
            guard other != action, let key = current[other] else { return false }
            return conflicts(other, key, action, fallback)
        }
    }

    private func save() {
        if chosen.isEmpty {
            Store.settings.removeObject(forKey: Self.storeKey)
        } else {
            Store.settings.set(chosen, forKey: Self.storeKey)
        }
        applied()
    }

    /// Keys another Mac chose, once sync has put them in Store.settings:
    /// taken at once, not at the next launch.
    func adoptStored() {
        let stored = Store.settings.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
        guard stored != chosen else { return }
        chosen = stored
        applied()
    }

    private func applied() {
        rebuild()
        // Everything that names a key, tooltips, the list ⌘T offers, asks
        // Hotkeys, which asks here.
        Hotkeys.shared.refresh()
        LinkWindow.hotkey(Links.browser?.prefs.smallKey ?? LinkWindow.keyWanted())
        ShowYab.hotkey()
        // SwiftUI brings a menu's items up to date only when AppKit says the
        // menu is about to open, and AppKit matches a key against the items
        // as they are: until someone opened the menu, the old key still
        // worked there and the new one didn't, in Settings, say, where the
        // key monitor stands aside. So each menu is told now, once SwiftUI
        // has seen the change.
        DispatchQueue.main.async {
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
            }
        }
    }

    struct Binding {
        let action: Shortcut.Action
        let key: Hotkey
        /// Global hotkey, App Shortcuts, Yab choice, then catalog default.
        let priority: Int
        let order: Int
    }

    private static let mailWhileWriting: Set<Shortcut.Action> = [
        .mailCommands, .mailAccountAll, .mailAccount1, .mailAccount2, .mailAccount3, .mailAccount4,
        .mailAccount5, .mailAccount6, .mailAccount7, .mailAccount8, .mailAccount9, .mailCopyChip,
        .mailRewrite, .mailSend, .mailSendLater, .mailBcc, .mailSubject, .mailRemindNoReply, .mailAttach, .mailFrom, .mailSnippet, .mailSlots,
    ]

    /// Mail's keys heard only while a mail is being written, and those
    /// heard only in the list: a draft is never open over the list, so a
    /// key can be one of each and do each where it is (MailDesk.take).
    /// ⇧⌘A selects every message in the list, and in a draft lists free
    /// slots; Settings › Shortcuts shows it on both rows.
    nonisolated static let mailDraftOnly: Set<Shortcut.Action> = [.mailSlots, .mailSendLater, .mailBcc, .mailSubject, .mailAttach]
    nonisolated static let mailListOnly: Set<Shortcut.Action> = [
        .mailOpen, .mailSelect, .mailSelectDown, .mailSelectUp, .mailSelectBelow, .mailSelectAll,
        .mailOnlyUnread, .mailOnlyStarred, .mailOnlyUnanswered,
    ]

    /// Two of mail's actions that are never heard in the same place.
    nonisolated static func apart(_ first: Shortcut.Action, _ second: Shortcut.Action) -> Bool {
        (mailDraftOnly.contains(first) && mailListOnly.contains(second)) || (mailListOnly.contains(first) && mailDraftOnly.contains(second))
    }

    private static let mailNavigation: Set<Hotkey> = [
        Hotkey("↩", []), Hotkey("esc", []), Hotkey("⌫", []),
        Hotkey("⇥", []), Hotkey("⇥", .shift),
        Hotkey("←", []), Hotkey("→", []), Hotkey("↑", []), Hotkey("↓", []),
    ]
    private static let agentOnBrowser: Set<Shortcut.Action> = [
        .agentAsk, .agentTakeWheel, .agentHandBack, .agentStop, .selectionCopy, .selectionRetry,
    ]
    private static let agentControls: Set<Shortcut.Action> = [.agentTakeWheel, .agentHandBack, .agentStop]
    private static let contextsOnBrowser: Set<Shortcut.Context> = [
        .mail, .mailWords, .space, .field, .fieldAnswer, .answer, .capture, .chat, .welcome, .confirmation, .pageCopy,
    ]
    private static let textEntryContexts: Set<Shortcut.Context> = [
        .space, .field, .fieldAnswer, .answer, .agent, .feedback, .call, .welcome, .confirmation, .pageCopy, .mailWords,
    ]

    private static func printable(_ key: String) -> Bool {
        if key == "space" || key.hasPrefix("keycode") { return true }
        if ["↩", "⇥", "⌫", "⌦", "←", "→", "↑", "↓"].contains(key) { return false }
        return key.count == 1
    }

    private static func onBrowser(_ action: Shortcut.Action) -> Bool {
        contextsOnBrowser.contains(Shortcut.context(action)) || agentOnBrowser.contains(action)
    }

    static func valid(_ hotkey: Hotkey, for action: Shortcut.Action) -> Bool {
        let modifiers = hotkey.flags.intersection([.command, .option, .control])
        if Shortcut.kept(hotkey, from: action) { return false }
        if Shortcut.context(action) == .browser && action != .peekClose
            && !(action == .closeChat && hotkey == Shortcut.byAction[.closeChat]?.key)
            && !hotkey.commands { return false }
        if action == .peekClose && modifiers.isEmpty && printable(hotkey.key) { return false }
        if agentOnBrowser.contains(action) && modifiers.isEmpty { return false }
        if Shortcut.context(action) == .chat && modifiers.isEmpty { return false }
        if textEntryContexts.contains(Shortcut.context(action)) && modifiers.isEmpty,
           printable(hotkey.key) && hotkey != Shortcut.byAction[action]?.key { return false }
        if Shortcut.global.contains(action) && KeyLayout.code(for: hotkey.key) == nil { return false }
        // ↩ is the list's and the thread's own, but for replying to all in a thread.
        if Shortcut.context(action) == .mail && mailNavigation.contains(hotkey)
            && !(action == .mailReplyAll && hotkey == Hotkey("↩", [])) { return false }
        if action == .captureSave && modifiers.isEmpty { return false }
        if Shortcut.context(action) == .capture {
            if hotkey.flags.isEmpty && ["↑", "↓", "←", "→"].contains(hotkey.key) { return false }
            if hotkey.flags.isEmpty && ["esc", "↩"].contains(hotkey.key) { return false }
        }
        if mailWhileWriting.contains(action) && modifiers.isEmpty { return false }
        // A mark's key is pressed among words being typed: never one alone.
        if Shortcut.context(action) == .mailWords && modifiers.isEmpty { return false }
        if action == .mailWriteDraft && modifiers.isEmpty && hotkey != Hotkey("space", []) { return false }
        if Shortcut.titles[action] != nil && hotkey.menu == nil { return false }
        return true
    }

    static func conflicts(_ first: Shortcut.Action, _ firstKey: Hotkey,
                          _ second: Shortcut.Action, _ secondKey: Hotkey) -> Bool {
        guard keysOverlap(firstKey, secondKey) else { return false }
        let firstContext = Shortcut.context(first)
        let secondContext = Shortcut.context(second)
        if Shortcut.global.contains(first) || Shortcut.global.contains(second) { return true }
        if firstContext == secondContext { return !apart(first, second) }
        // These handlers run before browser commands in their active state.
        // Shared catalog defaults are intentional; a changed chord may not
        // quietly hide another action in that state.
        let browserOverlap = (firstContext == .browser && onBrowser(second))
            || (secondContext == .browser && onBrowser(first))
        let mailOverlap = (firstContext == .mail && agentOnBrowser.contains(second))
            || (secondContext == .mail && agentOnBrowser.contains(first))
            // Words being written hear mail's own keys there before the marks'.
            || (firstContext == .mailWords && mailWhileWriting.contains(second))
            || (secondContext == .mailWords && mailWhileWriting.contains(first))
        let chatOverlap = (firstContext == .chat && (agentOnBrowser.contains(second) || contextsOnBrowser.contains(secondContext)))
            || (secondContext == .chat && (agentOnBrowser.contains(first) || contextsOnBrowser.contains(firstContext)))
        let controlOverlap = (agentControls.contains(first) && contextsOnBrowser.contains(secondContext))
            || (agentControls.contains(second) && contextsOnBrowser.contains(firstContext))
        if browserOverlap || mailOverlap || chatOverlap || controlOverlap {
            if Shortcut.byAction[first]?.key == firstKey && Shortcut.byAction[second]?.key == secondKey { return false }
            if browserOverlap && !(mailOverlap || chatOverlap || controlOverlap) {
                let (browser, browserKey, other, otherKey) = firstContext == .browser
                    ? (first, firstKey, second, secondKey) : (second, secondKey, first, firstKey)
                return !sharedByDefault(browser, browserKey, with: other, otherKey)
            }
            return true
        }
        return false
    }

    /// ⌘1 to ⌘9 are the tabs' in a window and Mail's accounts and an
    /// answer's picks where those are, all at their defaults. Moved from
    /// Go to Tab 1 to Go to Space 1, ⌘1 hides nothing it didn't hide
    /// before, so it is shared the same way (register 1163: Mail's and the
    /// answer's ⌘1, one of them on rows Settings doesn't show, kept ⌘1
    /// from the spaces even once the tabs had let it go). Only the digits
    /// and only the spaces: ⌥↩ given Duplicate still takes it from the
    /// field, though Fill Form shares it there by default.
    static let spaceDigits: Set<Shortcut.Action> = Set((1...9).compactMap { Shortcut.numbered("space", $0) })

    static func sharedByDefault(_ browser: Shortcut.Action, _ browserKey: Hotkey,
                                with other: Shortcut.Action, _ otherKey: Hotkey) -> Bool {
        guard spaceDigits.contains(browser), Shortcut.byAction[other]?.key == otherKey else { return false }
        return (1...9).contains { number in
            Shortcut.numbered("tab", number).flatMap { Shortcut.byAction[$0]?.key } == browserKey && browserKey == otherKey
        }
    }

    static func keysOverlap(_ first: Hotkey, _ second: Hotkey) -> Bool {
        if first == second { return true }
        // The browser accepts both physical = chords for its historical +
        // binding. Treat those aliases as owned when recording another key.
        let plus = first.key == "+" ? first : second.key == "+" ? second : nil
        let equal = first.key == "=" ? first : second.key == "=" ? second : nil
        guard let plus, let equal else { return false }
        return plus.flags == equal.flags || plus.flags == equal.flags.subtracting(.shift)
    }

    static func resolve(_ bindings: [Binding]) -> [Shortcut.Action: Hotkey] {
        var current: [Shortcut.Action: Hotkey] = [:]
        let sorted = bindings.sorted {
            $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority
        }
        for binding in sorted {
            guard !current.contains(where: { conflicts($0.key, $0.value, binding.action, binding.key) }) else { continue }
            current[binding.action] = binding.key
        }
        return current
    }

    /// Every action's key as the person's choices and App Shortcuts leave
    /// it. `chosen` holds only what differs from the catalog (`set`): an
    /// action not in it has whatever default the catalog has now, so a
    /// changed default reaches it, while a key chosen, or one taken away
    /// (""), stays as it was.
    static func resolved(chosen: [String: String],
                         system: [Shortcut.Action: Hotkey] = [:]) -> [Shortcut.Action: Hotkey] {
        resolveAll(chosen: chosen, system: system).actions
    }

    static func bindings(chosen: [String: String], system: [Shortcut.Action: Hotkey]) -> [Binding] {
        var bindings: [Binding] = []
        for (order, item) in Shortcut.items.enumerated() {
            guard let action = item.action else { continue }
            let key: Hotkey?
            var priority = 1
            if let given = system[action], Self.valid(given, for: action) {
                key = given
                priority = 3
            } else if let stored = chosen[action.rawValue] {
                if stored.isEmpty { continue }
                if let saved = Hotkey(stored: stored), Self.valid(saved, for: action) {
                    key = saved
                    priority = 2
                } else {
                    key = item.key
                }
            } else {
                key = item.key
            }
            guard let key, Self.valid(key, for: action) else { continue }
            bindings.append(Binding(action: action, key: key,
                                    priority: Shortcut.global.contains(action) ? 4 : priority, order: order))
        }
        return bindings
    }

    private func rebuild() {
        var owners: [Hotkey: Shortcut.Action] = [:]
        let resolved = Self.resolveAll(chosen: chosen, system: system)
        let current = resolved.actions
        commandCurrent = resolved.commands
        for item in Shortcut.items {
            guard let action = item.action, Shortcut.context(action) == .browser,
                  let key = current[action] else { continue }
            owners[key] = action
        }
        self.current = current
        bound = Set(current.values).union(commandCurrent.values)
        self.owners = owners
        // Told only where something changed, so nothing else redraws.
        for (action, slot) in slots {
            let key = current[action]
            let fallback = chosen[action.rawValue] == nil
            if slot.keys != key { slot.keys = key }
            if slot.isDefault != fallback { slot.isDefault = fallback }
        }
        for (command, slot) in commandSlots {
            let key = commandCurrent[command]
            if slot.keys != key { slot.keys = key }
            if slot.isDefault != isDefault(command: command) { slot.isDefault = isDefault(command: command) }
        }
        index = Shortcut.all.flatMap { group in
            group.items.map { item in
                let caps = item.action.flatMap { current[$0] }.map { [$0.caps] } ?? item.fixed
                let words = caps.map { $0.joined() }.joined(separator: " ")
                return SettingsItem(id: "key:" + item.id, page: .shortcuts, title: item.does,
                                    words: "shortcut keys keyboard " + group.title + " " + words)
            }
        }
        index += CommandHotkeys.commands.map { command in
            SettingsItem(id: "key:" + command.shortcutID, page: .shortcuts, title: command.shortcutTitle,
                         words: "shortcut keys keyboard Commands " + CommandHotkeys.variants(of: command).flatMap(\.searchNames).joined(separator: " ")
                            + " " + (keys(for: command)?.text ?? ""))
        }
    }

    // MARK: - who has a key

    enum Clash {
        /// Someone else's that Overwrite or a second press takes: what to
        /// say, and how to take it from every owner.
        case taken(String, free: () -> Void)
        /// Never to be had.
        case refused(String)
    }

    /// Who a key would be taken from, recorded for `owner`: an action here,
    /// or an extension's command (`command`, compared by identity).
    /// Imports have no Overwrite confirmation, so keep `takeSeveral` false.
    func clash(_ hotkey: Hotkey, for owner: Shortcut.Action?, command: AnyObject? = nil,
               quickAction: String? = nil, snippet: String? = nil, takeSeveral: Bool = true,
               commandAction: Command? = nil, extensionCommand: String? = nil) -> Clash? {
        // An extension's command Chrome keeps ("id/command"): an extension's
        // shortcut as much as WebKit's `command` is.
        let command: AnyObject? = command ?? extensionCommand.map { $0 as NSString }
        if Shortcut.kept(hotkey, from: owner) { return .refused("macOS keeps this one.") }
        if let owner, Shortcut.global.contains(owner),
           hotkey.flags.intersection([.command, .option, .control]).isEmpty || KeyLayout.code(for: hotkey.key) == nil {
            return .refused("A shortcut for any app needs a modifier and a physical key.")
        }
        if let owner, !Self.valid(hotkey, for: owner) {
            return .refused("This key cannot be used for that shortcut.")
        }
        if commandAction != nil, !Self.valid(hotkey, for: .duplicate) {
            return .refused("This key cannot be used for that shortcut.")
        }
        if command != nil, hotkey.menu == nil {
            return .refused("An extension shortcut needs a key the menu can represent.")
        }
        if let fixed = Shortcut.items.first(where: { $0.holds.contains(hotkey) }) {
            return .refused("Always \(fixed.taken).")
        }
        let context = owner.map(Shortcut.context) ?? .browser
        if context == .browser, !hotkey.commands,
           owner != .peekClose && !(owner == .closeChat && hotkey == Shortcut.byAction[.closeChat]?.key) {
            return .refused("Browser shortcuts need a modifier so typing still reaches the page.")
        }
        let others = Self.holders(of: hotkey, for: owner, in: current)
        if commandAction != nil, others.contains(where: { system[$0] == current[$0] }) {
            return .refused("Already used by a macOS App Shortcut.")
        }
        // Context-only actions can share Copy, Paste or Undo. Their presence
        // must not make the native menu key available to a browser command.
        // Menu-backed actions here still allow moving their own menu keys.
        if [.browser, .mail, .mailWords].contains(context), owner.flatMap({ current[$0] }) != hotkey,
           !others.contains(where: { Shortcut.titles[$0] != nil }),
           let title = Self.menuHolder(of: hotkey) {
            return .refused("Kept for “\(title)”.")
        }
        var owners: [(name: String, free: () -> Void)] = others.map { other in
            (Shortcut.byAction[other]?.does ?? other.rawValue, { self.set(nil, for: other) })
        }
        owners += CommandHotkeys.commands.filter { other in
            guard other != commandAction, let key = commandCurrent[other] else { return false }
            return Self.conflicts(.duplicate, key, owner ?? .duplicate, hotkey)
        }.map { other in (other.title, { self.set(nil, forCommand: other) }) }
        if #available(macOS 15.4, *) { owners += Self.extensionClash(hotkey, besides: command, besidesChromium: extensionCommand) }
        let quicks = QuickActions.shared.actions.filter {
            $0.id != quickAction && $0.enabled && Hotkey(stored: $0.shortcut).map { Self.keysOverlap($0, hotkey) } == true
        }
        // A snippet's own key (Snippets.swift), whoever else wants it.
        if let other = MailSnippets.shared.holding(hotkey, besides: snippet) {
            return .refused("Already used by the snippet \u{201C}\(other.name)\u{201D}.")
        }
        if owner != nil || command != nil || quickAction != nil || commandAction != nil {
            for browser in BrowserWindows.shared.browsers {
                if let selected = browser.selectionCommands.commands.first(where: {
                    $0.enabled && Hotkey(stored: $0.shortcut).map { Self.keysOverlap($0, hotkey) } == true
                }) {
                    return .refused("Already used by \(selected.name) in Selection Commands.")
                }
            }
        }
        owners += quicks.map { quick in
            (quick.name, { QuickActions.shared.clearShortcut(quick.id) })
        }
        if let last = owners.last {
            let names = owners.count == 1 ? last.name
                : owners.dropLast().map(\.name).joined(separator: ", ") + " and " + last.name
            let words = "Already used by \(names)"
            if !takeSeveral, owners.count > 1 { return .refused(words) }
            return .taken(words, free: { owners.forEach { $0.free() } })
        }
        return nil
    }

    /// The actions that would lose `hotkey`, or hide it, were it given
    /// to `owner` (to an extension's command without one).
    static func holders(of hotkey: Hotkey, for owner: Shortcut.Action?,
                        in current: [Shortcut.Action: Hotkey]) -> [Shortcut.Action] {
        Shortcut.items.compactMap(\.action).filter { action in
            guard action != owner, let key = current[action] else { return false }
            if let owner { return conflicts(action, key, owner, hotkey) }
            return (Shortcut.context(action) == .browser || onBrowser(action))
                && keysOverlap(key, hotkey)
        }
    }

    @available(macOS 15.4, *)
    private static func extensionClash(_ hotkey: Hotkey, besides command: AnyObject?,
                                       besidesChromium: String? = nil) -> [(name: String, free: () -> Void)] {
        let extensions = Extensions.here
        let groups = extensions.commandGroups()
        let titles = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.commands.map { ($0.id, $0.title) }
        })
        // The commands of those that run in Chromium, by the keys Chrome gave them.
        let chromium = groups.flatMap { group in
            group.commands.filter { entry in
                entry.chromium && entry.id != besidesChromium && entry.keys.map { Self.keysOverlap($0, hotkey) } == true
            }
        }.map { entry -> (name: String, free: () -> Void) in
            (entry.title, { extensions.setKey(nil, extension: entry.extensionID, command: entry.command) })
        }
        let matches = extensions.contexts.keys.sorted().flatMap { id -> [(String, WKWebExtension.Command)] in
            guard let context = extensions.contexts[id] else { return [] }
            return context.commands.compactMap { other -> (String, WKWebExtension.Command)? in
                guard other !== command, let key = other.activationKey,
                      Self.keysOverlap(Hotkey(key, other.modifierFlags), hotkey) else { return nil }
                return (id, other)
            }
        }
        return matches.map { id, other in
            let name = titles[id + "/" + other.id] ?? (other.title.isEmpty ? other.id : other.title)
            return (name, { extensions.setKey(nil, [], for: other) })
        } + chromium
    }

    /// Check every reading, the layout's key first. A mark's US Shift
    /// alias does not make its own ISO key a shifted press of that alias.
    static func hasShiftedOwner(_ readings: [Hotkey], matching owner: (Hotkey) -> Bool) -> Bool {
        guard let primary = readings.first else { return false }
        return readings.contains { key in
            if key != primary, Hotkey.unshifted[primary.key] != nil, Hotkey.shifted[key.key] != nil,
               key.flags == primary.flags.subtracting([.shift, .option]).union(.shift) { return false }
            return owner(Hotkey(key.key, key.flags.symmetricDifference(.shift)))
        }
    }

    /// A key taken away from an action in Settings › Shortcuts is nobody's
    /// in a browser window, once the page has had it, rather than what the
    /// menus would make of it. With Reload moved off ⌘R, ⌘R went on to the
    /// menus, which, finding no item for it, tried it again with Shift and
    /// reloaded without the cache (⇧⌘R's item); with Close Tab moved off ⌘W,
    /// ⌘W was AppKit's own File › Close and shut the whole window, tabs and
    /// all. The same for a press only an action's with Shift turned over.
    /// A menu item that holds the key itself (Edit's ⌘C, ⌘Z) keeps it.
    func nobodys(_ event: NSEvent) -> Bool {
        // ⌘ and ⇧⌘ with an arrow in a text field are the field's: to the
        // line's ends, selecting with Shift (feedback #292). ⇧⌘← is no
        // shifted Back, and ⌘← with Back moved away still moves the caret.
        if (123...126).contains(event.keyCode), event.modifierFlags.intersection(Hotkey.carried).subtracting(.shift) == .command,
           event.window?.firstResponder is NSTextView {
            return false
        }
        let readings = Hotkey.readings(event)
        guard readings.contains(where: { $0.flags.contains(.command) }),
              !readings.contains(where: { action(for: $0) != nil }) else { return false }
        let moved = readings.contains { reading in
            Shortcut.items.contains { item in
                guard let action = item.action, Shortcut.context(action) == .browser, item.key == reading else { return false }
                return current[action] != reading
            }
        }
        let shifted = Self.hasShiftedOwner(readings) { action(for: $0) != nil }
        guard moved || shifted else { return false }
        return !readings.contains { reading in
            guard let item = Self.menuItem(holding: reading) else { return false }
            // AppKit's own Close and Close All, which a browser window's
            // keys never meant: closing it is Close Window's, ⇧⌘W.
            let closing = item.action == #selector(NSWindow.performClose(_:)) || item.action.map(NSStringFromSelector) == "closeAll:"
            return !closing && item.title != "Close" && item.title != "Close All"
        }
    }

    private static func menuItem(holding hotkey: Hotkey) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let found = search(sub) { return found }
                // fn with it, macOS's window tiling: another keystroke.
                if item.keyEquivalentModifierMask.contains(.function) { continue }
                var equivalent = item.keyEquivalent
                var mask = item.keyEquivalentModifierMask.intersection(Hotkey.carried)
                // A capital letter in a menu is its shift.
                if equivalent.count == 1, equivalent != equivalent.lowercased() {
                    equivalent = equivalent.lowercased()
                    mask.insert(.shift)
                }
                if !equivalent.isEmpty, equivalent == hotkey.key, mask == hotkey.flags { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// A menu item whose key is held with fn (the globe), pressed: fn F,
    /// View's Enter and Exit Full Screen since macOS 15, and the like held
    /// on a letter (Window's fn ⌃F, Fill). AppKit asks the window's views
    /// for a key carrying fn before the menus, as it does for the arrows,
    /// and the page's WebKit view takes every such key for the page there,
    /// so with a page in front the menu never heard fn F (register #1693).
    /// The browser's key monitor asks this first, as the menu bar would.
    @discardableResult
    static func pressFunctionItem(for event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.function),
              let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty,
              // Arrows, Home, End and F keys carry fn of themselves: theirs
              // stay the page's and the text's (⌘← in a box), as ever.
              !typed.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }),
              let menu = NSApp.mainMenu, Narrow.fnMenu else { return false }
        let marks: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
        let flags = event.modifierFlags.intersection(marks)
        func search(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if let sub = item.submenu, let found = search(sub) { return found }
                guard item.keyEquivalentModifierMask.contains(.function), !item.keyEquivalent.isEmpty else { continue }
                var equivalent = item.keyEquivalent
                var mask = item.keyEquivalentModifierMask.intersection(marks)
                if equivalent.count == 1, equivalent != equivalent.lowercased() {
                    equivalent = equivalent.lowercased()
                    mask.insert(.shift)
                }
                if equivalent == typed, mask == flags { return (menu, index) }
            }
            return nil
        }
        guard let (holder, index) = search(menu) else {
            // View's full screen item, which AppKit may put in only once the
            // menu has been opened: fn F is its key on every macOS Yab runs on.
            guard event.keyCode == 3, flags == .function, let window = event.window,
                  window.collectionBehavior.contains(.fullScreenPrimary) || window.styleMask.contains(.resizable) else { return false }
            if !event.isARepeat { window.toggleFullScreen(nil) }
            return true
        }
        holder.update()
        guard holder.items.indices.contains(index), holder.items[index].isEnabled else { return false }
        // Held down, it goes once, as a menu's key does.
        if !event.isARepeat { holder.performActionForItem(at: index) }
        return true
    }

    private static func menuHolder(of hotkey: Hotkey) -> String? {
        menuItem(holding: hotkey)?.title
    }

    // MARK: - said elsewhere

    func text(_ action: Shortcut.Action) -> String { keys(action)?.text ?? "" }
}

extension View {
    /// The menu item's key, the one chosen in Settings › Shortcuts, kept up
    /// with it.
    @MainActor
    func shortcut(_ action: Shortcut.Action, enabled: Bool = true) -> some View {
        modifier(MenuKey(action: action, enabled: enabled))
    }
}

/// Each item watches its own key: a menu item is drawn from the commands'
/// own graph, which a change seen only by the App doesn't reach.
/// Keep construction on the actor at compile time: an assumeIsolated check
/// here crashed inside Swift's executor lookup while SwiftUI rebuilt menus
/// on the main thread (reports 902, 926 and 933).
@MainActor
struct MenuKey: ViewModifier {
    let action: Shortcut.Action
    let enabled: Bool
    @ObservedObject var slot: KeySlot

    init(action: Shortcut.Action, enabled: Bool) {
        self.action = action
        self.enabled = enabled
        slot = Keymap.shared.slot(action)
    }

    func body(content: Content) -> some View {
        // A key with nothing held is never a menu item's: the menu would
        // take it from every page and field, and Esc, Close Peek's key, is
        // the key monitor's to hand on when there is no peek.
        content.keyboardShortcut(slot.keys.flatMap { key -> KeyboardShortcut? in
            guard enabled, !key.flags.isEmpty else { return nil }
            if action == .pasteAndMatchStyle,
               Keymap.shared.keys(action) != key || !PasteStyleMenuOrder.permits(key, in: NSApp.mainMenu) { return nil }
            return key.menu
        })
    }
}

/// A button's visible key, driven by the same slot as its handler and menu.
@MainActor
struct ShortcutGlyphs: View {
    @ObservedObject private var slot: KeySlot
    let size: CGFloat
    let tint: Color?

    init(_ action: Shortcut.Action, size: CGFloat, tint: Color?) {
        slot = Keymap.shared.slot(action)
        self.size = size
        self.tint = tint
    }

    var body: some View {
        if let keys = slot.keys?.text { KeyGlyphs(keys: keys, size: size, tint: tint) }
    }
}

/// One action's key as it is now, for what shows it to watch.
@MainActor
final class KeySlot: ObservableObject {
    @Published fileprivate(set) var keys: Hotkey?
    @Published fileprivate(set) var isDefault = true
    /// The bench asked its row to start recording.
    @Published var asked = false
    /// The bench drew its row as if the pointer were on it, for a picture.
    @Published var pointed = false
}
