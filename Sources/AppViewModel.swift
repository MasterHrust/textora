import AppKit
import Carbon
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum OnboardingInterfaceMode {
        case toolbox
        case floatingIcon
        case hotKeys
    }

    enum SettingsKeys {
        static let detailedCorrectionsEnabled = "overlay.detailedCorrections.enabled"
        static let smartAIEnabled = "overlay.smartAI.enabled"
        static let selectionAssistantBetaEnabled = SelectionAssistantSettings.Keys.enabled
        static let toolboxEnabled = SelectionAssistantSettings.Keys.toolboxEnabled
        static let floatingIconEnabled = SelectionAssistantSettings.Keys.floatingIconEnabled
        static let hotKeysModeEnabled = SelectionAssistantSettings.Keys.hotKeysModeEnabled
    }

    private enum OnboardingDefaults {
        static let completedKey = "onboarding.byok.completed.v2"
        static let skippedKey = "onboarding.byok.skipped"
    }

    struct AppConsentRow: Identifiable {
        let id: String
        let bundleID: String
        var status: TextAccessService.AppConsentStatus
    }

    @Published var originalText = ""
    @Published var rewrittenText = ""
    @Published var operation: RewriteOperation = .fixGrammar {
        didSet {
            guard !isReloadingFromDefaults, oldValue != operation else { return }
            SelectionAssistantSettings.setSelectedOperation(operation)
        }
    }
    @Published var translationLanguage: TranslationLanguage = .english {
        didSet {
            guard !isReloadingFromDefaults, oldValue != translationLanguage else { return }
            SelectionAssistantSettings.setTranslationLanguage(translationLanguage)
        }
    }
    @Published var isLoading = false
    @Published var errorText = ""

    @Published var provider: AIProvider = .openai {
        didSet {
            guard !isReloadingFromDefaults else { return }
            UserDefaults.standard.set(
                model.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: oldValue.modelUserDefaultsKey
            )
            model = storedModel(for: provider, allowLegacyValue: false)
            UserDefaults.standard.set(model, forKey: "model")
            availableModels = []
            modelCatalogError = ""
            Task { await refreshAvailableModels() }
        }
    }
    @Published var model: String = ""
    @Published var availableModels: [AIModelOption] = []
    @Published var isLoadingModels = false
    @Published var modelCatalogError = ""
    @Published var openAIKey: String = "" {
        didSet { providerKeyDidChange(.openai, from: oldValue, to: openAIKey) }
    }
    @Published var geminiKey: String = "" {
        didSet { providerKeyDidChange(.gemini, from: oldValue, to: geminiKey) }
    }
    @Published var claudeKey: String = "" {
        didSet { providerKeyDidChange(.claude, from: oldValue, to: claudeKey) }
    }
    @Published var customToken: String = ""
    /// OpenAI-compatible Chat Completions base URL (e.g. `https://api.example.com` or `https://host/v1`).
    @Published var customOpenAIBaseURL: String = ""
    @Published var appConsentRows: [AppConsentRow] = []
    @Published var hasAccessibilityPermission: Bool = false
    @Published var detailedCorrectionsEnabled: Bool = false
    @Published var selectionAssistantBetaEnabled: Bool = false
    @Published var toolboxEnabled: Bool = true {
        didSet {
            guard !isReloadingFromDefaults else { return }
            guard oldValue != toolboxEnabled else { return }
            SelectionAssistantSettings.setToolboxEnabled(toolboxEnabled)
        }
    }
    @Published var floatingIconEnabled: Bool = false {
        didSet {
            guard !isReloadingFromDefaults else { return }
            guard oldValue != floatingIconEnabled else { return }
            SelectionAssistantSettings.setFloatingIconEnabled(floatingIconEnabled)
        }
    }
    @Published var hotKeysModeEnabled: Bool = false {
        didSet {
            guard !isReloadingFromDefaults, oldValue != hotKeysModeEnabled else { return }
            SelectionAssistantSettings.setHotKeysModeEnabled(hotKeysModeEnabled)
        }
    }
    @Published var rewriteHotKey = TextoraHotKey(keyCode: 15, modifiers: UInt32(cmdKey | optionKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != rewriteHotKey else { return }
            SelectionAssistantSettings.setHotKey(rewriteHotKey, for: .rewrite)
        }
    }
    @Published var translateHotKey = TextoraHotKey(keyCode: 17, modifiers: UInt32(cmdKey | optionKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != translateHotKey else { return }
            SelectionAssistantSettings.setHotKey(translateHotKey, for: .translate)
        }
    }
    @Published var onboardingStep: Int = 1
    @Published var onboardingErrorText: String = ""
    @Published var isOnboardingBusy: Bool = false
    @Published var isOnboardingComplete: Bool = false

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private var isReloadingFromDefaults = false
    private var autoSaveTask: DispatchWorkItem?
    private var accessibilityPermissionObserver: NSObjectProtocol?
    private var modelCatalogRequestID = UUID()

    init() {
        AccessibilityPermissionMonitor.shared.start()
        accessibilityPermissionObserver = NotificationCenter.default.addObserver(
            forName: .textoraAccessibilityPermissionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isTrusted = (notification.userInfo?["isTrusted"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.hasAccessibilityPermission = isTrusted
            }
        }
        reloadFromUserDefaults()
        isOnboardingComplete = UserDefaults.standard.bool(forKey: OnboardingDefaults.completedKey)
    }

    deinit {
        if let accessibilityPermissionObserver {
            NotificationCenter.default.removeObserver(accessibilityPermissionObserver)
        }
        autoSaveTask?.cancel()
    }

    /// Sync fields when reopening Settings so keys/model match disk (avoids stale SwiftUI state).
    func reloadFromUserDefaults() {
        isReloadingFromDefaults = true
        defer { isReloadingFromDefaults = false }
        SelectionAssistantSettings.registerDefaults()
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "openai") ?? .openai
        model = storedModelForCurrentProvider()
        openAIKey = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        geminiKey = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        claudeKey = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        customToken = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
        customOpenAIBaseURL = UserDefaults.standard.string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey) ?? ""
        detailedCorrectionsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.detailedCorrectionsEnabled)
        selectionAssistantBetaEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.selectionAssistantBetaEnabled)
        toolboxEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.toolboxEnabled)
        floatingIconEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.floatingIconEnabled)
        hotKeysModeEnabled = SelectionAssistantSettings.hotKeysModeEnabled()
        operation = SelectionAssistantSettings.selectedOperation()
        translationLanguage = SelectionAssistantSettings.translationLanguage()
        rewriteHotKey = SelectionAssistantSettings.hotKey(for: .rewrite)
        translateHotKey = SelectionAssistantSettings.hotKey(for: .translate)
        hasAccessibilityPermission = textService.hasAccessibilityPermission()
        refreshAppConsents()
    }

    func refreshSelection() {
        originalText = textService.getSelectedText()
        rewrittenText = ""
        errorText = ""
    }

    func rewrite() async {
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "No selected text found"
            return
        }
        let key: String
        switch provider {
        case .openai:
            key = openAIKey
        case .gemini:
            key = geminiKey
        case .claude:
            key = claudeKey
        case .other:
            key = customToken
        }
        guard !key.isEmpty else {
            errorText = "API key is missing for selected provider"
            return
        }
        if provider == .other {
            let base = customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else {
                errorText = "API base URL is missing for Other"
                return
            }
        }
        isLoading = true
        errorText = ""
        do {
            rewrittenText = try await aiClient.rewriteText(
                provider: provider,
                model: model,
                apiKey: key,
                text: originalText,
                operation: operation
            )
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    var recommendedModel: String {
        defaultModel(for: provider)
    }

    var hasCurrentProviderAPIKey: Bool {
        !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var modelPickerOptions: [AIModelOption] {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !availableModels.contains(where: { $0.id == selected }) else {
            return availableModels
        }
        return [AIModelOption(id: selected, displayName: selected)] + availableModels
    }

    func refreshAvailableModels() async {
        let requestedProvider = provider
        guard requestedProvider != .other else {
            availableModels = []
            modelCatalogError = ""
            isLoadingModels = false
            return
        }

        let key = apiKey(for: requestedProvider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            availableModels = []
            modelCatalogError = "Add the API key to load available models."
            isLoadingModels = false
            return
        }

        let requestID = UUID()
        modelCatalogRequestID = requestID
        isLoadingModels = true
        modelCatalogError = ""
        do {
            let models = try await aiClient.availableModels(provider: requestedProvider, apiKey: key)
            guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
            availableModels = models
            if models.isEmpty {
                modelCatalogError = "The provider returned no compatible text models."
            }
        } catch {
            guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
            availableModels = []
            modelCatalogError = friendlyModelCatalogError(error.localizedDescription)
        }
        guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
        isLoadingModels = false
    }

    func copyResult() {
        guard !rewrittenText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewrittenText, forType: .string)
    }

    func replaceOrCopy() {
        guard !rewrittenText.isEmpty else { return }
        let replaced = textService.replaceSelectedText(with: rewrittenText)
        if !replaced {
            copyResult()
        }
    }

    @discardableResult
    func saveSettings() -> Bool {
        UserDefaults.standard.set(provider.rawValue, forKey: "provider")
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedModel, forKey: provider.modelUserDefaultsKey)
        UserDefaults.standard.set(trimmedModel, forKey: "model")
        UserDefaults.standard.set(
            customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey
        )
        SelectionAssistantSettings.setEnabled(true)
        UserDefaults.standard.set(toolboxEnabled, forKey: SettingsKeys.toolboxEnabled)
        UserDefaults.standard.set(floatingIconEnabled, forKey: SettingsKeys.floatingIconEnabled)
        UserDefaults.standard.set(hotKeysModeEnabled, forKey: SettingsKeys.hotKeysModeEnabled)
        SelectionAssistantSettings.setActivationMode(
            hotKeysModeEnabled && !toolboxEnabled && !floatingIconEnabled ? .hotkeyOnly : .automatic
        )
        SelectionAssistantSettings.setSelectedOperation(operation)
        SelectionAssistantSettings.setTranslationLanguage(translationLanguage)
        NotificationCenter.default.post(name: SelectionAssistantSettings.settingsDidChangeNotification, object: nil)
        let keyResult: Result<Void, KeychainHelper.KeychainError>
        switch provider {
        case .openai:
            keyResult = KeychainHelper.save(key: KeychainHelper.openAIKeyAccount, value: openAIKey)
        case .gemini:
            keyResult = KeychainHelper.save(key: KeychainHelper.geminiKeyAccount, value: geminiKey)
        case .claude:
            keyResult = KeychainHelper.save(key: KeychainHelper.claudeKeyAccount, value: claudeKey)
        case .other:
            keyResult = KeychainHelper.save(key: KeychainHelper.customTokenAccount, value: customToken)
        }
        if case .failure(let error) = keyResult {
            errorText = error.localizedDescription
            onboardingErrorText = error.localizedDescription
            return false
        }
        return true
    }

    var shouldShowOnboarding: Bool {
        !isOnboardingComplete && !UserDefaults.standard.bool(forKey: OnboardingDefaults.skippedKey)
    }

    var settingsAutosaveToken: String {
        [
            provider.rawValue,
            model,
            openAIKey,
            geminiKey,
            claudeKey,
            customToken,
            customOpenAIBaseURL,
            String(toolboxEnabled),
            String(floatingIconEnabled),
            String(hotKeysModeEnabled),
            operation.rawValue,
            translationLanguage.rawValue,
            String(rewriteHotKey.keyCode), String(rewriteHotKey.modifiers), String(rewriteHotKey.isEnabled),
            String(translateHotKey.keyCode), String(translateHotKey.modifiers), String(translateHotKey.isEnabled)
        ].joined(separator: "\u{1F}")
    }

    func skipOnboardingForNow() {
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.skippedKey)
    }

    func moveOnboardingBack() {
        onboardingErrorText = ""
        onboardingStep = max(1, onboardingStep - 1)
    }

    func moveOnboardingNext() {
        onboardingErrorText = ""
        onboardingStep = min(5, onboardingStep + 1)
    }

    var onboardingInterfaceMode: OnboardingInterfaceMode {
        if hotKeysModeEnabled && !toolboxEnabled && !floatingIconEnabled { return .hotKeys }
        return toolboxEnabled ? .toolbox : .floatingIcon
    }

    var hasValidOnboardingInterfaceSelection: Bool {
        switch onboardingInterfaceMode {
        case .hotKeys:
            return rewriteHotKey.isEnabled || translateHotKey.isEnabled
        case .toolbox, .floatingIcon:
            return toolboxEnabled || floatingIconEnabled
        }
    }

    func selectOnboardingInterfaceMode(_ mode: OnboardingInterfaceMode) {
        switch mode {
        case .toolbox:
            updateInterfaceModes(toolbox: true, floatingIcon: false, hotKeys: false)
        case .floatingIcon:
            updateInterfaceModes(toolbox: false, floatingIcon: true, hotKeys: false)
        case .hotKeys:
            updateInterfaceModes(toolbox: false, floatingIcon: false, hotKeys: true)
            rewriteHotKey.isEnabled = true
            translateHotKey.isEnabled = true
        }
    }

    func setInterfaceMode(_ mode: OnboardingInterfaceMode, enabled: Bool) {
        guard enabled else { return }
        switch mode {
        case .toolbox:
            updateInterfaceModes(toolbox: true, floatingIcon: false, hotKeys: false)
        case .floatingIcon:
            updateInterfaceModes(toolbox: false, floatingIcon: true, hotKeys: false)
        case .hotKeys:
            updateInterfaceModes(toolbox: false, floatingIcon: false, hotKeys: true)
            if !rewriteHotKey.isEnabled && !translateHotKey.isEnabled {
                rewriteHotKey.isEnabled = true
                translateHotKey.isEnabled = true
            }
        }
    }

    private func updateInterfaceModes(toolbox: Bool, floatingIcon: Bool, hotKeys: Bool) {
        isReloadingFromDefaults = true
        toolboxEnabled = toolbox
        floatingIconEnabled = floatingIcon
        hotKeysModeEnabled = hotKeys
        isReloadingFromDefaults = false
        SelectionAssistantSettings.setInterfaceModes(
            toolbox: toolbox,
            floatingIcon: floatingIcon,
            hotKeys: hotKeys
        )
    }

    @discardableResult
    func completeOnboarding() -> Bool {
        onboardingErrorText = ""
        guard saveSettings() else { return false }
        isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingDefaults.skippedKey)
        return true
    }

    func prepareOnboardingSession() {
        onboardingStep = 1
        onboardingErrorText = ""
        isOnboardingBusy = false
        reloadFromUserDefaults()
        modelCatalogRequestID = UUID()
        availableModels = []
        modelCatalogError = ""
        isLoadingModels = false
    }

    func validateCurrentProviderSetup() async -> Bool {
        onboardingErrorText = ""
        let key: String
        let validationModel: String
        switch provider {
        case .openai:
            key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.openAIModel : model
        case .gemini:
            key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.geminiModel : model
        case .claude:
            key = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.claudeModel : model
        case .other:
            key = customToken.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.customModel : model
            let base = customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                onboardingErrorText = "Set API URL for Other."
                return false
            }
        }
        guard !key.isEmpty else {
            onboardingErrorText = "Add an API key for the selected provider."
            return false
        }
        isOnboardingBusy = true
        defer { isOnboardingBusy = false }
        guard saveSettings() else { return false }
        do {
            _ = try await aiClient.rewriteText(
                provider: provider,
                model: validationModel,
                apiKey: key,
                text: "hello",
                operation: .fixGrammar
            )
            return true
        } catch {
            onboardingErrorText = friendlyValidationError(error.localizedDescription)
            return false
        }
    }

    private func friendlyValidationError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("invalid api key") {
            return "The key was not accepted. Make sure it is copied fully and has no extra spaces."
        }
        if lower.contains("429") || lower.contains("quota") || lower.contains("rate limit") {
            return "Provider limit reached. Check balance and quotas in your AI account."
        }
        if lower.contains("base url") || lower.contains("invalid api base url") {
            return "API URL looks invalid. Verify the address and format."
        }
        if lower.contains("network") || lower.contains("timed out") || lower.contains("offline") {
            return "Could not connect to the provider. Check your internet connection and try again."
        }
        return "Validation failed: \(raw)"
    }

    private func friendlyModelCatalogError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("api key") || lower.contains("permission") {
            return "Could not load models. Check the API key and its permissions."
        }
        if lower.contains("network") || lower.contains("timed out") || lower.contains("offline") {
            return "Could not load models. Check your internet connection."
        }
        return raw
    }

    /// Debounced auto-save: persists settings 0.5s after the last change.
    func debouncedSave() {
        guard !isReloadingFromDefaults else { return }
        autoSaveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.saveSettings()
        }
        autoSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        _ = saveSettings()
    }

    private func defaultModel(for provider: AIProvider) -> String {
        switch provider {
        case .openai:
            return AIClient.Defaults.openAIModel
        case .gemini:
            return AIClient.Defaults.geminiModel
        case .claude:
            return AIClient.Defaults.claudeModel
        case .other:
            return AIClient.Defaults.customModel
        }
    }

    private func apiKey(for provider: AIProvider) -> String {
        switch provider {
        case .openai:
            return openAIKey
        case .gemini:
            return geminiKey
        case .claude:
            return claudeKey
        case .other:
            return customToken
        }
    }

    private func providerKeyDidChange(_ keyProvider: AIProvider, from oldValue: String, to newValue: String) {
        guard !isReloadingFromDefaults, provider == keyProvider else { return }
        let oldKey = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldKey != newKey else { return }
        modelCatalogRequestID = UUID()
        availableModels = []
        modelCatalogError = ""
        isLoadingModels = false
    }

    private func storedModelForCurrentProvider() -> String {
        storedModel(for: provider, allowLegacyValue: true)
    }

    private func storedModel(for provider: AIProvider, allowLegacyValue: Bool) -> String {
        let defaultsStore = UserDefaults.standard
        let providerValue = defaultsStore.string(forKey: provider.modelUserDefaultsKey)
        let legacyValue = allowLegacyValue ? defaultsStore.string(forKey: "model") : nil
        let stored = (providerValue ?? legacyValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return "" }
        let defaults: Set<String> = [
            AIClient.Defaults.openAIModel,
            "gemini-1.5-pro",
            AIClient.Defaults.geminiModel,
            "claude-3-5-sonnet-latest",
            AIClient.Defaults.claudeModel,
            AIClient.Defaults.customModel
        ]
        if defaults.contains(stored) {
            defaultsStore.set("", forKey: provider.modelUserDefaultsKey)
            return ""
        }
        if providerValue == nil {
            defaultsStore.set(stored, forKey: provider.modelUserDefaultsKey)
        }
        return stored
    }

    func refreshAppConsents() {
        appConsentRows = textService.allAppConsents().map {
            AppConsentRow(id: $0.bundleID, bundleID: $0.bundleID, status: $0.status)
        }
    }

    func requestAccessibilityPermission() {
        textService.openAccessibilitySettings()
        // Permission is granted outside the app; re-check after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAccessibilityPermissionStatus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshAccessibilityPermissionStatus()
        }
    }

    func refreshAccessibilityPermissionStatus() {
        hasAccessibilityPermission = textService.hasAccessibilityPermission()
    }

    func setConsentStatus(for bundleID: String, status: TextAccessService.AppConsentStatus) {
        textService.setAppConsentStatus(status, for: bundleID)
        refreshAppConsents()
    }

    func removeConsent(for bundleID: String) {
        textService.removeAppConsent(for: bundleID)
        refreshAppConsents()
    }
}
