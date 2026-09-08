import AppKit
import SwiftUI

private final class MarkerHitPanel: NSPanel {
    var onMarkerHoverChanged: ((Bool) -> Void)?
    var onMarkerHoverMoved: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override var canBecomeKey: Bool { false }

    override var contentView: NSView? {
        didSet { setupTrackingArea() }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        acceptsMouseMovedEvents = true
        setupTrackingArea()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        guard let contentView else { return }
        if let trackingArea {
            contentView.removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovered else { return }
        isHovered = true
        onMarkerHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        onMarkerHoverMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        isHovered = false
        onMarkerHoverChanged?(false)
    }
}

@MainActor
final class FloatingHelperController {
    enum MarkerAnchor: String {
        case caret
        case field
    }

    enum SuggestionState {
        case neutral
        case needsAttention
        case looksGood
    }

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private let spellChecker = NSSpellChecker.shared
    private var panel: DraggableFloatingPanel?
    private var issueOverlayPanel: NSPanel?
    private var extraIssueOverlayPanels: [NSPanel] = []
    private var markerPanel: NSPanel?
    private var extraMarkerPanels: [NSPanel] = []
    private var hoverCardPanel: NSPanel?
    private var timer: Timer?
    private var isRunning = false
    private var workspaceActivationObserver: NSObjectProtocol?
    private let onRewriteTap: (CGRect) -> Void
    private let onFloatingHoverChanged: (Bool, CGRect) -> Void
    private var lastFrame: CGRect = .zero
    var onStatusChange: ((String) -> Void)?
    private var isDragging = false
    private var isFloatingHovered = false
    private var dragBoundaryWindowFrame: CGRect?
    private var dragSessionStartFrame: CGRect?
    private var lastDragMoveFrame: CGRect?
    private var dragHintDirections: [FloatingDragHintDirection] = []
    private var activeDragHintDirection: FloatingDragHintDirection?
    private var dragHintEmphasis: [FloatingDragHintDirection: CGFloat] = [:]
    private var dragHintPanels: [FloatingDragHintDirection: NSPanel] = [:]
    private var dragHintHideTask: DispatchWorkItem?
    private var manualOffset: CGPoint = CGPoint(x: 8, y: -42)
    private var lastSignature: String?
    private var lastActivityAt = Date()
    private let idleDelay: TimeInterval = 1.0
    private let sentenceDelay: TimeInterval = 1.0
    private var suppressAutoEvaluationUntil: Date?
    /// Debounces AI auto-check by focused **text** (caret moves change `focusedTextSignature` but not this segment).
    private var lastCheckedValueSegment: String?
    /// Guards the AI path by the actual context text. Some Chrome surfaces
    /// can expose the same composer through changing AX focus signatures,
    /// which otherwise replays identical requests indefinitely.
    private var lastAutoEvaluationSnapshotKey: String?
    private var lastAutoEvaluationSnapshotNormalizedText: String?
    private var lastAutoEvaluationSnapshotAt: Date?
    private let autoEvaluationSnapshotTTL: TimeInterval = 30
    private var postApplyAcceptedValueSegment: String?
    /// Avoid `orderFrontRegardless` on every 200ms tick; set true when panel is hidden or z-order policy changes.
    private var floatingPanelNeedsZOrderPass = true
    private var lastLayoutStatusPostedAt: Date?
    private var isEvaluating = false
    var isCurrentlyEvaluating: Bool { isEvaluating }
    var onEvaluationCompleted: (() -> Void)?
    var onEvaluationStarted: (() -> Void)?
    var onFocusedTextContentChanged: ((TextAccessService.FocusedTextContext?) -> Void)?
    private var suggestionState: SuggestionState = .neutral
    private var latestSuggestion: String = ""
    private var latestSuggestionOptions: [OverlaySuggestion] = []
    private var latestContext: TextAccessService.FocusedTextContext?
    private var latestSignature: String?
    private var latestIssueRange: NSRange?
    /// All localized issues the AI "auditor" reported for the active
    /// segment. Empty on the legacy `overlaySuggestions` path; non-empty
    /// when the per-span rendering is active. Each issue yields one
    /// underline panel + one hover-card entry.
    private var latestIssues: [OverlayIssue] = []
    /// When the user hovers a specific underline, remember which issue
    /// the hover card is showing. `nil` for the floating-icon hover
    /// (shows the primary issue).
    private var hoveredIssueID: UUID?
    private var hoveredIssueIDs: Set<UUID> = []
    /// Maps each rendered underline panel back to the issue it
    /// represents. Used by the per-issue hover hit-test (mouseEntered
    /// → look up panel index → look up issue ID → show that issue's
    /// hover card). Built on every `updateMarker` pass.
    private struct IssuePanelLayout {
        let panelIndex: Int
        let frame: CGRect
        let issueID: UUID?
        let issueIDs: [UUID]
        let style: FloatingIssueMarkerStyle
        let isLoading: Bool
    }
    private var issuePanelLayouts: [IssuePanelLayout] = []
    /// Signatures of issues the user explicitly dismissed via "Skip"
    /// on the hover card. Keyed by segment signature + category + span
    /// + replacement so a skip is tied to the exact phrasing of the
    /// current sentence — editing the sentence invalidates the skip
    /// automatically.
    private var skippedIssueSignatures: Set<String> = []
    /// Recent successful rewrites used as a loop guard. If the next
    /// auto-check suggests reverting a fresh fix back to its previous
    /// wording, we suppress that suggestion instead of bouncing the
    /// user between the same two variants.
    private struct RecentAppliedRewrite {
        let fromKey: String
        let toKey: String
        let recordedAt: Date
    }
    private var recentAppliedRewrites: [RecentAppliedRewrite] = []
    private let recentAppliedRewriteTTL: TimeInterval = 180
    private let recentAppliedRewriteCap = 24
    private var localBatchMutationGraceUntil: Date?
    private var pendingHoverCardIssueIDsAfterApply: [UUID] = []
    private var lastMarkerFieldFrame: CGRect?
    private var lastMarkerCaretFrame: CGRect?
    private var lastMarkerDebugSignature: String?
    private var recentOverlayLayoutDebugSignatures: [String] = []
    private var recentMarkerPipelineDebugSignatures: [String] = []
    private var markerAnchor: MarkerAnchor = .field
    private var isMarkerHovered = false
    private var isHoverCardHovered = false
    private var hoverHideTask: DispatchWorkItem?
    /// 34pt × 1.5 — easier to see and drag.
    private static let floatingPanelSide: CGFloat = 51
    private var visibilityDropTask: DispatchWorkItem?
    private let visibilityDropDelay: TimeInterval = 0.45
    private var detailedCorrectionsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.detailedCorrectionsEnabled)
    }
    private var smartAIEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.smartAIEnabled)
    }
    private var lastObservedDetailedCorrectionsEnabled = UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.detailedCorrectionsEnabled)
    private var lastObservedSmartAIEnabled = UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.smartAIEnabled)
    private static let lastOperationKey = "inlineRewrite.lastOperation"

    private struct CorrectionScope {
        let text: String
        let range: NSRange
    }

    private struct SegmentEvaluationResult {
        enum State { case clean, needsAttention, inconclusive }
        var suggestion: String
        var suggestionOptions: [OverlaySuggestion]
        var issueLocalRange: NSRange?
        var state: State
        /// Structured list of localized issues inside the segment —
        /// populated by `AIClient.auditIssues`. When empty the UI falls
        /// back to the legacy single-marker path driven by
        /// `issueLocalRange` + `suggestion`.
        var issues: [OverlayIssue] = []
    }

    /// Caches per-segment auto-check results so we don't re-run the AI over
    /// unchanged paragraphs (prevents "infinite suggestion loops" when a
    /// multi-segment message has one issue and the others are clean).
    /// Key: `normalized(segment.text)` — same text ⇒ same result.
    private var segmentEvaluationCache: [String: SegmentEvaluationResult] = [:]
    private var segmentEvaluationCacheOrder: [String] = []
    private let segmentEvaluationCacheCap = 64

    private enum AnchorMode: String {
        case focusedEditable
        case selection
    }
    private var anchorMode: AnchorMode = .focusedEditable
    private var selectionSignature: String?
    private var selectionSignatureSince: Date?
    private var lastFocusSurfaceSignature: String?
    private let selectionAppearDelay: TimeInterval = 0.22
    private weak var keepBelowWindow: NSWindow?
    private var isManuallyPlacedForCurrentFocus = false
    private var manualFixedFrame: CGRect?
    private let autoGap: CGFloat = 10
    /// ~3cm in points (72pt per inch). 3cm ≈ 1.18in ≈ 85pt.
    private let caretOffsetDistance: CGFloat = 85
    private let caretAvoidancePadding: CGFloat = 14
    private var ourBundleID: String { Bundle.main.bundleIdentifier ?? "" }
    private var consentBootstrapFrame: CGRect?
    private var consentBootstrapBundleID: String?
    init(
        onRewriteTap: @escaping (CGRect) -> Void,
        onFloatingHoverChanged: @escaping (Bool, CGRect) -> Void
    ) {
        self.onRewriteTap = onRewriteTap
        self.onFloatingHoverChanged = onFloatingHoverChanged
    }

    deinit {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        timer?.invalidate()
    }

    /// Pop-up should anchor to the floating bubble, not the text field / window.
    private func floatingBubbleFrameForRewritePopup() -> CGRect {
        panel?.frame ?? lastFrame
    }

    var currentFrame: CGRect {
        floatingBubbleFrameForRewritePopup()
    }

    /// `focusedTextSignature()` is `range|valueText`.
    private func valueSegment(ofFocusedSignature full: String) -> String {
        guard let idx = full.firstIndex(of: "|") else { return full }
        return String(full[full.index(after: idx)...])
    }

    private func postStatus(_ message: String) {
        let now = Date()
        if message.hasPrefix("Showing helper at") {
            if let t = lastLayoutStatusPostedAt, now.timeIntervalSince(t) < 1.2 {
                return
            }
            lastLayoutStatusPostedAt = now
        }
        onStatusChange?(message)
    }

    private func postOverlayLayoutDebug(
        stage: String,
        hasEditableFocus: Bool,
        appConsent: TextAccessService.AppConsentStatus,
        fieldFrame: CGRect?,
        windowFrame: CGRect?,
        caretFrame: CGRect?,
        bubbleFrame: CGRect?,
        valueLength: Int? = nil,
        fallback: String? = nil,
        note: String? = nil
    ) {
        let front = textService.frontmostAppInfo()
        let message = "stage=\(stage) "
            + "front=\(front?.bundleID ?? "nil")(\(front?.displayName ?? "nil")) "
            + "consent=\(appConsent.rawValue) hasEditable=\(hasEditableFocus) "
            + "anchorMode=\(anchorMode.rawValue) manual=\(isManuallyPlacedForCurrentFocus) "
            + "field=\(textoraDiagRect(fieldFrame)) window=\(textoraDiagRect(windowFrame)) "
            + "caret=\(textoraDiagRect(caretFrame)) bubble=\(textoraDiagRect(bubbleFrame)) "
            + "windowScreen={\(textoraDiagScreen(windowFrame))} bubbleScreen={\(textoraDiagScreen(bubbleFrame))} "
            + "fallback=\(fallback ?? "nil") "
            + "valueLen=\(valueLength.map(String.init) ?? "nil") "
            + "note=\(note ?? "nil")"
        guard shouldPostControllerDiagnostic(message, history: &recentOverlayLayoutDebugSignatures) else { return }
        textoraDiagLog("overlayLayout", message)
    }

    private func postMarkerPipelineDebug(
        stage: String,
        context: TextAccessService.FocusedTextContext,
        issueRange: NSRange?,
        fallback: CGRect,
        axFrames: [CGRect],
        selectedSource: String,
        selectedFrames: [CGRect],
        normalizedFrames: [CGRect]
    ) {
        let message = "stage=\(stage) bundle=\(context.targetBundleID) "
            + "textLen=\((context.text as NSString).length) range=\(textoraDiagNSRange(issueRange)) "
            + "geometry=\(diagnosticGeometryKind(for: context, selectedSource: selectedSource)) "
            + "anchor=\(context.anchor.debugSummary) contextFrame=\(textoraDiagRect(context.frame)) "
            + "fallback=\(textoraDiagRect(fallback)) ax=\(textoraDiagRects(axFrames)) "
            + "source=\(selectedSource) raw=\(textoraDiagRects(selectedFrames)) "
            + "normalized=\(textoraDiagRects(normalizedFrames))"
        guard shouldPostControllerDiagnostic(message, history: &recentMarkerPipelineDebugSignatures, cap: 192) else { return }
        textoraDiagLog("markerPipeline", message)
    }

    private func shouldPostControllerDiagnostic(_ message: String, history: inout [String], cap: Int = 96) -> Bool {
        if history.contains(message) {
            return false
        }
        history.append(message)
        if history.count > cap {
            history.removeFirst(history.count - cap)
        }
        return true
    }

    private func diagnosticGeometryKind(
        for context: TextAccessService.FocusedTextContext,
        selectedSource: String
    ) -> String {
        if selectedSource == "axPrecise" {
            return "ax"
        }
        if isSlackBundle(context.targetBundleID) {
            return "estimated"
        }
        if selectedSource == "hostEstimated" || selectedSource == "hostFallbackFrame" {
            return "estimated"
        }
        return "fallback"
    }

    private func noteFloatingPanelHidden() {
        floatingPanelNeedsZOrderPass = true
    }

    /// When a pop-up is visible, keep the floating bubble below it to avoid z-order fighting.
    func setKeepBelowWindow(_ window: NSWindow?) {
        let hadBelow = keepBelowWindow != nil
        keepBelowWindow = window
        guard let panel else { return }
        if let window {
            let wn = window.windowNumber
            guard wn != 0 else { return }
            if panel.isVisible {
                panel.order(.below, relativeTo: wn)
            }
        } else if hadBelow {
            floatingPanelNeedsZOrderPass = true
        }
    }

    func start() {
        isRunning = true
        if panel == nil {
            createPanel()
        }
        if markerPanel == nil {
            createMarkerPanel()
        }
        if issueOverlayPanel == nil {
            createIssueOverlayPanel()
        }
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateVisibilityAndPosition()
            }
        }
        // `.common` includes default + event-tracking so one tick isn’t deferred for whole seconds during
        // nested tracking (e.g. dragging the bubble) the way a default-only timer can be.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        installWorkspaceActivationObserverIfNeeded()
        updateVisibilityAndPosition()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        hideFloatingHelperImmediately()
        hideMarkerAndCard()
        hideDragHintPanels()
        suggestionState = .neutral
        latestSuggestion = ""
        latestSuggestionOptions = []
        latestContext = nil
        latestSignature = nil
        latestIssues = []
        isEvaluating = false
        setKeepBelowWindow(nil)
    }

    private func installWorkspaceActivationObserverIfNeeded() {
        guard workspaceActivationObserver == nil else { return }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleWorkspaceDidActivate(notification)
            }
        }
    }

    private func handleWorkspaceDidActivate(_ notification: Notification) {
        guard isRunning else {
            hideFloatingHelperImmediately()
            return
        }
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleID = app?.bundleIdentifier ?? ""
        guard bundleID != ourBundleID else { return }

        textService.invalidateTransientFocusCaches()
        lastSignature = nil
        lastCheckedValueSegment = nil
        clearRecentAutoEvaluationSnapshot()
        postApplyAcceptedValueSegment = nil
        latestSignature = nil
        selectionSignature = nil
        selectionSignatureSince = nil
        lastFocusSurfaceSignature = nil
        hoveredIssueID = nil
        hoveredIssueIDs = []
        lastActivityAt = Date()
        cancelScheduledVisibilityDrop()
        hideFloatingHelperImmediately()
        resetSuggestionStateAfterAppSwitch()
        postStatus("App activated; refreshing focused text")

        updateVisibilityAndPosition()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.isRunning, !self.isEvaluating, !self.isDragging else { return }
            self.evaluateCurrentText()
        }
    }

    private func createPanel() {
        let content = NSHostingView(
            rootView: FloatingButtonView(
                ringColors: ringColors(for: suggestionState),
                isLoading: isEvaluating,
                isHovered: isFloatingHovered,
                showsCheckmark: shouldShowLooksGoodBadge,
                showsSmartAIBadge: smartAIEnabled
            )
        )
        let panel = DraggableFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.floatingPanelSide, height: Self.floatingPanelSide),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 1
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.allowsDragging = true
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.isOpaque = false
        content.layer?.cornerRadius = Self.floatingPanelSide / 2
        content.layer?.masksToBounds = true
        panel.contentView = content
        panel.orderOut(nil)

        panel.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.isFloatingHovered = hovering
            self.panel?.alphaValue = 1.0
            self.updateRingColor()
            self.onFloatingHoverChanged(hovering, self.floatingBubbleFrameForRewritePopup())
        }
        panel.onClicked = { [weak self] in
            guard let self else { return }
            self.onRewriteTap(self.floatingBubbleFrameForRewritePopup())
        }
        panel.onLeftMouseSessionBegan = { [weak self] in
            guard let self else { return }
            self.cancelScheduledDragHintHide()
            self.dragSessionStartFrame = self.panel?.frame ?? self.lastFrame
            self.lastDragMoveFrame = self.dragSessionStartFrame
            self.dragBoundaryWindowFrame = self.textService.floatingHelperAnchorWindowFrame()
                ?? self.lastMarkerFieldFrame
                ?? self.lastFrame
            self.dragHintDirections = self.dragHintDirectionsForCurrentBubbleFrame()
            self.activeDragHintDirection = nil
            self.dragHintEmphasis = [:]
            self.updateRingColor()
            self.updateDragHintPanels()
        }
        panel.onDragBegan = { [weak self] in
            guard let self else { return }
            self.isDragging = true
            self.dragBoundaryWindowFrame = self.textService.floatingHelperAnchorWindowFrame()
                ?? self.lastMarkerFieldFrame
                ?? self.lastFrame
        }
        panel.onLeftMouseSessionEnded = { [weak self] in
            guard let self else { return }
            self.dragBoundaryWindowFrame = nil
            self.dragSessionStartFrame = nil
            self.lastDragMoveFrame = nil
            self.dragHintDirections = []
            self.activeDragHintDirection = nil
            self.dragHintEmphasis = [:]
            self.updateRingColor()
            self.scheduleDragHintHide()
        }
        panel.constrainDragFrame = { [weak self] rawFrame in
            guard let self else { return rawFrame }
            return self.pinnedBubbleFrame(fallback: rawFrame)
        }
        panel.onDragMoved = { [weak self] newFrame in
            guard let self else { return }
            let pinned = self.pinnedBubbleFrame(fallback: newFrame)
            self.manualFixedFrame = pinned
            self.dragHintDirections = self.dragHintDirections(
                for: pinned,
                in: self.dragBoundaryWindowFrame ?? self.lastMarkerFieldFrame ?? self.lastFrame
            )
            let movementDirection = self.activeDragDirection(
                for: pinned,
                previousFrame: self.lastDragMoveFrame ?? self.dragSessionStartFrame
            )
            self.activeDragHintDirection = movementDirection
            self.updateDragHintEmphasis(activeDirection: movementDirection)
            self.lastDragMoveFrame = pinned
            self.applyMainBubbleFrameIfChanged(pinned)
            self.updateRingColor()
            self.updateDragHintPanels(anchorFrame: pinned)
        }
        panel.onDragEnded = { [weak self] finalFrame in
            guard let self else { return }
            self.isManuallyPlacedForCurrentFocus = true
            self.isDragging = false
            let pinned = self.pinnedBubbleFrame(fallback: finalFrame)
            self.manualFixedFrame = pinned
            self.consentBootstrapFrame = pinned
            self.applyMainBubbleFrameIfChanged(pinned)
            self.dragBoundaryWindowFrame = nil
            self.lastDragMoveFrame = nil
            self.dragHintEmphasis = [:]
            self.hideDragHintPanels()
            self.postStatus("Helper is pinned")
        }

        self.panel = panel
    }

    private func updateVisibilityAndPosition() {
        guard isRunning else {
            hideFloatingHelperImmediately()
            return
        }
        syncRuntimeSettingsIfNeeded()
        guard textService.hasAccessibilityPermission() else {
            postStatus("No accessibility permission")
            cancelScheduledVisibilityDrop()
            panel?.orderOut(nil)
            noteFloatingPanelHidden()
            hideDragHintPanels()
            hideMarkerAndCard()
            return
        }
        if textService.isFrontmostAppSuppressedForHelper() {
            postStatus("Suppressed in current app")
            cancelScheduledVisibilityDrop()
            panel?.orderOut(nil)
            noteFloatingPanelHidden()
            hideDragHintPanels()
            hideMarkerAndCard()
            return
        }
        if isFrontmostOurOwnApp() {
            postStatus("Suppressed in Textora UI")
            hideFloatingHelperImmediately()
            return
        }
        // While the panel runs its modal `nextEvent` loop, skip layout/AX (z-order is fixed once in
        // `onDragBegan` — avoid `orderFrontRegardless` every 200ms fighting `setFrame`).
        if panel?.isPointerTrackingInPanel == true {
            return
        }

        textService.withCoalescedFocusQueries {
            if self.textService.isCurrentFocusOwnedBy(bundleID: self.ourBundleID) {
                self.postStatus("Suppressed in Textora UI")
                self.hideFloatingHelperImmediately()
                return
            }
            self.resetOverlayStateIfFocusSurfaceChanged()
            if self.textService.isCurrentFocusInTransientPopupOrMenu() {
                self.postStatus("Ignoring transient popup/menu focus")
                if self.panel?.isVisible == true {
                    self.bringToFrontOrBelowIfNeeded()
                } else {
                    self.hideFloatingHelperImmediately()
                }
                return
            }
            if self.textService.selectedTextSignalAnyFocus()?.hasSelection == true {
                self.applyFloatingHelperLayoutForCurrentFocus()
                return
            }
            if self.textService.shouldHardIgnoreCurrentFocusedInput() {
                self.postStatus("Ignored focused field/app")
                self.cancelScheduledVisibilityDrop()
                self.panel?.orderOut(nil)
                self.noteFloatingPanelHidden()
                self.hideDragHintPanels()
                self.hideMarkerAndCard()
                return
            }
            self.applyFloatingHelperLayoutForCurrentFocus()
        }
    }

    private func syncRuntimeSettingsIfNeeded() {
        let detailed = detailedCorrectionsEnabled
        let smart = smartAIEnabled
        guard detailed != lastObservedDetailedCorrectionsEnabled
                || smart != lastObservedSmartAIEnabled else {
            return
        }
        lastObservedDetailedCorrectionsEnabled = detailed
        lastObservedSmartAIEnabled = smart
        segmentEvaluationCache.removeAll()
        segmentEvaluationCacheOrder.removeAll()
        latestSignature = nil
        latestSuggestion = ""
        latestSuggestionOptions = []
        latestIssueRange = nil
        latestIssues = []
        hoveredIssueID = nil
        hoveredIssueIDs = []
        lastCheckedValueSegment = nil
        clearRecentAutoEvaluationSnapshot()
        postApplyAcceptedValueSegment = nil
        suggestionState = .neutral
        hideMarkerAndCard()
        updateRingColor()
        onFocusedTextContentChanged?(currentFocusedContextForPopup())
        postStatus("Settings changed; refreshing suggestions")
    }

    /// One timer tick worth of AX reads (coalesced in `TextAccessService`) and bubble/marker layout.
    private func applyFloatingHelperLayoutForCurrentFocus() {
        let hasEditableFocus = textService.hasFocusedEditableElement()
        let fieldFrame = hasEditableFocus ? textService.focusedEditableFrame() : nil
        let fallbackAnchorFrame = textService.focusedWindowFrame()
        let appConsent = textService.currentAppConsentStatus()
        postOverlayLayoutDebug(
            stage: "tick",
            hasEditableFocus: hasEditableFocus,
            appConsent: appConsent,
            fieldFrame: fieldFrame,
            windowFrame: fallbackAnchorFrame,
            caretFrame: nil,
            bubbleFrame: panel?.frame,
            fallback: "initial-read",
            note: "initial"
        )

        if !hasEditableFocus {
            // Selection mode: show helper near selected text when there's a non-empty selection
            // outside of an editable input (keeps current behaviour intact).
            guard let signal = textService.selectedTextSignalAnyFocus(), signal.hasSelection else {
                resetSuggestionStateForEmptyInput()
                selectionSignature = nil
                selectionSignatureSince = nil
                // Any host (Electron, WebView, future apps) may omit standard editable AX; if the user
                // did not deny this app, still show the bubble near the focused window or mouse so they
                // can grant consent or open the rewrite flow.
                if appConsent != .denied,
                   !isFrontmostOurOwnApp(),
                   showConsentBootstrap(windowFrame: fallbackAnchorFrame, allowMouseFallback: panel?.isVisible != true) {
                    postOverlayLayoutDebug(
                        stage: "noEditable.bootstrap",
                        hasEditableFocus: hasEditableFocus,
                        appConsent: appConsent,
                        fieldFrame: nil,
                        windowFrame: fallbackAnchorFrame,
                        caretFrame: nil,
                        bubbleFrame: panel?.frame,
                        fallback: fallbackAnchorFrame == nil ? "mouse" : "focusedWindow",
                        note: "no AX field/selection"
                    )
                    postStatus("Showing helper (no AX field/selection; window or mouse anchor)")
                    return
                }
                postOverlayLayoutDebug(
                    stage: "noEditable.hidden",
                    hasEditableFocus: hasEditableFocus,
                    appConsent: appConsent,
                    fieldFrame: nil,
                    windowFrame: fallbackAnchorFrame,
                    caretFrame: nil,
                    bubbleFrame: nil,
                    fallback: "none",
                    note: "no focused editable field and no selection"
                )
                postStatus("No focused editable field and no selection")
                scheduleVisibilityDrop()
                return
            }
            let boundsPart: String = {
                guard let b = signal.bounds else { return "no-bounds" }
                // Rounded signature to avoid jitter due to sub-pixel rect changes.
                return "\(Int(b.minX)):\(Int(b.minY)):\(Int(b.width)):\(Int(b.height))"
            }()
            let rangePart: String = {
                guard let r = signal.selectedRange else { return "no-range" }
                return "\(r.location):\(r.length)"
            }()
            let sig = "\(signal.targetBundleID)|\(rangePart)|\(boundsPart)"
            if sig != selectionSignature {
                selectionSignature = sig
                selectionSignatureSince = Date()
                scheduleVisibilityDrop()
                postStatus("Selection changed; waiting to stabilize")
                return
            }
            if let since = selectionSignatureSince,
               Date().timeIntervalSince(since) < selectionAppearDelay {
                scheduleVisibilityDrop()
                return
            }
            if anchorMode != .selection {
                anchorMode = .selection
                clearConsentBootstrapAnchor()
                suggestionState = .neutral
                latestSuggestion = ""
                latestSuggestionOptions = []
                latestContext = nil
                latestSignature = nil
                latestIssueRange = nil
                latestIssues = []
                hoveredIssueID = nil
                hoveredIssueIDs = []
                lastCheckedValueSegment = nil
                lastSignature = nil
                updateRingColor()
                hideMarkerAndCard()
            }
            if isDragging {
                bringToFrontOrBelowIfNeeded()
                return
            }
            let nextFrame: CGRect = {
                let anchorRect = textService.focusedWindowFrame() ?? signal.bounds ?? lastFrame
                if isManuallyPlacedForCurrentFocus, let manualFixedFrame {
                    return pinnedBubbleFrame(fallback: manualFixedFrame)
                }
                return clampedToVisibleScreens(
                    CGRect(
                        x: anchorRect.maxX - Self.floatingPanelSide - autoGap,
                        y: anchorRect.minY + autoGap,
                        width: Self.floatingPanelSide,
                        height: Self.floatingPanelSide
                    )
                )
            }()
            applyMainBubbleFrameIfChanged(nextFrame)
            cancelScheduledVisibilityDrop()
            postOverlayLayoutDebug(
                stage: "selection",
                hasEditableFocus: hasEditableFocus,
                appConsent: appConsent,
                fieldFrame: signal.bounds,
                windowFrame: fallbackAnchorFrame,
                caretFrame: nil,
                bubbleFrame: nextFrame,
                valueLength: signal.selectedRange?.length,
                fallback: isManuallyPlacedForCurrentFocus ? "manualFixedFrame" : (fallbackAnchorFrame == nil ? "selectionBounds" : "focusedWindow"),
                note: "selection bounds=\(textoraDiagRect(signal.bounds))"
            )
            postStatus("Showing helper (selection) x:\(Int(nextFrame.minX)) y:\(Int(nextFrame.minY))")
            bringToFrontOrBelowIfNeeded()
            return
        }

        // Focused editable mode (original behaviour).
        guard let fieldFrameUnwrapped = fieldFrame ?? fallbackAnchorFrame else {
            if appConsent != .denied,
               !isFrontmostOurOwnApp(),
               showConsentBootstrap(windowFrame: nil, allowMouseFallback: panel?.isVisible != true) {
                postOverlayLayoutDebug(
                    stage: "editable.bootstrap",
                    hasEditableFocus: hasEditableFocus,
                    appConsent: appConsent,
                    fieldFrame: fieldFrame,
                    windowFrame: fallbackAnchorFrame,
                    caretFrame: nil,
                    bubbleFrame: panel?.frame,
                    fallback: "mouse",
                    note: "editable signal but no frame"
                )
                postStatus("Showing helper (editable signal but no frame; mouse anchor)")
                return
            }
            postOverlayLayoutDebug(
                stage: "editable.hidden",
                hasEditableFocus: hasEditableFocus,
                appConsent: appConsent,
                fieldFrame: fieldFrame,
                windowFrame: fallbackAnchorFrame,
                caretFrame: nil,
                bubbleFrame: nil,
                fallback: "none",
                note: "focused editable reported but frame and window are missing"
            )
            postStatus("Focused editable reported but frame and window are missing")
            scheduleVisibilityDrop()
            return
        }
        if fieldFrame == nil {
            postStatus("Focused editable frame missing; using window fallback")
        }
        if anchorMode != .focusedEditable {
            anchorMode = .focusedEditable
            clearConsentBootstrapAnchor()
            // Reset manual offset base to align with editable anchors.
            let baseAnchor = textService.focusedWindowFrame() ?? fieldFrameUnwrapped
            manualOffset = CGPoint(x: lastFrame.minX - baseAnchor.minX, y: lastFrame.minY - baseAnchor.maxY)
            isManuallyPlacedForCurrentFocus = false
            manualFixedFrame = nil
        }
        if isDragging {
            bringToFrontOrBelowIfNeeded()
            return
        }
        let signature = textService.focusedTextSignature() ?? ""
        if signature != lastSignature {
            let newValue = valueSegment(ofFocusedSignature: signature)
            let oldValue = lastSignature.map { valueSegment(ofFocusedSignature: $0) } ?? ""
            lastSignature = signature
            if newValue != oldValue {
                let preservingLocalBatch = !latestIssues.isEmpty
                    && (localBatchMutationGraceUntil.map { Date() <= $0 } ?? false)
                let suppressingPostApply = suppressAutoEvaluationUntil.map { Date() <= $0 } ?? false
                let acceptingPostApplyValue = suppressingPostApply
                    && postApplyAcceptedValueSegment == newValue
                lastActivityAt = Date()
                latestSignature = nil
                if acceptingPostApplyValue {
                    lastCheckedValueSegment = newValue
                    latestSignature = signature
                    latestIssueRange = nil
                    latestIssues = []
                    hoveredIssueID = nil
                    hoveredIssueIDs = []
                    latestSuggestion = ""
                    latestSuggestionOptions = []
                    latestContext = nil
                    suggestionState = .looksGood
                    updateRingColor()
                    postStatus("Post-apply text accepted; auto-check suppressed briefly")
                } else if !suppressingPostApply, wasRecentlyAutoEvaluatedValueSegment(newValue) {
                    lastCheckedValueSegment = newValue
                    latestSignature = signature
                    postStatus("Ignoring Chrome focus churn for already checked text")
                } else if preservingLocalBatch {
                    lastCheckedValueSegment = newValue
                    postStatus("Keeping local suggestion batch after apply")
                } else {
                    localBatchMutationGraceUntil = nil
                    lastCheckedValueSegment = nil
                    latestIssueRange = nil
                    latestIssues = []
                    hoveredIssueID = nil
                    hoveredIssueIDs = []
                    latestSuggestion = ""
                    latestSuggestionOptions = []
                    latestContext = nil
                    suggestionState = .neutral
                    // Value changed: loading / red / green must not stick for new text.
                    updateRingColor()
                }
                onFocusedTextContentChanged?(currentFocusedContextForPopup())
            }
        }

        let caretFrame = textService.focusedCaretFrame()
        let nextFrame: CGRect = {
            if isManuallyPlacedForCurrentFocus, let manualFixedFrame {
                return pinnedBubbleFrame(fallback: manualFixedFrame)
            }
            return computeAutoBubbleFrame(
                fieldFrame: fieldFrameUnwrapped,
                windowFrame: fallbackAnchorFrame,
                caretFrame: caretFrame
            )
        }()
        let valueSeg = valueSegment(ofFocusedSignature: signature)
        let valueRaw = valueSeg.trimmingCharacters(in: .whitespacesAndNewlines)
        if valueRaw.isEmpty {
            resetSuggestionStateForEmptyInput()
            // Mark empty value as already handled to prevent re-triggering evaluation every timer tick.
            lastCheckedValueSegment = valueSegment(ofFocusedSignature: signature)
            latestSignature = nil
        }
        let bubbleMoveThreshold: CGFloat = valueRaw.isEmpty ? 10 : 2
        applyMainBubbleFrameIfChanged(nextFrame, threshold: bubbleMoveThreshold)
        cancelScheduledVisibilityDrop()
        markerAnchor = caretFrame == nil ? .field : .caret
        updateMarker(caretFrame: caretFrame, fieldFrame: fieldFrameUnwrapped, anchor: markerAnchor)
        postOverlayLayoutDebug(
            stage: "editable",
            hasEditableFocus: hasEditableFocus,
            appConsent: appConsent,
            fieldFrame: fieldFrameUnwrapped,
            windowFrame: fallbackAnchorFrame,
            caretFrame: caretFrame,
            bubbleFrame: nextFrame,
            valueLength: (valueSeg as NSString).length,
            fallback: isManuallyPlacedForCurrentFocus
                ? "manualFixedFrame"
                : (fallbackAnchorFrame == nil ? "fieldFrame" : "focusedWindow"),
            note: "markerAnchor=\(markerAnchor.rawValue) valueEmpty=\(valueRaw.isEmpty)"
        )

        let elapsed = Date().timeIntervalSince(lastActivityAt)
        let sentenceEnd = hasSentenceEnding()
        if let until = suppressAutoEvaluationUntil,
           Date() <= until,
           postApplyAcceptedValueSegment == valueSeg {
            lastCheckedValueSegment = valueSeg
            latestSignature = signature
        } else {
            suppressAutoEvaluationUntil = nil
            postApplyAcceptedValueSegment = nil
        }
        if !valueRaw.isEmpty, wasRecentlyAutoEvaluatedValueSegment(valueSeg) {
            lastCheckedValueSegment = valueSeg
            latestSignature = signature
        }
        if !valueRaw.isEmpty,
           (elapsed >= idleDelay || (elapsed >= sentenceDelay && sentenceEnd)),
           lastCheckedValueSegment != valueSeg,
           !isEvaluating,
           !isDragging {
            lastCheckedValueSegment = valueSeg
            evaluateCurrentText()
        }
        postStatus(
            "Showing helper at x:\(Int(nextFrame.minX)) y:\(Int(nextFrame.minY)) marker-anchor=\(markerAnchor.rawValue)"
        )
        bringToFrontOrBelowIfNeeded()
    }

    private func computeAutoBubbleFrame(fieldFrame: CGRect, windowFrame: CGRect?, caretFrame: CGRect?) -> CGRect {
        let bubbleW = Self.floatingPanelSide
        let bubbleH = Self.floatingPanelSide
        _ = caretFrame
        let anchor = windowFrame ?? fieldFrame
        // Stable auto-mode: bottom-right corner of active window, falling back to field bounds.
        let target = CGRect(
            x: anchor.maxX - bubbleW - autoGap,
            y: anchor.minY + autoGap,
            width: bubbleW,
            height: bubbleH
        )
        return clampedToVisibleScreens(target)
    }

    private func pinnedBubbleFrame(fallback: CGRect) -> CGRect {
        let anchor = dragBoundaryWindowFrame
            ?? textService.floatingHelperAnchorWindowFrame()
            ?? lastMarkerFieldFrame
            ?? fallback
        guard !anchor.isEmpty, anchor.width > Self.floatingPanelSide, anchor.height > Self.floatingPanelSide else {
            return clampedToVisibleScreens(fallback)
        }

        let minX = anchor.minX
        let maxX = anchor.maxX - Self.floatingPanelSide
        let minY = anchor.minY
        let maxY = anchor.maxY - Self.floatingPanelSide
        let clampedX = min(max(fallback.minX, minX), maxX)
        let clampedY = min(max(fallback.minY, minY), maxY)
        let topEdge = CGRect(
            x: clampedX,
            y: maxY,
            width: Self.floatingPanelSide,
            height: Self.floatingPanelSide
        )
        let rightEdge = CGRect(
            x: maxX,
            y: clampedY,
            width: Self.floatingPanelSide,
            height: Self.floatingPanelSide
        )
        let bottomEdge = CGRect(
            x: clampedX,
            y: minY,
            width: Self.floatingPanelSide,
            height: Self.floatingPanelSide
        )
        let leftEdge = CGRect(
            x: minX,
            y: clampedY,
            width: Self.floatingPanelSide,
            height: Self.floatingPanelSide
        )
        let distanceToTop = abs(fallback.midY - topEdge.midY)
        let distanceToRight = abs(fallback.midX - rightEdge.midX)
        let distanceToBottom = abs(fallback.midY - bottomEdge.midY)
        let distanceToLeft = abs(fallback.midX - leftEdge.midX)
        let candidates = [
            (topEdge, distanceToTop),
            (rightEdge, distanceToRight),
            (bottomEdge, distanceToBottom),
            (leftEdge, distanceToLeft)
        ]
        let nearest = candidates.min { lhs, rhs in lhs.1 < rhs.1 }?.0 ?? rightEdge
        return clampedToVisibleScreens(nearest)
    }

    private func dragHintDirectionsForCurrentBubbleFrame() -> [FloatingDragHintDirection] {
        let frame = panel?.frame ?? lastFrame
        let anchor = dragBoundaryWindowFrame
            ?? textService.floatingHelperAnchorWindowFrame()
            ?? lastMarkerFieldFrame
            ?? frame
        return dragHintDirections(for: frame, in: anchor)
    }

    private func dragHintDirections(
        for frame: CGRect,
        in anchor: CGRect
    ) -> [FloatingDragHintDirection] {
        guard !anchor.isEmpty,
              anchor.width > Self.floatingPanelSide,
              anchor.height > Self.floatingPanelSide else {
            return [.left, .right]
        }
        let tolerance: CGFloat = 18
        let left = abs(frame.minX - anchor.minX) <= tolerance
        let right = abs(frame.maxX - anchor.maxX) <= tolerance
        let bottom = abs(frame.minY - anchor.minY) <= tolerance
        let top = abs(frame.maxY - anchor.maxY) <= tolerance

        if bottom && right { return [.up, .left] }
        if top && right { return [.left, .down] }
        if top && left { return [.right, .down] }
        if bottom && left { return [.up, .right] }
        if top || bottom { return [.left, .right] }
        if left || right { return [.up, .down] }

        return anchor.width >= anchor.height ? [.left, .right] : [.up, .down]
    }

    private func activeDragDirection(
        for frame: CGRect,
        previousFrame: CGRect?
    ) -> FloatingDragHintDirection? {
        let reference = previousFrame ?? dragSessionStartFrame
        guard let reference else { return nil }
        let dx = frame.midX - reference.midX
        let dy = frame.midY - reference.midY
        let threshold: CGFloat = previousFrame == nil ? 8 : 1.8
        let candidate: FloatingDragHintDirection?
        if abs(dx) >= abs(dy), abs(dx) >= threshold {
            candidate = dx > 0 ? .right : .left
        } else if abs(dy) >= threshold {
            candidate = dy > 0 ? .up : .down
        } else {
            candidate = nil
        }
        guard let candidate, dragHintDirections.contains(candidate) else { return nil }
        return candidate
    }

    private func updateDragHintEmphasis(activeDirection: FloatingDragHintDirection?) {
        var next: [FloatingDragHintDirection: CGFloat] = [:]
        for direction in dragHintDirections {
            let current = dragHintEmphasis[direction] ?? 0
            let target: CGFloat = direction == activeDirection ? 1 : 0
            next[direction] = current * 0.52 + target * 0.48
        }
        dragHintEmphasis = next
    }

    private func makeDragHintPanel(direction: FloatingDragHintDirection) -> NSPanel {
        let side: CGFloat = 46
        let host = NSHostingView(
            rootView: FloatingDragHintArrowView(
                direction: direction,
                emphasis: dragHintEmphasis[direction] ?? (activeDragHintDirection == direction ? 1 : 0)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.autoresizingMask = [.width, .height]
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.92
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = host
        panel.orderOut(nil)
        return panel
    }

    private func dragHintPanel(for direction: FloatingDragHintDirection) -> NSPanel {
        if let panel = dragHintPanels[direction] {
            return panel
        }
        let panel = makeDragHintPanel(direction: direction)
        dragHintPanels[direction] = panel
        return panel
    }

    private func updateDragHintPanels(anchorFrame: CGRect? = nil) {
        let bubbleFrame = anchorFrame ?? panel?.frame ?? lastFrame
        guard !bubbleFrame.isEmpty, !dragHintDirections.isEmpty else {
            hideDragHintPanels()
            return
        }
        for direction in FloatingDragHintDirection.allCases {
            let hintPanel = dragHintPanel(for: direction)
            if dragHintDirections.contains(direction) {
                if let host = hintPanel.contentView as? NSHostingView<FloatingDragHintArrowView> {
                    host.rootView = FloatingDragHintArrowView(
                        direction: direction,
                        emphasis: dragHintEmphasis[direction] ?? (activeDragHintDirection == direction ? 1 : 0)
                    )
                }
                hintPanel.setFrame(dragHintFrame(direction: direction, bubbleFrame: bubbleFrame), display: true)
                hintPanel.orderFrontRegardless()
            } else {
                hintPanel.orderOut(nil)
            }
        }
    }

    private func hideDragHintPanels() {
        cancelScheduledDragHintHide()
        dragHintPanels.values.forEach { $0.orderOut(nil) }
    }

    private func scheduleDragHintHide() {
        cancelScheduledDragHintHide()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dragHintPanels.values.forEach { $0.orderOut(nil) }
            self.dragHintHideTask = nil
        }
        dragHintHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func cancelScheduledDragHintHide() {
        dragHintHideTask?.cancel()
        dragHintHideTask = nil
    }

    private func dragHintFrame(
        direction: FloatingDragHintDirection,
        bubbleFrame: CGRect
    ) -> CGRect {
        let side: CGFloat = 46
        let gap: CGFloat = 7
        let origin: CGPoint
        switch direction {
        case .up:
            origin = CGPoint(x: bubbleFrame.midX - side / 2, y: bubbleFrame.maxY + gap)
        case .down:
            origin = CGPoint(x: bubbleFrame.midX - side / 2, y: bubbleFrame.minY - side - gap)
        case .left:
            origin = CGPoint(x: bubbleFrame.minX - side - gap, y: bubbleFrame.midY - side / 2)
        case .right:
            origin = CGPoint(x: bubbleFrame.maxX + gap, y: bubbleFrame.midY - side / 2)
        }
        return clampedToVisibleScreens(CGRect(x: origin.x, y: origin.y, width: side, height: side))
    }

    private func bringToFrontOrBelowIfNeeded() {
        guard let panel else { return }
        if let below = keepBelowWindow {
            let wn = below.windowNumber
            if wn != 0 {
                panel.order(.below, relativeTo: wn)
                return
            }
            // If the pop-up isn't numbered yet, avoid fighting for front.
            return
        }
        guard floatingPanelNeedsZOrderPass else { return }
        floatingPanelNeedsZOrderPass = false
        panel.orderFrontRegardless()
    }

    @discardableResult
    private func showConsentBootstrap(windowFrame: CGRect?, allowMouseFallback: Bool = true) -> Bool {
        let frontBundle = textService.frontmostAppInfo()?.bundleID
        if consentBootstrapBundleID != frontBundle {
            clearConsentBootstrapAnchor()
            consentBootstrapBundleID = frontBundle
        }
        let frame: CGRect? = {
            if isManuallyPlacedForCurrentFocus, let manualFixedFrame {
                let pinned = pinnedBubbleFrame(fallback: manualFixedFrame)
                consentBootstrapFrame = pinned
                return pinned
            }
            if let fixed = consentBootstrapFrame {
                return pinnedBubbleFrame(fallback: fixed)
            }
            let initial: CGRect
            if let windowFrame {
                initial = CGRect(
                    x: windowFrame.maxX - Self.floatingPanelSide - autoGap,
                    y: windowFrame.minY + autoGap,
                    width: Self.floatingPanelSide,
                    height: Self.floatingPanelSide
                )
            } else if panel?.isVisible == true {
                initial = lastFrame
            } else {
                guard allowMouseFallback else { return nil }
                let mouse = NSEvent.mouseLocation
                initial = CGRect(
                    x: mouse.x + 12,
                    y: mouse.y - Self.floatingPanelSide - 12,
                    width: Self.floatingPanelSide,
                    height: Self.floatingPanelSide
                )
            }
            let clamped = clampedToVisibleScreens(initial)
            consentBootstrapFrame = clamped
            return clamped
        }()
        guard let frame else { return false }
        applyMainBubbleFrameIfChanged(frame)
        cancelScheduledVisibilityDrop()
        postOverlayLayoutDebug(
            stage: "consentBootstrap",
            hasEditableFocus: false,
            appConsent: textService.currentAppConsentStatus(),
            fieldFrame: nil,
            windowFrame: windowFrame,
            caretFrame: nil,
            bubbleFrame: frame,
            fallback: windowFrame == nil ? "mouse" : "focusedWindow",
            note: windowFrame == nil ? "mouse anchor" : "focused window anchor"
        )
        postStatus(
            windowFrame == nil
                ? "Showing helper (anchor: mouse — no focused window frame from AX)"
                : "Showing helper (anchor: focused window)"
        )
        bringToFrontOrBelowIfNeeded()
        return true
    }

    private func isFrontmostOurOwnApp() -> Bool {
        guard let info = textService.frontmostAppInfo() else { return false }
        return !ourBundleID.isEmpty && info.bundleID == ourBundleID
    }

    private func scheduleVisibilityDrop() {
        guard panel?.isVisible == true else { return }
        guard visibilityDropTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.noteFloatingPanelHidden()
            self.hideDragHintPanels()
            self.hideMarkerAndCard()
            self.clearConsentBootstrapAnchor()
            self.visibilityDropTask = nil
        }
        visibilityDropTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + visibilityDropDelay, execute: task)
    }

    private func cancelScheduledVisibilityDrop() {
        visibilityDropTask?.cancel()
        visibilityDropTask = nil
    }

    private func resetSuggestionStateAfterAppSwitch() {
        suggestionState = .neutral
        latestSuggestion = ""
        latestSuggestionOptions = []
        latestContext = nil
        latestSignature = nil
        latestIssueRange = nil
        latestIssues = []
        hoveredIssueID = nil
        hoveredIssueIDs = []
        lastMarkerFieldFrame = nil
        lastMarkerCaretFrame = nil
        issuePanelLayouts = []
        updateRingColor()
    }

    private func resetOverlayStateIfFocusSurfaceChanged() {
        let signature = textService.currentFocusSurfaceSignature()
        guard lastFocusSurfaceSignature != signature else { return }
        let hadPreviousSurface = lastFocusSurfaceSignature != nil
        lastFocusSurfaceSignature = signature
        guard hadPreviousSurface else { return }

        selectionSignature = nil
        selectionSignatureSince = nil
        latestSignature = nil
        latestSuggestion = ""
        latestSuggestionOptions = []
        latestContext = nil
        latestIssueRange = nil
        latestIssues = []
        hoveredIssueID = nil
        hoveredIssueIDs = []
        lastCheckedValueSegment = nil
        suggestionState = .neutral
        issuePanelLayouts = []
        lastMarkerFieldFrame = nil
        lastMarkerCaretFrame = nil
        lastMarkerDebugSignature = nil
        hideMarkerAndCard()
        updateRingColor()
        postStatus("Focus/window changed; cleared overlays")
    }

    private func hideFloatingHelperImmediately() {
        cancelScheduledVisibilityDrop()
        panel?.orderOut(nil)
        noteFloatingPanelHidden()
        hideDragHintPanels()
        hideMarkerAndCard()
        clearConsentBootstrapAnchor()
    }

    private func clearConsentBootstrapAnchor() {
        consentBootstrapFrame = nil
        consentBootstrapBundleID = nil
    }

    /// Empty input should never inherit prior red/green result state.
    private func resetSuggestionStateForEmptyInput() {
        guard suggestionState != .neutral || !latestSuggestion.isEmpty || !latestSuggestionOptions.isEmpty || latestContext != nil || latestSignature != nil || !latestIssues.isEmpty else {
            return
        }
        suggestionState = .neutral
        latestSuggestion = ""
        latestSuggestionOptions = []
        latestContext = nil
        latestSignature = nil
        latestIssueRange = nil
        latestIssues = []
        hoveredIssueID = nil
        hoveredIssueIDs = []
        updateRingColor()
        hideMarkerAndCard()
    }

    func showDebugBubbleAtMouse() {
        if panel == nil {
            createPanel()
        }
        let mouse = NSEvent.mouseLocation
        let frame = clampedToVisibleScreens(CGRect(x: mouse.x + 8, y: mouse.y - 8, width: Self.floatingPanelSide, height: Self.floatingPanelSide))
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
        floatingPanelNeedsZOrderPass = false
        postStatus("Debug bubble shown at mouse")
    }

    func refreshAfterExternalRewriteApplied() {
        suppressAutoEvaluationUntil = Date().addingTimeInterval(0.9)
        clearRecentAutoEvaluationSnapshot()
        postApplyAcceptedValueSegment = nil
        if let signature = textService.focusedTextSignature(), !signature.isEmpty {
            let valueSeg = valueSegment(ofFocusedSignature: signature)
            lastCheckedValueSegment = valueSeg
            postApplyAcceptedValueSegment = valueSeg
            latestSignature = signature
        }
        suggestionState = .looksGood
        latestSuggestion = ""
        latestSuggestionOptions = []
        latestIssueRange = nil
        latestIssues = []
        hoveredIssueID = nil
        hoveredIssueIDs = []
        hideMarkerAndCard()
        updateRingColor()
    }

    private func clearRecentAutoEvaluationSnapshot() {
        lastAutoEvaluationSnapshotKey = nil
        lastAutoEvaluationSnapshotNormalizedText = nil
        lastAutoEvaluationSnapshotAt = nil
    }

    func markRewritePopupSuggestionAvailability(_ hasSuggestion: Bool) {
        if hasSuggestion {
            suggestionState = .needsAttention
        } else {
            suggestionState = .looksGood
            latestSuggestion = ""
            latestSuggestionOptions = []
            latestIssueRange = nil
            latestIssues = []
            hoveredIssueID = nil
            hoveredIssueIDs = []
            hideMarkerAndCard()
        }
        updateRingColor()
    }


    private func hasSentenceEnding() -> Bool {
        guard let context = textService.focusedTextContext(minLength: 1) else { return false }
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")
    }

    private func evaluateCurrentText() {
        guard !isEvaluating else { return }
        isEvaluating = true
        updateRingColor()
        onEvaluationStarted?()
        Task { @MainActor in
            var completedSnapshotKey: String?
            var completedSnapshotNormalizedText: String?
            let evaluationSignature = textService.focusedTextSignature() ?? self.lastSignature
            if let evaluationSignature, !evaluationSignature.isEmpty {
                lastCheckedValueSegment = valueSegment(ofFocusedSignature: evaluationSignature)
            }
            defer {
                if let completedSnapshotKey {
                    lastAutoEvaluationSnapshotKey = completedSnapshotKey
                    lastAutoEvaluationSnapshotNormalizedText = completedSnapshotNormalizedText
                    lastAutoEvaluationSnapshotAt = Date()
                }
                isEvaluating = false
                updateRingColor()
                onEvaluationCompleted?()
            }
            guard let context = textService.focusedTextContext(minLength: 1) else {
                suggestionState = .neutral
                latestContext = nil
                latestIssueRange = nil
                latestIssues = []
                hoveredIssueID = nil
                hoveredIssueIDs = []
                return
            }

            guard let credentials = resolveAutoCheckCredentials() else { return }
            let snapshotKey = autoEvaluationSnapshotKey(for: context.text, credentials: credentials)
            if shouldSkipAutoEvaluation(snapshotKey: snapshotKey) {
                textoraDiagLog(
                    "aiRewrite",
                    "skip evaluation: recently checked same text snapshot"
                )
                latestSignature = evaluationSignature
                return
            }
            completedSnapshotKey = snapshotKey
            completedSnapshotNormalizedText = normalized(context.text)

            if !detailedCorrectionsEnabled {
                latestContext = context
                latestIssueRange = NSRange(location: 0, length: (context.text as NSString).length)
                latestIssues = []
                updateRingColor()
                let result = await evaluateWholeContext(context, credentials: credentials)
                suggestionState = suggestionState(from: result.state)
                latestContext = context
                latestSuggestion = result.suggestion
                latestSuggestionOptions = result.suggestionOptions
                latestIssueRange = NSRange(location: 0, length: (context.text as NSString).length)
                latestIssues = []
                hoveredIssueID = nil
                hoveredIssueIDs = []
                latestSignature = evaluationSignature
                updateRingColor()
                return
            }

            // Break the full focused text into every meaningful segment
            // (paragraphs / list items / sentences around protected tokens),
            // so the overlay considers every logical piece of the message
            // independently — not just the single best-scoring one.
            let segments = correctionSegments(in: context.text)
            guard !segments.isEmpty else {
                suggestionState = .neutral
                latestContext = nil
                latestSuggestion = ""
                latestSuggestionOptions = []
                latestSignature = nil
                latestIssueRange = nil
                latestIssues = []
                hoveredIssueID = nil
                hoveredIssueIDs = []
                updateRingColor()
                return
            }

            // Evaluate each segment concurrently, honouring the cache so we
            // don't hit the AI for paragraphs whose text hasn't changed.
            let capturedCredentials = credentials
            var results = [SegmentEvaluationResult?](repeating: nil, count: segments.count)
            await withTaskGroup(of: (Int, SegmentEvaluationResult).self) { group in
                for (i, scope) in segments.enumerated() {
                    let key = segmentCacheKey(scope.text)
                    if let cached = segmentEvaluationCache[key] {
                        results[i] = cached
                        continue
                    }
                    group.addTask { @MainActor [weak self] in
                        guard let self else {
                            return (i, SegmentEvaluationResult(
                                suggestion: "",
                                suggestionOptions: [],
                                issueLocalRange: nil,
                                state: .inconclusive,
                                issues: []
                            ))
                        }
                        let r = await self.evaluateSegment(
                            scope: scope,
                            credentials: capturedCredentials
                        )
                        return (i, r)
                    }
                }
                for await (i, result) in group {
                    results[i] = result
                    cacheSegmentResult(result, for: segmentCacheKey(segments[i].text))
                }
            }

            // First render every localized issue we can safely anchor in the
            // full focused text. This is the multi-overlay path: a sentence
            // can show several independent underlines, and several segments
            // can be visible at the same time.
            var aggregatedIssues: [OverlayIssue] = []
            for (i, result) in results.enumerated() {
                guard let result, result.state == .needsAttention else { continue }
                let scope = segments[i]
                let sourceIssues: [OverlayIssue]
                if !result.issues.isEmpty {
                    sourceIssues = result.issues
                } else {
                    let sourceSuggestions = result.suggestionOptions.isEmpty
                        ? [OverlaySuggestion(operation: .fixGrammar, text: result.suggestion)]
                        : result.suggestionOptions
                    sourceIssues = deriveIssues(fromSegment: scope.text, suggestions: sourceSuggestions)
                }
                aggregatedIssues.append(contentsOf: sourceIssues.map {
                    shiftedIssue($0, by: scope.range.location, sourceRange: scope.range)
                })
            }

            if !aggregatedIssues.isEmpty, let primary = primaryIssue(in: aggregatedIssues, original: context.text) {
                suggestionState = .needsAttention
                latestContext = context
                latestSuggestion = applyIssueToSegment(context.text, issue: primary)
                latestSuggestionOptions = overlaySuggestions(for: aggregatedIssues, in: context.text)
                latestIssueRange = primary.localRange
                latestIssues = aggregatedIssues
                hoveredIssueID = nil
                hoveredIssueIDs = []
                latestSignature = evaluationSignature
                updateRingColor()
                return
            }

            // Fallback: if a segment has only a wholesale rewrite (no stable
            // localized issue), keep the old single-card behavior for the
            // segment closest to the caret.
            let caret = context.selectedRange?.location ?? 0
            var activeIndex: Int?
            var bestDistance = Int.max
            for (i, result) in results.enumerated() {
                guard let result, result.state == .needsAttention else { continue }
                guard !result.suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !result.suggestionOptions.isEmpty else { continue }
                let segRange = segments[i].range
                let distance: Int
                if caret < segRange.location {
                    distance = segRange.location - caret
                } else if caret > segRange.location + segRange.length {
                    distance = caret - (segRange.location + segRange.length)
                } else {
                    distance = 0
                }
                if distance < bestDistance {
                    bestDistance = distance
                    activeIndex = i
                }
            }

            if let activeIndex, let activeResult = results[activeIndex] {
                let scope = segments[activeIndex]
                let scopedContext = scopedFocusedContext(context, scope: scope)
                suggestionState = .needsAttention
                latestContext = scopedContext
                latestSuggestion = activeResult.suggestion
                latestSuggestionOptions = activeResult.suggestionOptions
                latestIssueRange = activeResult.issueLocalRange
                latestIssues = activeResult.issues
                hoveredIssueID = nil
                hoveredIssueIDs = []
                latestSignature = evaluationSignature
                updateRingColor()
                return
            }

            // No actionable segment. If at least one meaningful segment was
            // fully evaluated and came back clean, the composer is "looks
            // good"; otherwise we stay neutral (e.g. all segments too short
            // or AI inconclusive).
            let evaluatedResults = results.compactMap { $0 }
            let hasClean = evaluatedResults.contains { $0.state == .clean }
            let hasAttention = evaluatedResults.contains { $0.state == .needsAttention }
            suggestionState = hasClean && !hasAttention ? .looksGood : .neutral
            latestContext = hasClean && !hasAttention ? context : nil
            latestSuggestion = ""
            latestSuggestionOptions = []
            latestSignature = hasClean && !hasAttention ? evaluationSignature : nil
            latestIssueRange = nil
            latestIssues = []
            hoveredIssueID = nil
            hoveredIssueIDs = []
            updateRingColor()
        }
    }

    private struct AutoCheckCredentials {
        let provider: AIProvider
        let model: String
        let apiKey: String
    }

    private func resolveAutoCheckCredentials() -> AutoCheckCredentials? {
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
            suggestionState = .neutral
            latestContext = nil
            postStatus("API key missing")
            return nil
        }
        if provider == .other {
            let base = UserDefaults.standard
                .string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base.isEmpty else {
                suggestionState = .neutral
                latestContext = nil
                postStatus("API base URL missing")
                return nil
            }
        }
        return AutoCheckCredentials(provider: provider, model: model, apiKey: key)
    }

    private func autoEvaluationSnapshotKey(
        for text: String,
        credentials: AutoCheckCredentials
    ) -> String {
        [
            credentials.provider.rawValue,
            credentials.model,
            smartAIEnabled ? "smart" : "manual",
            detailedCorrectionsEnabled ? "detailed" : "whole",
            normalized(text)
        ].joined(separator: "\t")
    }

    private func shouldSkipAutoEvaluation(snapshotKey: String) -> Bool {
        guard lastAutoEvaluationSnapshotKey == snapshotKey,
              let lastAutoEvaluationSnapshotAt else {
            return false
        }
        return Date().timeIntervalSince(lastAutoEvaluationSnapshotAt) < autoEvaluationSnapshotTTL
    }

    private func wasRecentlyAutoEvaluatedValueSegment(_ valueSegment: String) -> Bool {
        guard let lastAutoEvaluationSnapshotNormalizedText,
              let lastAutoEvaluationSnapshotAt,
              Date().timeIntervalSince(lastAutoEvaluationSnapshotAt) < autoEvaluationSnapshotTTL else {
            return false
        }
        return normalized(valueSegment) == lastAutoEvaluationSnapshotNormalizedText
    }

    private func evaluateWholeContext(
        _ context: TextAccessService.FocusedTextContext,
        credentials: AutoCheckCredentials
    ) async -> SegmentEvaluationResult {
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .inconclusive
            )
        }

        let localRepeatedIssues = repeatedWordIssues(in: text)
        if let primary = primaryIssue(in: localRepeatedIssues, original: text) {
            let suggestions = overlaySuggestions(for: localRepeatedIssues, in: text)
            return SegmentEvaluationResult(
                suggestion: applyIssueToSegment(text, issue: primary),
                suggestionOptions: suggestions,
                issueLocalRange: primary.localRange,
                state: .needsAttention,
                issues: localRepeatedIssues
            )
        }

        if let contraction = contractionTypoFix(in: text) {
            return SegmentEvaluationResult(
                suggestion: contraction.fixedText,
                suggestionOptions: rankedSuggestions([OverlaySuggestion(operation: .fixGrammar, text: contraction.fixedText)], original: text),
                issueLocalRange: contraction.issue.localRange,
                state: .needsAttention,
                issues: [contraction.issue]
            )
        }

        if !isMeaningfulForAutoCheck(text) {
            if text.count >= 3,
               let localIssue = firstMisspelledRange(in: text),
               let localFix = bestLocalSpellingReplacement(in: text).flatMap({
                validatedSafeFixSuggestion(original: text, candidate: $0)
               }) {
                return SegmentEvaluationResult(
                    suggestion: localFix,
                    suggestionOptions: rankedSuggestions([OverlaySuggestion(operation: .fixGrammar, text: localFix)], original: text),
                    issueLocalRange: localIssue.0,
                    state: .needsAttention
                )
            }
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .clean
            )
        }

        let localMixedScriptFix = fixMixedLatinCyrillicWords(in: text)
        if let validatedMixedScriptFix = validatedSafeFixSuggestion(
            original: text,
            candidate: localMixedScriptFix
        ) {
            return SegmentEvaluationResult(
                suggestion: validatedMixedScriptFix,
                suggestionOptions: rankedSuggestions([OverlaySuggestion(operation: .fixGrammar, text: validatedMixedScriptFix)], original: text),
                issueLocalRange: firstMixedLatinCyrillicRange(in: text),
                state: .needsAttention
            )
        }

        do {
            textoraDiagLog(
                "aiRewrite",
                "caller=autoWhole smartAI=\(smartAIEnabled) detailed=\(detailedCorrectionsEnabled) "
                + "strategy=\(smartAIEnabled ? "multiSmart" : "singleSavedOperation") text=\(textoraDiagPreview(text))"
            )
            let suggestions = smartAIEnabled
                ? try await multiAISuggestions(for: text, credentials: credentials)
                : (try await singleAISuggestion(for: text, credentials: credentials).map { [$0] } ?? [])
            guard let suggestion = suggestions.first else {
                return SegmentEvaluationResult(
                    suggestion: "",
                    suggestionOptions: [],
                    issueLocalRange: nil,
                    state: .clean
                )
            }
            return SegmentEvaluationResult(
                suggestion: suggestion.text,
                suggestionOptions: suggestions,
                issueLocalRange: NSRange(location: 0, length: (text as NSString).length),
                state: .needsAttention,
                issues: deriveIssues(fromSegment: text, suggestions: suggestions)
            )
        } catch {
            postStatus("Auto-check failed: \(error.localizedDescription)")
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .inconclusive
            )
        }
    }

    private func suggestionState(from state: SegmentEvaluationResult.State) -> SuggestionState {
        switch state {
        case .clean:
            return .looksGood
        case .needsAttention:
            return .needsAttention
        case .inconclusive:
            return .neutral
        }
    }

    private func orderedUniqueWholeTextSuggestions(
        _ suggestions: [OverlaySuggestion],
        original: String
    ) -> [OverlaySuggestion] {
        var byOperation: [RewriteOperation: OverlaySuggestion] = [:]
        var seenText = Set<String>()
        let originalKey = normalized(original)
        for suggestion in suggestions {
            let text = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = normalized(text)
            guard key != originalKey, !seenText.contains(key) else { continue }
            seenText.insert(key)
            if byOperation[suggestion.operation] == nil {
                byOperation[suggestion.operation] = OverlaySuggestion(operation: suggestion.operation, text: text)
            }
        }
        return rankedSuggestions(Array(byOperation.values), original: original)
    }

    private func singleRequestOperation(for text: String) -> RewriteOperation {
        if smartAIEnabled {
            return preferredOperation(
                for: text,
                available: Set(RewriteOperation.allCases)
            ) ?? .fixGrammar
        }
        let savedRaw = UserDefaults.standard.string(forKey: Self.lastOperationKey)
            ?? RewriteOperation.fixGrammar.rawValue
        return RewriteOperation(rawValue: savedRaw) ?? .fixGrammar
    }

    private func grammarOnlyAISuggestion(
        for text: String,
        credentials: AutoCheckCredentials
    ) async throws -> OverlaySuggestion? {
        let candidate = try await aiClient.checkAndSuggestIfNeeded(
            provider: credentials.provider,
            model: credentials.model,
            apiKey: credentials.apiKey,
            text: text
        )
        let trimmed = sanitizedAISuggestion(original: text, candidate: candidate)
        guard !trimmed.isEmpty,
              normalized(trimmed) != normalized(text),
              preservesProtectedTokens(original: text, candidate: trimmed),
              !wouldRevertRecentRewrite(original: text, candidate: trimmed),
              !shouldRejectFixSuggestion(original: text, candidate: trimmed) else {
            return nil
        }
        var suggestion = OverlaySuggestion(operation: .fixGrammar, text: trimmed)
        suggestion.isRecommended = smartAIEnabled
        return suggestion
    }

    private func singleAISuggestion(
        for text: String,
        credentials: AutoCheckCredentials
    ) async throws -> OverlaySuggestion? {
        let operation = singleRequestOperation(for: text)
        let candidate: String
        if operation == .fixGrammar {
            candidate = try await aiClient.checkAndSuggestIfNeeded(
                provider: credentials.provider,
                model: credentials.model,
                apiKey: credentials.apiKey,
                text: text
            )
        } else {
            candidate = try await aiClient.rewriteText(
                provider: credentials.provider,
                model: credentials.model,
                apiKey: credentials.apiKey,
                text: text,
                operation: operation
            )
        }

        let trimmed = sanitizedAISuggestion(original: text, candidate: candidate)
        guard !trimmed.isEmpty,
              normalized(trimmed) != normalized(text),
              preservesProtectedTokens(original: text, candidate: trimmed),
              !wouldRevertRecentRewrite(original: text, candidate: trimmed) else {
            return nil
        }
        if operation == .fixGrammar {
            guard !shouldRejectFixSuggestion(original: text, candidate: trimmed) else { return nil }
        } else {
            guard isReasonableStyleIssue(original: text, candidate: trimmed) else { return nil }
        }

        var suggestion = OverlaySuggestion(operation: operation, text: trimmed)
        suggestion.isRecommended = smartAIEnabled
        return suggestion
    }

    private func multiAISuggestions(
        for text: String,
        credentials: AutoCheckCredentials
    ) async throws -> [OverlaySuggestion] {
        guard shouldUseAIForAutoCheck(text) else {
            textoraDiagLog("aiRewrite", "multiSmart skipped: low-confidence fragment")
            return []
        }
        let candidates = try await aiClient.overlaySuggestions(
            provider: credentials.provider,
            model: credentials.model,
            apiKey: credentials.apiKey,
            text: text
        )
        let filtered = candidates.compactMap { suggestion -> OverlaySuggestion? in
            let trimmed = sanitizedAISuggestion(original: text, candidate: suggestion.text)
            guard !trimmed.isEmpty,
                  normalized(trimmed) != normalized(text),
                  preservesProtectedTokens(original: text, candidate: trimmed),
                  !wouldRevertRecentRewrite(original: text, candidate: trimmed) else {
                return nil
            }
            if suggestion.operation == .fixGrammar {
                guard !shouldRejectFixSuggestion(original: text, candidate: trimmed) else { return nil }
            } else {
                guard isReasonableStyleIssue(original: text, candidate: trimmed) else { return nil }
            }
            return OverlaySuggestion(operation: suggestion.operation, text: trimmed)
        }
        let ordered = orderedUniqueWholeTextSuggestions(filtered, original: text)
        if !ordered.isEmpty {
            return ordered
        }
        if let fallback = try await grammarOnlyAISuggestion(for: text, credentials: credentials) {
            textoraDiagLog(
                "aiRewrite",
                "multiSmart empty; fallback strictFix=\(textoraDiagPreview(fallback.text))"
            )
            return [fallback]
        }
        return []
    }

    private func rankedSuggestions(
        _ suggestions: [OverlaySuggestion],
        original: String
    ) -> [OverlaySuggestion] {
        var byOperation: [RewriteOperation: OverlaySuggestion] = [:]
        for suggestion in suggestions {
            guard byOperation[suggestion.operation] == nil else { continue }
            byOperation[suggestion.operation] = OverlaySuggestion(
                operation: suggestion.operation,
                text: suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !byOperation.isEmpty else { return [] }

        let available = Set(byOperation.keys)
        let preferred = preferredOperation(for: original, available: available)
        let fallbackOrder: [RewriteOperation] = [.fixGrammar, .makeProfessional, .shorten, .humanize]
        var orderedOps: [RewriteOperation] = []
        if let preferred {
            orderedOps.append(preferred)
        }
        for op in fallbackOrder where !orderedOps.contains(op) {
            orderedOps.append(op)
        }

        let shouldDecorate = smartAIEnabled && preferred != nil
        let secondaryOps = secondarySmartOperations(for: original, primary: preferred)
        return orderedOps.compactMap { byOperation[$0] }.enumerated().map { index, suggestion in
            var copy = suggestion
            copy.isRecommended = shouldDecorate && index == 0
            copy.isOptional = shouldDecorate && secondaryOps.contains(suggestion.operation)
            return copy
        }
    }

    private func secondarySmartOperations(
        for text: String,
        primary: RewriteOperation?
    ) -> Set<RewriteOperation> {
        guard smartAIEnabled, primary != nil else { return [] }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard primary != .fixGrammar,
              hasLocalSpellingIssues(cleaned) || containsMixedLatinCyrillicWord(cleaned) else {
            return []
        }
        return [.fixGrammar]
    }

    private func preferredOperation(
        for text: String,
        available: Set<RewriteOperation>
    ) -> RewriteOperation? {
        guard !available.isEmpty else { return nil }
        if !smartAIEnabled {
            let savedRaw = UserDefaults.standard.string(forKey: Self.lastOperationKey)
                ?? RewriteOperation.fixGrammar.rawValue
            let saved = RewriteOperation(rawValue: savedRaw) ?? .fixGrammar
            return available.contains(saved) ? saved : nil
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let hasTextIssues = hasLocalSpellingIssues(cleaned)
            || containsMixedLatinCyrillicWord(cleaned)
        if hasTextIssues, available.contains(.fixGrammar) {
            return .fixGrammar
        }
        if isLowConfidenceAutoCheckFragment(cleaned) {
            return nil
        }

        let preferredOrder: [RewriteOperation]
        if looksOverloaded(cleaned) {
            preferredOrder = [.shorten, .humanize, .makeProfessional, .fixGrammar]
        } else if looksFormal(cleaned) {
            preferredOrder = [.makeProfessional, .shorten, .humanize, .fixGrammar]
        } else if looksPlain(cleaned) {
            preferredOrder = [.humanize, .makeProfessional, .shorten, .fixGrammar]
        } else {
            preferredOrder = [.makeProfessional, .humanize, .shorten, .fixGrammar]
        }
        return preferredOrder.first { available.contains($0) }
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

    private func shouldUseAIForAutoCheck(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLowConfidenceAutoCheckFragment(cleaned) else { return false }
        return true
    }

    private func isLowConfidenceAutoCheckFragment(_ text: String) -> Bool {
        let words = wordsForHeuristicChecks(in: text)
        guard !words.isEmpty else { return true }
        if words.count <= 3, startsWithDanglingClauseCue(text) {
            return true
        }
        if words.count <= 2, !hasSentenceEndingPunctuation(text) {
            return true
        }
        return false
    }

    private func startsWithDanglingClauseCue(_ text: String) -> Bool {
        guard let first = wordsForHeuristicChecks(in: text).first?.lowercased() else { return false }
        let cues: Set<String> = [
            "if", "when", "while", "because", "although", "though", "unless",
            "since", "before", "after", "whether", "once", "как", "если",
            "когда", "пока", "потому", "хотя"
        ]
        return cues.contains(first)
    }

    private func hasSentenceEndingPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?…".contains(last)
    }

    /// Evaluates a single segment: local spelling, mixed-script fix, then AI.
    /// Mirrors the original `evaluateCurrentText` decision tree but scoped
    /// to one segment so multiple segments can be processed independently
    /// (and cached).
    private func evaluateSegment(
        scope: CorrectionScope,
        credentials: AutoCheckCredentials
    ) async -> SegmentEvaluationResult {
        let text = scope.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .inconclusive
            )
        }

        let localRepeatedIssues = repeatedWordIssues(in: text)
        if !isMeaningfulForAutoCheck(text),
           let primary = primaryIssue(in: localRepeatedIssues, original: text) {
            let suggestions = overlaySuggestions(for: localRepeatedIssues, in: text)
            return SegmentEvaluationResult(
                suggestion: applyIssueToSegment(text, issue: primary),
                suggestionOptions: suggestions,
                issueLocalRange: primary.localRange,
                state: .needsAttention,
                issues: localRepeatedIssues
            )
        }

        if let contraction = contractionTypoFix(in: text) {
            return SegmentEvaluationResult(
                suggestion: contraction.fixedText,
                suggestionOptions: rankedSuggestions([OverlaySuggestion(operation: .fixGrammar, text: contraction.fixedText)], original: text),
                issueLocalRange: contraction.issue.localRange,
                state: .needsAttention,
                issues: [contraction.issue]
            )
        }

        if !isMeaningfulForAutoCheck(text) {
            if text.count >= 3, let localIssue = firstMisspelledRange(in: text) {
                if let localFix = bestLocalSpellingReplacement(in: text).flatMap({
                    validatedSafeFixSuggestion(original: text, candidate: $0)
                }) {
                    return SegmentEvaluationResult(
                        suggestion: localFix,
                        suggestionOptions: rankedSuggestions([OverlaySuggestion(operation: .fixGrammar, text: localFix)], original: text),
                        issueLocalRange: localIssue.0,
                        state: .needsAttention
                    )
                }
            }
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .inconclusive
            )
        }

        let localMixedScriptFix = fixMixedLatinCyrillicWords(in: text)
        if let validatedMixedScriptFix = validatedSafeFixSuggestion(
            original: text,
            candidate: localMixedScriptFix
        ) {
            return SegmentEvaluationResult(
                suggestion: validatedMixedScriptFix,
                suggestionOptions: rankedSuggestions([OverlaySuggestion(operation: .fixGrammar, text: validatedMixedScriptFix)], original: text),
                issueLocalRange: firstMixedLatinCyrillicRange(in: text),
                state: .needsAttention
            )
        }

        let localListIssues = malformedNumberedListIssues(in: text)
        let localDeterministicIssues = mergedIssues(localRepeatedIssues + localListIssues)

        do {
            textoraDiagLog(
                "aiRewrite",
                "caller=autoSegment smartAI=\(smartAIEnabled) detailed=\(detailedCorrectionsEnabled) "
                + "strategy=localizedAudit text=\(textoraDiagPreview(text))"
            )
            let auditedIssues = sanitizeAuditIssues(
                try await aiClient.auditIssues(
                    provider: credentials.provider,
                    model: credentials.model,
                    apiKey: credentials.apiKey,
                    text: text
                ),
                in: text
            )
            let merged = mergedIssues(localDeterministicIssues + auditedIssues)
            if !merged.isEmpty {
                if let primary = primaryIssue(in: merged, original: text) {
                    let suggestions = overlaySuggestions(for: merged, in: text)
                    return SegmentEvaluationResult(
                        suggestion: applyIssueToSegment(text, issue: primary),
                        suggestionOptions: suggestions,
                        issueLocalRange: primary.localRange,
                        state: .needsAttention,
                        issues: merged
                    )
                }
            }
            if let primary = primaryIssue(in: localDeterministicIssues, original: text) {
                let suggestions = overlaySuggestions(for: localDeterministicIssues, in: text)
                return SegmentEvaluationResult(
                    suggestion: applyIssueToSegment(text, issue: primary),
                    suggestionOptions: suggestions,
                    issueLocalRange: primary.localRange,
                    state: .needsAttention,
                    issues: localDeterministicIssues
                )
            }
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .clean
            )
        } catch {
            postStatus("Auto-check failed: \(error.localizedDescription)")
            if let primary = primaryIssue(in: localDeterministicIssues, original: text) {
                let suggestions = overlaySuggestions(for: localDeterministicIssues, in: text)
                return SegmentEvaluationResult(
                    suggestion: applyIssueToSegment(text, issue: primary),
                    suggestionOptions: suggestions,
                    issueLocalRange: primary.localRange,
                    state: .needsAttention,
                    issues: localDeterministicIssues
                )
            }
            return SegmentEvaluationResult(
                suggestion: "",
                suggestionOptions: [],
                issueLocalRange: nil,
                state: .inconclusive
            )
        }
    }

    struct CachedSuggestionResult {
        let context: TextAccessService.FocusedTextContext
        let suggestion: String
        let suggestionOptions: [OverlaySuggestion]
        let signature: String
        let operation: RewriteOperation
        let isNoIssues: Bool
    }

    func cachedSuggestionResultForCurrentFocus(operation: RewriteOperation) -> CachedSuggestionResult? {
        guard let signature = textService.focusedTextSignature(), !signature.isEmpty else { return nil }
        guard let currentContext = textService.focusedTextContext(minLength: 1) else { return nil }
        guard let latestContext, let latestSignature, latestSignature == signature else { return nil }
        let currentText = currentContext.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else { return nil }
        // Prevent showing stale cached text when current element isn't readable or changed.
        let normalizedCurrent = normalized(currentText)
        let normalizedLatest = normalized(latestContext.text)
        guard normalizedCurrent == normalizedLatest || normalizedCurrent.contains(normalizedLatest) else { return nil }
        if suggestionState == .looksGood,
           latestSuggestionOptions.isEmpty,
           latestIssues.isEmpty,
           latestSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CachedSuggestionResult(
                context: latestContext,
                suggestion: latestContext.text,
                suggestionOptions: [],
                signature: signature,
                operation: operation,
                isNoIssues: true
            )
        }
        let cachedSuggestion: String = {
            if let exact = latestSuggestionOptions.first(where: { $0.operation == operation })?.text {
                return exact
            }
            if operation == .fixGrammar {
                return latestSuggestion
            }
            return ""
        }()
        guard !cachedSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let isNoIssues = suggestionState == .looksGood
        return CachedSuggestionResult(
            context: currentContext,
            suggestion: cachedSuggestion,
            suggestionOptions: latestSuggestionOptions,
            signature: signature,
            operation: operation,
            isNoIssues: isNoIssues
        )
    }

    func cachedFixGrammarResultForCurrentFocus() -> CachedSuggestionResult? {
        cachedSuggestionResultForCurrentFocus(operation: .fixGrammar)
    }

    func cachedPopupResultForCurrentFocus() -> CachedSuggestionResult? {
        guard let signature = textService.focusedTextSignature(), !signature.isEmpty else { return nil }
        guard let latestContext, let latestSignature, latestSignature == signature else { return nil }
        if suggestionState == .looksGood,
           latestSuggestionOptions.isEmpty,
           latestIssues.isEmpty,
           latestSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CachedSuggestionResult(
                context: latestContext,
                suggestion: latestContext.text,
                suggestionOptions: [],
                signature: signature,
                operation: .fixGrammar,
                isNoIssues: true
            )
        }

        let suggestion = latestSuggestionOptions.first(where: { $0.isRecommended })
            ?? latestSuggestionOptions.first
        if let suggestion,
           !suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CachedSuggestionResult(
                context: latestContext,
                suggestion: suggestion.text,
                suggestionOptions: latestSuggestionOptions,
                signature: signature,
                operation: suggestion.operation,
                isNoIssues: false
            )
        }
        let fallback = latestSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { return nil }
        return CachedSuggestionResult(
            context: latestContext,
            suggestion: fallback,
            suggestionOptions: latestSuggestionOptions,
            signature: signature,
            operation: .fixGrammar,
            isNoIssues: false
        )
    }

    func currentFocusedContextForPopup() -> TextAccessService.FocusedTextContext? {
        textService.focusedTextContext(minLength: 1, maxLength: 6000, allowClipboardFallback: true)
    }

    func requestEvaluationForCurrentFocusIfNeeded() {
        guard !isEvaluating else { return }
        if let signature = textService.focusedTextSignature(), !signature.isEmpty {
            let valueSeg = valueSegment(ofFocusedSignature: signature)
            let valueRaw = valueSeg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !valueRaw.isEmpty else {
                resetSuggestionStateForEmptyInput()
                lastCheckedValueSegment = valueSeg
                return
            }
            if wasRecentlyAutoEvaluatedValueSegment(valueSeg) {
                lastCheckedValueSegment = valueSeg
                latestSignature = signature
                return
            }
            guard lastCheckedValueSegment != valueSeg, latestSignature != signature else { return }
        }
        evaluateCurrentText()
    }

    /// Spell-check languages to try (`nil` = system default). Fixes cases like "Helo" when default dictionary does not flag.
    private func spellingLanguageCandidates(for text: String) -> [String?] {
        var result: [String?] = [nil]
        var seen = Set<String>(["__nil__"])
        func push(_ lang: String?) {
            let key = lang ?? "__nil__"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(lang)
        }
        let system = spellChecker.language().trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { push(system) }
        let lettersOnly = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let hasCyrillic = lettersOnly.contains { scalar in
            let v = scalar.value
            return (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v)
        }
        let isMostlyLatin = !lettersOnly.isEmpty && lettersOnly.allSatisfy { s in
            let v = s.value
            return (0x0041...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v)
        }
        if hasCyrillic {
            push("ru")
            push("uk")
        } else if isMostlyLatin {
            push("en")
        }
        for pref in Locale.preferredLanguages.prefix(3) {
            let code = pref.split(separator: "-").first.map(String.init) ?? ""
            if !code.isEmpty { push(code) }
        }
        return result
    }

    private func firstMisspelledRange(in text: String) -> (NSRange, String?)? {
        let nsText = text as NSString
        if nsText.length < 3 { return nil }
        let protectedRanges = protectedTokenRanges(in: text)
        for lang in spellingLanguageCandidates(for: text) {
            var start = 0
            while start < nsText.length {
                let misspelled = spellChecker.checkSpelling(
                    of: text,
                    startingAt: start,
                    language: lang,
                    wrap: false,
                    inSpellDocumentWithTag: 0,
                    wordCount: nil
                )
                guard misspelled.location != NSNotFound else { break }
                if protectedRanges.contains(where: { NSIntersectionRange($0, misspelled).length > 0 }) {
                    start = misspelled.location + max(1, misspelled.length)
                    continue
                }
                return (misspelled, lang)
            }
        }
        return nil
    }

    private func contractionTypoFix(in text: String) -> (fixedText: String, issue: OverlayIssue)? {
        let ns = text as NSString
        guard ns.length >= 4 else { return nil }
        let protectedRanges = protectedTokenRanges(in: text)
        let pattern = #"\b([A-Za-z]+)(['’])t\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            guard match.numberOfRanges >= 3,
                  !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
                continue
            }
            let base = ns.substring(with: match.range(at: 1))
            let apostrophe = ns.substring(with: match.range(at: 2))
            guard let replacement = correctedNegativeContraction(base: base, apostrophe: apostrophe) else {
                continue
            }
            let originalWord = ns.substring(with: match.range)
            guard replacement != originalWord else { continue }

            let fixed = NSMutableString(string: text)
            fixed.replaceCharacters(in: match.range, with: replacement)
            let issue = OverlayIssue(
                localRange: match.range,
                originalText: originalWord,
                category: .fixGrammar,
                replacement: replacement,
                reason: "Fix contraction"
            )
            return (fixed as String, issue)
        }

        return nil
    }

    private func correctedNegativeContraction(base: String, apostrophe: String) -> String? {
        let lower = base.lowercased()
        let correctedLower: String
        switch lower {
        case "can", "ca":
            correctedLower = "can\(apostrophe)t"
        case "won", "wo", "will":
            correctedLower = "won\(apostrophe)t"
        case "could", "would", "should", "do", "does", "did",
             "is", "are", "was", "were", "has", "have", "had", "must":
            correctedLower = "\(lower)n\(apostrophe)t"
        default:
            return nil
        }
        return matchCapitalization(of: base, replacement: correctedLower)
    }

    private func matchCapitalization(of source: String, replacement: String) -> String {
        guard let first = source.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first),
              let replacementFirst = replacement.first else {
            return replacement
        }
        return String(replacementFirst).uppercased() + replacement.dropFirst()
    }

    private func hasLocalSpellingIssues(_ text: String) -> Bool {
        firstMisspelledRange(in: text) != nil
    }

    private func firstMixedLatinCyrillicRange(in text: String) -> NSRange? {
        let ns = text as NSString
        let protectedRanges = protectedTokenRanges(in: text)
        var i = 0
        while i < ns.length {
            while i < ns.length {
                let ch = ns.character(at: i)
                guard let scalar = UnicodeScalar(ch), CharacterSet.letters.contains(scalar) else { break }
                i += 1
            }
            let start = i
            var hasLatin = false
            var hasCyrillic = false
            while i < ns.length {
                let ch = ns.character(at: i)
                guard let scalar = UnicodeScalar(ch), CharacterSet.letters.contains(scalar) else { break }
                let v = scalar.value
                if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                    hasLatin = true
                } else if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                    hasCyrillic = true
                }
                i += 1
            }
            let range = NSRange(location: start, length: max(0, i - start))
            if range.length > 0,
               !protectedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }),
               hasLatin && hasCyrillic {
                return range
            }
            i += 1
        }
        return nil
    }

    /// First NSSpellChecker guess for the first misspelled word in `fullText` (single-word typos, AI unchanged).
    private func bestLocalSpellingReplacement(in fullText: String) -> String? {
        let ns = fullText as NSString
        guard ns.length >= 2 else { return nil }
        guard let (misspelled, lang) = firstMisspelledRange(in: fullText) else { return nil }
        let guesses = spellChecker.guesses(
            forWordRange: misspelled,
            in: fullText,
            language: lang,
            inSpellDocumentWithTag: 0
        ) ?? []
        guard let best = guesses.first else { return nil }
        let mutable = NSMutableString(string: fullText)
        mutable.replaceCharacters(in: misspelled, with: best)
        return mutable as String
    }

    private func sanitizeAuditIssues(_ issues: [OverlayIssue], in text: String) -> [OverlayIssue] {
        issues.filter { issue in
            guard !issueBreaksNumberedListMarker(issue, in: text) else {
                return false
            }
            if wouldRevertRecentRewrite(original: issue.patch.originalText, candidate: issue.replacement) {
                return false
            }
            guard issue.category == .fixGrammar else {
                return isReasonableStyleIssue(
                    original: issue.patch.originalText,
                    candidate: issue.replacement
                )
            }
            return !shouldRejectFixSuggestion(
                original: issue.patch.originalText,
                candidate: issue.replacement
            )
        }
    }

    private func repeatedWordIssues(in text: String) -> [OverlayIssue] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let protectedRanges = protectedTokenRanges(in: text)
        let pattern = #"[\p{L}\p{N}][\p{L}\p{N}'’_-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return [] }

        let segmentSignature = segmentCacheKey(text)
        var issues: [OverlayIssue] = []
        for index in 0..<(matches.count - 1) {
            let first = matches[index].range
            let second = matches[index + 1].range
            guard NSIntersectionRange(first, second).length == 0,
                  !protectedRanges.contains(where: {
                      NSIntersectionRange($0, first).length > 0 || NSIntersectionRange($0, second).length > 0
                  }) else {
                continue
            }

            let separatorStart = NSMaxRange(first)
            let separatorLength = second.location - separatorStart
            guard separatorLength > 0 else { continue }
            let separatorRange = NSRange(location: separatorStart, length: separatorLength)
            let separator = ns.substring(with: separatorRange)
            guard separator.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                continue
            }

            let firstWord = ns.substring(with: first)
            let secondWord = ns.substring(with: second)
            guard firstWord.localizedCaseInsensitiveCompare(secondWord) == .orderedSame,
                  containsLetter(firstWord) else {
                continue
            }

            let removeRange = NSRange(
                location: separatorStart,
                length: NSMaxRange(second) - separatorStart
            )
            let originalText = ns.substring(with: removeRange)
            let issue = OverlayIssue(
                localRange: removeRange,
                originalText: originalText,
                category: .fixGrammar,
                replacement: "",
                reason: "Repeated word",
                segmentSignature: segmentSignature,
                sourceSegmentRange: nil
            )
            let skip = skipSignature(
                segmentSignature: segmentSignature,
                issue: issue,
                spanText: originalText
            )
            guard !skippedIssueSignatures.contains(skip) else { continue }
            issues.append(issue)
        }
        return mergedIssues(issues)
    }

    private func containsLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private func malformedNumberedListIssues(in text: String) -> [OverlayIssue] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let segmentSignature = segmentCacheKey(text)
        var issues: [OverlayIssue] = []
        var lineStart = 0

        func inspectLine(start: Int, end: Int) {
            guard start < end else { return }
            var cursor = start
            while cursor < end, isASCIIDigit(ns.character(at: cursor)) {
                cursor += 1
            }
            guard cursor > start else { return }

            if cursor < end {
                let next = ns.character(at: cursor)
                if isLetter(next) {
                    let original = ns.substring(with: NSRange(location: start, length: cursor - start))
                    issues.append(
                        OverlayIssue(
                            localRange: NSRange(location: start, length: cursor - start),
                            originalText: original,
                            category: .fixGrammar,
                            replacement: "\(original). ",
                            reason: "Restore list marker",
                            segmentSignature: segmentSignature,
                            sourceSegmentRange: nil
                        )
                    )
                    return
                }
            }

            if cursor < end,
               ns.character(at: cursor) == 46,
               cursor + 1 < end,
               isLetter(ns.character(at: cursor + 1)) {
                let original = ns.substring(with: NSRange(location: start, length: cursor - start + 1))
                issues.append(
                    OverlayIssue(
                        localRange: NSRange(location: start, length: cursor - start + 1),
                        originalText: original,
                        category: .fixGrammar,
                        replacement: "\(original) ",
                        reason: "Restore list spacing",
                        segmentSignature: segmentSignature,
                        sourceSegmentRange: nil
                    )
                )
            }
        }

        var index = 0
        while index < ns.length {
            let ch = ns.character(at: index)
            if ch == 10 || ch == 13 {
                inspectLine(start: lineStart, end: index)
                if ch == 13, index + 1 < ns.length, ns.character(at: index + 1) == 10 {
                    index += 1
                }
                lineStart = index + 1
            }
            index += 1
        }
        inspectLine(start: lineStart, end: ns.length)
        return issues
    }

    private func isLetter(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private func issueBreaksNumberedListMarker(_ issue: OverlayIssue, in text: String?) -> Bool {
        if let text {
            return patchBreaksNumberedListMarker(issue.patch, in: text)
        }
        let span = issue.patch.originalText
        return startsWithDigits(span)
            && !issue.replacement.hasPrefix(leadingDigits(in: span))
            || span.hasPrefix(". ") && !issue.replacement.hasPrefix(". ")
    }

    private func patchBreaksNumberedListMarker(_ patch: TextPatch, in text: String) -> Bool {
        let ns = text as NSString
        guard patch.start >= 0,
              patch.start <= ns.length else {
            return false
        }

        if isAtLineStart(patch.start, in: ns),
           let marker = leadingNumberedListMarker(in: patch.originalText),
           !patch.replacement.hasPrefix(marker) {
            return true
        }

        if isAtLineStart(patch.start, in: ns),
           startsWithDigits(patch.originalText),
           !patch.replacement.hasPrefix(leadingDigits(in: patch.originalText)) {
            return true
        }

        guard patch.start > 0, patch.start < ns.length else {
            return false
        }
        let previous = ns.character(at: patch.start - 1)
        if isASCIIDigit(previous),
           isAtLineStartOfDigits(endingAt: patch.start - 1, in: ns),
           patch.originalText.hasPrefix(". "),
           !patch.replacement.hasPrefix(". ") {
            return true
        }
        return false
    }

    private func leadingNumberedListMarker(in text: String) -> String? {
        let ns = text as NSString
        guard ns.length >= 3 else { return nil }
        var cursor = 0
        while cursor < ns.length, isASCIIDigit(ns.character(at: cursor)) {
            cursor += 1
        }
        guard cursor > 0,
              cursor + 1 < ns.length,
              ns.character(at: cursor) == 46,
              ns.character(at: cursor + 1) == 32 else {
            return nil
        }
        return ns.substring(with: NSRange(location: 0, length: cursor + 2))
    }

    private func startsWithDigits(_ text: String) -> Bool {
        guard let first = text.utf16.first else { return false }
        return isASCIIDigit(first)
    }

    private func leadingDigits(in text: String) -> String {
        var scalars: [UInt16] = []
        for unit in text.utf16 {
            guard isASCIIDigit(unit) else { break }
            scalars.append(unit)
        }
        return String(decoding: scalars, as: UTF16.self)
    }

    private func isASCIIDigit(_ unit: UInt16) -> Bool {
        unit >= 48 && unit <= 57
    }

    private func isAtLineStart(_ location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return true }
        let previous = text.character(at: location - 1)
        return previous == 10 || previous == 13
    }

    private func isAtLineStartOfDigits(endingAt digitIndex: Int, in text: NSString) -> Bool {
        var start = digitIndex
        while start > 0, isASCIIDigit(text.character(at: start - 1)) {
            start -= 1
        }
        return isAtLineStart(start, in: text)
    }

    private func validatedSafeFixSuggestion(original: String, candidate: String) -> String? {
        let trimmed = sanitizedAISuggestion(original: original, candidate: candidate)
        guard !trimmed.isEmpty,
              normalized(trimmed) != normalized(original),
              preservesProtectedTokens(original: original, candidate: trimmed),
              !shouldRejectFixSuggestion(original: original, candidate: trimmed) else {
            return nil
        }
        return trimmed
    }

    private func sanitizedAISuggestion(original: String, candidate: String) -> String {
        restoreOriginalProtectedTrailingPunctuationSpacing(
            original: original,
            candidate: candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func restoreOriginalProtectedTrailingPunctuationSpacing(
        original: String,
        candidate: String
    ) -> String {
        guard !candidate.isEmpty else { return candidate }
        let originalNS = original as NSString
        let punctuation = CharacterSet(charactersIn: ".,;:!?")
        var result = candidate

        for protectedRange in protectedTokenRanges(in: original) {
            let protectedToken = normalizedProtectedToken(originalNS.substring(with: protectedRange))
            guard protectedTokenLooksLikeURL(protectedToken) else { continue }

            let tokenEnd = protectedRange.location + protectedRange.length
            guard tokenEnd < originalNS.length else { continue }
            var cursor = tokenEnd
            while cursor < originalNS.length,
                  isWhitespace(originalNS.character(at: cursor)) {
                cursor += 1
            }
            guard cursor > tokenEnd, cursor < originalNS.length,
                  let scalar = UnicodeScalar(UInt32(originalNS.character(at: cursor))),
                  punctuation.contains(scalar) else {
                continue
            }

            let separator = originalNS.substring(with: NSRange(location: tokenEnd, length: cursor - tokenEnd))
            let mark = String(Character(scalar))
            result = result.replacingOccurrences(
                of: protectedToken + mark,
                with: protectedToken + separator + mark
            )
        }

        return result
    }

    private func protectedTokenLooksLikeURL(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("www.")
    }

    private func mergedIssues(_ issues: [OverlayIssue]) -> [OverlayIssue] {
        let sorted = issues.sorted { lhs, rhs in
            if lhs.localRange.location != rhs.localRange.location {
                return lhs.localRange.location < rhs.localRange.location
            }
            return OverlayIssue.priority(of: lhs.category) < OverlayIssue.priority(of: rhs.category)
        }
        var accepted: [OverlayIssue] = []
        for issue in sorted {
            if let last = accepted.last,
               NSIntersectionRange(last.localRange, issue.localRange).length > 0 {
                if OverlayIssue.priority(of: issue.category) < OverlayIssue.priority(of: last.category) {
                    accepted.removeLast()
                    accepted.append(issue)
                }
                continue
            }
            accepted.append(issue)
        }
        return accepted
    }

    private func isSuspiciousFixSuggestion(original: String, candidate: String) -> Bool {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty, !trimmedCandidate.isEmpty else { return false }
        if containsMixedLatinCyrillicWord(trimmedCandidate) && !containsMixedLatinCyrillicWord(trimmedOriginal) {
            return true
        }
        return hasLocalSpellingIssues(trimmedCandidate) && !hasLocalSpellingIssues(trimmedOriginal)
    }

    private func shouldRejectFixSuggestion(original: String, candidate: String) -> Bool {
        isSuspiciousFixSuggestion(original: original, candidate: candidate)
            || containsUnsafeValidWordSubstitution(original: original, candidate: candidate)
            || containsUnsafeRussianWordMutation(original: original, candidate: candidate)
            || introducesSuspiciousDuplicatePunctuation(original: original, candidate: candidate)
            || wouldRevertRecentRewrite(original: original, candidate: candidate)
    }

    private func containsUnsafeValidWordSubstitution(original: String, candidate: String) -> Bool {
        let originalWords = wordsForHeuristicChecks(in: original)
        let candidateWords = wordsForHeuristicChecks(in: candidate)
        guard originalWords.count == candidateWords.count,
              !originalWords.isEmpty,
              !hasLocalSpellingIssues(original),
              !hasLocalSpellingIssues(candidate) else {
            return false
        }

        var changed: [(String, String)] = []
        for (lhs, rhs) in zip(originalWords, candidateWords) {
            if lhs.caseInsensitiveCompare(rhs) != .orderedSame {
                changed.append((lhs, rhs))
            }
        }
        guard changed.count == 1, let pair = changed.first else { return false }
        let lhs = pair.0.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        let rhs = pair.1.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        guard isMostlyLatinWord(lhs), isMostlyLatinWord(rhs) else { return false }
        guard lhs.count >= 3, rhs.count >= 3 else { return false }
        if isSafeInflectionChange(original: lhs, candidate: rhs) {
            return false
        }
        if isCaseOnlyChange(lhs, rhs) {
            return false
        }
        textoraDiagLog(
            "aiRewrite",
            "reject fix: unsafe valid-word substitution \(textoraDiagPreview(lhs))->\(textoraDiagPreview(rhs))"
        )
        return true
    }

    private func wordsForHeuristicChecks(in text: String) -> [String] {
        let pattern = #"[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё'’_-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private func isMostlyLatinWord(_ word: String) -> Bool {
        let scalars = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { scalar in
            (0x0041...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
        }
    }

    private func isSafeInflectionChange(original: String, candidate: String) -> Bool {
        let lhs = original.lowercased()
        let rhs = candidate.lowercased()
        if rhs.hasPrefix(lhs), rhs.count - lhs.count <= 4 {
            return true
        }
        if lhs.hasPrefix(rhs), lhs.count - rhs.count <= 4 {
            return true
        }
        return false
    }

    private func isCaseOnlyChange(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased() && lhs != rhs
    }

    private func containsUnsafeRussianWordMutation(original: String, candidate: String) -> Bool {
        let originalWords = cyrillicWords(in: original).filter { $0.count >= 6 }
        guard !originalWords.isEmpty else { return false }
        let candidateWords = cyrillicWords(in: candidate)
        let candidateSet = Set(candidateWords.map { $0.lowercased() })

        for originalWord in originalWords {
            let lower = originalWord.lowercased()
            guard !candidateSet.contains(lower) else { continue }

            let nearest = candidateWords
                .filter { abs($0.count - lower.count) <= 2 }
                .min { lhs, rhs in
                    russianWordEditDistance(lower, lhs.lowercased(), maxDistance: 3)
                        < russianWordEditDistance(lower, rhs.lowercased(), maxDistance: 3)
                }

            guard let nearest else { return true }
            if !isSafeRussianWordCorrection(from: lower, to: nearest.lowercased()) {
                return true
            }
        }
        return false
    }

    private func cyrillicWords(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isCyrillicLetter(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private func isSafeRussianWordCorrection(from original: String, to corrected: String) -> Bool {
        guard original != corrected else { return true }
        guard abs(original.count - corrected.count) <= 2 else { return false }
        let edits = russianWordEdits(from: original, to: corrected, maxDistance: 2)
        guard !edits.isEmpty, edits.count <= 2 else { return false }
        return edits.allSatisfy { edit in
            switch edit {
            case .insert, .delete, .transpose:
                return true
            case let .substitute(lhs, rhs):
                return isRussianVowel(lhs) && isRussianVowel(rhs)
                    || (lhs == "е" && rhs == "ё")
                    || (lhs == "ё" && rhs == "е")
            }
        }
    }

    private enum RussianWordEdit {
        case insert(Character)
        case delete(Character)
        case substitute(Character, Character)
        case transpose(Character, Character)
    }

    private func russianWordEdits(
        from original: String,
        to corrected: String,
        maxDistance: Int
    ) -> [RussianWordEdit] {
        let source = Array(original)
        let target = Array(corrected)
        var edits: [RussianWordEdit] = []
        var sourceIndex = 0
        var targetIndex = 0

        while sourceIndex < source.count || targetIndex < target.count {
            if sourceIndex < source.count,
               targetIndex < target.count,
               source[sourceIndex] == target[targetIndex] {
                sourceIndex += 1
                targetIndex += 1
                continue
            }

            if sourceIndex + 1 < source.count,
               targetIndex + 1 < target.count,
               source[sourceIndex] == target[targetIndex + 1],
               source[sourceIndex + 1] == target[targetIndex] {
                edits.append(.transpose(source[sourceIndex], source[sourceIndex + 1]))
                sourceIndex += 2
                targetIndex += 2
            } else if sourceIndex + 1 < source.count,
                      targetIndex < target.count,
                      source[sourceIndex + 1] == target[targetIndex] {
                edits.append(.delete(source[sourceIndex]))
                sourceIndex += 1
            } else if sourceIndex < source.count,
                      targetIndex + 1 < target.count,
                      source[sourceIndex] == target[targetIndex + 1] {
                edits.append(.insert(target[targetIndex]))
                targetIndex += 1
            } else if sourceIndex < source.count,
                      targetIndex < target.count {
                edits.append(.substitute(source[sourceIndex], target[targetIndex]))
                sourceIndex += 1
                targetIndex += 1
            } else if sourceIndex < source.count {
                edits.append(.delete(source[sourceIndex]))
                sourceIndex += 1
            } else if targetIndex < target.count {
                edits.append(.insert(target[targetIndex]))
                targetIndex += 1
            }

            if edits.count > maxDistance {
                return edits
            }
        }
        return edits
    }

    private func russianWordEditDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for leftIndex in 1...left.count {
            current[0] = leftIndex
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            if rowMinimum > maxDistance {
                return maxDistance + 1
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private func isCyrillicLetter(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.letters.contains(scalar)
            && ((0x0400...0x04FF).contains(scalar.value) || (0x0500...0x052F).contains(scalar.value))
    }

    private func isRussianVowel(_ character: Character) -> Bool {
        ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я"].contains(character)
    }

    private func isReasonableStyleIssue(original: String, candidate: String) -> Bool {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty, !trimmedCandidate.isEmpty else { return false }
        guard normalized(trimmedOriginal) != normalized(trimmedCandidate) else { return false }
        if containsUnsafeRussianWordMutation(original: trimmedOriginal, candidate: trimmedCandidate) {
            return false
        }
        if stripsToSameAlphanumericCore(trimmedOriginal, trimmedCandidate) {
            return false
        }
        let originalWords = wordCount(in: trimmedOriginal)
        let candidateWords = wordCount(in: trimmedCandidate)
        if max(originalWords, candidateWords) < 3 {
            return false
        }
        let originalLetters = letterCount(in: trimmedOriginal)
        let candidateLetters = letterCount(in: trimmedCandidate)
        if max(originalLetters, candidateLetters) < 10 {
            return false
        }
        return true
    }

    private func stripsToSameAlphanumericCore(_ lhs: String, _ rhs: String) -> Bool {
        normalizeAlphanumericCore(lhs) == normalizeAlphanumericCore(rhs)
    }

    private func normalizeAlphanumericCore(_ text: String) -> String {
        let parts = text.unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return String(scalar).lowercased()
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return " "
            }
            return nil
        }
        return parts.joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wordCount(in text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    private func letterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { partial, scalar in
            partial + (CharacterSet.letters.contains(scalar) ? 1 : 0)
        }
    }

    private func introducesSuspiciousDuplicatePunctuation(original: String, candidate: String) -> Bool {
        let pattern = "([,;:!?])\\1+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let originalSet = Set(regex.matches(in: original, range: NSRange(location: 0, length: (original as NSString).length)).map {
            (original as NSString).substring(with: $0.range)
        })
        let candidateMatches = regex.matches(
            in: candidate,
            range: NSRange(location: 0, length: (candidate as NSString).length)
        )
        for match in candidateMatches {
            let duplicated = (candidate as NSString).substring(with: match.range)
            if !originalSet.contains(duplicated) {
                return true
            }
        }
        return false
    }

    private func rememberAppliedRewrite(original: String, rewritten: String) {
        pruneRecentAppliedRewrites()
        let fromKey = normalized(original)
        let toKey = normalized(rewritten)
        guard !fromKey.isEmpty, !toKey.isEmpty, fromKey != toKey else { return }
        recentAppliedRewrites.removeAll { $0.fromKey == fromKey && $0.toKey == toKey }
        recentAppliedRewrites.append(
            RecentAppliedRewrite(fromKey: fromKey, toKey: toKey, recordedAt: Date())
        )
        if recentAppliedRewrites.count > recentAppliedRewriteCap {
            recentAppliedRewrites.removeFirst(recentAppliedRewrites.count - recentAppliedRewriteCap)
        }
    }

    private func wouldRevertRecentRewrite(original: String, candidate: String) -> Bool {
        pruneRecentAppliedRewrites()
        let currentKey = normalized(original)
        let candidateKey = normalized(candidate)
        guard !currentKey.isEmpty, !candidateKey.isEmpty, currentKey != candidateKey else {
            return false
        }
        return recentAppliedRewrites.contains {
            $0.fromKey == candidateKey && $0.toKey == currentKey
        }
    }

    private func pruneRecentAppliedRewrites() {
        let now = Date()
        recentAppliedRewrites.removeAll {
            now.timeIntervalSince($0.recordedAt) > recentAppliedRewriteTTL
        }
    }

    private func isMeaningfulForAutoCheck(_ text: String) -> Bool {
        let visibleText = textWithoutProtectedTokens(text)
        if containsMixedLatinCyrillicWord(visibleText) {
            // Common typo class: visually similar Latin/Cyrillic letters in one word.
            return true
        }
        let words = visibleText.split { $0.isWhitespace }.filter { !$0.isEmpty }
        // Single real word (e.g. "Helo"): still run auto-check — two-word rule was hiding obvious typos.
        if words.count == 1 {
            let w = String(words[0])
            guard w.count >= 4 else { return false }
            let letterCount = w.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letterCount >= 3 else { return false }
            let nonSpace = w.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            guard nonSpace > 0 else { return false }
            return Double(letterCount) / Double(nonSpace) >= 0.75
        }
        if words.count < 2 { return false }

        let letterCount = visibleText.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let nonSpaceCount = visibleText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard nonSpaceCount > 0 else { return false }
        let letterRatio = Double(letterCount) / Double(nonSpaceCount)
        return letterRatio >= 0.55
    }

    private func containsMixedLatinCyrillicWord(_ text: String) -> Bool {
        let ns = text as NSString
        let protectedRanges = protectedTokenRanges(in: text)
        var i = 0
        while i < ns.length {
            while i < ns.length {
                let ch = ns.character(at: i)
                guard let scalar = UnicodeScalar(ch), CharacterSet.letters.contains(scalar) else { break }
                i += 1
            }
            let start = i
            var hasLatin = false
            var hasCyrillic = false
            while i < ns.length {
                let ch = ns.character(at: i)
                guard let scalar = UnicodeScalar(ch), CharacterSet.letters.contains(scalar) else { break }
                let v = scalar.value
                if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                    hasLatin = true
                } else if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                    hasCyrillic = true
                }
                i += 1
            }
            let range = NSRange(location: start, length: max(0, i - start))
            if range.length > 0,
               !protectedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }),
               hasLatin && hasCyrillic {
                return true
            }
            i += 1
        }
        return false
    }

    private func protectedTokenRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let pattern = #"(?i)(?:https?://|www\.)\S+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|[@#][\p{L}\p{N}_]+(?:[._-][\p{L}\p{N}_]+)*|\+?\d[\d\s().-]{2,}\d|\b\d+(?:[.,:/-]\d+)*\b|\b[\w.-]+\.(?:com|net|org|io|dev|app|ai|co|ru|ua|by|de|fr|es|it|pl|nl|uk)\b\S*"#
        var ranges: [NSRange] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            ranges.append(contentsOf: regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range))
        }
        ranges.append(contentsOf: emojiRanges(in: text))
        for index in 0..<ns.length where isSlackInvisibleMarker(ns.character(at: index)) {
            ranges.append(NSRange(location: index, length: 1))
        }
        return ranges.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }
    }

    private func correctionScope(in text: String) -> CorrectionScope? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let protectedRanges = protectedTokenRanges(in: text).sorted { $0.location < $1.location }
        guard !protectedRanges.isEmpty else {
            let trimmed = trimmedRange(NSRange(location: 0, length: ns.length), in: ns)
            guard trimmed.length > 0 else { return nil }
            return CorrectionScope(text: ns.substring(with: trimmed), range: trimmed)
        }

        var segments: [CorrectionScope] = []
        var cursor = 0
        for protectedRange in protectedRanges {
            if protectedRange.location > cursor {
                appendCorrectionSegment(
                    NSRange(location: cursor, length: protectedRange.location - cursor),
                    in: ns,
                    to: &segments
                )
            }
            cursor = max(cursor, protectedRange.location + protectedRange.length)
        }
        if cursor < ns.length {
            appendCorrectionSegment(NSRange(location: cursor, length: ns.length - cursor), in: ns, to: &segments)
        }

        return segments
            .filter { isMeaningfulForAutoCheck($0.text) || hasLocalSpellingIssues($0.text) }
            .max { lhs, rhs in
                correctionScore(lhs.text) < correctionScore(rhs.text)
            }
    }

    private func appendCorrectionSegment(_ range: NSRange, in text: NSString, to segments: inout [CorrectionScope]) {
        let trimmed = trimmedRange(range, in: text)
        guard trimmed.length > 0 else { return }
        segments.append(CorrectionScope(text: text.substring(with: trimmed), range: trimmed))
    }

    /// Split the full focused text into ALL meaningful segments ordered by
    /// position. Unlike `correctionScope`, this does not pick the single
    /// "best" scope — the overlay must consider every paragraph/sentence in
    /// the composer so that a URL (or any protected token) sitting between
    /// two sentences does not hide the one that comes after it.
    ///
    /// Splitting rules:
    /// 1. Protected tokens (URLs, emails, @mentions, #channels, phones) cut
    ///    the text into top-level chunks.
    /// 2. Each chunk is further split on newlines — a multi-line composer
    ///    usually has one logical sentence per line (e.g. bullet lists in
    ///    Slack), and each line is rewritten independently.
    /// 3. Segments that are too short / noisy to auto-check are dropped
    ///    (same filter as `correctionScope`).
    private func correctionSegments(in text: String) -> [CorrectionScope] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let protectedRanges = protectedTokenRanges(in: text).sorted { $0.location < $1.location }

        var rawChunks: [NSRange] = []
        if protectedRanges.isEmpty {
            rawChunks.append(NSRange(location: 0, length: ns.length))
        } else {
            var cursor = 0
            for protectedRange in protectedRanges {
                if protectedRange.location > cursor {
                    rawChunks.append(NSRange(location: cursor, length: protectedRange.location - cursor))
                }
                cursor = max(cursor, protectedRange.location + protectedRange.length)
            }
            if cursor < ns.length {
                rawChunks.append(NSRange(location: cursor, length: ns.length - cursor))
            }
        }

        var segments: [CorrectionScope] = []
        for chunkRange in rawChunks {
            splitChunkByNewlinesAndSentences(chunkRange, in: ns, into: &segments)
        }

        return segments
            .filter { isMeaningfulForAutoCheck($0.text) || hasLocalSpellingIssues($0.text) }
            .sorted { $0.range.location < $1.range.location }
    }

    private func splitChunkByNewlinesAndSentences(
        _ chunkRange: NSRange,
        in text: NSString,
        into segments: inout [CorrectionScope]
    ) {
        guard chunkRange.length > 0 else { return }
        var cursor = chunkRange.location
        let end = chunkRange.location + chunkRange.length
        while cursor < end {
            let searchRange = NSRange(location: cursor, length: end - cursor)
            let newlineRange = text.range(of: "\n", options: [], range: searchRange)
            let lineEnd = newlineRange.location == NSNotFound ? end : newlineRange.location
            splitLineBySentences(NSRange(location: cursor, length: lineEnd - cursor), in: text, into: &segments)
            if newlineRange.location == NSNotFound {
                break
            }
            cursor = newlineRange.location + newlineRange.length
        }
    }

    private func splitLineBySentences(
        _ lineRange: NSRange,
        in text: NSString,
        into segments: inout [CorrectionScope]
    ) {
        guard lineRange.length > 0 else { return }
        let lineEnd = lineRange.location + lineRange.length
        var sentenceStart = lineRange.location
        var cursor = lineRange.location
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if isSentenceTerminator(ch) {
                var next = cursor + 1
                while next < lineEnd, isClosingSentencePunctuation(text.character(at: next)) {
                    next += 1
                }
                var whitespaceEnd = next
                while whitespaceEnd < lineEnd, isWhitespace(text.character(at: whitespaceEnd)) {
                    whitespaceEnd += 1
                }
                if whitespaceEnd > next {
                    appendCorrectionSegment(
                        NSRange(location: sentenceStart, length: next - sentenceStart),
                        in: text,
                        to: &segments
                    )
                    sentenceStart = whitespaceEnd
                    cursor = whitespaceEnd
                    continue
                }
            }
            cursor += 1
        }
        if sentenceStart < lineEnd {
            appendCorrectionSegment(
                NSRange(location: sentenceStart, length: lineEnd - sentenceStart),
                in: text,
                to: &segments
            )
        }
    }

    private func isSentenceTerminator(_ codeUnit: unichar) -> Bool {
        codeUnit == 46 || codeUnit == 33 || codeUnit == 63
    }

    private func isClosingSentencePunctuation(_ codeUnit: unichar) -> Bool {
        switch codeUnit {
        case 34, 39, 41, 93, 125, 0x00BB, 0x2019, 0x201D:
            return true
        default:
            return false
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

    private func segmentCacheKey(_ text: String) -> String {
        normalized(text)
    }

    private func cacheSegmentResult(_ result: SegmentEvaluationResult, for key: String) {
        if segmentEvaluationCache[key] == nil {
            segmentEvaluationCacheOrder.append(key)
            while segmentEvaluationCacheOrder.count > segmentEvaluationCacheCap {
                let old = segmentEvaluationCacheOrder.removeFirst()
                segmentEvaluationCache.removeValue(forKey: old)
            }
        }
        segmentEvaluationCache[key] = result
    }

    private func invalidateSegmentCache(for text: String) {
        let key = segmentCacheKey(text)
        segmentEvaluationCache.removeValue(forKey: key)
        segmentEvaluationCacheOrder.removeAll { $0 == key }
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

    private func correctionScore(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { score, scalar in
            CharacterSet.letters.contains(scalar) ? score + 2 : score + 1
        }
    }

    private func scopedFocusedContext(
        _ context: TextAccessService.FocusedTextContext,
        scope: CorrectionScope
    ) -> TextAccessService.FocusedTextContext {
        let anchor = scopedAnchor(for: context, scope: scope)
        let frame = isSlackBundle(context.targetBundleID) ? anchor.rect : context.frame
        return TextAccessService.FocusedTextContext(
            text: scope.text,
            frame: frame,
            usesSelection: false,
            selectedRange: nil,
            targetElement: context.targetElement,
            targetAppPID: context.targetAppPID,
            targetBundleID: context.targetBundleID,
            anchor: anchor,
            textFragments: scopedFragments(from: context.textFragments, scope: scope)
        )
    }

    private func scopedAnchor(
        for context: TextAccessService.FocusedTextContext,
        scope: CorrectionScope
    ) -> TextAccessService.TextAnchor {
        guard isSlackBundle(context.targetBundleID) else { return context.anchor }
        let base = !context.anchor.rect.isEmpty ? context.anchor.rect : context.frame
        guard !base.isEmpty, base.height > 48 else { return context.anchor }

        let text = context.text as NSString
        let metrics = slackScopedLineMetrics(in: text, scope: scope, base: base)
        guard metrics.lineCount > 1 else { return context.anchor }

        let lineHeight = min(max(base.height / CGFloat(metrics.lineCount), 18), 34)
        let lineY = max(base.minY, base.maxY - CGFloat(metrics.lineIndex + 1) * lineHeight)
        let lineRect = CGRect(
            x: base.minX,
            y: lineY,
            width: base.width,
            height: lineHeight
        )
        return TextAccessService.TextAnchor(
            rect: lineRect,
            source: .axElementFrame,
            confidence: .approximate,
            rawRect: context.anchor.rawRect
        )
    }

    private func slackScopedLineMetrics(
        in text: NSString,
        scope: CorrectionScope,
        base: CGRect
    ) -> TextLineMetrics {
        let metrics = textLineMetrics(in: text, issueLocation: scope.range.location)
        guard base.height > 60 else { return metrics }

        let fullText = text as String
        let protectedBefore = protectedTokenRanges(in: fullText)
            .filter { $0.location < scope.range.location }
            .map { text.substring(with: $0) }
            .filter { token in
                let lower = token.lowercased()
                return lower.hasPrefix("http://")
                    || lower.hasPrefix("https://")
                    || lower.hasPrefix("www.")
            }
            .count
        guard protectedBefore > 0 else { return metrics }

        let shouldTreatProtectedTokensAsRows = protectedBefore >= 2
            || metrics.lineCount > 1
            || base.height > 84
        guard shouldTreatProtectedTokensAsRows else { return metrics }

        let estimatedLineCount = max(metrics.lineCount, protectedBefore + 1)
        let estimatedLineIndex = max(metrics.lineIndex, min(estimatedLineCount - 1, protectedBefore))
        return TextLineMetrics(
            lineIndex: estimatedLineIndex,
            column: metrics.column,
            lineLength: metrics.lineLength,
            lineCount: estimatedLineCount
        )
    }

    private func scopedFragments(
        from fragments: [TextAccessService.TextFragment],
        scope: CorrectionScope
    ) -> [TextAccessService.TextFragment] {
        let scopeNS = scope.text as NSString
        return fragments.compactMap { fragment -> TextAccessService.TextFragment? in
            let overlap = NSIntersectionRange(fragment.range, scope.range)
            guard overlap.length > 0 else { return nil }
            let localLocation = max(0, overlap.location - scope.range.location)
            let localLength = max(0, min(overlap.length, scopeNS.length - localLocation))
            guard localLength > 0 else { return nil }
            guard let rect = TextoraCharacterGeometry.rect(for: overlap, in: fragment) else {
                return nil
            }
            return TextAccessService.TextFragment(
                text: scopeNS.substring(with: NSRange(location: localLocation, length: localLength)),
                range: NSRange(location: localLocation, length: localLength),
                rect: rect
            )
        }
    }

    private func textWithoutProtectedTokens(_ text: String) -> String {
        var result = text
        for range in protectedTokenRanges(in: text).reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: " ")
        }
        return result
    }

    private func preservesProtectedTokens(original: String, candidate: String) -> Bool {
        protectedTokens(in: original) == protectedTokens(in: candidate)
    }

    /// Splices a single audit issue's replacement into the segment text
    /// at its declared local range. Used to build the "primary
    /// suggestion" string that legacy apply code still consumes through
    /// `latestSuggestion` / `latestIssueRange`.
    private func applyIssueToSegment(_ segmentText: String, issue: OverlayIssue) -> String {
        let ns = segmentText as NSString
        let safeStart = max(0, min(issue.localRange.location, ns.length))
        let safeLen = max(0, min(issue.localRange.length, ns.length - safeStart))
        let safeRange = NSRange(location: safeStart, length: safeLen)
        return ns.replacingCharacters(in: safeRange, with: issue.replacement)
    }

    /// Grows a diff tuple `(range, replacement)` out to whole-word
    /// boundaries so the rendered underline and the hover card's word-
    /// level diff agree on what span they are describing. The tiny
    /// `"n" → "p"` diff inside `"tulin" → "tulip"` becomes a
    /// `"tulin" → "tulip"` edit with the underline covering the whole
    /// word instead of a single glyph somewhere inside it.
    ///
    /// Keeps `range` and `replacement` in lockstep — because the
    /// characters we add on each side come from the common prefix /
    /// suffix shared by segment and candidate, we can read them
    /// straight off the segment without touching the (possibly long)
    /// candidate string.
    private func expandAtomicEditToWordBounds(
        segment: String,
        range: NSRange,
        replacement: String
    ) -> (range: NSRange, replacement: String) {
        let ns = segment as NSString
        let total = ns.length
        guard range.location >= 0, NSMaxRange(range) <= total else {
            return (range, replacement)
        }
        let isWordLike: (unichar) -> Bool = { cu in
            guard let s = UnicodeScalar(UInt32(cu)) else { return false }
            return CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s)
        }
        var start = range.location
        var end = NSMaxRange(range)
        // Extend left while the preceding char is word-like — pulls the
        // edit back to the beginning of the word that contains the
        // diff point.
        while start > 0, isWordLike(ns.character(at: start - 1)) {
            start -= 1
        }
        // Extend right while the next char is word-like — pulls the
        // edit forward to the end of the affected word.
        while end < total, isWordLike(ns.character(at: end)) {
            end += 1
        }
        let expandedRange = NSRange(location: start, length: max(0, end - start))
        guard expandedRange != range else { return (range, replacement) }
        let leftPad = ns.substring(with: NSRange(location: start, length: range.location - start))
        let rightPad = ns.substring(
            with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))
        )
        let expandedReplacement = leftPad + replacement + rightPad
        return (expandedRange, expandedReplacement)
    }

    /// Signature used to remember that the user dismissed an issue via
    /// Skip. Intentionally tied to the segment's normalized text so
    /// that once the segment is edited (even slightly) the user sees a
    /// fresh batch of suggestions — Skip is a "not for this version of
    /// the sentence" gesture, not a permanent mute.
    private func skipSignature(
        segmentSignature: String,
        issue: OverlayIssue,
        spanText: String
    ) -> String {
        "\(segmentSignature)|\(issue.category.rawValue)|\(normalized(spanText))|\(normalized(issue.replacement))"
    }

    /// Picks the "primary" issue inside a segment — the one that drives
    /// the floating-bubble ring color, the legacy `latestSuggestion`,
    /// and the fallback hover-card when the user hovers the floating
    /// icon instead of a specific underline. With Smart AI enabled, the
    /// text style can promote a style rewrite above Fix; within the same
    /// category we prefer the earliest span.
    private func primaryIssue(in issues: [OverlayIssue]) -> OverlayIssue? {
        primaryIssue(in: issues, original: latestContext?.text)
    }

    private func primaryIssue(in issues: [OverlayIssue], original: String?) -> OverlayIssue? {
        if smartAIEnabled,
           let original,
           let preferred = preferredOperation(for: original, available: Set(issues.map(\.category))),
           let smartPrimary = issues
            .filter({ $0.category == preferred })
            .min(by: { $0.localRange.location < $1.localRange.location }) {
            return smartPrimary
        }
        return issues.min { lhs, rhs in
            let lp = OverlayIssue.priority(of: lhs.category)
            let rp = OverlayIssue.priority(of: rhs.category)
            if lp != rp { return lp < rp }
            return lhs.localRange.location < rhs.localRange.location
        }
    }

    private func shiftedIssue(
        _ issue: OverlayIssue,
        by offset: Int,
        sourceRange: NSRange
    ) -> OverlayIssue {
        OverlayIssue(
            id: issue.id,
            patch: TextPatch(
                id: issue.patch.id,
                start: max(0, issue.localRange.location + offset),
                end: max(0, issue.localRange.location + offset) + issue.localRange.length,
                originalText: issue.patch.originalText,
                replacement: issue.replacement,
                reason: issue.reason
            ),
            category: issue.category,
            segmentSignature: issue.segmentSignature,
            sourceSegmentRange: sourceRange
        )
    }

    private func overlaySuggestions(for issues: [OverlayIssue], in text: String) -> [OverlaySuggestion] {
        var seen = Set<String>()
        var rebuilt: [OverlaySuggestion] = []
        let sortedIssues = issues.sorted(by: { lhs, rhs in
            let lp = OverlayIssue.priority(of: lhs.category)
            let rp = OverlayIssue.priority(of: rhs.category)
            if lp != rp { return lp < rp }
            return lhs.localRange.location < rhs.localRange.location
        })
        for issue in sortedIssues {
            guard !seen.contains(issue.category.rawValue) else { continue }
            seen.insert(issue.category.rawValue)
            rebuilt.append(
                OverlaySuggestion(
                    operation: issue.category,
                    text: applyIssueToSegment(text, issue: issue)
                )
            )
        }
        return rankedSuggestions(rebuilt, original: text)
    }

    /// Minimal diff envelope between `original` and `candidate`
    /// expressed as the range inside `original` that must change and
    /// the substring of `candidate` that replaces it. Uses UTF-16 code
    /// units so the result plugs straight into `issueBoundsList` and
    /// the AX range APIs without re-indexing. Returns nil when the two
    /// strings are identical.
    private func diffEnvelope(original: String, candidate: String) -> (range: NSRange, replacement: String)? {
        let orig = original as NSString
        let cand = candidate as NSString
        let oLen = orig.length
        let cLen = cand.length
        guard oLen > 0 || cLen > 0 else { return nil }
        var prefix = 0
        let maxPrefix = min(oLen, cLen)
        while prefix < maxPrefix
                && orig.character(at: prefix) == cand.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(oLen - prefix, cLen - prefix)
        while suffix < maxSuffix
                && orig.character(at: oLen - 1 - suffix) == cand.character(at: cLen - 1 - suffix) {
            suffix += 1
        }
        let oRangeLen = max(0, oLen - prefix - suffix)
        let cRangeLen = max(0, cLen - prefix - suffix)
        guard oRangeLen > 0 || cRangeLen > 0 else { return nil }
        let replacement = cand.substring(with: NSRange(location: prefix, length: cRangeLen))
        return (NSRange(location: prefix, length: oRangeLen), replacement)
    }

    /// Splits the diff between `original` and `candidate` into one or
    /// more atomic edits by recursively finding long common
    /// substrings (≥ `minGap` UTF-16 units) inside the diff envelope
    /// and cutting at them. A single Formal rewrite that touches both
    /// `They're → They are` and `figure out → determine` thus emits
    /// two separate (range, replacement) entries instead of a single
    /// envelope spanning the whole sentence.
    ///
    /// Each returned tuple's `range` is anchored to the original
    /// string's UTF-16 indexing — safe to feed straight into
    /// `issueBoundsList` and AX range APIs.
    private func atomicDiffs(
        original: String,
        candidate: String,
        minGap: Int = 12
    ) -> [(range: NSRange, replacement: String)] {
        guard let envelope = diffEnvelope(original: original, candidate: candidate) else {
            return []
        }
        let origNS = original as NSString
        let origMid = envelope.range.length > 0
            ? origNS.substring(with: envelope.range)
            : ""
        let candMid = envelope.replacement
        _ = candidate
        // No room to split — return as-is.
        guard origMid.count >= minGap, candMid.count >= minGap else {
            return [envelope]
        }
        guard let common = longestCommonSubstring(origMid, candMid),
              common.length >= minGap else {
            return [envelope]
        }

        let leftOrig = (origMid as NSString).substring(to: common.origStart)
        let rightOrig = (origMid as NSString).substring(from: common.origStart + common.length)
        let leftCand = (candMid as NSString).substring(to: common.candStart)
        let rightCand = (candMid as NSString).substring(from: common.candStart + common.length)

        var out: [(range: NSRange, replacement: String)] = []
        let leftDiffs = atomicDiffs(original: leftOrig, candidate: leftCand, minGap: minGap)
        for d in leftDiffs {
            // shift relative ranges to absolute (relative to `original`)
            let shifted = NSRange(
                location: d.range.location + envelope.range.location,
                length: d.range.length
            )
            out.append((shifted, d.replacement))
        }
        let rightDiffs = atomicDiffs(original: rightOrig, candidate: rightCand, minGap: minGap)
        let rightOffset = envelope.range.location + common.origStart + common.length
        for d in rightDiffs {
            let shifted = NSRange(
                location: d.range.location + rightOffset,
                length: d.range.length
            )
            out.append((shifted, d.replacement))
        }
        return out.isEmpty ? [envelope] : out
    }

    /// Plain O(n*m) longest-common-substring — fine for our segment
    /// sizes (≲ 200 chars). Returns the start indices in both strings
    /// (UTF-16 code units) and the matched length, or nil when the
    /// inputs share no characters.
    private func longestCommonSubstring(
        _ a: String,
        _ b: String
    ) -> (origStart: Int, candStart: Int, length: Int)? {
        let aNS = a as NSString
        let bNS = b as NSString
        let aLen = aNS.length
        let bLen = bNS.length
        guard aLen > 0, bLen > 0 else { return nil }
        var prev = [Int](repeating: 0, count: bLen + 1)
        var curr = [Int](repeating: 0, count: bLen + 1)
        var bestLen = 0
        var bestAEnd = 0
        var bestBEnd = 0
        for i in 1...aLen {
            let ca = aNS.character(at: i - 1)
            for j in 1...bLen {
                if ca == bNS.character(at: j - 1) {
                    curr[j] = prev[j - 1] + 1
                    if curr[j] > bestLen {
                        bestLen = curr[j]
                        bestAEnd = i
                        bestBEnd = j
                    }
                } else {
                    curr[j] = 0
                }
            }
            swap(&prev, &curr)
            for j in 0...bLen { curr[j] = 0 }
        }
        guard bestLen > 0 else { return nil }
        return (bestAEnd - bestLen, bestBEnd - bestLen, bestLen)
    }

    /// Converts the list of whole-segment rewrites that
    /// `overlaySuggestions` returned into per-span `OverlayIssue`
    /// entries. Each suggestion produces at most one issue whose
    /// `localRange` is the minimal diff envelope against the segment
    /// and whose `replacement` is the corresponding substring of the
    /// rewrite. Overlapping issues collapse to the highest-priority
    /// category (Fix > Formal > Humanize > Shorten) so the UI never
    /// paints two different colored underlines on top of each other.
    private func deriveIssues(
        fromSegment segment: String,
        suggestions: [OverlaySuggestion]
    ) -> [OverlayIssue] {
        let segmentNS = segment as NSString
        let segmentSignature = segmentCacheKey(segment)
        var candidates: [OverlayIssue] = []
        for suggestion in suggestions {
            // Final safety net at the suggestion level: variants that
            // mangle protected tokens (URLs, currencies, units, etc.)
            // are dropped wholesale before we split them up.
            if !preservesProtectedTokens(original: segment, candidate: suggestion.text)
                || wouldRevertRecentRewrite(original: segment, candidate: suggestion.text) {
                continue
            }
            // Split each whole-segment rewrite into one or more
            // atomic edits so a Formal/Shorten/Humanize variant that
            // touches two separate spots produces two underlines
            // instead of one giant envelope across the sentence.
            let edits = atomicDiffs(original: segment, candidate: suggestion.text)
            for edit in edits {
                // Widen each atomic edit out to whole-word boundaries
                // before we build the issue — keeps the underline,
                // the hit-test, and the hover card's word-level diff
                // in visual agreement.
                let expanded = expandAtomicEditToWordBounds(
                    segment: segment,
                    range: edit.range,
                    replacement: edit.replacement
                )
                guard expanded.range.location >= 0,
                      NSMaxRange(expanded.range) <= segmentNS.length else { continue }
                let span = expanded.range.length > 0
                    ? segmentNS.substring(with: expanded.range)
                    : ""
                // Skip no-op atomic edits (e.g. whitespace-only).
                if normalized(span) == normalized(expanded.replacement) {
                    continue
                }
                if wouldRevertRecentRewrite(original: span, candidate: expanded.replacement) {
                    continue
                }
                if suggestion.operation == .fixGrammar,
                   shouldRejectFixSuggestion(original: span, candidate: expanded.replacement) {
                    continue
                }
                // Per-issue length sanity: an atomic edit should be a
                // local change. Anything still spanning ≥ 70% of the
                // segment after splitting is almost certainly a
                // wholesale rewrite — leave it to the popup, don't
                // paint a useless line under the entire paragraph.
                if expanded.range.length > 0,
                   Double(expanded.range.length) / Double(max(1, segmentNS.length)) >= 0.7 {
                    continue
                }
                let issue = OverlayIssue(
                    localRange: expanded.range,
                    originalText: span,
                    category: suggestion.operation,
                    replacement: expanded.replacement,
                    reason: nil,
                    segmentSignature: segmentSignature,
                    sourceSegmentRange: nil
                )
                if issueBreaksNumberedListMarker(issue, in: segment) {
                    continue
                }
                // Honor previous Skip clicks for this exact span.
                let sig = skipSignature(
                    segmentSignature: segmentSignature,
                    issue: issue,
                    spanText: span
                )
                if skippedIssueSignatures.contains(sig) {
                    continue
                }
                candidates.append(issue)
            }
        }

        // Sort by start, then priority, and drop overlapping
        // lower-priority entries. This mirrors the dedupe we do for
        // `auditIssues` and guarantees each visible underline maps to
        // exactly one category.
        candidates.sort { lhs, rhs in
            if lhs.localRange.location != rhs.localRange.location {
                return lhs.localRange.location < rhs.localRange.location
            }
            return OverlayIssue.priority(of: lhs.category) < OverlayIssue.priority(of: rhs.category)
        }
        var accepted: [OverlayIssue] = []
        for issue in candidates {
            if let last = accepted.last,
               NSIntersectionRange(last.localRange, issue.localRange).length > 0 {
                if OverlayIssue.priority(of: issue.category) < OverlayIssue.priority(of: last.category) {
                    accepted.removeLast()
                    accepted.append(issue)
                }
                continue
            }
            accepted.append(issue)
        }
        return accepted
    }

    private func semanticStyleIssues(
        fromSegment segment: String,
        suggestions: [OverlaySuggestion],
        excludingOperations: Set<RewriteOperation>
    ) -> [OverlayIssue] {
        let segmentNS = segment as NSString
        guard segmentNS.length > 0 else { return [] }
        let segmentSignature = segmentCacheKey(segment)
        var issues: [OverlayIssue] = []
        for suggestion in suggestions {
            guard suggestion.operation != .fixGrammar,
                  !excludingOperations.contains(suggestion.operation) else {
                continue
            }
            let candidate = sanitizedAISuggestion(original: segment, candidate: suggestion.text)
            guard !candidate.isEmpty,
                  normalized(candidate) != normalized(segment),
                  preservesProtectedTokens(original: segment, candidate: candidate),
                  !wouldRevertRecentRewrite(original: segment, candidate: candidate),
                  isReasonableStyleIssue(original: segment, candidate: candidate) else {
                continue
            }
            let issue = OverlayIssue(
                localRange: NSRange(location: 0, length: segmentNS.length),
                originalText: segment,
                category: suggestion.operation,
                replacement: candidate,
                reason: "Sentence-level rewrite",
                segmentSignature: segmentSignature,
                sourceSegmentRange: nil
            )
            if issueBreaksNumberedListMarker(issue, in: segment) {
                continue
            }
            let sig = skipSignature(
                segmentSignature: segmentSignature,
                issue: issue,
                spanText: segment
            )
            if skippedIssueSignatures.contains(sig) {
                continue
            }
            issues.append(issue)
        }
        return issues
    }

    private func protectedTokens(in text: String) -> [String] {
        let ns = text as NSString
        return protectedTokenRanges(in: text).map {
            normalizedProtectedToken(ns.substring(with: $0))
        }
    }

    private func normalizedProtectedToken(_ token: String) -> String {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")
        while let last = trimmed.unicodeScalars.last,
              trailingPunctuation.contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func fixMixedLatinCyrillicWords(in text: String) -> String {
        let protectedRanges = protectedTokenRanges(in: text)
        if !protectedRanges.isEmpty {
            let ns = text as NSString
            var result = ""
            var cursor = 0
            for range in protectedRanges.sorted(by: { $0.location < $1.location }) {
                if range.location > cursor {
                    let chunkRange = NSRange(location: cursor, length: range.location - cursor)
                    result += fixMixedLatinCyrillicWords(in: ns.substring(with: chunkRange))
                }
                result += ns.substring(with: range)
                cursor = range.location + range.length
            }
            if cursor < ns.length {
                result += fixMixedLatinCyrillicWords(in: ns.substring(from: cursor))
            }
            return result
        }

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

    private func normalized(_ text: String) -> String {
        stripSlackInvisibleMarkers(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func stripSlackInvisibleMarkers(from text: String) -> String {
        String(text.unicodeScalars.filter { !isSlackInvisibleMarker($0) })
    }

    private func isSlackInvisibleMarker(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0xFFFC, 0x200B, 0x200C, 0x200D, 0x2060:
            return true
        default:
            return false
        }
    }

    private func isSlackInvisibleMarker(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
        return isSlackInvisibleMarker(scalar)
    }

    private func estimatedChangedRange(original: String, suggestion: String) -> NSRange? {
        let lhs = original as NSString
        let rhs = suggestion as NSString
        guard lhs.length > 0, rhs.length > 0 else { return nil }
        let limit = min(lhs.length, rhs.length)
        var prefix = 0
        while prefix < limit, lhs.character(at: prefix) == rhs.character(at: prefix) {
            prefix += 1
        }
        if prefix == lhs.length, prefix == rhs.length {
            return nil
        }

        var suffix = 0
        while suffix < lhs.length - prefix,
              suffix < rhs.length - prefix,
              lhs.character(at: lhs.length - 1 - suffix) == rhs.character(at: rhs.length - 1 - suffix) {
            suffix += 1
        }

        let changedLength = max(1, lhs.length - prefix - suffix)
        let rawStart = min(prefix, lhs.length - 1)
        let rawEnd = min(lhs.length, prefix + changedLength)
        let expanded = expandedToWordBoundaries(start: rawStart, end: rawEnd, in: lhs)
        return NSRange(location: expanded.start, length: max(1, expanded.end - expanded.start))
    }

    private func expandedToWordBoundaries(start: Int, end: Int, in text: NSString) -> (start: Int, end: Int) {
        var expandedStart = max(0, min(start, text.length))
        var expandedEnd = max(expandedStart, min(end, text.length))

        while expandedStart > 0, isWordLike(text.character(at: expandedStart - 1)) {
            expandedStart -= 1
        }
        while expandedEnd < text.length, isWordLike(text.character(at: expandedEnd)) {
            expandedEnd += 1
        }

        return (expandedStart, max(expandedStart + 1, expandedEnd))
    }

    private func isWordLike(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
        return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }

    private func updateRingColor() {
        guard let panel else { return }
        let root = FloatingButtonView(
            ringColors: ringColors(for: suggestionState),
            isLoading: isEvaluating,
            isHovered: isFloatingHovered,
            showsCheckmark: shouldShowLooksGoodBadge,
            showsSmartAIBadge: smartAIEnabled
        )
        guard let hosting = panel.contentView as? NSHostingView<FloatingButtonView> else { return }
        hosting.rootView = root
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
    }

    /// AX caret/field rects often jitter sub‑pixel when idle; avoid hammering `setFrame` every 200ms.
    private func applyMainBubbleFrameIfChanged(_ nextFrame: CGRect, threshold: CGFloat = 2) {
        let t = threshold
        if abs(nextFrame.origin.x - lastFrame.origin.x) < t,
           abs(nextFrame.origin.y - lastFrame.origin.y) < t,
           abs(nextFrame.width - lastFrame.width) < 0.5,
           abs(nextFrame.height - lastFrame.height) < 0.5 {
            return
        }
        panel?.setFrame(nextFrame, display: true)
        lastFrame = nextFrame
    }

    private func createIssueOverlayPanel() {
        let host = NSHostingView(rootView: FloatingIssueUnderlineView(colors: issueOverlayColors()))
        issueOverlayPanel = makeIssueOverlayPanel(host: host)
    }

    private func makeIssueOverlayPanel(host: NSHostingView<FloatingIssueUnderlineView>) -> NSPanel {
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 8)
        host.autoresizingMask = [.width, .height]
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 8),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = host
        panel.orderOut(nil)
        return panel
    }

    private func issueOverlayPanel(at index: Int) -> NSPanel {
        if index == 0 {
            if issueOverlayPanel == nil {
                createIssueOverlayPanel()
            }
            return issueOverlayPanel!
        }
        let extraIndex = index - 1
        while extraIssueOverlayPanels.count <= extraIndex {
            let host = NSHostingView(rootView: FloatingIssueUnderlineView(colors: issueOverlayColors()))
            extraIssueOverlayPanels.append(makeIssueOverlayPanel(host: host))
        }
        return extraIssueOverlayPanels[extraIndex]
    }

    private func createMarkerPanel() {
        markerPanel = makeMarkerPanel()
    }

    private func makeMarkerPanel() -> NSPanel {
        let host = NSHostingView(
            rootView: FloatingMarkerView(
                onOpen: { [weak self] in
                    guard let self else { return }
                    self.cancelScheduledHoverHide()
                    self.showHoverCard()
                },
                onHoverChanged: { _ in },
                onHoverMoved: {}
            )
        )
        let panel = MarkerHitPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 18),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.contentView = host
        panel.onMarkerHoverChanged = { [weak self] isHovering in
            self?.handleMarkerHover(isHovering)
        }
        panel.onMarkerHoverMoved = { [weak self] in
            self?.handleMarkerHoverMoved()
        }
        panel.orderOut(nil)
        return panel
    }

    private func markerHitPanel(at index: Int) -> NSPanel {
        if index == 0 {
            if markerPanel == nil {
                createMarkerPanel()
            }
            return markerPanel!
        }
        let extraIndex = index - 1
        while extraMarkerPanels.count <= extraIndex {
            extraMarkerPanels.append(makeMarkerPanel())
        }
        return extraMarkerPanels[extraIndex]
    }

    private func updateMarker(caretFrame: CGRect?, fieldFrame: CGRect, anchor: MarkerAnchor) {
        lastMarkerFieldFrame = fieldFrame
        lastMarkerCaretFrame = caretFrame
        guard detailedCorrectionsEnabled else {
            hideIssueOverlayPanelsAndMarkers()
            markerAnchor = anchor
            return
        }
        let shouldShowDetailedMarker = detailedCorrectionsEnabled
            && suggestionState == .needsAttention
            && !latestSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard shouldShowDetailedMarker,
              let context = latestContext,
              context.anchor.source != .clipboardFallback else {
            hideMarkerAndCard()
            return
        }
        let fallback = fallbackIssueFrame(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context,
            issueRange: latestIssueRange
        )

        // Build the list of underline jobs. In the new per-span path
        // each issue contributes its own (frame, color, issueID)
        // entries — possibly several frames if the issue wraps across
        // text-view lines. In the legacy path we render a single
        // multi-color underline derived from `latestIssueRange`.
        struct UnderlineJob {
            let frame: CGRect
            let colors: [Color]
            let issueID: UUID?
            let issueIDs: [UUID]
            let geometry: String
            let source: String
            let style: FloatingIssueMarkerStyle
            let lineFrame: CGRect
            let isLoading: Bool
        }
        var jobs: [UnderlineJob] = []
        if !latestIssues.isEmpty {
            let renderableIssues = issuesToRender(in: context)
            for issue in renderableIssues {
                let geometryTarget = localizedGeometryTarget(for: issue, in: context)
                let useScopedGeometry = shouldUseScopedOverlayGeometry(
                    for: context,
                    geometryTargetAvailable: geometryTarget != nil
                )
                let issueContext = useScopedGeometry ? (geometryTarget?.context ?? context) : context
                let issueRange = useScopedGeometry ? (geometryTarget?.localRange ?? issue.localRange) : issue.localRange
                let fallbackContext = useScopedGeometry ? (geometryTarget?.context ?? issueContext) : issueContext
                let fallbackRange = useScopedGeometry ? (geometryTarget?.localRange ?? issueRange) : issueRange
                let issueFallback = fallbackIssueFrame(
                    caretFrame: caretFrame,
                    fieldFrame: fieldFrame,
                    context: fallbackContext,
                    issueRange: fallbackRange
                )
                let axFrames = textService.issueBoundsList(
                    in: issueContext,
                    localRange: issueRange,
                    fallbackFrame: issueFallback
                )
                let axFramesAreHostFallback = axFrames.count == 1 && approximatelySameRect(axFrames[0], issueFallback)
                let preciseFrames = axFramesAreHostFallback ? nil : usablePreciseIssueFrames(axFrames, fallback: issueFallback)
                let estimatedFrames = hostEstimatedIssueFrames(
                    caretFrame: caretFrame,
                    fieldFrame: fieldFrame,
                    context: fallbackContext,
                    issueRange: fallbackRange
                )
                let preferEstimated = estimatedFrames != nil && shouldPreferHostEstimatedGeometry(
                    for: fallbackContext,
                    fieldFrame: fieldFrame,
                    issueFallback: issueFallback,
                    preciseFrames: preciseFrames
                )
                let selectedSource: String
                let rawFrames: [CGRect]
                if preferEstimated, let estimatedFrames {
                    selectedSource = "hostEstimated"
                    rawFrames = estimatedFrames
                } else if let preciseFrames {
                    selectedSource = "axPrecise"
                    rawFrames = preciseFrames
                } else if let estimatedFrames {
                    selectedSource = "hostEstimated"
                    rawFrames = estimatedFrames
                } else if axFramesAreHostFallback {
                    selectedSource = "hostFallbackFrame"
                    rawFrames = axFrames
                } else {
                    selectedSource = "axRawOrFallback"
                    rawFrames = axFrames
                }
                let markerStyle = issueMarkerStyle(
                    selectedSource: selectedSource,
                    context: fallbackContext
                )
                let normalized = normalizedIssueOverlayFrames(
                    for: rawFrames,
                    fallback: issueFallback,
                    style: markerStyle
                )
                postMarkerPipelineDebug(
                    stage: "issue",
                    context: issueContext,
                    issueRange: issueRange,
                    fallback: issueFallback,
                    axFrames: axFrames,
                    selectedSource: selectedSource,
                    selectedFrames: rawFrames,
                    normalizedFrames: normalized
                )
                guard !normalized.isEmpty else { continue }
                let issueColor = TextoraSuggestionColors.color(for: issue.category)
                let geometry = diagnosticGeometryKind(for: issueContext, selectedSource: selectedSource)
                for frame in normalized {
                    jobs.append(
                        UnderlineJob(
                            frame: frame,
                            colors: [issueColor],
                            issueID: issue.id,
                            issueIDs: [issue.id],
                            geometry: geometry,
                            source: selectedSource,
                            style: markerStyle,
                            lineFrame: fallbackContext.frame.isEmpty ? frame : fallbackContext.frame,
                            isLoading: false
                        )
                    )
                }
            }
        }
        if jobs.isEmpty {
            // Legacy single-issue rendering. The marker uses the
            // multi-color brand gradient (or per-operation color when
            // exactly one operation is suggested) the same way it did
            // before per-span issues existed.
            let axFrames = textService.issueBoundsList(
                in: context,
                localRange: latestIssueRange,
                fallbackFrame: fallback
            )
            let axFramesAreHostFallback = axFrames.count == 1 && approximatelySameRect(axFrames[0], fallback)
            let preciseFrames = axFramesAreHostFallback ? nil : usablePreciseIssueFrames(axFrames, fallback: fallback)
            let estimatedFrames = hostEstimatedIssueFrames(
                caretFrame: caretFrame,
                fieldFrame: fieldFrame,
                context: context,
                issueRange: latestIssueRange
            )
            let preferEstimated = estimatedFrames != nil && shouldPreferHostEstimatedGeometry(
                for: context,
                fieldFrame: fieldFrame,
                issueFallback: fallback,
                preciseFrames: preciseFrames
            )
            let selectedSource: String
            let rawFrames: [CGRect]
            if preferEstimated, let estimatedFrames {
                selectedSource = "hostEstimated"
                rawFrames = estimatedFrames
            } else if let preciseFrames {
                selectedSource = "axPrecise"
                rawFrames = preciseFrames
            } else if let estimatedFrames {
                selectedSource = "hostEstimated"
                rawFrames = estimatedFrames
            } else if axFramesAreHostFallback {
                selectedSource = "hostFallbackFrame"
                rawFrames = axFrames
            } else {
                selectedSource = "axRawOrFallback"
                rawFrames = axFrames
            }
            let markerStyle = issueMarkerStyle(
                selectedSource: selectedSource,
                context: context
            )
            let normalized = normalizedIssueOverlayFrames(
                for: rawFrames,
                fallback: fallback,
                style: markerStyle
            )
            postMarkerPipelineDebug(
                stage: "legacy",
                context: context,
                issueRange: latestIssueRange,
                fallback: fallback,
                axFrames: axFrames,
                selectedSource: selectedSource,
                selectedFrames: rawFrames,
                normalizedFrames: normalized
            )
            guard !normalized.isEmpty else {
                hideMarkerAndCard()
                return
            }
            let colors = issueOverlayColors()
            let geometry = diagnosticGeometryKind(for: context, selectedSource: selectedSource)
            for frame in normalized {
                jobs.append(
                    UnderlineJob(
                        frame: frame,
                        colors: colors,
                        issueID: nil,
                        issueIDs: [],
                        geometry: geometry,
                        source: selectedSource,
                        style: markerStyle,
                        lineFrame: context.frame.isEmpty ? frame : context.frame,
                        isLoading: false
                    )
                )
            }
        }
        guard !jobs.isEmpty else {
            hideMarkerAndCard()
            return
        }
        if shouldGroupCompactLineMarkers(for: context) {
            var grouped: [UnderlineJob] = []
            var compactGroups: [(key: Int, jobs: [UnderlineJob])] = []
            for job in jobs {
                guard job.style == .compactDot, !job.issueIDs.isEmpty else {
                    grouped.append(job)
                    continue
                }
                let key = Int((job.lineFrame.midY / 8).rounded())
                if let index = compactGroups.firstIndex(where: { $0.key == key }) {
                    compactGroups[index].jobs.append(job)
                } else {
                    compactGroups.append((key, [job]))
                }
            }
            for group in compactGroups {
                guard let first = group.jobs.first else { continue }
                let lineFrame = group.jobs
                    .map(\.lineFrame)
                    .filter { !$0.isEmpty }
                    .reduce(first.lineFrame.isEmpty ? first.frame : first.lineFrame) { $0.union($1) }
                let markerSide: CGFloat = 16
                let frame = clampedToVisibleScreens(
                    CGRect(
                        x: lineFrame.minX - markerSide - 7,
                        y: lineFrame.minY + max(0, (lineFrame.height - markerSide) * 0.5),
                        width: markerSide,
                        height: markerSide
                    )
                )
                let issueIDs = uniqueIssueIDs(group.jobs.flatMap(\.issueIDs))
                let colors = issueOverlayColors(for: issueIDs)
                grouped.append(
                    UnderlineJob(
                        frame: frame,
                        colors: colors.isEmpty ? first.colors : colors,
                        issueID: issueIDs.first,
                        issueIDs: issueIDs,
                        geometry: first.geometry,
                        source: first.source,
                        style: .compactDot,
                        lineFrame: lineFrame,
                        isLoading: first.isLoading
                    )
                )
            }
            jobs = grouped.sorted { lhs, rhs in
                if abs(lhs.frame.midY - rhs.frame.midY) > 2 {
                    return lhs.frame.midY > rhs.frame.midY
                }
                return lhs.frame.minX < rhs.frame.minX
            }
        }

        let allFrames = jobs.map(\.frame)
        let hitFrame = markerHitFrame(for: allFrames)
        postMarkerGeometryStatus(
            context: context,
            issueFrame: hitFrame,
            fallback: fallback,
            underlineFrames: allFrames,
            geometrySources: jobs.map { "\($0.geometry):\($0.source)" },
            segmentCount: jobs.count
        )
        if markerPanel == nil {
            createMarkerPanel()
        }

        var newLayouts: [IssuePanelLayout] = []
        for (index, job) in jobs.enumerated() {
            let overlayPanel = issueOverlayPanel(at: index)
            if let host = overlayPanel.contentView as? NSHostingView<FloatingIssueUnderlineView> {
                host.rootView = FloatingIssueUnderlineView(
                    colors: job.colors,
                    isHighlighted: isLayoutHighlighted(issueID: job.issueID, issueIDs: job.issueIDs),
                    style: job.style,
                    isLoading: job.isLoading
                )
            }
            let overlayWasVisible = overlayPanel.isVisible
            overlayPanel.setFrame(job.frame, display: true)
            if !overlayWasVisible {
                overlayPanel.orderFrontRegardless()
            }

            let hitPanel = markerHitPanel(at: index)
            let issueHitFrame = markerHitFrame(forSingleUnderline: job.frame)
            let hitWasVisible = hitPanel.isVisible
            hitPanel.setFrame(issueHitFrame, display: true)
            if !hitWasVisible {
                hitPanel.orderFrontRegardless()
            }
            newLayouts.append(
                IssuePanelLayout(
                    panelIndex: index,
                    frame: job.frame,
                    issueID: job.issueID,
                    issueIDs: job.issueIDs,
                    style: job.style,
                    isLoading: job.isLoading
                )
            )
        }
        // Hide any panels left over from a previous render with more
        // jobs than this one.
        if jobs.count - 1 < extraIssueOverlayPanels.count {
            for panel in extraIssueOverlayPanels.dropFirst(max(0, jobs.count - 1)) {
                panel.orderOut(nil)
            }
        }
        if jobs.count - 1 < extraMarkerPanels.count {
            for panel in extraMarkerPanels.dropFirst(max(0, jobs.count - 1)) {
                panel.orderOut(nil)
            }
        }
        issuePanelLayouts = newLayouts
        refreshIssueUnderlineHighlight()
        keepMarkerPanelBehindHoverCardIfNeeded()
        markerAnchor = anchor
    }

    private func issuesToRender(in _: TextAccessService.FocusedTextContext) -> [OverlayIssue] {
        latestIssues
    }

    private func shouldGroupCompactLineMarkers(for context: TextAccessService.FocusedTextContext) -> Bool {
        _ = context
        return true
    }

    private func uniqueIssueIDs(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private func refreshIssueUnderlineHighlight() {
        for layout in issuePanelLayouts {
            let overlayPanel = issueOverlayPanel(at: layout.panelIndex)
            guard let host = overlayPanel.contentView as? NSHostingView<FloatingIssueUnderlineView> else {
                continue
            }
            let issueColor = layout.issueID
                .flatMap { id in latestIssues.first(where: { $0.id == id })?.category }
                .map { TextoraSuggestionColors.color(for: $0) }
            let issueGroupColors = issueOverlayColors(for: layout.issueIDs)
            let colors = issueGroupColors.isEmpty
                ? (issueColor.map { [$0] } ?? issueOverlayColors())
                : issueGroupColors
            host.rootView = FloatingIssueUnderlineView(
                colors: colors,
                isHighlighted: isLayoutHighlighted(issueID: layout.issueID, issueIDs: layout.issueIDs),
                style: layout.style,
                isLoading: layout.isLoading
            )
        }
    }

    private func isLayoutHighlighted(issueID: UUID?, issueIDs: [UUID]) -> Bool {
        if let issueID, issueID == hoveredIssueID {
            return true
        }
        return !hoveredIssueIDs.isDisjoint(with: Set(issueIDs))
    }

    private func shouldUseScopedOverlayGeometry(
        for context: TextAccessService.FocusedTextContext,
        geometryTargetAvailable: Bool
    ) -> Bool {
        guard geometryTargetAvailable else { return false }
        if !context.textFragments.isEmpty || context.anchor.source == .visiblePageText {
            return false
        }
        if isSlackBundle(context.targetBundleID) {
            return true
        }
        if isBrowserBundle(context.targetBundleID) {
            return true
        }
        return false
    }

    /// Returns the issues (if any) whose underline panel covers `point`
    /// in screen coordinates. Used by the per-issue hover hit-test —
    /// when the mouse moves over the marker panel we look up which
    /// underline it actually sits over and show that issue's card.
    private func issues(atScreenPoint point: CGPoint) -> [OverlayIssue] {
        for layout in issuePanelLayouts {
            let hit = markerHitFrame(forSingleUnderline: layout.frame)
            guard hit.contains(point) else { continue }
            let ids = layout.issueIDs.isEmpty
                ? layout.issueID.map { [$0] } ?? []
                : layout.issueIDs
            return ids.compactMap { id in latestIssues.first(where: { $0.id == id }) }
        }
        return []
    }

    private func postMarkerGeometryStatus(
        context: TextAccessService.FocusedTextContext,
        issueFrame: CGRect,
        fallback: CGRect,
        underlineFrames: [CGRect] = [],
        geometrySources: [String] = [],
        segmentCount: Int = 1
    ) {
        let issuePart = "\(Int(issueFrame.minX)):\(Int(issueFrame.minY)):\(Int(issueFrame.width)):\(Int(issueFrame.height))"
        let fallbackPart = "\(Int(fallback.minX)):\(Int(fallback.minY)):\(Int(fallback.width)):\(Int(fallback.height))"
        let underlinePart = underlineFrames
            .map { "\(Int($0.minX)):\(Int($0.minY)):\(Int($0.width)):\(Int($0.height))" }
            .joined(separator: ",")
        let geometryPart = uniquePreservingOrder(geometrySources).joined(separator: ",")
        let signature = "\(context.anchor.source.rawValue)|\(context.anchor.confidence.rawValue)|\(geometryPart)|\(issuePart)|\(fallbackPart)|\(underlinePart)|\(segmentCount)"
        guard signature != lastMarkerDebugSignature else { return }
        lastMarkerDebugSignature = signature
        let message = "Marker geometry bundle=\(context.targetBundleID) geometry=[\(geometryPart)] \(context.anchor.debugSummary) hit \(issuePart) fallback \(fallbackPart) underlines [\(underlinePart)] segments \(segmentCount)"
        textoraDiagLog("markerGeometry", message)
        postStatus(message)
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !value.isEmpty {
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private func shouldPreferHostEstimatedGeometry(
        for context: TextAccessService.FocusedTextContext,
        fieldFrame: CGRect,
        issueFallback: CGRect,
        preciseFrames: [CGRect]?
    ) -> Bool {
        if preciseFrames != nil {
            return false
        }
        guard isBrowserBundle(context.targetBundleID) else {
            return isSlackBundle(context.targetBundleID)
        }
        return context.anchor.source == .axElementFrame
            || context.frame.height > 44
            || fieldFrame.height > 44
            || issueFallback.height > 44
    }

    private func issueMarkerStyle(
        selectedSource: String,
        context: TextAccessService.FocusedTextContext
    ) -> FloatingIssueMarkerStyle {
        _ = context
        if selectedSource == "hostFallbackFrame"
            || selectedSource == "axRawOrFallback"
            || selectedSource == "hostEstimated" {
            return .compactDot
        }
        return .underline
    }

    private func normalizedIssueOverlayFrames(
        for bounds: [CGRect],
        fallback: CGRect,
        style: FloatingIssueMarkerStyle = .underline
    ) -> [CGRect] {
        let sourceBounds = bounds.isEmpty ? [fallback] : bounds
        var frames: [CGRect] = []
        for rect in sourceBounds.prefix(8) {
            let frame: CGRect = {
                switch style {
                case .underline:
                    return normalizedIssueOverlayFrame(for: rect, fallback: fallback)
                case .compactDot:
                    return normalizedCompactIssueOverlayFrame(for: rect, fallback: fallback)
                }
            }()
            guard !frame.isEmpty else { continue }
            let isDuplicate = frames.contains {
                abs($0.minX - frame.minX) < 2
                    && abs($0.minY - frame.minY) < 2
                    && abs($0.width - frame.width) < 2
                    && abs($0.height - frame.height) < 2
            }
            if !isDuplicate {
                frames.append(frame)
            }
        }
        return frames
    }

    private func usablePreciseIssueFrames(_ frames: [CGRect], fallback: CGRect) -> [CGRect]? {
        let usable = frames.filter { frame in
            guard !frame.isEmpty else { return false }
            guard frame.width >= 1, frame.height >= 2, frame.width <= 900, frame.height <= 90 else { return false }
            guard !fallback.isEmpty else { return true }
            let area = fallback.insetBy(dx: -220, dy: -180)
            return area.intersects(frame) || area.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        return usable.isEmpty ? nil : usable
    }

    private func approximatelySameRect(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func markerHitFrame(for underlineFrames: [CGRect]) -> CGRect {
        guard let first = underlineFrames.first else { return .zero }
        let union = underlineFrames.dropFirst().reduce(first) { $0.union($1) }
        let hit = CGRect(
            x: union.minX - 6,
            y: union.minY - 2,
            width: union.width + 12,
            height: max(12, union.height + 8)
        )
        return clampedToVisibleScreens(hit)
    }

    private func markerHitFrame(forSingleUnderline underlineFrame: CGRect) -> CGRect {
        let hit = CGRect(
            x: underlineFrame.minX - 5,
            y: underlineFrame.minY - 4,
            width: underlineFrame.width + 10,
            height: max(12, underlineFrame.height + 8)
        )
        return clampedToVisibleScreens(hit)
    }

    private func globalOverlayLineFrame(
        context: TextAccessService.FocusedTextContext,
        fieldFrame: CGRect,
        fallback: CGRect
    ) -> CGRect {
        if !context.frame.isEmpty, context.frame.height <= 220 {
            return context.frame
        }
        if !fallback.isEmpty, fallback.height <= 220 {
            return fallback
        }
        if !fieldFrame.isEmpty {
            let height = min(max(fieldFrame.height, 20), 44)
            return CGRect(
                x: fieldFrame.minX,
                y: fieldFrame.maxY - height,
                width: fieldFrame.width,
                height: height
            )
        }
        return fallback
    }

    private func globalCompactMarkerFrame(for lineFrame: CGRect) -> CGRect {
        guard !lineFrame.isEmpty else { return .zero }
        let side: CGFloat = 16
        return clampedToVisibleScreens(
            CGRect(
                x: lineFrame.minX - side - 7,
                y: lineFrame.minY + max(0, (lineFrame.height - side) * 0.5),
                width: side,
                height: side
            )
        )
    }

    private func normalizedIssueOverlayFrame(for bounds: CGRect, fallback: CGRect) -> CGRect {
        let source = bounds.isEmpty ? fallback : bounds
        let minWidth: CGFloat = 10
        let maxWidth: CGFloat = 520
        let width = min(max(source.width, minWidth), maxWidth)
        let underlineHeight: CGFloat = 4
        let underlineOffset: CGFloat = 3
        let frame = CGRect(
            x: source.minX,
            y: source.minY - underlineOffset,
            width: width,
            height: underlineHeight
        )
        return clampedToVisibleScreens(frame)
    }

    private func normalizedCompactIssueOverlayFrame(for bounds: CGRect, fallback: CGRect) -> CGRect {
        let source = bounds.isEmpty ? fallback : bounds
        guard !source.isEmpty else { return .zero }
        let side: CGFloat = 16
        let frame = CGRect(
            x: source.minX - side - 7,
            y: source.minY + max(0, (source.height - side) * 0.5),
            width: side,
            height: side
        )
        return clampedToVisibleScreens(frame)
    }

    private func hostEstimatedIssueFrames(
        caretFrame: CGRect?,
        fieldFrame: CGRect,
        context: TextAccessService.FocusedTextContext,
        issueRange: NSRange?
    ) -> [CGRect]? {
        guard context.anchor.source != .clipboardFallback else {
            return nil
        }
        guard isSlackBundle(context.targetBundleID) || isBrowserBundle(context.targetBundleID) else {
            return nil
        }
        guard let issueRange else { return nil }
        if !context.textFragments.isEmpty || context.anchor.source == .visiblePageText {
            return nil
        }
        if let frames = estimatedIssueFramesFromTextAnchor(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context,
            issueRange: issueRange
        ), !frames.isEmpty {
            return frames
        }
        if let fallback = estimatedIssueFrameFromVisibleText(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context,
            issueRange: issueRange
        ) {
            return [fallback]
        }
        return nil
    }

    private func fallbackIssueFrame(
        caretFrame: CGRect?,
        fieldFrame: CGRect,
        context: TextAccessService.FocusedTextContext,
        issueRange: NSRange?
    ) -> CGRect {
        if let anchoredFrame = estimatedIssueFrameFromTextAnchor(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context,
            issueRange: issueRange
        ) {
            return anchoredFrame
        }

        if isWebOrMessengerBundle(context.targetBundleID),
           let textLineFrame = estimatedIssueFrameFromVisibleText(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context,
            issueRange: issueRange
           ) {
            return textLineFrame
        }

        let stableFieldFrame = stableIssueAnchorFrame(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context
        )
        let textLength = max(1, (context.text as NSString).length)
        let issueLength = max(1, issueRange?.length ?? min(textLength, 42))
        let issueLocation = max(0, min(issueRange?.location ?? 0, textLength))
        let estimatedCharWidth: CGFloat = 7.2
        let width = min(max(CGFloat(issueLength) * estimatedCharWidth, 28), min(stableFieldFrame.width, 360))

        if let caretFrame, caretFrame.width <= 12, stableFieldFrame.insetBy(dx: -24, dy: -24).intersects(caretFrame) {
            return CGRect(
                x: caretFrame.minX,
                y: caretFrame.minY,
                width: width,
                height: max(caretFrame.height, 14)
            )
        }

        let horizontalInset: CGFloat = 12
        let availableWidth = max(1, stableFieldFrame.width - horizontalInset * 2)
        let xOffset = min(
            max(CGFloat(issueLocation) / CGFloat(textLength) * availableWidth, 0),
            max(0, availableWidth - width)
        )
        let lineHeight: CGFloat = min(max(stableFieldFrame.height, 18), 24)
        return CGRect(
            x: stableFieldFrame.minX + horizontalInset + xOffset,
            y: stableFieldFrame.maxY - lineHeight - 4,
            width: width,
            height: lineHeight
        )
    }

    private func estimatedIssueFrameFromTextAnchor(
        caretFrame: CGRect?,
        fieldFrame: CGRect,
        context: TextAccessService.FocusedTextContext,
        issueRange: NSRange?
    ) -> CGRect? {
        if let issueRange,
           let frames = estimatedIssueFramesFromTextAnchor(
            caretFrame: caretFrame,
            fieldFrame: fieldFrame,
            context: context,
            issueRange: issueRange
           ),
           let first = frames.first {
            return first
        }

        let anchor = context.anchor
        guard anchor.confidence != .weak, !anchor.rect.isEmpty else { return nil }
        if isSlackBundle(context.targetBundleID),
           !isUsableSlackTextFrame(anchor.rect) {
            return nil
        }

        let textNS = context.text as NSString
        guard textNS.length > 0 else { return nil }
        let issueLocation = max(0, min(issueRange?.location ?? 0, textNS.length))
        let issueLength = max(1, min(issueRange?.length ?? textNS.length, textNS.length - issueLocation))

        if (anchor.source == .axBoundsForRange || anchor.source == .axLineBounds), issueRange == nil {
            return anchor.rect
        }

        if (anchor.source == .axBoundsForRange || anchor.source == .axLineBounds), anchor.rect.width > 0 {
            let charWidth = min(max(anchor.rect.width / CGFloat(max(1, textNS.length)), 5.2), 14.5)
            let width = min(max(CGFloat(issueLength) * charWidth, 16), max(16, anchor.rect.width))
            let x = min(
                max(anchor.rect.minX + CGFloat(issueLocation) * charWidth, anchor.rect.minX),
                anchor.rect.maxX - width
            )
            return CGRect(
                x: x,
                y: anchor.rect.minY,
                width: width,
                height: max(anchor.rect.height, 14)
            )
        }

        if isSlackBundle(context.targetBundleID),
           anchor.source == .axElementFrame,
           let slackFrame = estimatedSlackIssueFrameFromElementAnchor(
            anchorFrame: anchor.rect,
            text: textNS,
            issueLocation: issueLocation,
            issueLength: issueLength
           ) {
            return slackFrame
        }

        if isBrowserBundle(context.targetBundleID),
           anchor.source == .axElementFrame,
           let browserFrame = estimatedBrowserIssueFrameFromElementAnchor(
            anchorFrame: anchor.rect,
            text: textNS,
            issueLocation: issueLocation,
            issueLength: issueLength
           ) {
            return browserFrame
        }

        let usableCaretFrame: CGRect? = {
            guard let caretFrame else { return nil }
            if isSlackBundle(context.targetBundleID) {
                return isUsableSlackCaretFrame(
                    caretFrame,
                    anchorFrame: anchor.rect,
                    contextFrame: context.frame
                ) ? caretFrame : nil
            }
            if isBrowserBundle(context.targetBundleID) {
                return isUsableBrowserCaretFrame(
                    caretFrame,
                    anchorFrame: anchor.rect,
                    contextFrame: context.frame
                ) ? caretFrame : nil
            }
            return caretFrame
        }()

        let lineFrame: CGRect
        if anchor.source == .axCaret || anchor.source == .axLineBounds {
            lineFrame = anchor.rect
        } else if let usableCaretFrame {
            lineFrame = usableCaretFrame
        } else {
            lineFrame = anchor.rect
        }

        guard lineFrame.width <= max(18, fieldFrame.width), lineFrame.height <= 80 else {
            return nil
        }

        let container = textContainerFrame(
            fieldFrame: fieldFrame,
            contextFrame: context.frame,
            lineFrame: lineFrame
        )
        let horizontalPadding: CGFloat = min(max(container.width * 0.025, 16), 34)
        let textStartX = min(
            max(container.minX + horizontalPadding, container.minX + 4),
            lineFrame.minX
        )
        let measuredWidth = max(1, lineFrame.minX - textStartX)
        let measuredCharWidth = measuredWidth / CGFloat(max(1, textNS.length))
        let charWidth = min(max(measuredCharWidth, 5.8), 13.5)
        let width = min(
            max(CGFloat(issueLength) * charWidth, 16),
            max(16, container.maxX - textStartX - 4)
        )
        let x = min(
            max(textStartX + CGFloat(issueLocation) * charWidth, container.minX + 4),
            container.maxX - width - 4
        )
        let lineHeight = min(max(lineFrame.height, 16), 28)
        return CGRect(
            x: x,
            y: lineFrame.minY - 1,
            width: width,
            height: lineHeight
        )
    }

    private func estimatedIssueFramesFromTextAnchor(
        caretFrame: CGRect?,
        fieldFrame: CGRect,
        context: TextAccessService.FocusedTextContext,
        issueRange: NSRange
    ) -> [CGRect]? {
        let textNS = context.text as NSString
        guard textNS.length > 0 else { return nil }
        let issueLocation = max(0, min(issueRange.location, textNS.length))
        let issueLength = max(1, min(issueRange.length, textNS.length - issueLocation))

        if isSlackBundle(context.targetBundleID) {
            let anchorFrame: CGRect = {
                let anchor = context.anchor
                if anchor.source == .axElementFrame, isUsableSlackTextFrame(anchor.rect) {
                    return anchor.rect
                }
                let stable = stableIssueAnchorFrame(
                    caretFrame: caretFrame,
                    fieldFrame: fieldFrame,
                    context: context
                )
                if isUsableSlackTextFrame(stable) {
                    return stable
                }
                return anchor.rect
            }()
            guard let frames = estimatedSlackIssueFramesFromElementAnchor(
                anchorFrame: anchorFrame,
                text: textNS,
                issueLocation: issueLocation,
                issueLength: issueLength
            ), !frames.isEmpty else {
                return nil
            }
            return frames
        }

        if isBrowserBundle(context.targetBundleID) {
            let anchor = context.anchor
            let anchorFrame: CGRect
            if isUsableBrowserTextFrame(anchor.rect) {
                anchorFrame = anchor.rect
            } else if isUsableBrowserTextFrame(fieldFrame) {
                anchorFrame = fieldFrame
            } else {
                return nil
            }
            guard let frames = estimatedBrowserIssueFramesFromElementAnchor(
                anchorFrame: anchorFrame,
                text: textNS,
                issueLocation: issueLocation,
                issueLength: issueLength
            ), !frames.isEmpty else {
                return nil
            }
            return frames
        }

        return nil
    }

    private func estimatedBrowserIssueFrameFromElementAnchor(
        anchorFrame: CGRect,
        text: NSString,
        issueLocation: Int,
        issueLength: Int
    ) -> CGRect? {
        if let first = estimatedBrowserIssueFramesFromElementAnchor(
            anchorFrame: anchorFrame,
            text: text,
            issueLocation: issueLocation,
            issueLength: issueLength
        )?.first {
            return first
        }
        return nil
    }

    private func estimatedBrowserIssueFramesFromElementAnchor(
        anchorFrame: CGRect,
        text: NSString,
        issueLocation: Int,
        issueLength: Int
    ) -> [CGRect]? {
        guard isUsableBrowserTextFrame(anchorFrame), text.length > 0 else { return nil }

        let newlineMetrics = textLineMetrics(in: text, issueLocation: issueLocation)
        let isMultiline = newlineMetrics.lineCount > 1 || anchorFrame.height > 44
        let horizontalInset: CGFloat = isMultiline
            ? min(max(anchorFrame.width * 0.012, 18), 28)
            : min(max(anchorFrame.height * 0.22, 6), 14)
        let topInset: CGFloat = isMultiline
            ? min(max(anchorFrame.height * 0.10, 14), 28)
            : max(1, anchorFrame.height * 0.16)
        let textStartX = anchorFrame.minX + horizontalInset
        let textEndX = anchorFrame.maxX - horizontalInset
        guard textEndX > textStartX + 12 else { return nil }

        let estimatedCharWidth = browserEstimatedCharWidth(
            availableWidth: textEndX - textStartX,
            lineLength: max(newlineMetrics.lineLength, min(text.length, 48))
        )
        let metrics = wrappedIssueMetrics(
            in: text,
            issueLocation: issueLocation,
            issueLength: issueLength,
            maxUnitsPerLine: (textEndX - textStartX) / max(estimatedCharWidth, 1)
        )
        let lineHeight: CGFloat = {
            guard isMultiline else {
                return min(max(anchorFrame.height * 0.68, 16), 24)
            }
            let usableHeight = max(18, anchorFrame.height - topInset - 10)
            return min(max(usableHeight / CGFloat(max(metrics.lineCount, 1)), 18), 34)
        }()
        let lineMetrics = wrappedIssueLineMetrics(
            in: text,
            issueLocation: issueLocation,
            issueLength: issueLength,
            maxUnitsPerLine: (textEndX - textStartX) / max(estimatedCharWidth, 1)
        )
        let topY = anchorFrame.maxY - topInset
        return lineMetrics.prefix(8).map { metric in
            let lineWidth = min(
                max(metric.lineUnits * estimatedCharWidth, 18),
                max(18, textEndX - textStartX)
            )
            let width = min(
                max(lineWidth * (metric.issueUnits / max(metric.lineUnits, 1)), 18),
                lineWidth
            )
            let x = min(
                max(textStartX + lineWidth * (metric.startUnits / max(metric.lineUnits, 1)), textStartX),
                textEndX - width
            )
            let y: CGFloat = {
                guard isMultiline else {
                    return anchorFrame.minY + max(1, (anchorFrame.height - lineHeight) * 0.5)
                }
                let lineBottom = topY - CGFloat(metric.lineIndex + 1) * lineHeight
                return max(anchorFrame.minY + 2, lineBottom)
            }()
            return CGRect(x: x, y: y, width: width, height: lineHeight)
        }
    }

    private struct TextLineMetrics {
        let lineIndex: Int
        let column: Int
        let lineLength: Int
        let lineCount: Int
    }

    private func textLineMetrics(in text: NSString, issueLocation: Int) -> TextLineMetrics {
        let safeLocation = max(0, min(issueLocation, text.length))
        var lineIndex = 0
        var lineStart = 0
        var index = 0
        while index < safeLocation {
            let ch = text.character(at: index)
            if ch == 10 || ch == 13 {
                lineIndex += 1
                if ch == 13, index + 1 < text.length, text.character(at: index + 1) == 10 {
                    index += 1
                }
                lineStart = index + 1
            }
            index += 1
        }

        var lineEnd = lineStart
        while lineEnd < text.length {
            let ch = text.character(at: lineEnd)
            if ch == 10 || ch == 13 { break }
            lineEnd += 1
        }

        var lineCount = 1
        index = 0
        while index < text.length {
            let ch = text.character(at: index)
            if ch == 10 || ch == 13 {
                lineCount += 1
                if ch == 13, index + 1 < text.length, text.character(at: index + 1) == 10 {
                    index += 1
                }
            }
            index += 1
        }

        return TextLineMetrics(
            lineIndex: lineIndex,
            column: max(0, safeLocation - lineStart),
            lineLength: max(1, lineEnd - lineStart),
            lineCount: max(1, lineCount)
        )
    }

    private struct WrappedIssueMetrics {
        let lineIndex: Int
        let lineCount: Int
        let startUnits: CGFloat
        let issueUnits: CGFloat
        let lineUnits: CGFloat
    }

    private struct WrappedIssueLineMetrics {
        let lineIndex: Int
        let lineCount: Int
        let startUnits: CGFloat
        let issueUnits: CGFloat
        let lineUnits: CGFloat
    }

    private func wrappedIssueMetrics(
        in text: NSString,
        issueLocation: Int,
        issueLength: Int,
        maxUnitsPerLine: CGFloat
    ) -> WrappedIssueMetrics {
        if let first = wrappedIssueLineMetrics(
            in: text,
            issueLocation: issueLocation,
            issueLength: issueLength,
            maxUnitsPerLine: maxUnitsPerLine
        ).first {
            return WrappedIssueMetrics(
                lineIndex: first.lineIndex,
                lineCount: first.lineCount,
                startUnits: first.startUnits,
                issueUnits: first.issueUnits,
                lineUnits: first.lineUnits
            )
        }
        return WrappedIssueMetrics(lineIndex: 0, lineCount: 1, startUnits: 0, issueUnits: 1, lineUnits: 1)
    }

    private func wrappedIssueLineMetrics(
        in text: NSString,
        issueLocation: Int,
        issueLength: Int,
        maxUnitsPerLine: CGFloat
    ) -> [WrappedIssueLineMetrics] {
        let safeMaxUnits = max(8, maxUnitsPerLine)
        let safeLocation = max(0, min(issueLocation, text.length))
        let safeLength = max(1, min(issueLength, max(0, text.length - safeLocation)))
        let issueRange = NSRange(location: safeLocation, length: safeLength)

        struct Line { let range: NSRange }
        var lines: [Line] = []
        var lineStart = 0
        var lineUnits: CGFloat = 0
        var lastBreakIndex: Int?
        var index = 0

        func commitLine(_ end: Int, nextStart: Int) {
            let safeEnd = max(lineStart, min(end, text.length))
            lines.append(Line(range: NSRange(location: lineStart, length: max(0, safeEnd - lineStart))))
            lineStart = max(nextStart, safeEnd)
            lineUnits = 0
            lastBreakIndex = nil
        }

        while index < text.length {
            let ch = text.character(at: index)
            if ch == 10 || ch == 13 {
                commitLine(index, nextStart: index + 1)
                index += 1
                if ch == 13, index < text.length, text.character(at: index) == 10 {
                    lineStart = index + 1
                    index += 1
                }
                continue
            }

            let charUnits = TextoraCharacterGeometry.widthWeight(for: ch)
            if lineUnits + charUnits > safeMaxUnits, index > lineStart {
                if let breakIndex = lastBreakIndex, breakIndex > lineStart {
                    commitLine(breakIndex, nextStart: breakIndex + 1)
                } else {
                    commitLine(index, nextStart: index)
                }
                index = lineStart
                continue
            }

            lineUnits += charUnits
            if isWhitespace(ch) {
                lastBreakIndex = index
            }
            index += 1
        }

        if lineStart <= text.length {
            lines.append(Line(range: NSRange(location: lineStart, length: max(0, text.length - lineStart))))
        }
        if lines.isEmpty {
            lines = [Line(range: NSRange(location: 0, length: text.length))]
        }

        var result: [WrappedIssueLineMetrics] = []
        for (idx, line) in lines.enumerated() {
            let overlap = NSIntersectionRange(line.range, issueRange)
            guard overlap.length > 0 else { continue }
            let localStart = max(0, overlap.location - line.range.location)
            let localLength = max(1, overlap.length)
            let lineText = text.substring(with: line.range) as NSString
            let prefixRange = NSRange(location: 0, length: min(localStart, lineText.length))
            let issueLocalRange = NSRange(
                location: min(localStart, lineText.length),
                length: min(localLength, max(0, lineText.length - min(localStart, lineText.length)))
            )
            let startUnits = weightedUnits(in: lineText, range: prefixRange)
            let issueUnits = max(0.8, weightedUnits(in: lineText, range: issueLocalRange))
            let lineUnits = max(1, weightedUnits(in: lineText, range: NSRange(location: 0, length: lineText.length)))
            result.append(
                WrappedIssueLineMetrics(
                    lineIndex: idx,
                    lineCount: max(1, lines.count),
                    startUnits: startUnits,
                    issueUnits: issueUnits,
                    lineUnits: lineUnits
                )
            )
        }

        if !result.isEmpty { return result }
        let fallbackIndex: Int = {
            for (idx, line) in lines.enumerated() {
                if line.range.location <= safeLocation && safeLocation <= NSMaxRange(line.range) {
                    return idx
                }
            }
            return max(0, lines.count - 1)
        }()
        return [
            WrappedIssueLineMetrics(
                lineIndex: fallbackIndex,
                lineCount: max(1, lines.count),
                startUnits: 0,
                issueUnits: CGFloat(min(max(safeLength, 1), 12)),
                lineUnits: CGFloat(max(text.length, 1))
            )
        ]
    }

    private func weightedUnits(in text: NSString, range: NSRange) -> CGFloat {
        guard text.length > 0, range.length > 0 else { return 0 }
        let safeLocation = max(0, min(range.location, text.length))
        let safeLength = max(0, min(range.length, text.length - safeLocation))
        guard safeLength > 0 else { return 0 }
        var total: CGFloat = 0
        for index in safeLocation..<(safeLocation + safeLength) {
            total += TextoraCharacterGeometry.widthWeight(for: text.character(at: index))
        }
        return total
    }

    private func browserEstimatedCharWidth(availableWidth: CGFloat, lineLength: Int) -> CGFloat {
        let measured = availableWidth / CGFloat(max(lineLength, 28))
        return min(max(measured, 6.6), 12.8)
    }

    private func estimatedSlackIssueFrameFromElementAnchor(
        anchorFrame: CGRect,
        text: NSString,
        issueLocation: Int,
        issueLength: Int
    ) -> CGRect? {
        if let first = estimatedSlackIssueFramesFromElementAnchor(
            anchorFrame: anchorFrame,
            text: text,
            issueLocation: issueLocation,
            issueLength: issueLength
        )?.first {
            return first
        }
        return nil
    }

    private func estimatedSlackIssueFramesFromElementAnchor(
        anchorFrame: CGRect,
        text: NSString,
        issueLocation: Int,
        issueLength: Int
    ) -> [CGRect]? {
        guard isUsableSlackTextFrame(anchorFrame), text.length > 0 else { return nil }

        let newlineMetrics = textLineMetrics(in: text, issueLocation: issueLocation)
        let textInsetX = min(max(anchorFrame.height * 0.62, 18), 30)
        let textStartX = anchorFrame.minX + textInsetX
        let textEndX = anchorFrame.maxX - min(max(anchorFrame.height * 0.42, 12), 24)
        guard textEndX > textStartX + 16 else { return nil }

        let isSingleLineComposer = newlineMetrics.lineCount == 1 && anchorFrame.height <= 48
        let estimatedCharWidth = slackEstimatedCharWidth(
            availableWidth: textEndX - textStartX,
            anchorHeight: anchorFrame.height,
            text: text,
            issueLocation: issueLocation,
            lineLength: newlineMetrics.lineLength,
            isSingleLineComposer: isSingleLineComposer
        )
        let topInset = min(max(anchorFrame.height * 0.10, 8), 18)
        let topY = anchorFrame.maxY - topInset
        let lineMetrics = wrappedIssueLineMetrics(
            in: text,
            issueLocation: issueLocation,
            issueLength: issueLength,
            maxUnitsPerLine: (textEndX - textStartX) / max(estimatedCharWidth, 1)
        )
        return lineMetrics.prefix(8).map { metric in
            let lineStep = min(
                max(anchorFrame.height / CGFloat(max(metric.lineCount, 1)), 20),
                36
            )
            let letterHeight = min(max(lineStep * 0.72, 15), 24)
            let lineWidth = min(
                max(metric.lineUnits * estimatedCharWidth, 18),
                max(18, textEndX - textStartX)
            )
            let width = min(
                max(lineWidth * (metric.issueUnits / max(metric.lineUnits, 1)), 18),
                lineWidth
            )
            let x = min(
                max(textStartX + lineWidth * (metric.startUnits / max(metric.lineUnits, 1)), textStartX),
                textEndX - width
            )
            let y = max(anchorFrame.minY + 2, topY - CGFloat(metric.lineIndex) * lineStep - letterHeight)
            return CGRect(x: x, y: y, width: width, height: letterHeight)
        }
    }

    private func slackEstimatedCharWidth(
        availableWidth: CGFloat,
        anchorHeight: CGFloat,
        text: NSString,
        issueLocation: Int,
        lineLength: Int,
        isSingleLineComposer: Bool
    ) -> CGFloat {
        let lineRange = textLineRange(in: text, containing: issueLocation)
        let lineUnits = max(
            1,
            weightedUnits(
                in: text,
                range: lineRange.length > 0
                    ? lineRange
                    : NSRange(location: 0, length: text.length)
            )
        )
        let widthFromAvailable = availableWidth / lineUnits

        if isSingleLineComposer {
            // Slack's AX line frames usually describe the visible text row,
            // not a narrow glyph box. A height-derived 6-7pt estimate makes
            // every later word drift left; calibrating from the row width
            // keeps offsets aligned across long composer lines.
            let heightFloor = anchorHeight * 0.28
            return min(max(widthFromAvailable, heightFloor, 7.6), 11.2)
        }

        let lengthBased = availableWidth / CGFloat(max(lineLength, min(text.length, 42), 24))
        return min(max(widthFromAvailable * 0.92, lengthBased, 6.8), 11.4)
    }

    private func textLineRange(in text: NSString, containing location: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let safeLocation = max(0, min(location, text.length - 1))
        var start = safeLocation
        while start > 0 {
            let ch = text.character(at: start - 1)
            if ch == 10 || ch == 13 { break }
            start -= 1
        }
        var end = safeLocation
        while end < text.length {
            let ch = text.character(at: end)
            if ch == 10 || ch == 13 { break }
            end += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func slackLineAnchorFrame(
        _ anchorFrame: CGRect,
        caretFrame: CGRect?,
        contextFrame: CGRect
    ) -> CGRect {
        guard let caretFrame,
              isUsableSlackCaretFrame(caretFrame, anchorFrame: anchorFrame, contextFrame: contextFrame) else {
            return anchorFrame
        }
        let lineHeight = min(max(caretFrame.height, 18), 28)
        return CGRect(
            x: anchorFrame.minX,
            y: caretFrame.minY,
            width: anchorFrame.width,
            height: lineHeight
        )
    }

    private func textContainerFrame(
        fieldFrame: CGRect,
        contextFrame: CGRect,
        lineFrame: CGRect
    ) -> CGRect {
        let candidates = [fieldFrame, contextFrame]
            .filter { !$0.isEmpty && $0.insetBy(dx: -36, dy: -36).intersects(lineFrame) }
            .sorted { ($0.width * $0.height) < ($1.width * $1.height) }
        if let best = candidates.first {
            return best
        }
        if let windowFrame = textService.focusedWindowFrame(),
           windowFrame.insetBy(dx: -36, dy: -36).intersects(lineFrame) {
            return windowFrame
        }
        return fieldFrame.isEmpty ? contextFrame : fieldFrame
    }

    private func isUsableSlackTextFrame(_ rect: CGRect) -> Bool {
        guard !rect.isEmpty, rect.height >= 3, rect.height <= 220, rect.width >= 1 else {
            return false
        }
        guard let windowFrame = textService.focusedWindowFrame(), !windowFrame.isEmpty else {
            return true
        }
        let windowArea = windowFrame.insetBy(dx: -2, dy: -2)
        return windowArea.intersects(rect) || windowArea.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    private func isUsableSlackCaretFrame(
        _ caretFrame: CGRect,
        anchorFrame: CGRect,
        contextFrame: CGRect
    ) -> Bool {
        guard isUsableSlackTextFrame(caretFrame), caretFrame.width <= 24 else {
            return false
        }
        let anchorBand = anchorFrame.insetBy(dx: -48, dy: -80)
        if anchorBand.intersects(caretFrame) || anchorBand.contains(CGPoint(x: caretFrame.midX, y: caretFrame.midY)) {
            return true
        }
        let contextBand = contextFrame.insetBy(dx: -48, dy: -80)
        return contextBand.intersects(caretFrame) || contextBand.contains(CGPoint(x: caretFrame.midX, y: caretFrame.midY))
    }

    private func isUsableBrowserTextFrame(_ rect: CGRect) -> Bool {
        guard !rect.isEmpty, rect.height >= 3, rect.height <= 140, rect.width >= 1 else {
            return false
        }
        guard let windowFrame = textService.focusedWindowFrame(), !windowFrame.isEmpty else {
            return true
        }
        let windowArea = windowFrame.insetBy(dx: -2, dy: -2)
        return windowArea.intersects(rect) || windowArea.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    private func isUsableBrowserCaretFrame(
        _ caretFrame: CGRect,
        anchorFrame: CGRect,
        contextFrame: CGRect
    ) -> Bool {
        guard isUsableBrowserTextFrame(caretFrame), caretFrame.width <= 32 else {
            return false
        }
        let anchorBand = anchorFrame.insetBy(dx: -64, dy: -96)
        if anchorBand.intersects(caretFrame) || anchorBand.contains(CGPoint(x: caretFrame.midX, y: caretFrame.midY)) {
            return true
        }
        let contextBand = contextFrame.insetBy(dx: -64, dy: -96)
        return contextBand.intersects(caretFrame) || contextBand.contains(CGPoint(x: caretFrame.midX, y: caretFrame.midY))
    }

    private func estimatedIssueFrameFromVisibleText(
        caretFrame: CGRect?,
        fieldFrame: CGRect,
        context: TextAccessService.FocusedTextContext,
        issueRange: NSRange?
    ) -> CGRect? {
        guard !fieldFrame.isEmpty,
              let windowFrame = textService.focusedWindowFrame(),
              windowFrame.insetBy(dx: -32, dy: -32).intersects(fieldFrame) else {
            return nil
        }
        let textNS = context.text as NSString
        guard textNS.length > 0 else { return nil }

        let issueLocation = max(0, min(issueRange?.location ?? 0, textNS.length))
        let issueLength = max(1, min(issueRange?.length ?? textNS.length, textNS.length - issueLocation))
        let horizontalPadding: CGFloat = min(max(fieldFrame.width * 0.025, 16), 28)
        let textStartX = fieldFrame.minX + horizontalPadding
        let textEndX = min(fieldFrame.maxX - horizontalPadding, textStartX + CGFloat(textNS.length) * 9.2)
        let newlineMetrics = textLineMetrics(in: textNS, issueLocation: issueLocation)
        let charWidth = browserEstimatedCharWidth(
            availableWidth: max(1, textEndX - textStartX),
            lineLength: max(newlineMetrics.lineLength, min(textNS.length, 48))
        )
        let metrics = wrappedIssueMetrics(
            in: textNS,
            issueLocation: issueLocation,
            issueLength: issueLength,
            maxUnitsPerLine: (textEndX - textStartX) / max(charWidth, 1)
        )
        let width = min(max(metrics.issueUnits * charWidth, 16), fieldFrame.width - horizontalPadding * 2)

        let fallbackLineHeight: CGFloat = {
            if let caretFrame, fieldFrame.insetBy(dx: -32, dy: -32).intersects(caretFrame) {
                return min(max(caretFrame.height, 16), 28)
            }
            return min(max(fieldFrame.height * 0.18, 18), 28)
        }()
        let textLineHeight: CGFloat = {
            guard metrics.lineCount > 1 || fieldFrame.height > 44 else {
                return fallbackLineHeight
            }
            let topInset = min(max(fieldFrame.height * 0.10, 14), 28)
            let usableHeight = max(18, fieldFrame.height - topInset - 10)
            return min(max(usableHeight / CGFloat(max(metrics.lineCount, 1)), 18), 34)
        }()
        let y: CGFloat = {
            if metrics.lineCount > 1 || fieldFrame.height > 44 {
                let topInset = min(max(fieldFrame.height * 0.10, 14), 28)
                let topY = fieldFrame.maxY - topInset
                let lineBottom = topY - CGFloat(metrics.lineIndex + 1) * textLineHeight
                return max(fieldFrame.minY + 2, lineBottom)
            }
            if let caretFrame, fieldFrame.insetBy(dx: -32, dy: -32).intersects(caretFrame) {
                return caretFrame.minY - 1
            }
            return fieldFrame.maxY - textLineHeight - min(max(fieldFrame.height * 0.08, 10), 20)
        }()

        let x = min(
            max(textStartX + metrics.startUnits * charWidth, fieldFrame.minX + 4),
            fieldFrame.maxX - width - 4
        )
        return CGRect(x: x, y: y, width: width, height: textLineHeight)
    }

    private func stableIssueAnchorFrame(
        caretFrame: CGRect?,
        fieldFrame: CGRect,
        context: TextAccessService.FocusedTextContext
    ) -> CGRect {
        guard isWebOrMessengerBundle(context.targetBundleID),
              let windowFrame = textService.focusedWindowFrame() else {
            return fieldFrame
        }

        let lowerComposerBand = CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: min(max(windowFrame.height * 0.18, 110), 220)
        )
        if let caretFrame, lowerComposerBand.insetBy(dx: -24, dy: -24).intersects(caretFrame) {
            return CGRect(
                x: max(windowFrame.minX + 24, caretFrame.minX - 18),
                y: max(windowFrame.minY + 36, caretFrame.minY - 12),
                width: min(max(windowFrame.width - 96, 260), 760),
                height: max(caretFrame.height + 18, 34)
            )
        }
        if lowerComposerBand.insetBy(dx: -24, dy: -24).intersects(fieldFrame),
           fieldFrame.width <= windowFrame.width,
           fieldFrame.height <= windowFrame.height * 0.35 {
            return fieldFrame
        }

        // Slack/Electron can expose the message list, pinned header, or whole webview as the editable AX node.
        // In that case, synthesize the composer zone from the real app window.
        let bottomInset: CGFloat = windowFrame.height > 900 ? 54 : 42
        let sideInset: CGFloat = 28
        let composerHeight = min(max(windowFrame.height * 0.075, 72), 118)
        return CGRect(
            x: windowFrame.minX + sideInset,
            y: windowFrame.minY + bottomInset,
            width: max(160, windowFrame.width - sideInset * 2 - 36),
            height: composerHeight
        )
    }

    private func isWebOrMessengerBundle(_ bundleID: String) -> Bool {
        let b = bundleID.lowercased()
        return b.contains("slack")
            || b.contains("telegram")
            || b.contains("discord")
            || b.contains("teams")
            || b.contains("mattermost")
            || b.contains("element")
            || b.contains("signal")
            || b.contains("whatsapp")
            || b.contains("messenger")
            || b.contains("zulip")
            || b.contains("chrome")
            || b.contains("firefox")
            || b.contains("brave")
            || b.contains("safari")
            || b.contains("arc")
            || b.contains("opera")
    }

    private func isSlackBundle(_ bundleID: String) -> Bool {
        bundleID.lowercased().contains("slack")
    }

    private func isBrowserBundle(_ bundleID: String) -> Bool {
        let b = bundleID.lowercased()
        return b.contains("chrome")
            || b.contains("firefox")
            || b.contains("brave")
            || b.contains("safari")
            || b.contains("arc")
            || b.contains("opera")
    }

    private func handleMarkerHover(_ isHovering: Bool) {
        isMarkerHovered = isHovering
        if isHovering {
            cancelScheduledHoverHide()
            if !issues(atScreenPoint: NSEvent.mouseLocation).isEmpty {
                showHoverCard()
            } else if isMouseInsideHoverCard() {
                isHoverCardHovered = true
                return
            } else {
                showHoverCard()
            }
        } else {
            scheduleHoverHideIfNeeded()
        }
    }

    private func handleMarkerHoverMoved() {
        guard isMarkerHovered || hoverCardPanel?.isVisible == true else { return }
        let issuesUnderMouse = issues(atScreenPoint: NSEvent.mouseLocation)
        if issuesUnderMouse.isEmpty, isMouseInsideHoverCard() || isHoverCardHovered {
            cancelScheduledHoverHide()
            return
        }
        if !latestIssues.isEmpty, issuesUnderMouse.isEmpty {
            return
        }
        let nextIDs = Set(issuesUnderMouse.map(\.id))
        guard nextIDs != hoveredIssueIDs else { return }
        cancelScheduledHoverHide()
        if issuesUnderMouse.isEmpty, let primary = primaryIssue(in: latestIssues, original: latestContext?.text) {
            showHoverCard(for: [primary])
        } else {
            showHoverCard(for: issuesUnderMouse)
        }
    }

    private func handleHoverCardHover(_ isHovering: Bool) {
        isHoverCardHovered = isHovering
        if isHovering {
            cancelScheduledHoverHide()
        } else {
            scheduleHoverHideIfNeeded()
        }
    }

    private func showHoverCard() {
        // Per-issue hit test: if the cursor is over a specific
        // underline, show only that issue's suggestion. Otherwise fall
        // back to the primary (highest-priority) issue, or to the
        // legacy `latestSuggestionOptions` list when no audited issues
        // exist for this segment at all.
        let mouseScreen = NSEvent.mouseLocation
        let issuesUnderMouse = issues(atScreenPoint: mouseScreen)
        if issuesUnderMouse.isEmpty, isMouseInsideHoverCard(), hoverCardPanel?.isVisible == true {
            cancelScheduledHoverHide()
            return
        }
        if !latestIssues.isEmpty, issuesUnderMouse.isEmpty {
            return
        }
        if issuesUnderMouse.isEmpty, let primary = primaryIssue(in: latestIssues, original: latestContext?.text) {
            showHoverCard(for: [primary])
        } else {
            showHoverCard(for: issuesUnderMouse)
        }
    }

    private func showHoverCard(for issue: OverlayIssue?) {
        showHoverCard(for: issue.map { [$0] } ?? [])
    }

    private func showHoverCard(for issues: [OverlayIssue]) {
        showHoverCard(for: issues, anchorOverride: nil)
    }

    private func showHoverCard(
        for issues: [OverlayIssue],
        anchorOverride: CGRect?
    ) {
        let segmentText = latestContext?.text ?? ""
        let cardSuggestions: [OverlaySuggestion]
        let anchorFrame: CGRect
        let cardIssueIDs: [UUID]
        let suggestionIssueIDs: [String: UUID]
        if !issues.isEmpty, !segmentText.isEmpty {
            let rawCardSuggestions = issues.map { issue in
                OverlaySuggestion(
                    operation: issue.category,
                    text: applyIssueToSegment(segmentText, issue: issue)
                )
            }
            cardSuggestions = rankedSuggestions(rawCardSuggestions, original: segmentText)
            cardIssueIDs = issues.map(\.id)
            var issueIDsBySuggestion: [String: UUID] = [:]
            for suggestion in cardSuggestions {
                if let issue = issues.first(where: { $0.category == suggestion.operation }) {
                    issueIDsBySuggestion[hoverSuggestionKey(suggestion)] = issue.id
                }
            }
            suggestionIssueIDs = issueIDsBySuggestion
            let cardIssueIDSet = Set(cardIssueIDs)
            anchorFrame = issuePanelLayouts.first(where: { layout in
                !cardIssueIDSet.isDisjoint(with: Set(layout.issueIDs))
                    || layout.issueID.map { cardIssueIDSet.contains($0) } == true
            })?.frame
                ?? anchorOverride
                ?? markerPanel?.frame
                ?? .zero
        } else {
            if latestSuggestionOptions.isEmpty {
                cardSuggestions = latestSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? []
                    : rankedSuggestions(
                        [OverlaySuggestion(operation: .fixGrammar, text: latestSuggestion)],
                        original: segmentText
                    )
            } else {
                cardSuggestions = latestSuggestionOptions
            }
            anchorFrame = anchorOverride ?? markerPanel?.frame ?? .zero
            cardIssueIDs = []
            suggestionIssueIDs = [:]
        }
        guard !cardSuggestions.isEmpty, latestContext != nil else { return }
        guard anchorFrame != .zero else { return }
        hoveredIssueID = cardIssueIDs.first
        hoveredIssueIDs = Set(cardIssueIDs)
        refreshIssueUnderlineHighlight()
        // Capture the issue ID so the apply closure routes the user's
        // click to the partial-apply path. Falls back to the legacy
        // full-suggestion apply when the card is not bound to a
        // specific issue.
        let skipHandler: ((OverlaySuggestion) -> Void)? = !suggestionIssueIDs.isEmpty ? { [weak self] suggestion in
            guard let self,
                  let id = suggestionIssueIDs[self.hoverSuggestionKey(suggestion)] else { return }
            self.skipIssue(withID: id)
        } : nil
        if hoverCardPanel == nil {
            let host = NSHostingView(
                rootView: HoverSuggestionCardView(
                    originalText: segmentText,
                    suggestions: cardSuggestions,
                    anchorSource: markerAnchor.rawValue,
                    onApply: { [weak self] suggestion in
                        guard let self else { return }
                        self.applyFromHoverCard(
                            suggestion.text,
                            operation: suggestion.operation,
                            issueID: suggestionIssueIDs[self.hoverSuggestionKey(suggestion)]
                        )
                    },
                    onHoverChanged: { [weak self] isHovering in
                        self?.handleHoverCardHover(isHovering)
                    },
                    showsDiffPreview: self.detailedCorrectionsEnabled,
                    onSkip: skipHandler
                )
            )
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: hoverCardHeight(for: cardSuggestions)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.ignoresMouseEvents = false
            panel.contentView = host
            hoverCardPanel = panel
        } else if let host = hoverCardPanel?.contentView as? NSHostingView<HoverSuggestionCardView> {
            host.rootView = HoverSuggestionCardView(
                originalText: segmentText,
                suggestions: cardSuggestions,
                anchorSource: markerAnchor.rawValue,
                onApply: { [weak self] suggestion in
                    guard let self else { return }
                    self.applyFromHoverCard(
                        suggestion.text,
                        operation: suggestion.operation,
                        issueID: suggestionIssueIDs[self.hoverSuggestionKey(suggestion)]
                    )
                },
                onHoverChanged: { [weak self] isHovering in
                    self?.handleHoverCardHover(isHovering)
                },
                showsDiffPreview: self.detailedCorrectionsEnabled,
                onSkip: skipHandler
            )
        }
        updateHoverCardFrame(for: cardSuggestions, anchorFrame: anchorFrame)
        hoverCardPanel?.orderFrontRegardless()
        keepMarkerPanelBehindHoverCardIfNeeded()
    }

    private func hoverSuggestionKey(_ suggestion: OverlaySuggestion) -> String {
        "\(suggestion.operation.rawValue)|\(suggestion.text)"
    }

    private func isMouseInsideHoverCard() -> Bool {
        guard let hoverCardPanel, hoverCardPanel.isVisible else { return false }
        return hoverCardPanel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func keepMarkerPanelBehindHoverCardIfNeeded() {
        guard let hoverCardPanel,
              hoverCardPanel.isVisible,
              hoverCardPanel.windowNumber != 0 else {
            return
        }
        markerPanel?.order(.below, relativeTo: hoverCardPanel.windowNumber)
        extraMarkerPanels.forEach { $0.order(.below, relativeTo: hoverCardPanel.windowNumber) }
    }

    private func updateHoverCardFrame(
        for suggestions: [OverlaySuggestion],
        anchorFrame: CGRect? = nil
    ) {
        guard let frame = anchorFrame ?? markerPanel?.frame else { return }
        let cardFrame = clampedToVisibleScreens(
            CGRect(
                x: frame.minX,
                y: frame.maxY + 6,
                width: 440,
                height: hoverCardHeight(for: suggestions)
            )
        )
        hoverCardPanel?.setFrame(cardFrame, display: true)
    }

    private func hoverCardHeight(for suggestions: [OverlaySuggestion]) -> CGFloat {
        let count = max(1, min(12, suggestions.count))
        let listHeight = min(CGFloat(count) * 124, 452)
        return CGFloat(66 + listHeight)
    }

    /// User dismissed a specific underline via the Skip button on the
    /// hover card. We remember the signature so it does not re-appear
    /// on subsequent re-evaluations of this segment, drop it from
    /// `latestIssues`, hide the hover card, and immediately repaint
    /// the remaining underlines. The skip is scoped to the current
    /// segment's normalized text — editing the sentence brings back
    /// the full batch of suggestions on the next tick.
    private func skipIssue(withID id: UUID) {
        guard let skipped = latestIssues.first(where: { $0.id == id }),
              let segmentText = latestContext?.text else {
            hideHoverCard()
            return
        }
        let signature = skipped.segmentSignature ?? segmentCacheKey(segmentText)
        let ns = segmentText as NSString
        let spanText: String
        if skipped.localRange.location >= 0,
           NSMaxRange(skipped.localRange) <= ns.length,
           skipped.localRange.length > 0 {
            spanText = ns.substring(with: skipped.localRange)
        } else {
            spanText = ""
        }
        let sig = skipSignature(
            segmentSignature: signature,
            issue: skipped,
            spanText: spanText
        )
        skippedIssueSignatures.insert(sig)

        textoraDiagLog(
            "skipIssue",
            "dismiss id=\(skipped.id) category=\(skipped.category.rawValue) "
            + "span=\(textoraDiagPreview(spanText)) "
            + "replacement=\(textoraDiagPreview(skipped.replacement))"
        )

        // Drop the skipped entry from live state and recompute the
        // remaining ring / primary-suggestion projection so the
        // floating icon no longer nudges the user toward it.
        let remaining = latestIssues.filter { $0.id != skipped.id }
        latestIssues = remaining
        hoveredIssueID = nil
        hoveredIssueIDs.remove(skipped.id)
        if remaining.isEmpty {
            suggestionState = .looksGood
            latestSuggestion = ""
            latestSuggestionOptions = []
            latestIssueRange = nil
        } else if let primary = primaryIssue(in: remaining, original: segmentText) {
            latestSuggestion = applyIssueToSegment(segmentText, issue: primary)
            latestIssueRange = primary.localRange
            latestSuggestionOptions = overlaySuggestions(for: remaining, in: segmentText)
        }

        hideHoverCard()
        updateRingColor()
        if remaining.isEmpty {
            scheduleSegmentRecheckAfterApply()
        }
        if let frame = lastFrameSnapshot() {
            updateMarker(caretFrame: lastMarkerCaretFrame, fieldFrame: frame, anchor: markerAnchor)
        }
    }

    /// Small convenience so `skipIssue` can redraw without re-running
    /// the AX geometry query — we already have a stable field frame
    /// cached from the last `updateMarker` pass.
    private func lastFrameSnapshot() -> CGRect? {
        let frame = lastMarkerFieldFrame ?? markerPanel?.frame ?? .zero
        return frame == .zero ? nil : frame
    }

    private func localizedApplyTarget(
        for issue: OverlayIssue,
        in context: TextAccessService.FocusedTextContext,
        sourceRange: NSRange
    ) -> (context: TextAccessService.FocusedTextContext, issue: OverlayIssue, suggestion: String)? {
        let fullNS = context.text as NSString
        guard sourceRange.location >= 0,
              NSMaxRange(sourceRange) <= fullNS.length,
              issue.localRange.location >= sourceRange.location else {
            return nil
        }

        let segmentText = fullNS.substring(with: sourceRange)
        let localRange = NSRange(
            location: issue.localRange.location - sourceRange.location,
            length: issue.localRange.length
        )
        let segmentNS = segmentText as NSString
        guard localRange.location >= 0,
              NSMaxRange(localRange) <= segmentNS.length else {
            return nil
        }

        let localIssue = OverlayIssue(
            id: issue.id,
            localRange: localRange,
            originalText: segmentNS.substring(with: localRange),
            category: issue.category,
            replacement: issue.replacement,
            reason: issue.reason,
            segmentSignature: issue.segmentSignature,
            sourceSegmentRange: nil
        )
        let scoped = scopedFocusedContext(
            context,
            scope: CorrectionScope(text: segmentText, range: sourceRange)
        )
        let suggestion = applyIssueToSegment(segmentText, issue: localIssue)
        return (scoped, localIssue, suggestion)
    }

    private func localizedGeometryTarget(
        for issue: OverlayIssue,
        in context: TextAccessService.FocusedTextContext
    ) -> (context: TextAccessService.FocusedTextContext, localRange: NSRange)? {
        guard let sourceRange = issue.sourceSegmentRange else {
            return nil
        }
        let fullNS = context.text as NSString
        guard sourceRange.location >= 0,
              NSMaxRange(sourceRange) <= fullNS.length,
              issue.localRange.location >= sourceRange.location else {
            return nil
        }

        let segmentText = fullNS.substring(with: sourceRange)
        let localRange = NSRange(
            location: issue.localRange.location - sourceRange.location,
            length: issue.localRange.length
        )
        let segmentNS = segmentText as NSString
        guard localRange.location >= 0,
              NSMaxRange(localRange) <= segmentNS.length else {
            return nil
        }

        let scoped = scopedFocusedContext(
            context,
            scope: CorrectionScope(text: segmentText, range: sourceRange)
        )
        return (scoped, localRange)
    }

    private func applyFromHoverCard(_ suggestion: String, operation: RewriteOperation, issueID: UUID?) {
        guard let context = latestContext, !latestSuggestion.isEmpty else {
            textoraDiagLog(
                "applyFromHoverCard",
                "abort: latestContext=\(latestContext == nil ? "nil" : "set") "
                + "latestSuggestion.isEmpty=\(latestSuggestion.isEmpty)"
            )
            return
        }
        if !smartAIEnabled {
            UserDefaults.standard.set(operation.rawValue, forKey: Self.lastOperationKey)
        }
        let previousSuggestion = latestSuggestion
        let previousSuggestionOptions = latestSuggestionOptions
        let previousContext = latestContext
        let previousIssues = latestIssues
        let previousIssueRange = latestIssueRange

        // Resolve the targeted issue (if any) so we can apply ONLY its
        // span and leave the other issues' underlines visible. When
        // `issueID` is nil we keep legacy behavior — apply the whole
        // `suggestion` against `latestIssueRange`.
        let targetedIssue = issueID.flatMap { id in
            previousIssues.first(where: { $0.id == id })
        }
        let applyContext = context
        let applySuggestion = suggestion
        let applyPatch = targetedIssue?.patch
        let preferredLocalRange = targetedIssue?.localRange ?? latestIssueRange
        let appliedSegmentText = context.text
        // Keep per-issue applies anchored to the FULL focused value.
        // The shifted `latestIssues` already carry full-text ranges, and
        // host AX offsets become less reliable when we re-scope the
        // context back down to the sentence and then try to rediscover its
        // absolute location inside a rich text composer.

        if let applyPatch, !applyPatch.isValid(in: applyContext.text) {
            textoraDiagLog(
                "applyFromHoverCard",
                "reject outdated patch id=\(applyPatch.id) range=\(applyPatch.start):\(applyPatch.end)"
            )
            postStatus("Suggestion outdated, re-analyzing")
            evaluateCurrentText()
            return
        }

        textoraDiagLog(
            "applyFromHoverCard",
            "invoke bundle=\(applyContext.targetBundleID) "
            + "segment=\(textoraDiagPreview(applyContext.text)) "
            + "suggestion=\(textoraDiagPreview(applySuggestion)) "
            + "issueID=\(issueID?.uuidString ?? "nil") "
            + "preferredLocal=\(preferredLocalRange.map { "\($0.location):\($0.length)" } ?? "nil")"
        )

        if let issueID {
            pendingHoverCardIssueIDsAfterApply = hoveredIssueIDs
                .filter { $0 != issueID }
                .map { $0 }
        } else {
            pendingHoverCardIssueIDsAfterApply = []
        }

        // Hide panels FIRST so AX focus can return to the original text field.
        hideMarkerAndCard()

        // Brief delay lets the system settle focus back to the text field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let result: TextAccessService.ApplyResult
            result = self.textService.applyLocalizedRewrite(
                applySuggestion,
                basedOn: applyContext,
                preferredLocalRange: preferredLocalRange
            )
            textoraDiagLog("applyFromHoverCard", "applyLocalizedRewrite result=\(result)")
            switch result {
            case .success:
                self.handleHoverApplySuccess(
                    previousContext: context,
                    appliedSegmentText: appliedSegmentText,
                    rewrittenSegmentText: applySuggestion,
                    appliedIssue: targetedIssue,
                    previousIssues: previousIssues
                )

            case .clipboardArmed:
                self.suggestionState = .needsAttention
                self.latestSuggestion = previousSuggestion
                self.latestSuggestionOptions = previousSuggestionOptions
                self.latestContext = previousContext
                self.latestIssues = previousIssues
                self.latestIssueRange = previousIssueRange
                self.postStatus("Apply requires user action")
                self.updateRingColor()

            case .failed, .unsupportedTarget:
                self.suggestionState = .needsAttention
                self.latestSuggestion = previousSuggestion
                self.latestSuggestionOptions = previousSuggestionOptions
                self.latestContext = previousContext
                self.latestIssues = previousIssues
                self.latestIssueRange = previousIssueRange
                self.postStatus("Apply failed in this field")
                self.updateRingColor()
            }
        }
    }

    /// Routes a successful per-span apply: drop caches for the
    /// just-applied segment so the next evaluation tick definitely
    /// re-runs `auditIssues` against the post-apply field value, then
    /// optimistically retain the still-pending issues (with shifted
    /// offsets) so the user sees the other underlines disappear from
    /// the DOM-corrupted Slack readback only briefly. The debounced
    /// re-evaluation either repaints those underlines on top of the
    /// new text or — if the segment is now clean — flips the floating
    /// ring to green.
    private func handleHoverApplySuccess(
        previousContext: TextAccessService.FocusedTextContext,
        appliedSegmentText: String,
        rewrittenSegmentText: String,
        appliedIssue: OverlayIssue?,
        previousIssues: [OverlayIssue]
    ) {
        clearRecentAutoEvaluationSnapshot()
        postApplyAcceptedValueSegment = nil
        invalidateSegmentCache(for: appliedSegmentText)
        invalidateSegmentCache(for: rewrittenSegmentText)
        localBatchMutationGraceUntil = Date().addingTimeInterval(2.0)

        guard let appliedIssue else {
            pendingHoverCardIssueIDsAfterApply = []
            rememberAppliedRewrite(original: appliedSegmentText, rewritten: rewrittenSegmentText)
            suggestionState = .looksGood
            latestSuggestion = ""
            latestSuggestionOptions = []
            latestContext = nil
            latestIssueRange = nil
            latestIssues = []
            hoveredIssueID = nil
            hoveredIssueIDs = []
            updateRingColor()
            scheduleSegmentRecheckAfterApply()
            return
        }

        let updatedText = applyIssueToSegment(previousContext.text, issue: appliedIssue)
        rememberAppliedRewrite(
            original: appliedIssue.patch.originalText,
            rewritten: appliedIssue.replacement
        )
        if let sourceRange = appliedIssue.sourceSegmentRange,
           let localized = localizedApplyTarget(
            for: appliedIssue,
            in: previousContext,
            sourceRange: sourceRange
           ) {
            rememberAppliedRewrite(
                original: localized.context.text,
                rewritten: localized.suggestion
            )
        } else {
            rememberAppliedRewrite(original: previousContext.text, rewritten: updatedText)
        }
        let remaining = remainingIssuesAfterApply(
            appliedIssue: appliedIssue,
            from: previousIssues
        )
        textoraDiagLog(
            "applyFromHoverCard",
            "partial apply success — applied id=\(appliedIssue.id) "
            + "category=\(appliedIssue.category.rawValue) "
            + "remainingCarryover=\(remaining.count)"
        )

        guard !remaining.isEmpty, let primary = primaryIssue(in: remaining, original: updatedText) else {
            pendingHoverCardIssueIDsAfterApply = []
            suggestionState = .looksGood
            latestSuggestion = ""
            latestSuggestionOptions = []
            latestContext = nil
            latestIssueRange = nil
            latestIssues = []
            hoveredIssueID = nil
            hoveredIssueIDs = []
            updateRingColor()
            scheduleSegmentRecheckAfterApply()
            return
        }

        let updatedContext = TextAccessService.FocusedTextContext(
            text: updatedText,
            frame: previousContext.frame,
            usesSelection: previousContext.usesSelection,
            selectedRange: previousContext.selectedRange,
            targetElement: previousContext.targetElement,
            targetAppPID: previousContext.targetAppPID,
            targetBundleID: previousContext.targetBundleID,
            anchor: previousContext.anchor
        )
        suggestionState = .needsAttention
        latestContext = updatedContext
        latestIssues = remaining
        hoveredIssueID = nil
        hoveredIssueIDs = []
        latestSuggestion = applyIssueToSegment(updatedText, issue: primary)
        latestSuggestionOptions = overlaySuggestions(for: remaining, in: updatedText)
        latestIssueRange = primary.localRange
        lastCheckedValueSegment = updatedText
        updateRingColor()
        if let frame = lastFrameSnapshot() {
            updateMarker(caretFrame: lastMarkerCaretFrame, fieldFrame: frame, anchor: markerAnchor)
        }
        reopenPendingHoverCardIfNeeded()
    }

    private func reopenPendingHoverCardIfNeeded() {
        guard !pendingHoverCardIssueIDsAfterApply.isEmpty else { return }
        let ids = pendingHoverCardIssueIDsAfterApply
        pendingHoverCardIssueIDsAfterApply = []
        let remaining = ids.compactMap { id in latestIssues.first(where: { $0.id == id }) }
        guard !remaining.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showHoverCard(for: remaining)
        }
    }

    /// Returns the issues that survive applying `appliedIssue`. Issues
    /// strictly to the left are unchanged; issues strictly to the
    /// right are shifted by the length delta; overlapping issues are
    /// invalidated. Currently only used for diagnostics — the live
    /// marker is rebuilt by the debounced re-evaluation.
    private func remainingIssuesAfterApply(
        appliedIssue: OverlayIssue,
        from previous: [OverlayIssue]
    ) -> [OverlayIssue] {
        let oldRange = appliedIssue.localRange
        let oldEnd = NSMaxRange(oldRange)
        let replacementLen = (appliedIssue.replacement as NSString).length
        let delta = replacementLen - oldRange.length

        var result: [OverlayIssue] = []
        for issue in previous where issue.id != appliedIssue.id {
            let r = issue.localRange
            let rEnd = NSMaxRange(r)
            if rEnd <= oldRange.location {
                result.append(issue)
            } else if r.location >= oldEnd {
                let shifted = NSRange(location: r.location + delta, length: r.length)
                guard shifted.location >= 0 else { continue }
                result.append(
                    OverlayIssue(
                        id: issue.id,
                        localRange: shifted,
                        originalText: issue.patch.originalText,
                        category: issue.category,
                        replacement: issue.replacement,
                        reason: issue.reason,
                        segmentSignature: issue.segmentSignature,
                        sourceSegmentRange: shiftedSourceSegmentRange(
                            issue.sourceSegmentRange,
                            afterApplying: oldRange,
                            delta: delta
                        )
                    )
                )
            } else {
                continue
            }
        }
        return result
    }

    private func shiftedSourceSegmentRange(
        _ source: NSRange?,
        afterApplying applied: NSRange,
        delta: Int
    ) -> NSRange? {
        guard let source else { return nil }
        let appliedEnd = NSMaxRange(applied)
        let sourceEnd = NSMaxRange(source)
        if sourceEnd <= applied.location {
            return source
        }
        if source.location >= appliedEnd {
            return NSRange(location: max(0, source.location + delta), length: source.length)
        }
        return NSRange(location: source.location, length: max(0, source.length + delta))
    }

    /// Triggers a delayed `evaluateCurrentText()` after a successful
    /// apply so the AI gets to see the post-paste field value (Slack /
    /// other Electron hosts need ~250 ms for AX to settle), without
    /// thrashing the model when the user clicks rapidly.
    private func scheduleSegmentRecheckAfterApply() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.evaluateCurrentText()
        }
    }

    private func hideHoverCard() {
        cancelScheduledHoverHide()
        isHoverCardHovered = false
        hoverCardPanel?.orderOut(nil)
    }

    private func hideIssueOverlayPanelsAndMarkers() {
        isMarkerHovered = false
        cancelScheduledHoverHide()
        issueOverlayPanel?.orderOut(nil)
        extraIssueOverlayPanels.forEach { $0.orderOut(nil) }
        markerPanel?.orderOut(nil)
        extraMarkerPanels.forEach { $0.orderOut(nil) }
        issuePanelLayouts = []
        lastMarkerDebugSignature = nil
    }

    private func hideMarkerAndCard() {
        isMarkerHovered = false
        isHoverCardHovered = false
        cancelScheduledHoverHide()
        hideIssueOverlayPanelsAndMarkers()
        hideHoverCard()
    }

    private func scheduleHoverHideIfNeeded() {
        cancelScheduledHoverHide()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isMarkerHovered && !self.isHoverCardHovered {
                self.hideHoverCard()
            }
        }
        hoverHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
    }

    private func cancelScheduledHoverHide() {
        hoverHideTask?.cancel()
        hoverHideTask = nil
    }

    private func ringColors(for state: SuggestionState) -> [Color] {
        if smartAIEnabled {
            switch state {
            case .neutral:
                return [.blue]
            case .needsAttention:
                return [.red]
            case .looksGood:
                return [.green]
            }
        }
        switch state {
        case .neutral:
            return [.blue]
        case .needsAttention:
            let colors = suggestionOperationColors()
            return colors.isEmpty ? [.red] : colors
        case .looksGood:
            if hasActiveSuggestion {
                let colors = suggestionOperationColors()
                return colors.isEmpty ? [.blue] : colors
            }
            return [.green]
        }
    }

    private var hasActiveSuggestion: Bool {
        !latestSuggestionOptions.isEmpty
            || !latestIssues.isEmpty
            || !latestSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowLooksGoodBadge: Bool {
        suggestionState == .looksGood && !hasActiveSuggestion
    }

    private func issueOverlayColors() -> [Color] {
        let colors = suggestionOperationColors()
        return colors.isEmpty ? TextoraSuggestionColors.brandGradient : colors
    }

    private func issueOverlayColors(for issueIDs: [UUID]) -> [Color] {
        var seen = Set<String>()
        var colors: [Color] = []
        for id in issueIDs {
            guard let category = latestIssues.first(where: { $0.id == id })?.category else { continue }
            let key = category.rawValue
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            colors.append(TextoraSuggestionColors.color(for: category))
        }
        return colors
    }

    private func suggestionOperationColors() -> [Color] {
        if smartAIEnabled {
            let proposed = latestSuggestionOptions.filter { $0.isRecommended || $0.isOptional }
            let source = proposed.isEmpty ? latestSuggestionOptions : proposed
            let colors = uniqueOperationColors(
                source.map(\.operation) + latestIssues.map(\.category)
            )
            return colors
        }
        return uniqueOperationColors(
            latestSuggestionOptions.map(\.operation) + latestIssues.map(\.category)
        )
    }

    private func uniqueOperationColors(_ operations: [RewriteOperation]) -> [Color] {
        var seen = Set<String>()
        var colors: [Color] = []
        for operation in operations {
            let key = operation.rawValue
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            colors.append(TextoraSuggestionColors.color(for: operation))
        }
        return colors
    }

    private func clampedToVisibleScreens(_ rect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) ?? NSScreen.main else {
            return rect
        }
        let vf = screen.visibleFrame
        let padding: CGFloat = 6
        let minX = vf.minX + padding
        let maxX = vf.maxX - rect.width - padding
        let minY = vf.minY + padding
        let maxY = vf.maxY - rect.height - padding
        return CGRect(
            x: min(max(rect.minX, minX), maxX),
            y: min(max(rect.minY, minY), maxY),
            width: rect.width,
            height: rect.height
        )
    }
}
