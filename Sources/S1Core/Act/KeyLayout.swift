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

    private static let cache = Mutex<(id: String, map: [Character: Stroke])?>(nil)

    /// The current layout's character → keystroke table (rebuilt on switch).
    static func current() -> [Character: Stroke] {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return [:] }
        let id = (TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }) ?? "?"
        if let hit = cache.withLock({ $0 }), hit.id == id { return hit.map }
        let map = build(src)
        cache.withLock { $0 = (id, map) }
        return map
    }

    private static func build(_ src: TISInputSource) -> [Character: Stroke] {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
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
                                             UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                             &dead, 4, &len, &chars)
                    guard err == noErr, len == 1, let ch = String(utf16CodeUnits: chars, count: len).first,
                          !ch.isNewline, ch != "\t", map[ch] == nil, chars[0] >= 0x20, chars[0] != 0x7F else { continue }
                    map[ch] = Stroke(code: CGKeyCode(code), flags: flags)
                }
            }
        }
        return map
    }
}
