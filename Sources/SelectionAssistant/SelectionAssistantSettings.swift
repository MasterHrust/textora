import AppKit
import Carbon
import Foundation

enum SelectionActivationMode: String, CaseIterable, Identifiable {
    case automatic
    case hotkeyOnly

    var id: String { rawValue }
}

enum TextoraHotKeyAction: UInt32 {
    case rewrite = 1
    case translate = 2
}

struct TextoraHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var isEnabled: Bool

    var displayName: String {
        guard isEnabled else { return "Disabled" }
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: "Space"
        ]
        return value + (names[keyCode] ?? "Key \(keyCode)")
    }
}

enum SelectionAssistantSettings {
    static let settingsDidChangeNotification = Notification.Name("SelectionAssistant.settingsDidChange")

    enum Keys {
        static let enabled = "selectionAssistant.beta.enabled"
        static let toolboxEnabled = "selectionAssistant.toolbox.enabled"
        static let floatingIconEnabled = "selectionAssistant.floatingIcon.enabled"
        static let hotKeysModeEnabled = "selectionAssistant.hotKeysMode.enabled"
        static let hotKeysModeMigration = "selectionAssistant.hotKeysMode.migration.v1"
        static let interfaceModeMigration = "selectionAssistant.interfaceMode.migration.v1"
        static let exclusiveInterfaceModeMigration = "selectionAssistant.interfaceMode.migration.v2"
        static let operation = "selectionAssistant.operation"
        static let activationMode = "selectionAssistant.activationMode"
        static let translationLanguage = "translation.targetLanguage"
        static let rewriteHotKeyCode = "hotkey.rewrite.keyCode"
        static let rewriteHotKeyModifiers = "hotkey.rewrite.modifiers"
        static let rewriteHotKeyEnabled = "hotkey.rewrite.enabled"
        static let rewriteHotKeyDefaultRMigration = "hotkey.rewrite.defaultRMigration"
        static let rewriteHotKeyDefaultRMigrationV2 = "hotkey.rewrite.defaultRMigrationV2"
        static let translateHotKeyCode = "hotkey.translate.keyCode"
        static let translateHotKeyModifiers = "hotkey.translate.modifiers"
        static let translateHotKeyEnabled = "hotkey.translate.enabled"
    }

    static func registerDefaults(defaults: UserDefaults = .standard) {
        let existingHotKeysMode = defaults.bool(forKey: Keys.hotKeysModeEnabled)
        let legacyActivationMode = defaults.string(forKey: Keys.activationMode)
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.toolboxEnabled: true,
            Keys.floatingIconEnabled: false,
            Keys.hotKeysModeEnabled: false,
            Keys.operation: RewriteOperation.fixGrammar.rawValue,
            Keys.activationMode: SelectionActivationMode.automatic.rawValue,
            Keys.translationLanguage: "english",
            Keys.rewriteHotKeyCode: 15,
            Keys.rewriteHotKeyModifiers: UInt32(cmdKey | optionKey),
            Keys.rewriteHotKeyEnabled: true,
            Keys.translateHotKeyCode: 17,
            Keys.translateHotKeyModifiers: UInt32(cmdKey | optionKey),
            Keys.translateHotKeyEnabled: true
        ])
        if !defaults.bool(forKey: Keys.hotKeysModeMigration) {
            let migratedValue = existingHotKeysMode
                || legacyActivationMode == SelectionActivationMode.hotkeyOnly.rawValue
            defaults.set(migratedValue, forKey: Keys.hotKeysModeEnabled)
            defaults.set(true, forKey: Keys.hotKeysModeMigration)
        }
        if !defaults.bool(forKey: Keys.interfaceModeMigration) {
            let toolboxEnabled = defaults.bool(forKey: Keys.toolboxEnabled)
            let floatingIconEnabled = defaults.bool(forKey: Keys.floatingIconEnabled)
            let hotKeysEnabled = defaults.bool(forKey: Keys.hotKeysModeEnabled)
            if toolboxEnabled && floatingIconEnabled {
                defaults.set(false, forKey: Keys.floatingIconEnabled)
            } else if !toolboxEnabled && !floatingIconEnabled && !hotKeysEnabled {
                defaults.set(true, forKey: Keys.toolboxEnabled)
            }
            defaults.set(true, forKey: Keys.interfaceModeMigration)
        }
        if !defaults.bool(forKey: Keys.exclusiveInterfaceModeMigration) {
            let toolboxEnabled = defaults.bool(forKey: Keys.toolboxEnabled)
            let floatingIconEnabled = defaults.bool(forKey: Keys.floatingIconEnabled)
            let hotKeysEnabled = defaults.bool(forKey: Keys.hotKeysModeEnabled)
            if legacyActivationMode == SelectionActivationMode.hotkeyOnly.rawValue, hotKeysEnabled {
                persistInterfaceModes(toolbox: false, floatingIcon: false, hotKeys: true, defaults: defaults)
            } else if toolboxEnabled {
                persistInterfaceModes(toolbox: true, floatingIcon: false, hotKeys: false, defaults: defaults)
            } else if floatingIconEnabled {
                persistInterfaceModes(toolbox: false, floatingIcon: true, hotKeys: false, defaults: defaults)
            } else if hotKeysEnabled {
                persistInterfaceModes(toolbox: false, floatingIcon: false, hotKeys: true, defaults: defaults)
            } else {
                persistInterfaceModes(toolbox: true, floatingIcon: false, hotKeys: false, defaults: defaults)
            }
            defaults.set(true, forKey: Keys.exclusiveInterfaceModeMigration)
        }
        if !defaults.bool(forKey: Keys.rewriteHotKeyDefaultRMigration) {
            let isLegacyDefault = defaults.integer(forKey: Keys.rewriteHotKeyCode) == 7
                && UInt32(defaults.integer(forKey: Keys.rewriteHotKeyModifiers)) == UInt32(cmdKey | optionKey)
            if isLegacyDefault {
                defaults.set(15, forKey: Keys.rewriteHotKeyCode)
            }
            defaults.set(true, forKey: Keys.rewriteHotKeyDefaultRMigration)
        }
        if !defaults.bool(forKey: Keys.rewriteHotKeyDefaultRMigrationV2) {
            let keyCode = defaults.integer(forKey: Keys.rewriteHotKeyCode)
            let modifiers = UInt32(defaults.integer(forKey: Keys.rewriteHotKeyModifiers))
            let legacyModifiers = [UInt32(cmdKey | optionKey), UInt32(cmdKey | controlKey)]
            if keyCode == 7, legacyModifiers.contains(modifiers) {
                defaults.set(15, forKey: Keys.rewriteHotKeyCode)
                defaults.set(UInt32(cmdKey | optionKey), forKey: Keys.rewriteHotKeyModifiers)
            }
            defaults.set(true, forKey: Keys.rewriteHotKeyDefaultRMigrationV2)
        }
        if defaults.object(forKey: Keys.enabled) as? Bool != true {
            defaults.set(true, forKey: Keys.enabled)
        }
        if defaults.object(forKey: Keys.toolboxEnabled) == nil {
            defaults.set(true, forKey: Keys.toolboxEnabled)
        }
        if defaults.object(forKey: Keys.floatingIconEnabled) == nil {
            defaults.set(false, forKey: Keys.floatingIconEnabled)
        }
    }

    static func selectedOperation(defaults: UserDefaults = .standard) -> RewriteOperation {
        registerDefaults(defaults: defaults)
        let raw = defaults.string(forKey: Keys.operation) ?? RewriteOperation.fixGrammar.rawValue
        return RewriteOperation(rawValue: raw) ?? .fixGrammar
    }

    static func setSelectedOperation(_ operation: RewriteOperation, defaults: UserDefaults = .standard) {
        defaults.set(operation.rawValue, forKey: Keys.operation)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func translationLanguage(defaults: UserDefaults = .standard) -> TranslationLanguage {
        registerDefaults(defaults: defaults)
        let raw = defaults.string(forKey: Keys.translationLanguage) ?? TranslationLanguage.english.rawValue
        return TranslationLanguage(rawValue: raw) ?? .english
    }

    static func setTranslationLanguage(_ language: TranslationLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: Keys.translationLanguage)
        defaults.set(language.displayName, forKey: "inlineTranslate.lastTargetLanguage")
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setToolboxEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.toolboxEnabled)
        defaults.set(true, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setFloatingIconEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.floatingIconEnabled)
        defaults.set(true, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func hotKeysModeEnabled(defaults: UserDefaults = .standard) -> Bool {
        registerDefaults(defaults: defaults)
        return defaults.bool(forKey: Keys.hotKeysModeEnabled)
    }

    static func setHotKeysModeEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.hotKeysModeEnabled)
        defaults.set(true, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setInterfaceModes(
        toolbox: Bool,
        floatingIcon: Bool,
        hotKeys: Bool,
        defaults: UserDefaults = .standard
    ) {
        if toolbox {
            persistInterfaceModes(toolbox: true, floatingIcon: false, hotKeys: false, defaults: defaults)
        } else if floatingIcon {
            persistInterfaceModes(toolbox: false, floatingIcon: true, hotKeys: false, defaults: defaults)
        } else if hotKeys {
            persistInterfaceModes(toolbox: false, floatingIcon: false, hotKeys: true, defaults: defaults)
        } else {
            persistInterfaceModes(toolbox: true, floatingIcon: false, hotKeys: false, defaults: defaults)
        }
        defaults.set(true, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    private static func persistInterfaceModes(
        toolbox: Bool,
        floatingIcon: Bool,
        hotKeys: Bool,
        defaults: UserDefaults
    ) {
        defaults.set(toolbox, forKey: Keys.toolboxEnabled)
        defaults.set(floatingIcon, forKey: Keys.floatingIconEnabled)
        defaults.set(hotKeys, forKey: Keys.hotKeysModeEnabled)
    }

    static func activationMode(defaults: UserDefaults = .standard) -> SelectionActivationMode {
        registerDefaults(defaults: defaults)
        return SelectionActivationMode(rawValue: defaults.string(forKey: Keys.activationMode) ?? "") ?? .automatic
    }

    static func setActivationMode(_ mode: SelectionActivationMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Keys.activationMode)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func hotKey(for action: TextoraHotKeyAction, defaults: UserDefaults = .standard) -> TextoraHotKey {
        registerDefaults(defaults: defaults)
        let prefix: (String, String, String) = action == .rewrite
            ? (Keys.rewriteHotKeyCode, Keys.rewriteHotKeyModifiers, Keys.rewriteHotKeyEnabled)
            : (Keys.translateHotKeyCode, Keys.translateHotKeyModifiers, Keys.translateHotKeyEnabled)
        return TextoraHotKey(
            keyCode: UInt32(defaults.integer(forKey: prefix.0)),
            modifiers: UInt32(defaults.integer(forKey: prefix.1)),
            isEnabled: defaults.bool(forKey: prefix.2)
        )
    }

    static func setHotKey(_ hotKey: TextoraHotKey, for action: TextoraHotKeyAction, defaults: UserDefaults = .standard) {
        let prefix: (String, String, String) = action == .rewrite
            ? (Keys.rewriteHotKeyCode, Keys.rewriteHotKeyModifiers, Keys.rewriteHotKeyEnabled)
            : (Keys.translateHotKeyCode, Keys.translateHotKeyModifiers, Keys.translateHotKeyEnabled)
        defaults.set(hotKey.keyCode, forKey: prefix.0)
        defaults.set(hotKey.modifiers, forKey: prefix.1)
        defaults.set(hotKey.isEnabled, forKey: prefix.2)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }
}

@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    var onAction: ((TextoraHotKeyAction) -> Void)?
    private var handler: EventHandlerRef?
    private var registrations: [TextoraHotKeyAction: EventHotKeyRef] = [:]
    private(set) var registrationError: String?

    func reload() {
        stop()
        guard SelectionAssistantSettings.hotKeysModeEnabled() else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr,
                  id.signature == OSType(0x54585452),
                  let action = TextoraHotKeyAction(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in GlobalHotKeyManager.shared.onAction?(action) }
            return noErr
        }, 1, &eventType, nil, &handler)

        registrationError = nil
        for action in [TextoraHotKeyAction.rewrite, .translate] {
            let shortcut = SelectionAssistantSettings.hotKey(for: action)
            guard shortcut.isEnabled else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(signature: OSType(0x54585452), id: action.rawValue),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref { registrations[action] = ref }
            else { registrationError = "Shortcut \(shortcut.displayName) is already used by another app." }
        }
    }

    func stop() {
        registrations.values.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
