import AppKit
import Carbon
import XCTest
@testable import Textora

final class SecurityAndSettingsTests: XCTestCase {
    func testCompatibleURLAddsHTTPSAndChatCompletionsPath() {
        let url = AIClient.validatedOpenAICompatibleURL(from: "api.example.com")
        XCTAssertEqual(url?.absoluteString, "https://api.example.com/v1/chat/completions")
    }

    func testCompatibleURLRejectsHTTPAndEmbeddedCredentials() {
        XCTAssertNil(AIClient.validatedOpenAICompatibleURL(from: "http://localhost:8080"))
        XCTAssertNil(AIClient.validatedOpenAICompatibleURL(from: "https://token@example.com"))
    }

    func testSecureAITransportRejectsHTTPAndCredentialedURLs() throws {
        XCTAssertTrue(SecureAITransportPolicy.allows(URL(string: "https://api.example.com/v1/models")))
        XCTAssertFalse(SecureAITransportPolicy.allows(URL(string: "http://api.example.com/v1/models")))
        XCTAssertFalse(SecureAITransportPolicy.allows(URL(string: "https://token@api.example.com/v1/models")))
    }

    func testSecureAITransportOnlyAllowsSameHostHTTPSRedirects() throws {
        let original = try XCTUnwrap(URL(string: "https://api.example.com/v1/chat/completions"))
        let sameHost = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v2/chat/completions")))
        let downgraded = URLRequest(url: try XCTUnwrap(URL(string: "http://api.example.com/v2/chat/completions")))
        let otherHost = URLRequest(url: try XCTUnwrap(URL(string: "https://redirect.example.net/v2/chat/completions")))

        XCTAssertNotNil(SecureAITransportPolicy.redirectedRequest(originalURL: original, proposedRequest: sameHost))
        XCTAssertNil(SecureAITransportPolicy.redirectedRequest(originalURL: original, proposedRequest: downgraded))
        XCTAssertNil(SecureAITransportPolicy.redirectedRequest(originalURL: original, proposedRequest: otherHost))
    }

    func testGeminiKeyIsOnlyInHeader() throws {
        let url = try XCTUnwrap(URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"))
        let request = AIClient.geminiRequest(url: url, apiKey: " secret-key ")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("secret-key"))
        XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { ["key", "api_key", "token"].contains($0.name.lowercased()) }))
    }

    func testRemovedDiagnosticHookDoesNotEvaluatePayload() {
        var didEvaluatePayload = false

        textoraDiagLog("test", {
            didEvaluatePayload = true
            return "private selected text 123"
        }())

        XCTAssertFalse(didEvaluatePayload)
    }

    @MainActor
    func testHotKeyPanelGrowsForLongTextAndStopsAtReadableMaximum() {
        let shortHeight = SelectionToolbarView.hotKeyPanelHeight(
            originalText: "Short source",
            resultText: "Short result"
        )
        let longText = Array(repeating: "A substantially longer sentence for the adaptive preview.", count: 80)
            .joined(separator: " ")
        let longHeight = SelectionToolbarView.hotKeyPanelHeight(
            originalText: longText,
            resultText: longText
        )

        XCTAssertEqual(shortHeight, 292)
        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertLessThanOrEqual(longHeight, 535)
    }

    @MainActor
    func testObjectPasteboardTypesAreRejected() {
        XCTAssertFalse(TextAccessService.containsObjectPasteboardType([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.html.rawValue
        ]))
        XCTAssertTrue(TextAccessService.containsObjectPasteboardType([
            NSPasteboard.PasteboardType.string.rawValue,
            "public.png"
        ]))
        XCTAssertTrue(TextAccessService.containsObjectPasteboardType(["com.adobe.pdf"] ))
        XCTAssertTrue(TextAccessService.containsObjectPasteboardType(["public.file-url"] ))
    }

    @MainActor
    func testRewrittenTextKeepsFormattingOfChangedAndUnchangedRuns() throws {
        let source = NSMutableAttributedString(string: "Plain bad link")
        let emphasis = NSAttributedString.Key("TextoraTestEmphasis")
        source.addAttribute(emphasis, value: true, range: (source.string as NSString).range(of: "bad"))
        let linkRange = (source.string as NSString).range(of: "link")
        source.addAttribute(.link, value: try XCTUnwrap(URL(string: "https://textora.app")), range: linkRange)

        let rewritten = TextAccessService.attributedReplacementPreservingFormatting(
            source: source,
            rewritten: "Plain good link!"
        )

        XCTAssertEqual(rewritten.string, "Plain good link!")
        let goodRange = (rewritten.string as NSString).range(of: "good")
        XCTAssertEqual(rewritten.attribute(emphasis, at: goodRange.location, effectiveRange: nil) as? Bool, true)
        let rewrittenLinkRange = (rewritten.string as NSString).range(of: "link")
        XCTAssertNotNil(rewritten.attribute(.link, at: rewrittenLinkRange.location, effectiveRange: nil))
        XCTAssertNil(rewritten.attribute(.link, at: rewritten.length - 1, effectiveRange: nil))
    }

    @MainActor
    func testInsertedTextInsideFormattedRunInheritsThatFormatting() {
        let source = NSMutableAttributedString(string: "helo")
        let emphasis = NSAttributedString.Key("TextoraTestEmphasis")
        source.addAttribute(emphasis, value: true, range: NSRange(location: 0, length: source.length))

        let rewritten = TextAccessService.attributedReplacementPreservingFormatting(
            source: source,
            rewritten: "hello"
        )

        XCTAssertEqual(rewritten.string, "hello")
        XCTAssertEqual(rewritten.attribute(emphasis, at: 3, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testLegacyDefaultRewriteHotKeyMigratesFromOptionCommandXToR() throws {
        let suiteName = "TextoraTests.HotKeyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(7, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyCode)
        defaults.set(UInt32(cmdKey | optionKey), forKey: SelectionAssistantSettings.Keys.rewriteHotKeyModifiers)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyEnabled)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let hotKey = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        XCTAssertEqual(hotKey.keyCode, 15)
        XCTAssertEqual(hotKey.modifiers, UInt32(cmdKey | optionKey))
    }

    @MainActor
    func testFreshInstallUsesSuggestedRewriteAndTranslateHotKeys() throws {
        let suiteName = "TextoraTests.HotKeyDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let rewrite = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        let translate = SelectionAssistantSettings.hotKey(for: .translate, defaults: defaults)
        XCTAssertEqual(rewrite, TextoraHotKey(
            keyCode: 15,
            modifiers: UInt32(cmdKey | optionKey),
            isEnabled: true
        ))
        XCTAssertEqual(translate, TextoraHotKey(
            keyCode: 17,
            modifiers: UInt32(cmdKey | optionKey),
            isEnabled: true
        ))
    }

    @MainActor
    func testLegacyControlCommandXAlsoMigratesToOptionCommandR() throws {
        let suiteName = "TextoraTests.HotKeyMigrationV2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(7, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyCode)
        defaults.set(UInt32(cmdKey | controlKey), forKey: SelectionAssistantSettings.Keys.rewriteHotKeyModifiers)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyDefaultRMigration)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let hotKey = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        XCTAssertEqual(hotKey.keyCode, 15)
        XCTAssertEqual(hotKey.modifiers, UInt32(cmdKey | optionKey))
    }

    @MainActor
    func testCustomRewriteHotKeyIsNotChangedByDefaultMigration() throws {
        let suiteName = "TextoraTests.HotKeyCustom.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(8, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyCode)
        defaults.set(UInt32(cmdKey | controlKey), forKey: SelectionAssistantSettings.Keys.rewriteHotKeyModifiers)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let hotKey = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        XCTAssertEqual(hotKey.keyCode, 8)
        XCTAssertEqual(hotKey.modifiers, UInt32(cmdKey | controlKey))
    }

    @MainActor
    func testSelectionSettingsPersistAcrossViewModels() {
        let defaults = UserDefaults.standard
        let keys = SelectionAssistantSettings.Keys.self
        let modifiedKeys = [
            keys.translationLanguage,
            keys.operation,
            keys.activationMode,
            keys.rewriteHotKeyCode,
            keys.rewriteHotKeyModifiers,
            keys.rewriteHotKeyEnabled,
            keys.rewriteHotKeyDefaultRMigration,
            keys.rewriteHotKeyDefaultRMigrationV2
        ]
        let previousValues = Dictionary(uniqueKeysWithValues: modifiedKeys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in modifiedKeys {
                if let value = previousValues[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        modifiedKeys.forEach(defaults.removeObject(forKey:))

        defaults.set(TranslationLanguage.russian.rawValue, forKey: keys.translationLanguage)
        SelectionAssistantSettings.setSelectedOperation(.makeProfessional)
        SelectionAssistantSettings.setActivationMode(.hotkeyOnly)
        SelectionAssistantSettings.setHotKey(
            TextoraHotKey(keyCode: 8, modifiers: UInt32(cmdKey | controlKey), isEnabled: true),
            for: .rewrite
        )

        let first = SelectionAssistantViewModel()
        let second = SelectionAssistantViewModel()
        XCTAssertEqual(first.translationLanguage, .russian)
        XCTAssertEqual(second.translationLanguage, .russian)
        XCTAssertEqual(first.operation, .makeProfessional)
        XCTAssertEqual(second.operation, .makeProfessional)
        XCTAssertEqual(SelectionAssistantSettings.activationMode(), .hotkeyOnly)
        XCTAssertEqual(SelectionAssistantSettings.hotKey(for: .rewrite).keyCode, 8)
    }
}
