import Carbon
import Foundation

enum TextInputKeyboardLayout {
    case english
    case russian
    case other
}

enum TextKeyboardLayoutMapper {
    private static let enToRu: [Character: Character] = [
        "`": "ё", "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
        "[": "х", "]": "ъ", "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л",
        "l": "д", ";": "ж", "'": "э", "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
        ",": "б", ".": "ю"
    ]

    static let ruToEn: [Character: Character] = Dictionary(
        uniqueKeysWithValues: enToRu.map { ($0.value, $0.key) }
    )
}

enum KeyboardInputSource {
    static func currentLayout() -> TextInputKeyboardLayout {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return .other }
        return keyboardLayout(of: source)
    }

    static func select(_ layout: TextInputKeyboardLayout) -> Bool {
        guard let source = selectableInputSource(for: layout) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func selectableInputSource(for layout: TextInputKeyboardLayout) -> TISInputSource? {
        let filter: [String: Any] = [kTISPropertyInputSourceIsSelectCapable as String: true]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else {
            return nil
        }
        for item in list as NSArray {
            let source = item as! TISInputSource
            if keyboardLayout(of: source) == layout { return source }
        }
        return nil
    }

    private static func keyboardLayout(of source: TISInputSource) -> TextInputKeyboardLayout {
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
            if languages.contains(where: { $0.lowercased().hasPrefix("ru") }) { return .russian }
            if languages.contains(where: { $0.lowercased().hasPrefix("en") }) { return .english }
        }
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let identifier = (Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String).lowercased()
            if identifier.contains("russian") || identifier.contains(".ru") { return .russian }
            if identifier.contains("abc") || identifier.contains("us") || identifier.contains("english") {
                return .english
            }
        }
        return .other
    }
}
