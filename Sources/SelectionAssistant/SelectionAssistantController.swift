import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class SelectionAssistantController: NSObject, NSWindowDelegate {
    private let textService = TextAccessService()
    private let viewModel = SelectionAssistantViewModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var pendingSelectionKey: String?
    private var pendingWeakSelectionRangeSignature: String?
    private var pendingConsentKey: String?
    private var lockedAnchorKey: String?
    private var lockedAnchor: CGRect?
    private var stableSelectionKey: String?
    private var stableSelectionAnchor: CGRect?
    private var lastSelectionGestureAnchor: CGRect?
    private var lockedPanelPlacementSide: PanelPlacementSide?
    private var suppressConsentPromptUntil: Date?
    private var selectionDebounceTask: DispatchWorkItem?
    private var fallbackResolveTask: DispatchWorkItem?
    private var lastFallbackProbeAt = Date.distantPast
    private var fallbackProbeAllowedUntil = Date.distantPast
    private var suppressSelectionUntil = Date.distantPast
    private var contextMenuSuppressionUntil = Date.distantPast
    private var transientSelectionLossGraceUntil = Date.distantPast
    private var ignoreCommandCUntil = Date.distantPast
    private var mouseDownPoint: CGPoint?
    private var didDragSinceMouseDown = false
    private var selectionGestureID = 0
    private var lastTraceSignature: String?
    private var eventMonitorTokens: [Any] = []
    private var commandAEventTap: CFMachPort?
    private var commandAEventTapSource: CFRunLoopSource?
    private var returnHotKeyHandler: EventHandlerRef?
    private var returnHotKeyRegistrations: [EventHotKeyRef] = []
    private var viewModelCancellable: AnyCancellable?
    private var automaticDetectionEnabled = true
    private var isProgrammaticallyMovingPanel = false
    private var pendingHotKeyAction: TextoraHotKeyAction?
    private var pendingHotKeyConsentBundleID: String?

    var onConsentRequired: ((CGRect, String) -> Void)?

    private static let panelWidth: CGFloat = 680
    private static let panelTopReserve: CGFloat = SelectionToolbarView.tooltipTopReserve
    private static let maxPanelContentHeight: CGFloat = 170
    private static let transientSelectionLossGrace: TimeInterval = 0.65
    private static let hotKeyPanelOriginXKey = "hotkey.panel.originX"
    private static let hotKeyPanelOriginYKey = "hotkey.panel.originY"
    private static let returnHotKeySignature = OSType(0x54585245) // TXRE

    private enum PanelPlacementSide {
        case above
        case below
    }

    func start(automaticDetectionEnabled: Bool = true) {
        SelectionAssistantSettings.registerDefaults()
        self.automaticDetectionEnabled = automaticDetectionEnabled
        createPanelIfNeeded()
        installInputMonitorsIfNeeded()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        removeInputMonitors()
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        pendingConsentKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        fallbackProbeAllowedUntil = .distantPast
        suppressSelectionUntil = .distantPast
        contextMenuSuppressionUntil = .distantPast
        transientSelectionLossGraceUntil = .distantPast
        ignoreCommandCUntil = .distantPast
        mouseDownPoint = nil
        didDragSinceMouseDown = false
        selectionGestureID += 1
        lastTraceSignature = nil
        viewModel.clear()
        hidePanel()
        removeReturnHotKeyHandler()
    }

    func resolvePendingHotKeyConsent(for bundleID: String, allowed: Bool) {
        let action = pendingHotKeyConsentBundleID == bundleID ? pendingHotKeyAction : nil
        pendingHotKeyAction = nil
        pendingHotKeyConsentBundleID = nil
        refreshAfterConsentChange()
        guard allowed, let action else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.performHotKeyAction(action)
        }
    }

    func refreshAfterConsentChange() {
        pendingConsentKey = nil
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        selectionGestureID += 1
        lastTraceSignature = nil
        tick()
    }

    func suppressConsentPromptBriefly() {
        suppressConsentPromptUntil = Date().addingTimeInterval(2.0)
        pendingConsentKey = nil
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        hidePanel()
    }

    private func tick() {
        guard UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.enabled) else {
            stop()
            return
        }
        guard automaticDetectionEnabled else { return }
        if Date() < suppressSelectionUntil {
            if !isMouseInsidePanel {
                let until = suppressSelectionUntil
                hideForNoSelection()
                suppressSelectionUntil = until
            }
            return
        }
        if isContextMenuSuppressed || textService.isCurrentFocusInTransientPopupOrMenu() {
            if !isMouseInsidePanel {
                let until = max(contextMenuSuppressionUntil, Date().addingTimeInterval(0.5))
                hideForNoSelection()
                contextMenuSuppressionUntil = until
                suppressSelectionUntil = max(suppressSelectionUntil, until)
            }
            return
        }
        if isFrontmostWeakSelectionApp {
            if let signal = textService.selectedTextSignalAnyFocus(), signal.hasSelection {
                trace("tick browser signal", signal: signal, key: selectionKey(for: signal))
                handleSelectionSignal(signal)
                return
            }
            if shouldHoldPanelDuringTransientSelectionLoss {
                trace("tick transient selection loss")
                if canUseFallbackSelectionProbe {
                    scheduleFallbackSelectionResolve()
                }
                return
            }
            guard canUseFallbackSelectionProbe else {
                if panel?.isVisible == true, pendingSelectionKey != nil {
                    return
                }
                hideForNoSelection()
                return
            }
            trace("tick browser fallback")
            scheduleFallbackSelectionResolve()
            return
        }
        guard let signal = textService.selectedTextSignalAnyFocus(), signal.hasSelection else {
            if isMouseInsidePanel {
                return
            }
            guard canUseFallbackSelectionProbe else {
                hideForNoSelection()
                return
            }
            scheduleFallbackSelectionResolve()
            return
        }
        handleSelectionSignal(signal)
    }

    private func handleSelectionSignal(_ signal: TextAccessService.SelectedTextSignal) {
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        extendTransientSelectionLossGrace()

        let key = selectionKey(for: signal)
        let weakRangeSignature = weakSelectionRangeSignature(for: signal)
        let anchor = anchorForCurrentSelection(
            key: key,
            preferred: preferredAnchor(for: signal),
            allowStableAnchor: true
        )
        rememberAnchor(anchor, for: key)

        switch textService.appConsentStatus(for: signal.targetBundleID) {
        case .allowed:
            pendingConsentKey = nil
        case .denied:
            hideForNoSelection()
            return
        case .unknown:
            hideForConsentRequired(signal: signal, anchor: anchor)
            return
        }

        if panel?.isVisible == true, pendingSelectionKey == key {
            trace("signal same move", signal: signal, key: key)
            showOrMovePanel(near: anchor)
        }

        if key == pendingSelectionKey,
           let weakRangeSignature,
           weakRangeSignature != pendingWeakSelectionRangeSignature {
            pendingWeakSelectionRangeSignature = weakRangeSignature
            trace("signal same range changed", signal: signal, key: key, extra: "rangeSignature=\(weakRangeSignature)")
            viewModel.prepareForSelectionMove()
            scheduleSelectionResolve(expectedKey: key, keepPendingKey: true)
            return
        }

        guard key != pendingSelectionKey else {
            trace("signal ignored same", signal: signal, key: key)
            return
        }
        trace(
            "signal new",
            signal: signal,
            key: key,
            extra: "pending=\(pendingSelectionKey ?? "nil")"
        )
        pendingSelectionKey = key
        pendingWeakSelectionRangeSignature = weakRangeSignature
        viewModel.prepareForSelectionMove()
        scheduleSelectionResolve(expectedKey: key, keepPendingKey: true)
    }

    private func hideForNoSelection() {
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        pendingConsentKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        fallbackProbeAllowedUntil = .distantPast
        suppressSelectionUntil = .distantPast
        transientSelectionLossGraceUntil = .distantPast
        viewModel.clear()
        hidePanel()
        trace("hide no selection")
    }

    private func hideForConsentRequired(signal: TextAccessService.SelectedTextSignal, anchor: CGRect) {
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        transientSelectionLossGraceUntil = .distantPast
        viewModel.clear()
        hidePanel()

        if let suppressConsentPromptUntil, suppressConsentPromptUntil > Date() {
            return
        }
        let key = consentKey(for: signal)
        guard key != pendingConsentKey else { return }
        pendingConsentKey = key
        onConsentRequired?(anchor, signal.targetBundleID)
    }

    private func scheduleSelectionResolve(expectedKey: String, keepPendingKey: Bool = false) {
        selectionDebounceTask?.cancel()
        trace("resolve scheduled", key: expectedKey, extra: "keepPending=\(keepPendingKey)")
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pendingSelectionKey == expectedKey else {
                    self.trace(
                        "resolve skipped stale",
                        key: expectedKey,
                        extra: "pending=\(self.pendingSelectionKey ?? "nil")"
                    )
                    return
                }
                guard Date() >= self.suppressSelectionUntil else {
                    self.trace("resolve skipped suppressed", key: expectedKey)
                    return
                }
                guard !self.isContextMenuSuppressed,
                      !self.textService.isCurrentFocusInTransientPopupOrMenu() else {
                    self.trace("resolve skipped context menu", key: expectedKey)
                    self.hideForNoSelection()
                    return
                }
                let context = self.readSelectedTextContextForToolbar()
                guard let context else {
                    self.trace("resolve no context", key: expectedKey)
                    self.hideForNoSelection()
                    return
                }
                self.extendTransientSelectionLossGrace()
                let anchor = self.anchorForCurrentSelection(
                    key: expectedKey,
                    preferred: self.preferredAnchor(for: context),
                    allowStableAnchor: true
                )
                self.rememberAnchor(anchor, for: expectedKey)
                self.showOrMovePanel(near: anchor)
                if !keepPendingKey {
                    self.pendingSelectionKey = self.selectionKey(for: context)
                }
                self.trace(
                    "resolve context",
                    context: context,
                    key: expectedKey,
                    extra: "keepPending=\(keepPendingKey)"
                )
                self.viewModel.setSelectionContext(context)
            }
        }
        selectionDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func readSelectedTextContextForToolbar() -> TextAccessService.FocusedTextContext? {
        ignoreCommandCUntil = Date().addingTimeInterval(1.25)
        let context = textService.selectedTextContextAnyFocus(
                    minLength: 1,
                    maxLength: 6000,
                    allowClipboardFallback: true,
                    allowBrowserClipboardSelection: true
        )
        ignoreCommandCUntil = Date().addingTimeInterval(0.45)
        return context
    }

    private func scheduleFallbackSelectionResolve() {
        guard canUseFallbackSelectionProbe else { return }
        guard fallbackResolveTask == nil else { return }
        guard Date().timeIntervalSince(lastFallbackProbeAt) > 0.45 else { return }
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fallbackResolveTask = nil
                self.lastFallbackProbeAt = Date()
                guard UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.enabled) else {
                    self.stop()
                    return
                }
                guard self.canUseFallbackSelectionProbe else {
                    self.hideForNoSelection()
                    return
                }
                guard Date() >= self.suppressSelectionUntil else {
                    return
                }
                guard !self.isContextMenuSuppressed,
                      !self.textService.isCurrentFocusInTransientPopupOrMenu() else {
                    self.trace("fallback skipped context menu")
                    self.hideForNoSelection()
                    return
                }
                if let app = self.textService.frontmostAppInfo() {
                    switch self.textService.appConsentStatus(for: app.bundleID) {
                    case .allowed:
                        break
                    case .denied:
                        self.hideForNoSelection()
                        return
                    case .unknown:
                        self.fallbackProbeAllowedUntil = .distantPast
                        self.onConsentRequired?(self.mouseAnchor(), app.bundleID)
                        return
                    }
                }
                guard let context = self.readSelectedTextContextForToolbar() else {
                    self.trace("fallback no context")
                    if self.shouldHoldPanelDuringTransientSelectionLoss {
                        return
                    }
                    self.hideForNoSelection()
                    return
                }
                self.extendTransientSelectionLossGrace()
                self.fallbackProbeAllowedUntil = .distantPast
                let key = self.selectionKey(for: context)
                let anchor = self.anchorForCurrentSelection(
                    key: key,
                    preferred: self.preferredAnchor(for: context),
                    allowStableAnchor: true
                )
                self.rememberAnchor(anchor, for: key)
                self.showOrMovePanel(near: anchor)
                guard key != self.pendingSelectionKey else {
                    self.trace("fallback same context", context: context, key: key)
                    self.viewModel.setSelectionContext(context)
                    return
                }
                self.trace(
                    "fallback new context",
                    context: context,
                    key: key,
                    extra: "pending=\(self.pendingSelectionKey ?? "nil")"
                )
                self.pendingSelectionKey = key
                self.viewModel.prepareForSelectionMove()
                self.viewModel.setSelectionContext(context)
            }
        }
        fallbackResolveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private var canUseFallbackSelectionProbe: Bool {
        Date() <= fallbackProbeAllowedUntil
    }

    private var isMouseSelectionDragActive: Bool {
        mouseDownPoint != nil && didDragSinceMouseDown
    }

    private func installInputMonitorsIfNeeded() {
        guard eventMonitorTokens.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleSelectionGestureEvent(event)
            }
        }
        if let global {
            eventMonitorTokens.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleSelectionGestureEvent(event)
            }
            return event
        }
        if let local {
            eventMonitorTokens.append(local)
        }
        installCommandAEventTapIfNeeded()
    }

    private func removeInputMonitors() {
        for token in eventMonitorTokens {
            NSEvent.removeMonitor(token)
        }
        eventMonitorTokens.removeAll()
        if let commandAEventTap {
            CGEvent.tapEnable(tap: commandAEventTap, enable: false)
        }
        if let commandAEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), commandAEventTapSource, .commonModes)
        }
        commandAEventTap = nil
        commandAEventTapSource = nil
    }

    private func installCommandAEventTapIfNeeded() {
        guard commandAEventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard type == .keyDown, let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                guard flags.contains(.maskCommand) else {
                    return Unmanaged.passUnretained(event)
                }
                if keyCode == 0 || keyCode == 8 {
                    let controller = Unmanaged<SelectionAssistantController>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                    Task { @MainActor in
                        if keyCode == 0 {
                            controller.resetResolvedSelectionState()
                            controller.beginNewSelectionGesture("cmdA")
                            controller.allowFallbackProbeBriefly()
                        } else {
                            controller.handleCommandCEvent()
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        commandAEventTap = tap
        commandAEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleSelectionGestureEvent(_ event: NSEvent) {
        guard UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.enabled) else { return }
        if event.type == .keyDown, event.keyCode == 53 {
            hideForNoSelection()
            return
        }
        if !automaticDetectionEnabled {
            if event.type == .leftMouseDown, panel?.isVisible == true, !isMouseInsidePanel {
                hideForNoSelection()
            }
            return
        }
        switch event.type {
        case .leftMouseDown:
            let clickedInsidePanel = isMouseInsidePanel
            if panel?.isVisible == true, !clickedInsidePanel {
                hideForNoSelection()
            }
            if isContextMenuSuppressed {
                contextMenuSuppressionUntil = Date().addingTimeInterval(0.35)
                suppressSelectionUntil = max(suppressSelectionUntil, contextMenuSuppressionUntil)
                return
            }
            if !clickedInsidePanel {
                suppressSelectionUntil = Date().addingTimeInterval(0.35)
            }
            lastSelectionGestureAnchor = nil
            mouseDownPoint = event.locationInWindow
            didDragSinceMouseDown = false
        case .rightMouseDown:
            suppressForContextMenu()
        case .leftMouseDragged:
            if let mouseDownPoint {
                let dx = event.locationInWindow.x - mouseDownPoint.x
                let dy = event.locationInWindow.y - mouseDownPoint.y
                didDragSinceMouseDown = sqrt(dx * dx + dy * dy) > 4
            } else {
                didDragSinceMouseDown = true
            }
            if didDragSinceMouseDown {
                suppressSelectionUntil = .distantPast
            }
        case .leftMouseUp:
            if didDragSinceMouseDown {
                lastSelectionGestureAnchor = mouseAnchor()
                beginNewSelectionGesture("mouseDrag")
                allowFallbackProbeBriefly()
            } else if event.clickCount >= 2 || event.modifierFlags.contains(.shift) {
                lastSelectionGestureAnchor = mouseAnchor()
                beginNewSelectionGesture(event.clickCount >= 3 ? "tripleClick" : "doubleOrShiftClick")
                allowFallbackProbeBriefly()
            } else if textService.isGoogleSheetsSelectionSurfaceFrontmost() {
                lastSelectionGestureAnchor = mouseAnchor()
                beginNewSelectionGesture("googleSheetsClick")
                allowFallbackProbeBriefly()
            } else {
                suppressSelectionUntil = Date().addingTimeInterval(0.35)
            }
            mouseDownPoint = nil
            didDragSinceMouseDown = false
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandA = flags.contains(.command)
                && (event.charactersIgnoringModifiers?.lowercased() == "a" || event.keyCode == 0)
            let isCommandC = flags.contains(.command)
                && (event.charactersIgnoringModifiers?.lowercased() == "c" || event.keyCode == 8)
            let isKeyboardSelection = flags.contains(.shift)
                && [UInt16(115), 119, 123, 124, 125, 126].contains(event.keyCode)
            if isCommandA {
                resetResolvedSelectionState()
                beginNewSelectionGesture("cmdA")
                allowFallbackProbeBriefly()
            } else if isCommandC {
                handleCommandCEvent()
            } else if isKeyboardSelection {
                beginNewSelectionGesture("keyboardSelection")
                allowFallbackProbeBriefly()
            }
        default:
            break
        }
    }

    private func handleCommandCEvent() {
        guard Date() >= ignoreCommandCUntil else {
            trace("ignore internal copy")
            return
        }
        suppressForUserCopy()
    }

    private func suppressForUserCopy() {
        suppressSelectionUntil = Date().addingTimeInterval(1.25)
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        pendingConsentKey = nil
        lockedPanelPlacementSide = nil
        transientSelectionLossGraceUntil = .distantPast
        viewModel.clear()
        hidePanel()
        trace("suppress copy")
    }

    private func suppressForContextMenu() {
        contextMenuSuppressionUntil = Date().addingTimeInterval(8.0)
        suppressSelectionUntil = max(suppressSelectionUntil, contextMenuSuppressionUntil)
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        pendingConsentKey = nil
        lockedPanelPlacementSide = nil
        transientSelectionLossGraceUntil = .distantPast
        viewModel.clear()
        hidePanel()
        trace("suppress context menu")
    }

    private var isContextMenuSuppressed: Bool {
        Date() < contextMenuSuppressionUntil
    }

    private func allowFallbackProbeBriefly() {
        fallbackProbeAllowedUntil = Date().addingTimeInterval(1.0)
    }

    private func extendTransientSelectionLossGrace() {
        transientSelectionLossGraceUntil = Date().addingTimeInterval(Self.transientSelectionLossGrace)
    }

    private var shouldHoldPanelDuringTransientSelectionLoss: Bool {
        guard panel?.isVisible == true else { return false }
        guard Date() <= transientSelectionLossGraceUntil else { return false }
        return isFrontmostWeakSelectionApp
    }

    private func beginNewSelectionGesture(_ reason: String) {
        selectionGestureID += 1
        pendingWeakSelectionRangeSignature = nil
        lastTraceSignature = nil
        trace("gesture new", extra: "reason=\(reason) id=\(selectionGestureID)")
    }

    private func resetResolvedSelectionState() {
        pendingSelectionKey = nil
        pendingWeakSelectionRangeSignature = nil
        pendingConsentKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lockedPanelPlacementSide = nil
        transientSelectionLossGraceUntil = .distantPast
    }

    private var isFrontmostWeakSelectionApp: Bool {
        guard let bundleID = textService.frontmostAppInfo()?.bundleID.lowercased() else { return false }
        return bundleID == "com.google.chrome"
            || bundleID == "com.apple.safari"
            || bundleID == "com.adobe.reader"
            || bundleID == "com.adobe.acrobat.pro"
            || bundleID == "com.apple.preview"
            || bundleID == "com.tinyspeck.slackmacgap"
            || bundleID.contains("chrome")
            || bundleID.contains("firefox")
            || bundleID.contains("slack")
            || bundleID.contains("tinyspeck")
            || bundleID.contains("brave")
            || bundleID.contains("opera")
            || bundleID.contains("arc")
            || bundleID.contains("adobe.reader")
            || bundleID.contains("adobe.acrobat")
            || bundleID.contains("pdf")
            || bundleID == "company.thebrowser.browser"
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }
        let root = SelectionToolbarView(
            viewModel: viewModel,
            onApply: { [weak self] in
                self?.applyCurrentRewrite()
            },
            onTranslationCopied: { [weak self] in
                self?.hideForNoSelection()
            },
            onClose: { [weak self] in
                self?.hideForNoSelection()
            }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: currentPanelSize)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: currentPanelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        self.panel = panel
        viewModelCancellable = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.resizeVisiblePanelForModelChange()
                self?.updateReturnHotKeyRegistration()
            }
        }
    }

    private func resizeVisiblePanelForModelChange() {
        guard panel?.isVisible == true else { return }
        let anchor = lockedAnchor ?? stableSelectionAnchor ?? lastSelectionGestureAnchor ?? mouseAnchor()
        showOrMovePanel(near: anchor)
    }

    private func showOrMovePanel(near anchor: CGRect) {
        createPanelIfNeeded()
        guard let panel else { return }
        let size = currentPanelSize
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        let frame: CGRect
        if viewModel.presentationMode != .standard,
           let savedFrame = savedHotKeyPanelFrame(size: size) {
            frame = savedFrame
        } else {
            frame = panelFrame(near: anchor, size: size, lockPlacement: !isMouseSelectionDragActive)
        }
        if panel.frame != frame {
            isProgrammaticallyMovingPanel = true
            panel.setFrame(frame, display: true)
            isProgrammaticallyMovingPanel = false
        }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        updateReturnHotKeyRegistration()
    }

    private func applyCurrentRewrite() {
        guard viewModel.canApply else { return }
        unregisterReturnHotKeys()
        viewModel.apply { [weak self] in self?.hidePanel() }
    }

    private func hidePanel() {
        unregisterReturnHotKeys()
        panel?.orderOut(nil)
    }

    private func updateReturnHotKeyRegistration() {
        let shouldRegister = panel?.isVisible == true
            && viewModel.presentationMode == .hotKeyRewrite
            && viewModel.canApply
        guard shouldRegister else {
            unregisterReturnHotKeys()
            return
        }
        guard returnHotKeyRegistrations.isEmpty else { return }
        installReturnHotKeyHandlerIfNeeded()
        for (id, keyCode) in [(UInt32(1), UInt32(36)), (UInt32(2), UInt32(76))] {
            var registration: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                0,
                EventHotKeyID(signature: Self.returnHotKeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &registration
            )
            if status == noErr, let registration {
                returnHotKeyRegistrations.append(registration)
            }
        }
    }

    private func installReturnHotKeyHandlerIfNeeded() {
        guard returnHotKeyHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, refcon in
                guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == SelectionAssistantController.returnHotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let controller = Unmanaged<SelectionAssistantController>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                Task { @MainActor in
                    controller.applyCurrentRewrite()
                }
                return noErr
            },
            1,
            &eventType,
            refcon,
            &returnHotKeyHandler
        )
    }

    private func unregisterReturnHotKeys() {
        returnHotKeyRegistrations.forEach { UnregisterEventHotKey($0) }
        returnHotKeyRegistrations.removeAll()
    }

    private func removeReturnHotKeyHandler() {
        unregisterReturnHotKeys()
        if let returnHotKeyHandler {
            RemoveEventHandler(returnHotKeyHandler)
        }
        returnHotKeyHandler = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticallyMovingPanel,
              viewModel.presentationMode != .standard,
              let movedPanel = notification.object as? NSPanel,
              movedPanel === panel,
              movedPanel.isVisible else { return }
        UserDefaults.standard.set(movedPanel.frame.minX, forKey: Self.hotKeyPanelOriginXKey)
        UserDefaults.standard.set(movedPanel.frame.minY, forKey: Self.hotKeyPanelOriginYKey)
    }

    private func savedHotKeyPanelFrame(size: CGSize) -> CGRect? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.hotKeyPanelOriginXKey) != nil,
              defaults.object(forKey: Self.hotKeyPanelOriginYKey) != nil else { return nil }
        var frame = CGRect(
            x: defaults.double(forKey: Self.hotKeyPanelOriginXKey),
            y: defaults.double(forKey: Self.hotKeyPanelOriginYKey),
            width: size.width,
            height: size.height
        )
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        let padding: CGFloat = 28
        frame.origin.x = min(
            max(frame.minX, visible.minX + padding),
            max(visible.minX + padding, visible.maxX - frame.width - padding)
        )
        frame.origin.y = min(
            max(frame.minY, visible.minY + padding),
            max(visible.minY + padding, visible.maxY - frame.height - padding)
        )
        return frame
    }

    func performHotKeyAction(_ action: TextoraHotKeyAction) {
        resetResolvedSelectionState()
        viewModel.clear()
        allowFallbackProbeBriefly()

        if let app = textService.frontmostAppInfo(),
           app.bundleID != Bundle.main.bundleIdentifier {
            switch textService.appConsentStatus(for: app.bundleID) {
            case .allowed:
                break
            case .denied:
                hideForNoSelection()
                return
            case .unknown:
                pendingHotKeyAction = action
                pendingHotKeyConsentBundleID = app.bundleID
                onConsentRequired?(mouseAnchor(), app.bundleID)
                return
            }
        }

        if let signal = textService.selectedTextSignalAnyFocus(),
           textService.appConsentStatus(for: signal.targetBundleID) == .unknown {
            hideForConsentRequired(signal: signal, anchor: preferredAnchor(for: signal))
            return
        }
        guard let context = readSelectedTextContextForToolbar() else {
            hideForNoSelection()
            return
        }
        let key = selectionKey(for: context)
        let anchor = preferredAnchor(for: context)
        pendingSelectionKey = key
        rememberAnchor(anchor, for: key)
        viewModel.prepareHotKeyPresentation(action)
        switch action {
        case .rewrite:
            viewModel.setSelectionContext(context, preservePresentation: true)
        case .translate:
            viewModel.setSelectionContext(context, automaticallyCheck: false, preservePresentation: true)
            viewModel.translate()
        }
        showOrMovePanel(near: anchor)
    }

    private var currentPanelSize: CGSize {
        if viewModel.presentationMode != .standard {
            return CGSize(
                width: SelectionToolbarView.hotKeyPanelWidth,
                height: SelectionToolbarView.hotKeyPanelHeight(for: viewModel)
            )
        }
        let contentHeight: CGFloat
        if viewModel.isLanguagePickerExpanded {
            contentHeight = 170
        } else {
            contentHeight = viewModel.showsTranslationPanel ? 164 : 50
        }
        return CGSize(width: Self.panelWidth, height: contentHeight + Self.panelTopReserve)
    }

    private var currentPanelTopReserve: CGFloat {
        viewModel.presentationMode == .standard ? Self.panelTopReserve : 0
    }

    private var isMouseInsidePanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func panelFrame(near anchor: CGRect, size: CGSize, lockPlacement: Bool) -> CGRect {
        let gap: CGFloat = viewModel.hasRewritePreview || viewModel.hasTranslationContent ? 34 : 18
        let contentSize = CGSize(width: size.width, height: max(1, size.height - currentPanelTopReserve))
        let placementContentHeight = viewModel.presentationMode == .standard
            ? max(contentSize.height, Self.maxPanelContentHeight)
            : contentSize.height
        let contentX = anchor.midX - contentSize.width / 2
        var contentFrame = CGRect(
            x: contentX,
            y: anchor.maxY + gap,
            width: contentSize.width,
            height: contentSize.height
        )
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchor) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return CGRect(origin: contentFrame.origin, size: size)
        }
        let pad: CGFloat = viewModel.presentationMode == .standard ? 8 : 28
        let aboveFrame = CGRect(
            x: anchor.midX - contentSize.width / 2,
            y: anchor.maxY + gap,
            width: contentSize.width,
            height: contentSize.height
        )
        let belowFrame = CGRect(
            x: anchor.midX - contentSize.width / 2,
            y: anchor.minY - gap - size.height,
            width: contentSize.width,
            height: contentSize.height
        )
        let aboveFits = anchor.maxY + gap + placementContentHeight + currentPanelTopReserve <= visible.maxY - pad
            && aboveFrame.minY >= visible.minY + pad
        let belowFits = anchor.minY - gap - placementContentHeight >= visible.minY + pad
            && belowFrame.maxY <= visible.maxY - pad

        let side: PanelPlacementSide
        if lockPlacement,
           let lockedPanelPlacementSide,
           (lockedPanelPlacementSide == .above ? aboveFits : belowFits) {
            side = lockedPanelPlacementSide
        } else if aboveFits {
            side = .above
        } else if belowFits {
            side = .below
        } else {
            let spaceAbove = visible.maxY - anchor.maxY - gap - currentPanelTopReserve
            let spaceBelow = anchor.minY - visible.minY - gap
            side = spaceAbove >= spaceBelow ? .above : .below
        }
        if lockPlacement {
            lockedPanelPlacementSide = side
        }
        contentFrame = side == .above ? aboveFrame : belowFrame
        contentFrame.origin.x = min(max(contentFrame.origin.x, visible.minX + pad), visible.maxX - contentFrame.width - pad)
        if side == .above {
            contentFrame.origin.y = min(contentFrame.origin.y, visible.maxY - contentFrame.height - currentPanelTopReserve - pad)
            contentFrame.origin.y = max(contentFrame.origin.y, anchor.maxY + gap)
        } else {
            contentFrame.origin.y = max(contentFrame.origin.y, visible.minY + pad)
            contentFrame.origin.y = min(contentFrame.origin.y, anchor.minY - gap - size.height)
        }
        return CGRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: size.width,
            height: size.height
        )
    }

    private func preferredAnchor(for signal: TextAccessService.SelectedTextSignal) -> CGRect {
        if shouldPreferMouseAnchor(bundleID: signal.targetBundleID, candidate: signal.bounds) {
            return fallbackInteractionAnchor()
        }
        if let bounds = signal.bounds, isUsableAnchor(bounds) {
            return bounds
        }
        return fallbackInteractionAnchor()
    }

    private func preferredAnchor(for context: TextAccessService.FocusedTextContext) -> CGRect {
        let anchor = context.anchor.rect
        if shouldPreferMouseAnchor(bundleID: context.targetBundleID, candidate: anchor) {
            return fallbackInteractionAnchor()
        }
        if isUsableAnchor(anchor), context.anchor.confidence != .weak {
            return anchor
        }
        if isUsableAnchor(context.frame) {
            return context.frame
        }
        return fallbackInteractionAnchor()
    }

    private func shouldPreferMouseAnchor(bundleID: String, candidate: CGRect?) -> Bool {
        guard usesWeakSelectionGeometry(bundleID: bundleID) else { return false }
        guard let candidate, isUsableAnchor(candidate) else { return true }
        if candidate.height > 90 || candidate.width > 1_800 {
            if !isMouseSelectionDragActive, candidate.height <= 320, candidate.width <= 1_600 {
                return false
            }
            return true
        }
        return false
    }

    private func usesWeakSelectionGeometry(bundleID: String) -> Bool {
        bundleID == "com.tinyspeck.slackmacgap"
            || bundleID == "com.google.Chrome"
            || bundleID == "com.google.Chrome.beta"
            || bundleID == "com.google.Chrome.canary"
            || bundleID == "com.apple.Safari"
            || bundleID == "com.microsoft.edgemac"
            || bundleID == "com.brave.Browser"
            || bundleID == "company.thebrowser.Browser"
            || bundleID.lowercased().contains("firefox")
            || bundleID.lowercased().contains("opera")
            || bundleID.lowercased().contains("arc")
    }

    private func isUsableAnchor(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isInfinite
            && rect.width > 0
            && rect.height > 0
            && rect.minX.isFinite
            && rect.minY.isFinite
    }

    private func mouseAnchor() -> CGRect {
        CGRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1)
    }

    private func fallbackInteractionAnchor() -> CGRect {
        if isMouseSelectionDragActive {
            return mouseAnchor()
        }
        if let lastSelectionGestureAnchor {
            return lastSelectionGestureAnchor
        }
        return mouseAnchor()
    }

    private func anchorForCurrentSelection(
        key: String,
        preferred: CGRect,
        allowStableAnchor: Bool
    ) -> CGRect {
        if stableSelectionKey != nil, stableSelectionKey != key {
            stableSelectionKey = nil
            stableSelectionAnchor = nil
            lockedPanelPlacementSide = nil
        }
        if allowStableAnchor, stableSelectionKey == key, let stableSelectionAnchor {
            return stableSelectionAnchor
        }
        if isMouseSelectionDragActive {
            return preferred
        }
        if let locked = anchoredSelectionRect(for: key) {
            stableSelectionKey = key
            stableSelectionAnchor = locked
            return locked
        }
        stableSelectionKey = key
        stableSelectionAnchor = preferred
        return preferred
    }

    private func anchoredSelectionRect(for key: String) -> CGRect? {
        lockedAnchorKey == key ? lockedAnchor : nil
    }

    private func rememberAnchor(_ anchor: CGRect, for key: String) {
        guard !isMouseSelectionDragActive else { return }
        lockedAnchorKey = key
        lockedAnchor = anchor
    }

    private func selectionKey(for signal: TextAccessService.SelectedTextSignal) -> String {
        let range: String
        if usesWeakSelectionGeometry(bundleID: signal.targetBundleID) {
            range = "weak-selection-signal-\(selectionGestureID)"
        } else {
            range = signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        }
        return [
            signal.targetBundleID,
            String(signal.targetAppPID),
            range
        ].joined(separator: "|")
    }

    private func selectionKey(for context: TextAccessService.FocusedTextContext) -> String {
        let range: String
        if context.usesSelection,
           (usesWeakSelectionGeometry(bundleID: context.targetBundleID)
            || context.anchor.source == .clipboardFallback) {
            range = "text-selection"
        } else {
            range = context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        }
        return [
            context.targetBundleID,
            String(context.targetAppPID),
            range,
            normalizedSelectionText(context.text)
        ].joined(separator: "|")
    }

    private func weakSelectionRangeSignature(for signal: TextAccessService.SelectedTextSignal) -> String? {
        guard usesWeakSelectionGeometry(bundleID: signal.targetBundleID) else { return nil }
        return signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
    }

    private func normalizedSelectionText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func consentKey(for signal: TextAccessService.SelectedTextSignal) -> String {
        let range = signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        return [
            signal.targetBundleID,
            String(signal.targetAppPID),
            range
        ].joined(separator: "|")
    }

    private func trace(
        _ event: String,
        signal: TextAccessService.SelectedTextSignal? = nil,
        context: TextAccessService.FocusedTextContext? = nil,
        key: String? = nil,
        extra: String = ""
    ) {}
}
