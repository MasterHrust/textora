import AppKit
import Foundation

@MainActor
final class InlineRewriteViewModel: ObservableObject {
    enum OperationReviewState: Equatable {
        case unknown
        case clean
        case hasSuggestion
    }

    @Published var operation: RewriteOperation {
        didSet {
            if shouldPersistOperationChanges {
                UserDefaults.standard.set(operation.rawValue, forKey: Self.lastOperationKey)
            }
        }
    }
    @Published var originalText = ""
    @Published var rewrittenText = ""
    @Published var isLoading = false
    @Published var errorText = ""
    @Published var applyErrorText = ""
    @Published private(set) var noChangesNeeded = false

    @Published var translateTargetLanguage: String {
        didSet {
            let value = translateTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            UserDefaults.standard.set(value, forKey: Self.lastTranslateLanguageKey)
            if let language = TranslationLanguage.allCases.first(where: {
                $0.displayName.caseInsensitiveCompare(value) == .orderedSame
            }) {
                UserDefaults.standard.set(language.rawValue, forKey: SelectionAssistantSettings.Keys.translationLanguage)
            }
        }
    }
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false
    @Published var translateErrorText: String = ""
    @Published private(set) var operationReviewStates: [RewriteOperation: OperationReviewState] = [:]
    @Published private(set) var smartBadgeOperation: RewriteOperation?
    @Published var needsMailManualCapture: Bool = false {
        didSet {
            if needsMailManualCapture {
                startMailAutoCaptureWatcherIfNeeded()
            } else {
                stopMailAutoCaptureWatcher()
            }
        }
    }

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private let spellChecker = NSSpellChecker.shared
    private var lastContext: TextAccessService.FocusedTextContext?
    private var rewriteTask: Task<Void, Never>?
    private var rewriteRequestID: Int = 0
    private var translateTask: Task<Void, Never>?
    private var translateRequestID: Int = 0
    private var cachedRewriteSuggestions: [RewriteOperation: String] = [:]
    private var mailAutoCaptureTask: Task<Void, Never>?
    private var mailSelectionStableSince: Date?
    private var suppressedProgrammaticOperationChange: RewriteOperation?
    private var shouldPersistOperationChanges = true
    private static let lastOperationKey = "inlineRewrite.lastOperation"
    private static let lastTranslateLanguageKey = "inlineTranslate.lastTargetLanguage"
    private let mailBundleID = "com.apple.mail"

    private struct RewriteScope {
        let text: String
        let range: NSRange
    }

    private func clearCachedReviewState() {
        cachedRewriteSuggestions.removeAll()
        operationReviewStates.removeAll()
        smartBadgeOperation = nil
    }

    func operationReviewState(for operation: RewriteOperation) -> OperationReviewState {
        operationReviewStates[operation] ?? .unknown
    }

    private func stopMailAutoCaptureWatcher() {
        mailAutoCaptureTask?.cancel()
        mailAutoCaptureTask = nil
        mailSelectionStableSince = nil
    }

    private func startMailAutoCaptureWatcherIfNeeded() {
        guard mailAutoCaptureTask == nil else { return }
        // Pop-up steals key focus from Mail, so we cannot rely on AX "selection in frontmost app".
        // Debounce from watcher start, then `manualCaptureSelectionFromMail` briefly activates Mail for Cmd+C.
        mailSelectionStableSince = Date()
        mailAutoCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.needsMailManualCapture {
                if let since = self.mailSelectionStableSince,
                   Date().timeIntervalSince(since) >= 1.0 {
                    self.captureMailSelectionAndRewrite()
                    if !self.needsMailManualCapture {
                        break
                    }
                    if self.errorText.contains("mail_capture_busy") {
                        // Retry soon after clipboard/copy throttle clears.
                        self.mailSelectionStableSince = Date().addingTimeInterval(-0.92)
                    } else {
                        // No selection / other failure: wait again so the user can adjust highlight.
                        self.mailSelectionStableSince = Date()
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.mailAutoCaptureTask = nil
        }
    }

    static let translateLanguageSuggestions: [String] = [
        "English",
        "Ukrainian",
        "Russian",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Portuguese",
        "Polish",
        "Czech",
        "Slovak",
        "Dutch",
        "Swedish",
        "Norwegian",
        "Danish",
        "Finnish",
        "Estonian",
        "Latvian",
        "Lithuanian",
        "Romanian",
        "Bulgarian",
        "Greek",
        "Turkish",
        "Arabic",
        "Hebrew",
        "Hindi",
        "Indonesian",
        "Vietnamese",
        "Thai",
        "Chinese (Simplified)",
        "Chinese (Traditional)",
        "Japanese",
        "Korean"
    ]

    init() {
        let sharedLanguage = UserDefaults.standard.string(forKey: SelectionAssistantSettings.Keys.translationLanguage)
            .flatMap(TranslationLanguage.init(rawValue:))?.displayName
        translateTargetLanguage = sharedLanguage
            ?? (UserDefaults.standard.string(forKey: Self.lastTranslateLanguageKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = UserDefaults.standard.string(forKey: Self.lastOperationKey) {
            operation = Self.migrateOperation(from: raw) ?? .fixGrammar
        } else {
            operation = .fixGrammar
        }
        if translateTargetLanguage.isEmpty {
            translateTargetLanguage = "English"
        }
    }

    /// Maps saved strings including legacy labels from older builds.
    private static func migrateOperation(from raw: String) -> RewriteOperation? {
        if let op = RewriteOperation(rawValue: raw) { return op }
        let legacy: [String: RewriteOperation] = [
            "Fix grammar": .fixGrammar,
            "Make professional": .makeProfessional
        ]
        return legacy[raw]
    }

    func loadFromFocusedField(minLength: Int = 1) -> Bool {
        // Pop-up should operate on a larger slice than the auto-check to reduce “multiple iterations”.
        guard let context = textService.focusedTextContext(
            minLength: minLength,
            maxLength: 6000,
            allowClipboardFallback: true
        ) else {
            // Critical: never keep stale context/text when current focus can't be read.
            lastContext = nil
            originalText = ""
            rewrittenText = ""
            clearCachedReviewState()
            translatedText = ""
            translateErrorText = ""
            isTranslating = false
            isLoading = false
            noChangesNeeded = false
            applyErrorText = ""
            errorText = "No suitable editable field found"
            return false
        }
        guard let scopedContext = contextForRewriteUI(context) else {
            lastContext = nil
            originalText = ""
            rewrittenText = ""
            clearCachedReviewState()
            translatedText = ""
            translateErrorText = ""
            isTranslating = false
            isLoading = false
            noChangesNeeded = false
            applyErrorText = ""
            errorText = "No editable text to rewrite"
            return false
        }
        lastContext = scopedContext
        originalText = scopedContext.text
        rewrittenText = ""
        clearCachedReviewState()
        translatedText = ""
        translateErrorText = ""
        isLoading = false
        errorText = ""
        applyErrorText = ""
        noChangesNeeded = false
        return true
    }

    func loadFromSelection(minLength: Int = 1) -> Bool {
        guard let context = textService.selectedTextContextAnyFocus(
            minLength: minLength,
            maxLength: 6000,
            allowClipboardFallback: true
        ) else {
            lastContext = nil
            originalText = ""
            rewrittenText = ""
            clearCachedReviewState()
            translatedText = ""
            translateErrorText = ""
            isTranslating = false
            isLoading = false
            noChangesNeeded = false
            applyErrorText = ""
            errorText = "No selected text found"
            return false
        }
        lastContext = context
        originalText = context.text
        rewrittenText = ""
        clearCachedReviewState()
        translatedText = ""
        translateErrorText = ""
        isLoading = false
        errorText = ""
        applyErrorText = ""
        noChangesNeeded = false
        return true
    }

    /// AX chain → selection → **live Cmd+C** when Slack/Electron hides selection from Accessibility.
    func loadFromBestAvailable(minLength: Int = 1) -> Bool {
        let isMailFrontmost = textService.frontmostAppInfo()?.bundleID == mailBundleID
        @discardableResult
        func commit(_ ctx: TextAccessService.FocusedTextContext) -> Bool {
            guard let scopedContext = contextForRewriteUI(ctx) else { return false }
            lastContext = scopedContext
            originalText = scopedContext.text
            rewrittenText = ""
            clearCachedReviewState()
            translatedText = ""
            translateErrorText = ""
            isTranslating = false
            isLoading = false
            noChangesNeeded = false
            applyErrorText = ""
            errorText = ""
            needsMailManualCapture = false
            return true
        }
        if let signal = textService.selectedTextSignalAnyFocus(), signal.hasSelection,
           let ctx = textService.selectedTextContextAnyFocus(
            minLength: minLength,
            maxLength: 6000,
            allowClipboardFallback: true
               ) {
            if commit(ctx) { return true }
        }
        if let ctx = textService.focusedTextContext(
            minLength: minLength,
            maxLength: 6000,
            allowClipboardFallback: true
        ) {
            if commit(ctx) { return true }
        }
        if textService.hasFocusedEditableElement(),
           let ctx = textService.focusedTextContext(
            minLength: 0,
               maxLength: 6000,
               allowClipboardFallback: true
           ) {
            if commit(ctx) { return true }
        }
        if let ctx = textService.selectedTextContextAnyFocus(
            minLength: minLength,
            maxLength: 6000,
            allowClipboardFallback: true
        ) {
            if commit(ctx) { return true }
        }
        if let ctx = textService.focusedTextContextFromLiveCopy(minLength: minLength, maxLength: 6000) {
            if commit(ctx) { return true }
        }
        lastContext = nil
        originalText = ""
        rewrittenText = ""
        clearCachedReviewState()
        translatedText = ""
        translateErrorText = ""
        isTranslating = false
        isLoading = false
        noChangesNeeded = false
        applyErrorText = ""
        if isMailFrontmost {
            needsMailManualCapture = true
            errorText = "No text available for rewrite (mail_ax_empty)"
        } else {
            errorText = "No suitable editable field found"
        }
        return false
    }

    private func captureMailSelectionAndRewrite() {
        switch textService.manualCaptureSelectionFromMail(minLength: 1, maxLength: 6000) {
        case .success(let context):
            let scopedContext = contextForRewriteUI(context) ?? context
            lastContext = scopedContext
            originalText = scopedContext.text
            rewrittenText = ""
            clearCachedReviewState()
            translatedText = ""
            translateErrorText = ""
            isTranslating = false
            isLoading = false
            noChangesNeeded = false
            applyErrorText = ""
            errorText = ""
            needsMailManualCapture = false
            triggerRewrite(.manual)
        case .busy:
            errorText = "No text available for rewrite (mail_capture_busy)"
            needsMailManualCapture = true
        case .noSelection:
            errorText = "No text available for rewrite (mail_manual_capture_empty)"
            needsMailManualCapture = true
        case .notAllowed:
            errorText = "No text available for rewrite (mail_not_allowed)"
            needsMailManualCapture = true
        case .notMail:
            errorText = "No text available for rewrite (mail_not_frontmost)"
            needsMailManualCapture = true
        }
    }

    func setPrefilled(
        context: TextAccessService.FocusedTextContext,
        suggestion: String,
        operation: RewriteOperation,
        suggestionOptions: [OverlaySuggestion] = []
    ) {
        lastContext = context
        originalText = context.text
        rewrittenText = suggestion
        let knownSuggestions: [OverlaySuggestion] = {
            if !suggestionOptions.isEmpty { return suggestionOptions }
            let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [OverlaySuggestion(operation: operation, text: suggestion)]
        }()
        cachedRewriteSuggestions = Dictionary(
            uniqueKeysWithValues: knownSuggestions.map { ($0.operation, $0.text) }
        )
        if suggestionOptions.isEmpty {
            operationReviewStates = knownSuggestions.isEmpty ? [:] : [operation: .hasSuggestion]
        } else {
            operationReviewStates = Dictionary(
                uniqueKeysWithValues: RewriteOperation.allCases.map { ($0, .clean) }
            )
            for option in knownSuggestions {
                operationReviewStates[option.operation] = .hasSuggestion
            }
        }
        let recommended = knownSuggestions.first(where: { $0.isRecommended })?.operation
        smartBadgeOperation = operationReviewStates[recommended ?? operation] == .hasSuggestion
            ? (recommended ?? operation)
            : nil
        translatedText = ""
        translateErrorText = ""
        isTranslating = false
        suppressedProgrammaticOperationChange = operation
        self.operation = operation
        errorText = ""
        applyErrorText = ""
        isLoading = false
        updateNoChangesNeededFlag()
    }

    func setNoChanges(
        context: TextAccessService.FocusedTextContext,
        operation: RewriteOperation
    ) {
        lastContext = context
        originalText = context.text
        rewrittenText = ""
        clearCachedReviewState()
        operationReviewStates = Dictionary(
            uniqueKeysWithValues: RewriteOperation.allCases.map { ($0, .clean) }
        )
        translatedText = ""
        translateErrorText = ""
        isTranslating = false
        suppressedProgrammaticOperationChange = operation
        self.operation = operation
        errorText = ""
        applyErrorText = ""
        isLoading = false
        noChangesNeeded = !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setProcessing(context: TextAccessService.FocusedTextContext) {
        lastContext = context
        originalText = context.text
        rewrittenText = ""
        clearCachedReviewState()
        translatedText = ""
        translateErrorText = ""
        isTranslating = false
        errorText = ""
        applyErrorText = ""
        noChangesNeeded = false
        isLoading = true
    }

    func prepareOperationForMarkerWindow() {
        let nextOperation: RewriteOperation
        if UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.smartAIEnabled) {
            nextOperation = smartRecommendedOperation()
        } else {
            let raw = UserDefaults.standard.string(forKey: Self.lastOperationKey)
                ?? RewriteOperation.fixGrammar.rawValue
            nextOperation = Self.migrateOperation(from: raw) ?? .fixGrammar
        }
        setOperation(nextOperation, persist: false)
    }

    func smartRecommendedOperation() -> RewriteOperation {
        recommendedOperation(for: originalText)
    }

    func smartSecondaryOperations() -> Set<RewriteOperation> {
        let primary = recommendedOperation(for: originalText)
        let cleaned = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard primary != .fixGrammar,
              hasLocalSpellingIssues(cleaned) || containsMixedLatinCyrillicWord(cleaned) else {
            return []
        }
        return [.fixGrammar]
    }

    private func setOperation(_ nextOperation: RewriteOperation, persist: Bool) {
        guard operation != nextOperation else { return }
        if !persist {
            suppressedProgrammaticOperationChange = nextOperation
        }
        shouldPersistOperationChanges = persist
        operation = nextOperation
        shouldPersistOperationChanges = true
    }

    func rewrite(requestID: Int) async {
        // Refresh from AX when we still see real text; after the popup opens, focus may move off Slack — do not wipe a good snapshot.
        if let freshContext = textService.focusedTextContext(minLength: 1, maxLength: 6000, allowClipboardFallback: true),
           let scopedFreshContext = contextForRewriteUI(freshContext),
           !scopedFreshContext.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastContext = scopedFreshContext
            originalText = scopedFreshContext.text
            needsMailManualCapture = false
        } else if textService.hasFocusedEditableElement(),
                  let emptyField = textService.focusedTextContext(minLength: 0, maxLength: 6000, allowClipboardFallback: true) {
            let existing = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty || lastContext == nil {
                // Use empty fallback only when we have no previously captured text.
                let scopedEmptyField = contextForRewriteUI(emptyField) ?? emptyField
                lastContext = scopedEmptyField
                originalText = scopedEmptyField.text
            }
        } else if let live = textService.focusedTextContextFromLiveCopy(minLength: 1, maxLength: 6000),
                  let scopedLive = contextForRewriteUI(live) {
            lastContext = scopedLive
            originalText = scopedLive.text
            needsMailManualCapture = false
        } else if lastContext == nil {
            guard requestID == rewriteRequestID else { return }
            if textService.frontmostAppInfo()?.bundleID == mailBundleID {
                needsMailManualCapture = true
                errorText = "No text available for rewrite (mail_ax_empty)"
            } else {
                errorText = "No text available for rewrite"
            }
            rewrittenText = ""
            noChangesNeeded = false
            return
        }

        let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            guard requestID == rewriteRequestID else { return }
            if textService.frontmostAppInfo()?.bundleID == mailBundleID {
                needsMailManualCapture = true
                errorText = "No text available for rewrite (mail_ax_empty)"
            } else {
                errorText = "No text available for rewrite"
            }
            return
        }

        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "openai") ?? .openai
        let fallbackModel: String
        switch provider {
        case .openai:
            fallbackModel = AIClient.Defaults.openAIModel
        case .gemini:
            fallbackModel = AIClient.Defaults.geminiModel
        case .claude:
            fallbackModel = AIClient.Defaults.claudeModel
        case .other:
            fallbackModel = AIClient.Defaults.customModel
        }
        let model = UserDefaults.standard.string(forKey: "model") ?? fallbackModel
        let key: String
        switch provider {
        case .openai:
            key = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        case .gemini:
            key = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        case .claude:
            key = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        case .other:
            key = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
        }
        guard !key.isEmpty else {
            guard requestID == rewriteRequestID else { return }
            errorText = "Add API key in Settings"
            return
        }
        if provider == .other {
            let base = UserDefaults.standard
                .string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base.isEmpty else {
                guard requestID == rewriteRequestID else { return }
                errorText = "Add API base URL in Settings (Other AI)"
                return
            }
        }

        guard requestID == rewriteRequestID else { return }
        isLoading = true
        errorText = ""
        applyErrorText = ""
        rewrittenText = ""
        noChangesNeeded = false
        textoraDiagLog(
            "aiRewrite",
            "caller=popupRewrite smartAI=\(UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.smartAIEnabled)) "
            + "operation=\(operation.rawValue) provider=\(provider.rawValue) model=\(model) "
            + "text=\(textoraDiagPreview(text))"
        )
        if operation == .fixGrammar {
            let localMixedScriptFix = fixMixedLatinCyrillicWords(in: text)
            if normalized(localMixedScriptFix) != normalized(text) {
                rewrittenText = localMixedScriptFix
                cachedRewriteSuggestions[operation] = localMixedScriptFix
                operationReviewStates[operation] = .hasSuggestion
                isLoading = false
                updateNoChangesNeededFlag()
                return
            }
        }
        do {
            let newText: String
            if operation == .fixGrammar {
                newText = try await aiClient.checkAndSuggestIfNeeded(
                    provider: provider,
                    model: model,
                    apiKey: key,
                    text: text
                )
            } else {
                newText = try await aiClient.rewriteText(
                    provider: provider,
                    model: model,
                    apiKey: key,
                    text: text,
                    operation: operation
                )
            }
            guard requestID == rewriteRequestID else { return }
            rewrittenText = newText
            updateNoChangesNeededFlag()
            let trimmedNewText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNewText.isEmpty, !noChangesNeeded {
                cachedRewriteSuggestions[operation] = newText
                operationReviewStates[operation] = .hasSuggestion
            } else {
                cachedRewriteSuggestions.removeValue(forKey: operation)
                operationReviewStates[operation] = .clean
                if smartBadgeOperation == operation {
                    smartBadgeOperation = nil
                }
            }
        } catch is CancellationError {
            // Expected when user quickly re-triggers rewrite; keep UI stable.
            guard requestID == rewriteRequestID else { return }
        } catch {
            guard requestID == rewriteRequestID else { return }
            errorText = error.localizedDescription
            rewrittenText = ""
            noChangesNeeded = false
        }
        guard requestID == rewriteRequestID else { return }
        isLoading = false
    }

    enum RewriteTrigger {
        case popupOpened
        case operationChanged
        case manual
    }

    func triggerRewrite(_ trigger: RewriteTrigger = .manual) {
        if trigger == .operationChanged, let suppressed = suppressedProgrammaticOperationChange {
            if operation == suppressed {
                suppressedProgrammaticOperationChange = nil
                return
            }
            suppressedProgrammaticOperationChange = nil
        }
        if lastContext == nil, !loadFromBestAvailable(minLength: 1) {
            return
        }
        if trigger == .operationChanged,
           operationReviewStates[operation] == .clean,
           !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rewriteTask?.cancel()
            isLoading = false
            errorText = ""
            applyErrorText = ""
            rewrittenText = ""
            noChangesNeeded = true
            if smartBadgeOperation == operation {
                smartBadgeOperation = nil
            }
            return
        }
        if trigger == .operationChanged,
           let cached = cachedRewriteSuggestions[operation],
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rewriteTask?.cancel()
            isLoading = false
            errorText = ""
            applyErrorText = ""
            rewrittenText = cached
            updateNoChangesNeededFlag()
            operationReviewStates[operation] = noChangesNeeded ? .clean : .hasSuggestion
            if noChangesNeeded, smartBadgeOperation == operation {
                smartBadgeOperation = nil
            }
            return
        }
        rewriteTask?.cancel()
        rewriteRequestID += 1
        let requestID = rewriteRequestID
        rewriteTask = Task { @MainActor in
            await rewrite(requestID: requestID)
        }
    }

    func triggerTranslate() {
        // Ensure we operate on fresh focused text when possible.
        if lastContext == nil, !loadFromBestAvailable(minLength: 1) {
            return
        }
        translateTask?.cancel()
        translateRequestID += 1
        let requestID = translateRequestID
        translateTask = Task { @MainActor in
            await translate(requestID: requestID)
        }
    }

    private func translate(requestID: Int) async {
        // Best effort refresh — same reasoning as rewrite(); live copy for Electron when AX is blind.
        if let freshContext = textService.focusedTextContext(minLength: 1, maxLength: 6000, allowClipboardFallback: true),
           let scopedFreshContext = contextForRewriteUI(freshContext),
           !scopedFreshContext.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastContext = scopedFreshContext
            originalText = scopedFreshContext.text
            needsMailManualCapture = false
        } else if textService.hasFocusedEditableElement(),
                  let emptyField = textService.focusedTextContext(minLength: 0, maxLength: 6000, allowClipboardFallback: true) {
            let existing = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty || lastContext == nil {
                let scopedEmptyField = contextForRewriteUI(emptyField) ?? emptyField
                lastContext = scopedEmptyField
                originalText = scopedEmptyField.text
            }
        } else if let live = textService.focusedTextContextFromLiveCopy(minLength: 1, maxLength: 6000),
                  let scopedLive = contextForRewriteUI(live) {
            lastContext = scopedLive
            originalText = scopedLive.text
            needsMailManualCapture = false
        } else if lastContext == nil {
            guard requestID == translateRequestID else { return }
            if textService.frontmostAppInfo()?.bundleID == mailBundleID {
                needsMailManualCapture = true
                translateErrorText = "No text available for translation (mail_ax_empty)"
            } else {
                translateErrorText = "No text available for translation"
            }
            translatedText = ""
            return
        }

        // If we already have a suggestion, translate the suggested text (more useful than translating the original).
        let candidateSuggestion = rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateOriginal = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = candidateSuggestion.isEmpty ? candidateOriginal : candidateSuggestion
        guard !text.isEmpty else {
            guard requestID == translateRequestID else { return }
            translateErrorText = "No text available for translation"
            translatedText = ""
            return
        }

        let target = translateTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            guard requestID == translateRequestID else { return }
            translateErrorText = "Choose target language"
            translatedText = ""
            return
        }

        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "openai") ?? .openai
        let fallbackModel: String
        switch provider {
        case .openai:
            fallbackModel = AIClient.Defaults.openAIModel
        case .gemini:
            fallbackModel = AIClient.Defaults.geminiModel
        case .claude:
            fallbackModel = AIClient.Defaults.claudeModel
        case .other:
            fallbackModel = AIClient.Defaults.customModel
        }
        let model = UserDefaults.standard.string(forKey: "model") ?? fallbackModel
        let key: String
        switch provider {
        case .openai:
            key = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        case .gemini:
            key = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        case .claude:
            key = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        case .other:
            key = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
        }
        guard !key.isEmpty else {
            guard requestID == translateRequestID else { return }
            translateErrorText = "Add API key in Settings"
            translatedText = ""
            return
        }
        if provider == .other {
            let base = UserDefaults.standard
                .string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base.isEmpty else {
                guard requestID == translateRequestID else { return }
                translateErrorText = "Add API base URL in Settings (Other AI)"
                translatedText = ""
                return
            }
        }

        guard requestID == translateRequestID else { return }
        isTranslating = true
        translateErrorText = ""
        translatedText = ""
        UserDefaults.standard.set(target, forKey: Self.lastTranslateLanguageKey)

        do {
            let out = try await aiClient.translateText(
                provider: provider,
                model: model,
                apiKey: key,
                text: text,
                targetLanguage: target
            )
            guard requestID == translateRequestID else { return }
            translatedText = out
        } catch is CancellationError {
            guard requestID == translateRequestID else { return }
        } catch {
            guard requestID == translateRequestID else { return }
            translateErrorText = error.localizedDescription
            translatedText = ""
        }
        guard requestID == translateRequestID else { return }
        isTranslating = false
    }

    func apply() -> TextAccessService.ApplyResult {
        guard let context = lastContext, !rewrittenText.isEmpty, !noChangesNeeded else { return .failed }
        return textService.applyRewrittenText(rewrittenText, basedOn: context)
    }

    /// Apply after a brief delay — gives the system time to return AX focus
    /// to the original text field once the popup panel is dismissed.
    func scheduleApply(onSuccess: @escaping () -> Void = {}) {
        guard let context = lastContext, !rewrittenText.isEmpty, !noChangesNeeded else { return }
        let text = rewrittenText
        let baselineOriginal = originalText
        applyErrorText = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            // Refresh context right before apply to avoid stale AX element/range.
            let applyContext: TextAccessService.FocusedTextContext = {
                guard let fresh = self.textService.focusedTextContext(minLength: 1, allowClipboardFallback: true) else {
                    return context
                }
                let normalizedFresh = self.normalized(fresh.text)
                let normalizedBaseline = self.normalized(baselineOriginal)
                return normalizedFresh == normalizedBaseline ? fresh : context
            }()

            let result = self.textService.applyRewrittenText(text, basedOn: applyContext)
            switch result {
            case .success:
                self.applyErrorText = ""
                onSuccess()
            case .clipboardArmed:
                self.applyErrorText = "Исправление в буфере — нажмите ⌘V"
            case .failed, .unsupportedTarget:
                self.applyErrorText = ""
            }
        }
    }

    private func preferredLocalRangeForPointApply(original: String, corrected: String) -> NSRange? {
        let originalNS = original as NSString
        let correctedNS = corrected as NSString
        guard originalNS.length > 0 || correctedNS.length > 0 else { return nil }
        let limit = min(originalNS.length, correctedNS.length)
        var prefix = 0
        while prefix < limit, originalNS.character(at: prefix) == correctedNS.character(at: prefix) {
            prefix += 1
        }
        if prefix == originalNS.length, prefix == correctedNS.length {
            return nil
        }
        var suffix = 0
        while suffix < originalNS.length - prefix,
              suffix < correctedNS.length - prefix,
              originalNS.character(at: originalNS.length - 1 - suffix) == correctedNS.character(at: correctedNS.length - 1 - suffix) {
            suffix += 1
        }
        let length = max(0, originalNS.length - prefix - suffix)
        return NSRange(location: min(prefix, originalNS.length), length: length)
    }

    func copyResult() {
        let translated = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(translated, forType: .string)
            return
        }
        guard !rewrittenText.isEmpty, !noChangesNeeded else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewrittenText, forType: .string)
    }

    private func updateNoChangesNeededFlag() {
        let trimmed = rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            noChangesNeeded = !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return
        }
        let unchangedByNormalization = normalizedForNoChanges(trimmed) == normalizedForNoChanges(originalText)
        // For Fix mode, do not show "no changes needed" if local spell checker still
        // sees a typo in the original text (AI sometimes returns input unchanged).
        if operation == .fixGrammar,
           unchangedByNormalization,
           (hasLocalSpellingIssues(originalText) || containsMixedLatinCyrillicWord(originalText)) {
            noChangesNeeded = false
            return
        }
        noChangesNeeded = unchangedByNormalization
    }

    private func recommendedOperation(for text: String) -> RewriteOperation {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .fixGrammar }
        let hasTextIssues = hasLocalSpellingIssues(cleaned) || containsMixedLatinCyrillicWord(cleaned)
        if hasTextIssues { return .fixGrammar }
        if looksOverloaded(cleaned) { return .shorten }
        if looksFormal(cleaned) { return .makeProfessional }
        if looksPlain(cleaned) { return .humanize }
        return .makeProfessional
    }

    private func looksFormal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let cues = [
            "dear ", "kindly", "regards", "sincerely", "appreciate", "would like",
            "please find", "i am writing", "could you please", "thank you for",
            "following up", "as discussed", "regarding", "replacement logic",
            "уважа", "пожалуйста", "благодар", "с уважением", "прошу", "не могли бы"
        ]
        return cues.contains { lower.contains($0) }
    }

    private func looksOverloaded(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 24 else { return false }
        let punctuationLoad = text.filter { ",;:()".contains($0) }.count
        let fillerCues = [
            "actually", "basically", "really", "very", "just", "probably",
            "как бы", "в целом", "просто", "очень"
        ]
        let lower = text.lowercased()
        let fillerCount = fillerCues.reduce(0) { partial, cue in
            partial + (lower.contains(cue) ? 1 : 0)
        }
        return words.count >= 34 || punctuationLoad >= 5 || fillerCount >= 2
    }

    private func looksPlain(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 3, words.count <= 28 else { return false }
        return !looksFormal(text) && !looksOverloaded(text)
    }

    private func contextForRewriteUI(
        _ context: TextAccessService.FocusedTextContext
    ) -> TextAccessService.FocusedTextContext? {
        // Explicit selection should stay exact. This keeps selected-text translation/rewrite predictable.
        guard !context.usesSelection else { return context }
        let ns = context.text as NSString
        let trimmed = trimmedRange(NSRange(location: 0, length: ns.length), in: ns)
        guard trimmed.length > 0 else { return nil }
        if trimmed.location == 0, trimmed.length == ns.length { return context }
        let scope = RewriteScope(text: ns.substring(with: trimmed), range: trimmed)
        return TextAccessService.FocusedTextContext(
            text: scope.text,
            frame: context.frame,
            usesSelection: false,
            selectedRange: nil,
            targetElement: context.targetElement,
            targetAppPID: context.targetAppPID,
            targetBundleID: context.targetBundleID,
            anchor: context.anchor,
            textFragments: scopedFragments(from: context.textFragments, scope: scope)
        )
    }

    private func rewriteScope(in text: String) -> RewriteScope? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let protectedRanges = protectedTokenRanges(in: text).sorted { $0.location < $1.location }
        guard !protectedRanges.isEmpty else {
            let trimmed = trimmedRange(NSRange(location: 0, length: ns.length), in: ns)
            guard trimmed.length > 0 else { return nil }
            return RewriteScope(text: ns.substring(with: trimmed), range: trimmed)
        }

        var segments: [RewriteScope] = []
        var cursor = 0
        for protectedRange in protectedRanges {
            if protectedRange.location > cursor {
                appendRewriteSegment(
                    NSRange(location: cursor, length: protectedRange.location - cursor),
                    in: ns,
                    to: &segments
                )
            }
            cursor = max(cursor, protectedRange.location + protectedRange.length)
        }
        if cursor < ns.length {
            appendRewriteSegment(NSRange(location: cursor, length: ns.length - cursor), in: ns, to: &segments)
        }

        return segments
            .filter { isMeaningfulRewriteSegment($0.text) }
            .max { lhs, rhs in
                rewriteScore(lhs.text) < rewriteScore(rhs.text)
            }
    }

    private func appendRewriteSegment(_ range: NSRange, in text: NSString, to segments: inout [RewriteScope]) {
        let trimmed = trimmedRange(range, in: text)
        guard trimmed.length > 0 else { return }
        segments.append(RewriteScope(text: text.substring(with: trimmed), range: trimmed))
    }

    private func scopedFragments(
        from fragments: [TextAccessService.TextFragment],
        scope: RewriteScope
    ) -> [TextAccessService.TextFragment] {
        let scopeNS = scope.text as NSString
        return fragments.compactMap { fragment -> TextAccessService.TextFragment? in
            let overlap = NSIntersectionRange(fragment.range, scope.range)
            guard overlap.length > 0 else { return nil }
            let localLocation = max(0, overlap.location - scope.range.location)
            let localLength = max(0, min(overlap.length, scopeNS.length - localLocation))
            guard localLength > 0 else { return nil }
            let fragmentLength = max(1, fragment.range.length)
            let startOffset = max(0, overlap.location - fragment.range.location)
            let charWidth = fragment.rect.width / CGFloat(fragmentLength)
            let x = fragment.rect.minX + CGFloat(startOffset) * charWidth
            let width = max(12, CGFloat(overlap.length) * charWidth)
            return TextAccessService.TextFragment(
                text: scopeNS.substring(with: NSRange(location: localLocation, length: localLength)),
                range: NSRange(location: localLocation, length: localLength),
                rect: CGRect(
                    x: x,
                    y: fragment.rect.minY,
                    width: min(width, max(12, fragment.rect.maxX - x)),
                    height: fragment.rect.height
                )
            )
        }
    }

    private func protectedTokenRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let pattern = #"(?i)(?:https?://|www\.)\S+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|[@#][\p{L}\p{N}_][\p{L}\p{N}_-]*|\+?\d[\d\s().-]{2,}\d|\b\d+(?:[.,:/-]\d+)*\b|\b[\w.-]+\.(?:com|net|org|io|dev|app|ai|co|ru|ua|by|de|fr|es|it|pl|nl|uk)\b\S*"#
        var ranges: [NSRange] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            ranges.append(contentsOf: regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range))
        }
        ranges.append(contentsOf: emojiRanges(in: text))
        return ranges.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }
    }

    private func emojiRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let cluster = text[index..<next]
            if cluster.unicodeScalars.contains(where: isEmojiScalar) {
                ranges.append(NSRange(index..<next, in: text))
            }
            index = next
        }
        return ranges
    }

    private func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        if scalar.value == 0xFE0F || scalar.value == 0x200D { return true }
        guard scalar.properties.isEmoji else { return false }
        return !(0x30...0x39).contains(scalar.value)
    }

    private func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange {
        var start = max(0, min(range.location, text.length))
        var end = max(start, min(range.location + range.length, text.length))
        while start < end, isWhitespace(text.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func isMeaningfulRewriteSegment(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let nonSpace = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard letters >= 3, nonSpace > 0 else { return false }
        if text.split(whereSeparator: { $0.isWhitespace }).count == 1 {
            return Double(letters) / Double(nonSpace) >= 0.75
        }
        return Double(letters) / Double(nonSpace) >= 0.45
    }

    private func rewriteScore(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { score, scalar in
            CharacterSet.letters.contains(scalar) ? score + 2 : score + 1
        }
    }

    private func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func normalizedForNoChanges(_ text: String) -> String {
        let folded = String(text.unicodeScalars.compactMap { scalar -> Character? in
            switch scalar.value {
            case 0xFFFC, 0x200B, 0x200C, 0x200D, 0x2060:
                return nil
            case 0x2018, 0x2019, 0x201B, 0x2032:
                return "'"
            case 0x201C, 0x201D, 0x201F, 0x2033:
                return "\""
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212:
                return "-"
            default:
                return Character(scalar)
            }
        })
        return normalized(folded)
    }

    private func hasLocalSpellingIssues(_ text: String) -> Bool {
        let nsText = text as NSString
        if nsText.length < 3 { return false }
        let misspelled = spellChecker.checkSpelling(
            of: text,
            startingAt: 0,
            language: nil,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelled.location != NSNotFound
    }

    private func containsMixedLatinCyrillicWord(_ text: String) -> Bool {
        for token in text.split(whereSeparator: { !$0.isLetter }) {
            var hasLatin = false
            var hasCyrillic = false
            for scalar in token.unicodeScalars {
                let v = scalar.value
                if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                    hasLatin = true
                } else if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                    hasCyrillic = true
                }
                if hasLatin && hasCyrillic {
                    return true
                }
            }
        }
        return false
    }

    private func fixMixedLatinCyrillicWords(in text: String) -> String {
        let map: [Character: Character] = [
            "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "У": "Y",
            "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "к": "k", "м": "m", "т": "t", "в": "b", "н": "h"
        ]
        var result = ""
        var token = ""
        for ch in text {
            if ch.isLetter {
                token.append(ch)
                continue
            }
            result.append(normalizeToken(token, map: map))
            token.removeAll(keepingCapacity: true)
            result.append(ch)
        }
        result.append(normalizeToken(token, map: map))
        return result
    }

    private func normalizeToken(_ token: String, map: [Character: Character]) -> String {
        guard !token.isEmpty else { return token }
        let hasLatin = token.unicodeScalars.contains {
            let v = $0.value
            return (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
        }
        let hasCyrillic = token.unicodeScalars.contains {
            let v = $0.value
            return (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v)
        }
        guard hasLatin && hasCyrillic else { return token }
        return String(token.map { map[$0] ?? $0 })
    }
}
