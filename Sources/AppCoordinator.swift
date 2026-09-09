import AppKit
import Combine
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppCoordinator()
    private static let onboardingCompletedKey = "onboarding.byok.completed.v2"
    private static let onboardingSkippedKey = "onboarding.byok.skipped"

    private var floatingHelper: FloatingHelperController?
    private let selectionAssistant = SelectionAssistantController()
    private let rewritePanel = InlineRewritePanelController()
    private var settingsWindow: NSWindow?
    private var settingsViewModel: AppViewModel?
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: AppViewModel?
    private var accessibilityWizardWindow: NSWindow?
    private let consentPrompt = AppConsentPromptController()
    private let textAccess = TextAccessService()
    private var selectionAssistantSettingsObserver: NSObjectProtocol?
    private var accessibilityPermissionObserver: NSObjectProtocol?
    private var primaryInteractionRetryTask: DispatchWorkItem?
    private var primaryInteractionRetryCount = 0
    private var launchWarmupTask: DispatchWorkItem?
    private var launchWarmupCount = 0
    private var isHelperHovered = false
    private var isRewritePopupHovered = false
    private var isConsentPromptHovered = false
    private var isHidingFloatingPanels = false
    private var floatingPanelsHideTask: DispatchWorkItem?
    @Published private(set) var helperStatus: String = "Initializing"
    private var didRunLaunchFlow = false
    private var shouldOpenAccessibilityAfterOnboarding = false

    override private init() {
        super.init()
    }

    deinit {
        if let selectionAssistantSettingsObserver {
            NotificationCenter.default.removeObserver(selectionAssistantSettingsObserver)
        }
        if let accessibilityPermissionObserver {
            NotificationCenter.default.removeObserver(accessibilityPermissionObserver)
        }
        primaryInteractionRetryTask?.cancel()
        launchWarmupTask?.cancel()
    }

    /// Call only from `NSApplicationDelegate.applicationDidFinishLaunching`.
    func startAfterApplicationReady() {
        guard !didRunLaunchFlow else { return }
        didRunLaunchFlow = true
        start()
    }

    func start() {
        removeObsoleteTextoraDiagnostics()
        AccessibilityPermissionMonitor.shared.start()
        installAccessibilityPermissionObserverIfNeeded()
        installSelectionAssistantSettingsObserverIfNeeded()
        rewritePanel.onHoverChanged = { [weak self] hovering in
            self?.handleRewritePopupHoverChanged(hovering)
        }
        rewritePanel.onActionInvoked = { [weak self] in
            self?.floatingHelper?.refreshAfterExternalRewriteApplied()
            self?.hideFloatingPanelsIfNeeded()
        }
        rewritePanel.onSuggestionAvailabilityChanged = { [weak self] hasSuggestion in
            self?.floatingHelper?.markRewritePopupSuggestionAvailability(hasSuggestion)
        }
        consentPrompt.onAllow = { [weak self] in
            self?.handleConsentAllow()
        }
        consentPrompt.onDeny = { [weak self] in
            self?.handleConsentDeny()
        }
        consentPrompt.onLater = { [weak self] in
            self?.handleConsentLater()
        }
        consentPrompt.onHoverChanged = { [weak self] hovering in
            self?.handleConsentPromptHoverChanged(hovering)
        }
        selectionAssistant.onConsentRequired = { [weak self] anchor, bundleID in
            self?.handleSelectionAssistantConsentRequired(anchor: anchor, bundleID: bundleID)
        }
        GlobalHotKeyManager.shared.onAction = { [weak self] action in
            self?.handleGlobalHotKey(action)
        }
        GlobalHotKeyManager.shared.reload()
        if floatingHelper == nil {
            floatingHelper = FloatingHelperController(
                onRewriteTap: { [weak self] frame in
                    self?.showRewritePopupFromFloatingState(frame: frame)
                },
                onFloatingHoverChanged: { [weak self] hovering, frame in
                    self?.handleFloatingHoverChanged(hovering: hovering, frame: frame)
                }
            )
            floatingHelper?.onStatusChange = { [weak self] status in
                self?.helperStatus = status
            }
            floatingHelper?.onEvaluationCompleted = { [weak self] in
                guard let self,
                      self.rewritePanel.isVisible,
                      let frame = self.floatingHelper?.currentFrame,
                      !frame.isEmpty else { return }
                self.showRewritePopupFromFloatingState(frame: frame, requestIfMissing: false)
            }
            floatingHelper?.onEvaluationStarted = { [weak self] in
                guard let self,
                      self.rewritePanel.isVisible,
                      let frame = self.floatingHelper?.currentFrame,
                      !frame.isEmpty,
                      let context = self.floatingHelper?.currentFocusedContextForPopup() else { return }
                self.rewritePanel.showProcessing(near: frame, context: context)
            }
            floatingHelper?.onFocusedTextContentChanged = { [weak self] context in
                guard let self,
                      self.rewritePanel.isVisible,
                      let frame = self.floatingHelper?.currentFrame,
                      !frame.isEmpty,
                      let context else { return }
                self.rewritePanel.showProcessing(near: frame, context: context)
            }
        }

        KeychainHelper.migrateIfNeeded()
        KeychainHelper.warmUpCache()
        scheduleLaunchWarmupRetry(reason: "launch")
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) {
            shouldOpenAccessibilityAfterOnboarding = true
            configurePrimaryInteractionMode()
            showOnboardingWindow()
            return
        }
        if !hasAnyConfiguredKey() {
            shouldOpenAccessibilityAfterOnboarding = true
            configurePrimaryInteractionMode()
            schedulePrimaryInteractionRetry(reason: "waitingForKey")
            showOnboardingWindow()
            return
        }
        if !textAccess.hasAccessibilityPermission() {
            configurePrimaryInteractionMode()
            schedulePrimaryInteractionRetry(reason: "accessibilityUnavailable")
            showAccessibilityWizardDeferred()
            return
        }
        configurePrimaryInteractionMode()
        schedulePrimaryInteractionRetry(reason: "launchWarmup")
        showOnboardingIfNeededOnLaunch()
    }

    private func installSelectionAssistantSettingsObserverIfNeeded() {
        guard selectionAssistantSettingsObserver == nil else { return }
        selectionAssistantSettingsObserver = NotificationCenter.default.addObserver(
            forName: SelectionAssistantSettings.settingsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configurePrimaryInteractionMode()
            }
        }
    }

    private func installAccessibilityPermissionObserverIfNeeded() {
        guard accessibilityPermissionObserver == nil else { return }
        accessibilityPermissionObserver = NotificationCenter.default.addObserver(
            forName: .textoraAccessibilityPermissionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isTrusted = (notification.userInfo?["isTrusted"] as? Bool) ?? self.textAccess.hasAccessibilityPermission()
                self.handleAccessibilityPermissionChanged(isTrusted: isTrusted)
            }
        }
    }

    private func handleAccessibilityPermissionChanged(isTrusted: Bool) {
        logSelectionAssistantDiagnostic("accessibility changed trusted=\(isTrusted)")
        if isTrusted {
            dismissAccessibilityWizardIfVisibleWithoutRestartingOnboarding()
            KeychainHelper.migrateIfNeeded()
            KeychainHelper.warmUpCache()
            cancelPrimaryInteractionRetry()
            configurePrimaryInteractionMode()
            scheduleLaunchWarmupRetry(reason: "accessibilityGranted")
            showOnboardingIfNeededOnLaunch(afterAccessibility: true)
        } else {
            selectionAssistant.stop()
            floatingHelper?.stop()
            rewritePanel.hide()
            consentPrompt.hide()
            helperStatus = "Accessibility disabled"
            schedulePrimaryInteractionRetry(reason: "accessibilityRevoked")
        }
        settingsViewModel?.refreshAccessibilityPermissionStatus()
        onboardingViewModel?.refreshAccessibilityPermissionStatus()
    }

    private func dismissAccessibilityWizardIfVisibleWithoutRestartingOnboarding() {
        guard let accessibilityWizardWindow else { return }
        accessibilityWizardWindow.delegate = nil
        accessibilityWizardWindow.close()
        self.accessibilityWizardWindow = nil
    }

    private var isToolboxEnabled: Bool {
        SelectionAssistantSettings.registerDefaults()
        return UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
    }

    private var isFloatingIconEnabled: Bool {
        SelectionAssistantSettings.registerDefaults()
        return UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.floatingIconEnabled)
    }

    private var isHotKeysEnabled: Bool {
        SelectionAssistantSettings.hotKeysModeEnabled()
    }

    private func configurePrimaryInteractionMode() {
        cancelScheduledFloatingPanelsHide()
        isHelperHovered = false
        isRewritePopupHovered = false
        isConsentPromptHovered = false
        rewritePanel.hide()
        consentPrompt.hide()
        floatingHelper?.setKeepBelowWindow(nil)

        GlobalHotKeyManager.shared.reload()
        guard hasAnyConfiguredKey() else {
            helperStatus = "API key required"
            selectionAssistant.stop()
            floatingHelper?.stop()
            return
        }
        guard textAccess.hasAccessibilityPermission() else {
            helperStatus = "Waiting for Accessibility permission"
            selectionAssistant.stop()
            floatingHelper?.stop()
            return
        }
        cancelPrimaryInteractionRetry()

        let hasEnabledHotKey = isHotKeysEnabled && (SelectionAssistantSettings.hotKey(for: .rewrite).isEnabled
            || SelectionAssistantSettings.hotKey(for: .translate).isEnabled
        )
        if isToolboxEnabled || hasEnabledHotKey {
            selectionAssistant.start(automaticDetectionEnabled: isToolboxEnabled)
        } else {
            selectionAssistant.stop()
        }

        if isFloatingIconEnabled {
            floatingHelper?.start()
        } else {
            floatingHelper?.stop()
        }

        if !isToolboxEnabled, !isFloatingIconEnabled, hasEnabledHotKey {
            helperStatus = "Hotkeys active"
            return
        }

        switch (isToolboxEnabled, isFloatingIconEnabled, hasEnabledHotKey) {
        case (true, _, true): helperStatus = "Toolbox + hotkeys active"
        case (true, _, false): helperStatus = "Toolbox active"
        case (_, true, true): helperStatus = "Floating icon + hotkeys active"
        case (_, true, false): helperStatus = "Floating icon active"
        case (false, false, true): helperStatus = "Hotkeys active"
        case (false, false, false): helperStatus = "No Textora interface enabled"
        }
    }

    private func handleGlobalHotKey(_ action: TextoraHotKeyAction) {
        guard hasAnyConfiguredKey() else {
            showOnboardingWindow()
            return
        }
        guard textAccess.hasAccessibilityPermission() else {
            showAccessibilityWizardDeferred()
            return
        }
        selectionAssistant.performHotKeyAction(action)
    }

    func warmPrimaryInteractionsIfPossible() {
        configurePrimaryInteractionMode()
        schedulePrimaryInteractionRetry(reason: "activationWarmup")
        scheduleLaunchWarmupRetry(reason: "activationWarmup")
    }

    func prepareForTermination() {
        settingsViewModel?.flushPendingSave()
        onboardingViewModel?.flushPendingSave()
        GlobalHotKeyManager.shared.stop()
    }

    private func scheduleLaunchWarmupRetry(reason: String) {
        guard hasAnyConfiguredKey() else { return }
        guard launchWarmupTask == nil else { return }
        guard launchWarmupCount < 24 else {
            logSelectionAssistantDiagnostic(
                "launch warmup abandoned attempts=\(launchWarmupCount) reason=\(reason)"
            )
            return
        }
        launchWarmupCount += 1
        let retryDelays: [TimeInterval] = [
            0.25, 0.50, 0.75, 1.0, 1.5, 2.0,
            3.0, 4.0, 5.0, 6.0, 8.0, 10.0
        ]
        let delay = retryDelays[min(launchWarmupCount - 1, retryDelays.count - 1)]
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launchWarmupTask = nil
                self.configurePrimaryInteractionMode()
                if self.shouldContinueLaunchWarmup {
                    self.scheduleLaunchWarmupRetry(reason: reason)
                } else {
                    self.cancelLaunchWarmupRetry()
                }
            }
        }
        launchWarmupTask = task
        logSelectionAssistantDiagnostic(
            "launch warmup scheduled attempt=\(launchWarmupCount) delay=\(String(format: "%.2f", delay)) reason=\(reason)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private var shouldContinueLaunchWarmup: Bool {
        guard hasAnyConfiguredKey() else { return false }
        guard textAccess.hasAccessibilityPermission() else { return true }
        if isToolboxEnabled || isFloatingIconEnabled || isHotKeysEnabled {
            return false
        }
        return launchWarmupCount < 3
    }

    private func cancelLaunchWarmupRetry() {
        launchWarmupTask?.cancel()
        launchWarmupTask = nil
        launchWarmupCount = 0
    }

    private func schedulePrimaryInteractionRetry(reason: String) {
        guard hasAnyConfiguredKey() else { return }
        guard primaryInteractionRetryTask == nil else { return }
        guard primaryInteractionRetryCount < 12 else {
            logSelectionAssistantDiagnostic(
                "primary retry abandoned attempts=\(primaryInteractionRetryCount) reason=\(reason)"
            )
            return
        }
        primaryInteractionRetryCount += 1
        let retryDelays: [TimeInterval] = [0.10, 0.25, 0.50, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0, 10.0]
        let delay = retryDelays[min(primaryInteractionRetryCount - 1, retryDelays.count - 1)]
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.primaryInteractionRetryTask = nil
                self.configurePrimaryInteractionMode()
                if !self.textAccess.hasAccessibilityPermission() {
                    self.schedulePrimaryInteractionRetry(reason: reason)
                }
            }
        }
        primaryInteractionRetryTask = task
        logSelectionAssistantDiagnostic(
            "primary retry scheduled attempt=\(primaryInteractionRetryCount) delay=\(String(format: "%.2f", delay)) reason=\(reason)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func cancelPrimaryInteractionRetry() {
        primaryInteractionRetryTask?.cancel()
        primaryInteractionRetryTask = nil
        primaryInteractionRetryCount = 0
    }

    private func logSelectionAssistantDiagnostic(_ message: @autoclosure () -> String) {}

    /// One run-loop cycle + short delay so MenuBarExtra and LSUIElement finish activation.
    private func showAccessibilityWizardDeferred() {
        DispatchQueue.main.async { [weak self] in
            self?.showAccessibilityWizard()
        }
    }

    private func showAccessibilityWizard() {
        guard accessibilityWizardWindow == nil else { return }
        let content = AccessibilityWizardView(
            onOpenAccessibility: { [weak self] in
                self?.textAccess.openAccessibilitySettings()
            }
        )
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Textora"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.center()
        window.delegate = self
        accessibilityWizardWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === accessibilityWizardWindow {
            accessibilityWizardWindow = nil
            KeychainHelper.migrateIfNeeded()
            KeychainHelper.warmUpCache()
            configurePrimaryInteractionMode()
            showOnboardingIfNeededOnLaunch(afterAccessibility: true)
            return
        }
        if (notification.object as? NSWindow) === onboardingWindow {
            if onboardingViewModel?.isOnboardingComplete != true {
                onboardingViewModel?.skipOnboardingForNow()
            }
            onboardingWindow = nil
        }
    }

    func showDebugBubbleAtMouse() {
        floatingHelper?.showDebugBubbleAtMouse()
    }

    private func handleFloatingHoverChanged(hovering: Bool, frame: CGRect) {
        guard isFloatingIconEnabled else {
            rewritePanel.hide()
            consentPrompt.hide()
            floatingHelper?.setKeepBelowWindow(nil)
            return
        }
        isHelperHovered = hovering
        if hovering {
            cancelScheduledFloatingPanelsHide()
            let status = textAccess.currentAppConsentStatus()
            switch status {
            case .allowed:
                isConsentPromptHovered = false
                consentPrompt.hide()
                showRewritePopupFromFloatingState(frame: frame)
                floatingHelper?.setKeepBelowWindow(rewritePanel.window)
            case .denied:
                rewritePanel.hide()
                isConsentPromptHovered = false
                consentPrompt.hide()
                floatingHelper?.setKeepBelowWindow(nil)
            case .unknown:
                rewritePanel.hide()
                floatingHelper?.setKeepBelowWindow(nil)
                if let app = textAccess.frontmostAppInfo() {
                    consentPrompt.show(near: frame, appName: app.displayName, targetBundleID: app.bundleID)
                }
            }
            return
        }
        scheduleHideFloatingPanelsIfNeeded()
    }

    private func showRewritePopupFromFloatingState(frame: CGRect, requestIfMissing: Bool = true) {
        guard let floatingHelper else {
            rewritePanel.show(near: frame, triggerRewrite: false)
            return
        }
        if let result = floatingHelper.cachedPopupResultForCurrentFocus() {
            rewritePanel.showWithSuggestion(
                near: frame,
                context: result.context,
                suggestion: result.suggestion,
                operation: result.operation,
                suggestionOptions: result.suggestionOptions,
                isNoIssues: result.isNoIssues
            )
            return
        }
        if let context = floatingHelper.currentFocusedContextForPopup(), floatingHelper.isCurrentlyEvaluating || requestIfMissing {
            rewritePanel.showProcessing(near: frame, context: context)
        } else {
            rewritePanel.show(near: frame, triggerRewrite: false)
        }
        if requestIfMissing {
            floatingHelper.requestEvaluationForCurrentFocusIfNeeded()
        }
    }

    private func handleRewritePopupHoverChanged(_ hovering: Bool) {
        isRewritePopupHovered = hovering
        if hovering {
            cancelScheduledFloatingPanelsHide()
        } else {
            scheduleHideFloatingPanelsIfNeeded()
        }
    }

    private func handleConsentPromptHoverChanged(_ hovering: Bool) {
        isConsentPromptHovered = hovering
        if hovering {
            cancelScheduledFloatingPanelsHide()
        } else {
            scheduleHideFloatingPanelsIfNeeded()
        }
    }

    private func scheduleHideFloatingPanelsIfNeeded() {
        cancelScheduledFloatingPanelsHide()
        let task = DispatchWorkItem { [weak self] in
            self?.hideFloatingPanelsIfNeeded()
        }
        floatingPanelsHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func cancelScheduledFloatingPanelsHide() {
        floatingPanelsHideTask?.cancel()
        floatingPanelsHideTask = nil
    }

    private func hideFloatingPanelsIfNeeded() {
        guard !isHelperHovered && !isRewritePopupHovered && !isConsentPromptHovered else { return }
        guard !isHidingFloatingPanels else { return }
        // If user manually dragged the rewrite pop-up, keep it open until explicitly closed.
        guard !rewritePanel.isPinnedOpen else { return }
        // Keep popup open when interacting with native dropdowns (they open in a separate window
        // and can temporarily end SwiftUI onHover). Use a small “tolerance” area around the popup.
        if rewritePanel.isVisible, let frame = rewritePanel.currentFrame {
            let mouse = NSEvent.mouseLocation
            let safe = frame.insetBy(dx: -90, dy: -90)
            if safe.contains(mouse) {
                return
            }
        }
        isHidingFloatingPanels = true
        cancelScheduledFloatingPanelsHide()
        rewritePanel.hide()
        floatingHelper?.setKeepBelowWindow(nil)
        consentPrompt.hide()
        isConsentPromptHovered = false
        isHidingFloatingPanels = false
    }

    private func handleConsentAllow() {
        isConsentPromptHovered = false
        guard let bundleID = consentPrompt.capturedConsentBundleID, !bundleID.isEmpty else {
            consentPrompt.hide()
            return
        }
        textAccess.setAppConsentStatus(.allowed, for: bundleID)
        consentPrompt.hide()
        selectionAssistant.resolvePendingHotKeyConsent(for: bundleID, allowed: true)
        if isFloatingIconEnabled, let frame = floatingHelper?.currentFrame, !frame.isEmpty {
            showRewritePopupFromFloatingState(frame: frame)
        }
    }

    private func handleConsentDeny() {
        isConsentPromptHovered = false
        guard let bundleID = consentPrompt.capturedConsentBundleID, !bundleID.isEmpty else {
            consentPrompt.hide()
            return
        }
        textAccess.setAppConsentStatus(.denied, for: bundleID)
        rewritePanel.hide()
        consentPrompt.hide()
        selectionAssistant.resolvePendingHotKeyConsent(for: bundleID, allowed: false)
    }

    private func handleConsentLater() {
        isConsentPromptHovered = false
        if let bundleID = consentPrompt.capturedConsentBundleID {
            selectionAssistant.resolvePendingHotKeyConsent(for: bundleID, allowed: false)
        }
        consentPrompt.hide()
        if isToolboxEnabled {
            selectionAssistant.suppressConsentPromptBriefly()
        }
    }

    private func handleSelectionAssistantConsentRequired(anchor: CGRect, bundleID: String) {
        guard isToolboxEnabled || isHotKeysEnabled else { return }
        cancelScheduledFloatingPanelsHide()
        rewritePanel.hide()
        floatingHelper?.setKeepBelowWindow(nil)

        let frontmost = textAccess.frontmostAppInfo()
        let appName = frontmost?.bundleID == bundleID ? frontmost?.displayName ?? bundleID : bundleID
        consentPrompt.show(near: anchor, appName: appName, targetBundleID: bundleID)
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let vm = AppViewModel()
            settingsViewModel = vm
            let root = ContentView(viewModel: vm)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Textora Settings"
            // Default true would release the window when closed → dangling ref / crash on second open.
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = hosting
            settingsWindow = window
        } else {
            settingsViewModel?.reloadFromUserDefaults()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showQuickSetupWindow() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingSkippedKey)
        showOnboardingWindow()
    }

    private func showOnboardingIfNeededOnLaunch(afterAccessibility: Bool = false) {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: Self.onboardingCompletedKey)
        let hasAnyConfiguredKey = hasAnyConfiguredKey()

        // If there are no configured keys, always show quick setup regardless of previous skip/completed flags.
        // This prevents "silent no-op" state when onboarding was previously dismissed.
        if !hasAnyConfiguredKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showOnboardingWindow()
            }
            return
        }

        // If keys are present, keep previous onboarding behavior.
        guard !completed else { return }
        if afterAccessibility {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showOnboardingWindow()
        }
    }

    private func showOnboardingWindow() {
        if onboardingViewModel == nil {
            onboardingViewModel = AppViewModel()
        }
        onboardingViewModel?.prepareOnboardingSession()
        if onboardingWindow == nil {
            let root = OnboardingView(
                viewModel: onboardingViewModel!,
                onClose: { [weak self] in
                    self?.closeOnboardingWindow()
                },
                onOpenSettings: { [weak self] in
                    self?.showSettingsWindow()
                },
                onFinish: { [weak self] in
                    guard let self else { return }
                    guard self.onboardingViewModel?.completeOnboarding() == true else { return }
                    self.closeOnboardingWindow()
                    if self.shouldOpenAccessibilityAfterOnboarding || !self.textAccess.hasAccessibilityPermission() {
                        self.shouldOpenAccessibilityAfterOnboarding = false
                        self.showAccessibilityWizardDeferred()
                    } else {
                        self.configurePrimaryInteractionMode()
                    }
                }
            )
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Textora"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.contentView = hosting
            window.center()
            window.delegate = self
            onboardingWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
    }

    private func hasAnyConfiguredKey() -> Bool {
        (KeychainHelper.read(key: KeychainHelper.openAIKeyAccount)?.isEmpty == false) ||
        (KeychainHelper.read(key: KeychainHelper.geminiKeyAccount)?.isEmpty == false) ||
        (KeychainHelper.read(key: KeychainHelper.claudeKeyAccount)?.isEmpty == false) ||
        (KeychainHelper.read(key: KeychainHelper.customTokenAccount)?.isEmpty == false)
    }
}
