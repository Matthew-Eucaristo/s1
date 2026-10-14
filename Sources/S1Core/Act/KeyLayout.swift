import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

/// Which key (and modifiers) types each character on the current keyboard
/// layout. Typing through real key codes is indistinguishable from the user
/// typing — Chrome's address bar, Electron apps and games ignore the
/// "unicode string on a dummy key" events that native text views accept.
enum KeyLayout {
    struct Stroke: Sendable, Equatable { var code: CGKeyCode; var flags: CGEventFlags }

    private typealias Layout = (id: String, data: Data, kbd: UInt32)

    private static let cache = Mutex<(id: String, map: [Character: Stroke])?>(nil)
    private static let shortcutCache = Mutex<(id: String, map: [Character: CGKeyCode])?>(nil)

    /// The current layout's character → keystroke table (rebuilt on switch).
    /// Empty when the layout can't be read: typing then falls back to unicode.
    static func current() -> [Character: Stroke] {
        guard let (id, data, kbd) = currentLayout() else { return [:] }
        if let hit = cache.withLock({ $0 }), hit.id == id { return hit.map }
        let map = build(data, kbd: kbd)
        cache.withLock { $0 = (id, map) }
        return map
    }

    /// The key that types `ch` while ⌘ is held — what a ⌘-shortcut for
    /// `ch` must post. Read in the ⌘ state because some layouts switch to
    /// QWERTY under ⌘ ("Dvorak – QWERTY ⌘"). nil when no key makes it.
    static func shortcutCode(for ch: Character) -> CGKeyCode? { shortcutMap()?[ch] }

    /// The ⌘-state map, or nil when the layout can't be read right now
    /// (callers must not guess a US position then: on AZERTY that's ⌘Q).
    static func shortcutMap() -> [Character: CGKeyCode]? {
        guard let (id, data, kbd) = currentLayout() else { return nil }
        if let hit = shortcutCache.withLock({ $0 }), hit.id == id { return hit.map }
        let map = buildShortcuts(data, kbd: kbd)
        shortcutCache.withLock { $0 = (id, map) }
        return map
    }

    private static func buildShortcuts(_ data: Data, kbd: UInt32) -> [Character: CGKeyCode] {
        var map: [Character: CGKeyCode] = [:]
        data.withUnsafeBytes { buf in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0, len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8),
                                         kbd, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                         &dead, 4, &len, &chars)
                guard err == noErr, len == 1, chars[0] > 0x20, chars[0] != 0x7F,
                      let ch = String(utf16CodeUnits: chars, count: len).lowercased().first,
                      map[ch] == nil else { continue }
                map[ch] = CGKeyCode(code)
            }
        }
        return map
    }

    /// The Text Input Sources API asserts it runs on the main queue (macOS 27
    /// traps otherwise), and typing happens on background tasks. Read the
    /// layout there; a busy main thread falls back instead of deadlocking.
    private static func currentLayout() -> Layout? {
        if Thread.isMainThread { return readLayout() }
        let result = Mutex<Layout??>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let r = readLayout()
            result.withLock { $0 = .some(r) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.5) == .success else { return nil }
        return result.withLock { $0 } ?? nil
    }

    private static func readLayout() -> Layout? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let id = (TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }) ?? "?"
        // A copy: the bytes must outlive the input source off the main thread.
        let data = Data(Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data)
        return (id, data, UInt32(LMGetKbdType()))
    }

    private static func build(_ data: Data, kbd: UInt32) -> [Character: Stroke] {
        var map: [Character: Stroke] = [:]
        data.withUnsafeBytes { buf in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Plain first, so the simplest stroke wins for each character.
            let mods: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift),
                                                 (UInt32(optionKey >> 8), .maskAlternate),
                                                 (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])]
            for (state, flags) in mods {
                for code in 0..<128 {
                    var dead: UInt32 = 0, len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), state,
                                             kbd, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                             &dead, 4, &len, &chars)
                    guard err == noErr, len == 1, let ch = String(utf16CodeUnits: chars, count: len).first,
                          !ch.isNewline, ch != "\t", map[ch] == nil, chars[0] >= 0x20, chars[0] != 0x7F else { continue }
                    // A dead key ("´" on US Option-E, "'" on US-International)
                    // starts a compose: posting it would merge with the NEXT
                    // character. Leave those to unicode events.
                    var deadState: UInt32 = 0, deadLen = 0
                    var deadChars = [UniChar](repeating: 0, count: 4)
                    _ = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), state, kbd,
                                       0, &deadState, 4, &deadLen, &deadChars)
                    guard deadState == 0 else { continue }
                    map[ch] = Stroke(code: CGKeyCode(code), flags: flags)
                }
            }
        }
        return map
    }
}
