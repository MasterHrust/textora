import AppKit
import ApplicationServices
import UniformTypeIdentifiers

extension Notification.Name {
    static let textoraAccessibilityPermissionDidChange = Notification.Name("textoraAccessibilityPermissionDidChange")
}

@MainActor
final class AccessibilityPermissionMonitor {
    static let shared = AccessibilityPermissionMonitor()

    private var timer: Timer?
    private(set) var isTrusted: Bool

    private init() {
        isTrusted = AXIsProcessTrusted()
    }

    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }
        refreshNow()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] (_: Timer) in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func refreshNow() -> Bool {
        let next = AXIsProcessTrusted()
        guard next != isTrusted else { return next }
        isTrusted = next
        NotificationCenter.default.post(
            name: .textoraAccessibilityPermissionDidChange,
            object: self,
            userInfo: ["isTrusted": next]
        )
        return next
    }
}

// MARK: - Removed diagnostics compatibility

func removeObsoleteTextoraDiagnostics() {
    let manager = FileManager.default
    let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let diagnosticsDirectory = appSupport
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.textora.app", isDirectory: true)
        .appendingPathComponent("Diagnostics", isDirectory: true)
    try? manager.removeItem(at: URL(fileURLWithPath: "/tmp/TextoraMarkerGeometry.log"))
    try? manager.removeItem(at: diagnosticsDirectory)
    UserDefaults.standard.removeObject(forKey: "selectionAssistant.diagnostics.enabled")
}

@inline(__always)
func textoraDiagLog(_ category: String, _ message: @autoclosure () -> String) {}

@inline(__always)
func textoraDiagPreview(_ value: String, limit: Int = 120) -> String {
    "<redacted len=\((value as NSString).length)>"
}

@inline(__always)
func textoraDiagRect(_ rect: CGRect?) -> String {
    guard let rect else { return "nil" }
    guard !rect.isEmpty else { return "empty" }
    return "x:\(Int(rect.minX)) y:\(Int(rect.minY)) w:\(Int(rect.width)) h:\(Int(rect.height))"
}

@inline(__always)
func textoraDiagRects(_ rects: [CGRect], limit: Int = 8) -> String {
    guard !rects.isEmpty else { return "[]" }
    return "[" + rects.prefix(limit).map { textoraDiagRect($0) }.joined(separator: "; ") + "]"
}

@inline(__always)
func textoraDiagScreen(_ rect: CGRect?) -> String {
    guard let rect, !rect.isEmpty else { return "nil" }
    let point = CGPoint(x: rect.midX, y: rect.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main else {
        return "nil"
    }
    let name = screen.localizedName.isEmpty ? "unknown" : screen.localizedName
    return "\(name) frame=\(textoraDiagRect(screen.frame)) visible=\(textoraDiagRect(screen.visibleFrame)) scale=\(String(format: "%.2f", screen.backingScaleFactor))"
}

@inline(__always)
func textoraDiagNSRange(_ range: NSRange?) -> String {
    guard let range else { return "nil" }
    return "\(range.location):\(range.length)"
}

enum TextoraCharacterGeometry {
    static func rect(
        for overlap: NSRange,
        in fragment: TextAccessService.TextFragment
    ) -> CGRect? {
        let localRange = NSRange(
            location: max(0, overlap.location - fragment.range.location),
            length: max(0, overlap.length)
        )
        return rect(
            forLocalRange: localRange,
            in: fragment.text as NSString,
            fragmentRect: fragment.rect
        )
    }

    static func rect(
        forLocalRange rawLocalRange: NSRange,
        in text: NSString,
        fragmentRect: CGRect
    ) -> CGRect? {
        guard !fragmentRect.isEmpty, text.length > 0 else { return nil }
        let safeLocation = max(0, min(rawLocalRange.location, text.length))
        let safeLength = max(0, min(rawLocalRange.length, text.length - safeLocation))
        guard safeLength > 0 else { return nil }

        let prefixWeights = cumulativeWeights(for: text)
        let totalWeight = max(prefixWeights.last ?? 0, CGFloat(text.length) * 0.35)
        let startWeight = prefixWeights[safeLocation]
        let endWeight = prefixWeights[safeLocation + safeLength]
        let startRatio = startWeight / totalWeight
        let endRatio = endWeight / totalWeight

        let x = fragmentRect.minX + fragmentRect.width * startRatio
        let measuredWidth = fragmentRect.width * max(0.02, endRatio - startRatio)
        let width = max(6, min(measuredWidth, max(6, fragmentRect.maxX - x)))
        return CGRect(
            x: x,
            y: fragmentRect.minY,
            width: width,
            height: fragmentRect.height
        )
    }

    private static func cumulativeWeights(for text: NSString) -> [CGFloat] {
        var weights: [CGFloat] = [0]
        weights.reserveCapacity(text.length + 1)
        var running: CGFloat = 0
        for index in 0..<text.length {
            running += widthWeight(for: text.character(at: index))
            weights.append(running)
        }
        return weights
    }

    static func widthWeight(for codeUnit: unichar) -> CGFloat {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return 1.0 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 0.42 }
        if CharacterSet.punctuationCharacters.contains(scalar) { return 0.38 }
        if CharacterSet.decimalDigits.contains(scalar) { return 0.92 }

        switch scalar {
        case "i", "l", "I", "j", "t", "f", "r", "1",
             "і", "ї", "ј", "г", "ґ", "!", "|":
            return 0.62
        case "m", "w", "M", "W", "@", "#", "%", "&",
             "Ж", "Ш", "Щ", "Ю", "ж", "ш", "щ", "ю":
            return 1.34
        default:
            return CharacterSet.uppercaseLetters.contains(scalar) ? 1.12 : 1.0
        }
    }
}

final class TextAccessService {
    struct TextAnchor {
        let rect: CGRect
        let source: Source
        let confidence: Confidence
        let rawRect: CGRect?

        enum Source: String {
            case axBoundsForRange
            case axCaret
            case axLineBounds
            case axElementFrame
            case visiblePageText
            case focusedWindow
            case clipboardFallback
            case mouseFallback
        }

        enum Confidence: String {
            case exact
            case good
            case approximate
            case weak
        }

        var debugSummary: String {
            let r = rect
            let rounded = "x:\(Int(r.minX)) y:\(Int(r.minY)) w:\(Int(r.width)) h:\(Int(r.height))"
            guard let rawRect else {
                return "\(source.rawValue)/\(confidence.rawValue) \(rounded)"
            }
            let raw = "raw x:\(Int(rawRect.minX)) y:\(Int(rawRect.minY)) w:\(Int(rawRect.width)) h:\(Int(rawRect.height))"
            return "\(source.rawValue)/\(confidence.rawValue) \(rounded) \(raw)"
        }
    }

    struct TextFragment {
        let text: String
        let range: NSRange
        let rect: CGRect
    }

    struct FocusedTextContext {
        let text: String
        let frame: CGRect
        let usesSelection: Bool
        let selectedRange: CFRange?
        let targetElement: AXUIElement
        let targetAppPID: pid_t
        let targetBundleID: String
        let anchor: TextAnchor
        let textFragments: [TextFragment]

        init(
            text: String,
            frame: CGRect,
            usesSelection: Bool,
            selectedRange: CFRange?,
            targetElement: AXUIElement,
            targetAppPID: pid_t,
            targetBundleID: String,
            anchor: TextAnchor? = nil,
            textFragments: [TextFragment] = []
        ) {
            self.text = text
            self.frame = frame
            self.usesSelection = usesSelection
            self.selectedRange = selectedRange
            self.targetElement = targetElement
            self.targetAppPID = targetAppPID
            self.targetBundleID = targetBundleID
            self.anchor = anchor ?? TextAnchor(
                rect: frame,
                source: .axElementFrame,
                confidence: .approximate,
                rawRect: nil
            )
            self.textFragments = textFragments
        }
    }

    struct SelectedTextSignal {
        let hasSelection: Bool
        let bounds: CGRect?
        let selectedRange: CFRange?
        let targetElement: AXUIElement
        let targetAppPID: pid_t
        let targetBundleID: String
    }

    struct FrontmostAppInfo {
        let bundleID: String
        let displayName: String
    }

    enum AppConsentStatus: String {
        case unknown
        case allowed
        case denied
    }

    enum ApplyResult: Equatable {
        case success
        case failed
        case unsupportedTarget
        /// The corrected text was armed on the system pasteboard because
        /// the only available write strategy (Cmd+A + Cmd+V over the full
        /// value) would have destroyed surrounding layout — e.g. in Slack
        /// a composer that contains URL/mention paragraph blocks around
        /// the correction scope. The user can press ⌘V to apply the fix
        /// without us damaging adjacent blocks.
        case clipboardArmed
    }

    enum MailManualCaptureResult {
        case success(FocusedTextContext)
        case notMail
        case notAllowed
        case noSelection
        case busy
    }

    private let appConsentKey = "textora.appConsentByBundleID"
    private let legacyAppConsentKey = "fixness.appConsentByBundleID"
    /// Apps where floating helper should never appear (file managers / terminals).
    private let helperSuppressedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]
    private let sensitiveFieldHints: [String] = [
        "password", "passcode", "otp", "token", "2fa", "login", "log in", "sign in", "sign-in",
        "signin", "username", "user name", "credential", "auth", "authentication", "authorize",
        "verification code", "secret", "passphrase", "unlock", "keychain",
        "private key", "account password", "admin password"
    ]
    private let highRiskSensitiveFieldHints: [String] = [
        "security", "secure", "certificate", "certificates", "signing", "code sign", "codesign",
        "developer id", "apple id"
    ]
    private let highRiskSensitiveBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.apple.SecurityAgent",
        "com.apple.keychainaccess"
    ]
    private let highRiskSensitiveBundleFragments: [String] = [
        "xcode", "securityagent", "keychain"
    ]
    private let neverEditableRoles: Set<String> = [
        "AXApplication",
        "AXBrowser",
        "AXButton",
        "AXCell",
        "AXCheckBox",
        "AXDisclosureTriangle",
        "AXGroup",
        "AXImage",
        "AXLayoutArea",
        "AXLayoutItem",
        "AXLink",
        "AXList",
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXMenuItem",
        "AXOutline",
        "AXPopUpButton",
        "AXRadioButton",
        "AXRow",
        "AXScrollArea",
        "AXSplitter",
        "AXStaticText",
        "AXTable",
        "AXToolbar",
        "AXWindow"
    ]
    private let maxContextCharacters = 6000
    private var isCopyProbeInProgress = false
    private var lastCopyProbeAt: Date = .distantPast

    /// Reuse one `kAXFocusedUIElement` / editable resolve / focused window read per outer call (e.g. one helper timer tick).
    func withCoalescedFocusQueries<R>(_ body: () throws -> R) rethrows -> R {
        focusCoalesceDepth += 1
        if focusCoalesceDepth == 1 {
            coalesceMemoFocusedInitialized = false
            coalesceMemoEditableInitialized = false
            coalesceMemoWindowFrameInitialized = false
        }
        defer {
            focusCoalesceDepth -= 1
            if focusCoalesceDepth == 0 {
                coalesceMemoFocusedInitialized = false
                coalesceMemoEditableInitialized = false
                coalesceMemoWindowFrameInitialized = false
            }
        }
        return try body()
    }

    func invalidateTransientFocusCaches() {
        coalesceMemoFocusedInitialized = false
        coalesceMemoFocused = nil
        coalesceMemoEditableInitialized = false
        coalesceMemoEditable = nil
        coalesceMemoWindowFrameInitialized = false
        coalesceMemoWindowFrame = nil
        googleDocsContextCache = nil
        googleDocsFrontmostCache = nil
    }

    private var focusCoalesceDepth = 0
    private var coalesceMemoFocusedInitialized = false
    private var coalesceMemoFocused: AXUIElement?
    private var coalesceMemoEditableInitialized = false
    private var coalesceMemoEditable: AXUIElement?
    private var coalesceMemoWindowFrameInitialized = false
    private var coalesceMemoWindowFrame: CGRect?
    private var googleDocsContextCache: (createdAt: Date, maxLength: Int, context: FocusedTextContext?)?
    private var googleDocsFrontmostCache: (createdAt: Date, isDocs: Bool)?
    private var googleSheetsFrontmostCache: (createdAt: Date, isSheets: Bool)?
    private var lastGoogleDocsDebugSignature: String?
    private let transientPopupRoles: Set<String> = [
        "AXComboBox",
        "AXHelpTag",
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuItem",
        "AXMenuButton",
        "AXPopover",
        "AXPopUpButton"
    ]

    func hasAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        Task { @MainActor in
            AccessibilityPermissionMonitor.shared.refreshNow()
        }
        return trusted
    }

    @discardableResult
    private func registerForAccessibilityPermission() -> Bool {
        registerRunningAppForSystemServices()
        touchAccessibilityAPIForTCCRegistration()
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        touchAccessibilityAPIForTCCRegistration()
        Task { @MainActor in
            AccessibilityPermissionMonitor.shared.refreshNow()
        }
        return trusted
    }

    private func registerRunningAppForSystemServices() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        _ = LSRegisterURL(bundleURL as CFURL, true)
    }

    private func touchAccessibilityAPIForTCCRegistration() {
        let selfElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var selfRole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            selfElement,
            kAXRoleAttribute as CFString,
            &selfRole
        )
        var selfWindows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            selfElement,
            kAXWindowsAttribute as CFString,
            &selfWindows
        )

        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        if let focusedAppElement = focusedApp as! AXUIElement? {
            var focusedRole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                focusedAppElement,
                kAXRoleAttribute as CFString,
                &focusedRole
            )
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                appElement,
                kAXRoleAttribute as CFString,
                &role
            )
        }
    }

    func openAccessibilitySettings() {
        _ = registerForAccessibilityPermission()
        Self.openAccessibilitySettingsPane()
        Task { @MainActor in
            AccessibilityPermissionMonitor.shared.refreshNow()
        }
    }

    private static func openAccessibilitySettingsPane() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.systempreferences"
        ]

        for rawURL in settingsURLs {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        let appURLs = [
            URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            URL(fileURLWithPath: "/System/Applications/System Preferences.app")
        ]
        for appURL in appURLs where FileManager.default.fileExists(atPath: appURL.path) {
            if NSWorkspace.shared.open(appURL) {
                return
            }
        }
    }

    func getSelectedText() -> String {
        if let axText = readViaAccessibility(), !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return axText
        }
        return readClipboardAfterCopyIfSelectionLikely() ?? ""
    }

    func replaceSelectedText(with text: String) -> Bool {
        if replaceViaAccessibility(text) {
            return true
        }
        return false
    }

    func focusedEditableFrame() -> CGRect? {
        guard let focused = focusedEditableElement() else { return nil }
        guard
            let point = axPoint(of: focused, attribute: kAXPositionAttribute),
            let size = axSize(of: focused, attribute: kAXSizeAttribute)
        else {
            return nil
        }
        return normalizedAXRect(CGRect(origin: point, size: size))
    }

    func focusedWindowFrame() -> CGRect? {
        if focusCoalesceDepth > 0 {
            if coalesceMemoWindowFrameInitialized {
                return coalesceMemoWindowFrame
            }
            let v = queryFocusedWindowFrameFromSystem()
            coalesceMemoWindowFrame = v
            coalesceMemoWindowFrameInitialized = true
            return v
        }
        return queryFocusedWindowFrameFromSystem()
    }

    func floatingHelperAnchorWindowFrame() -> CGRect? {
        if let frame = focusedWindowFrame(),
           isUsableFloatingHelperWindowFrame(frame) {
            return frame
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        return frontmostCGWindowFrame(for: pid, requireMainAppWindow: true)
            ?? mainCGWindowFrame(for: pid, requireMainAppWindow: true)
            ?? frontmostCGWindowFrame(for: pid)
            ?? mainCGWindowFrame(for: pid)
    }

    private func queryFocusedWindowFrameFromSystem() -> CGRect? {
        if let browserFrame = frontmostBrowserCGWindowFrame() {
            return browserFrame
        }
        if isGoogleDocsFrontmost(),
           let focusedWindow = queryFocusedWindowElementFromSystem() {
            let axFrame = elementFrame(of: focusedWindow)
            var pid: pid_t = 0
            if AXUIElementGetPid(focusedWindow, &pid) == .success,
               pid != 0,
               resolvedBundleID(forOwningPID: pid) == "com.google.Chrome" {
                return focusedCGWindowFrame(for: pid, matching: axFrame)
                    ?? axFrame
                    ?? mainCGWindowFrame(for: pid)
            }
        }
        guard let element = queryFocusedWindowElementFromSystem() else {
            guard let focused = focusedElement() else { return nil }
            var focusedPID: pid_t = 0
            guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID != 0 else { return nil }
            return mainCGWindowFrame(for: focusedPID)
        }
        guard !isTransientPopupLike(element) else { return nil }
        let axFrame = elementFrame(of: element)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else {
            return axFrame
        }
        guard let cgFrame = mainCGWindowFrame(for: pid) else {
            return axFrame
        }
        if resolvedBundleID(forOwningPID: pid) == "com.google.Chrome",
           isGoogleDocsFrontmost() {
            return focusedCGWindowFrame(for: pid, matching: axFrame) ?? cgFrame
        }
        guard let axFrame else { return cgFrame }
        if shouldPreferCGWindowFrame(cgFrame, overAXFrame: axFrame) {
            return cgFrame
        }
        return axFrame
    }

    private func frontmostBrowserCGWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              isBrowserBundleID(bundleID) else {
            return nil
        }
        let pid = app.processIdentifier
        let axFrame = queryFocusedWindowElementFromSystem().flatMap { elementFrame(of: $0) }
        if let axFrame,
           !isSmallDetachedPopupFrame(axFrame),
           let focused = focusedCGWindowFrame(for: pid, matching: axFrame, requireMainBrowserWindow: true) {
            return focused
        }
        return frontmostCGWindowFrame(for: pid, requireMainBrowserWindow: true)
            ?? frontmostCGWindowFrame(for: pid)
    }

    func isCurrentFocusOwnedBy(bundleID expectedBundleID: String) -> Bool {
        guard !expectedBundleID.isEmpty else { return false }
        if let focused = focusedElement(), bundleID(for: focused) == expectedBundleID {
            return true
        }
        if let window = queryFocusedWindowElementFromSystem(), bundleID(for: window) == expectedBundleID {
            return true
        }
        return false
    }

    func isCurrentFocusInTransientPopupOrMenu() -> Bool {
        if let window = queryFocusedWindowElementFromSystem(), isTransientPopupLike(window) {
            return true
        }
        guard var current = focusedElement() else { return false }
        if isTransientPopupLike(current) { return true }
        for _ in 0..<10 {
            guard let parent = axElement(of: current, attribute: kAXParentAttribute as String) else { break }
            current = parent
            if isTransientPopupLike(current) { return true }
        }
        return false
    }

    func isGoogleSheetsSelectionSurfaceFrontmost() -> Bool {
        isGoogleSheetsFrontmost()
    }

    func currentFocusSurfaceSignature() -> String {
        let front = frontmostAppInfo()
        let frontPart = "\(front?.bundleID ?? "nil"):\(front?.displayName ?? "nil")"
        let windowPart: String = {
            guard let window = queryFocusedWindowElementFromSystem() else {
                if let focused = focusedElement() {
                    return "window=nil focused=\(elementSignature(focused))"
                }
                return "window=nil focused=nil"
            }
            return "window=\(elementSignature(window))"
        }()
        let focusedPart = focusedElement().map { "focused=\(elementSignature($0))" } ?? "focused=nil"
        return "\(frontPart)|\(windowPart)|\(focusedPart)"
    }

    func issueBounds(
        in context: FocusedTextContext,
        localRange: NSRange?,
        fallbackFrame: CGRect
    ) -> CGRect {
        let bounds = issueBoundsList(in: context, localRange: localRange, fallbackFrame: fallbackFrame)
        guard !bounds.isEmpty else { return fallbackFrame.isEmpty ? context.frame : fallbackFrame }
        return bounds.reduce(bounds[0]) { $0.union($1) }
    }

    func issueBoundsList(
        in context: FocusedTextContext,
        localRange: NSRange?,
        fallbackFrame: CGRect
    ) -> [CGRect] {
        let fullFallback = fallbackFrame.isEmpty ? context.frame : fallbackFrame
        let contextNS = context.text as NSString
        let rawLocalRange = localRange ?? NSRange(location: 0, length: contextNS.length)
        guard contextNS.length > 0 else { return [fullFallback] }

        let safeLocation = max(0, min(rawLocalRange.location, max(0, contextNS.length - 1)))
        let safeLocal = NSRange(
            location: safeLocation,
            length: max(1, min(rawLocalRange.length, contextNS.length - safeLocation))
        )
        if let fragmentBounds = textFragmentBoundsList(for: safeLocal, in: context), !fragmentBounds.isEmpty {
            return fragmentBounds
        }
        let splitRanges = visualLineRanges(for: safeLocal, in: context)
        let splitBounds = splitRanges.compactMap {
            singleIssueBounds(in: context, localRange: $0, fallbackFrame: fullFallback)
        }
        if !splitBounds.isEmpty {
            return splitBounds
        }
        if let single = singleIssueBounds(in: context, localRange: safeLocal, fallbackFrame: fullFallback) {
            return [single]
        }
        return [fullFallback]
    }

    private func singleIssueBounds(
        in context: FocusedTextContext,
        localRange safeLocal: NSRange,
        fallbackFrame fullFallback: CGRect
    ) -> CGRect? {
        guard let absoluteRange = absoluteAXRange(for: safeLocal, in: context) else {
            return nil
        }
        var cfRange = CFRange(location: absoluteRange.location, length: absoluteRange.length)
        let reference = preferredGeometryReference(for: context, fallbackFrame: fullFallback)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange),
              let bounds = selectionBounds(of: context.targetElement, rangeValue: rangeValue, reference: reference),
              !bounds.isEmpty else {
            return nil
        }
        guard isPlausibleIssueBounds(bounds, context: context, fallbackFrame: fullFallback) else {
            return nil
        }
        return bounds
    }

    private func textFragmentBoundsList(for range: NSRange, in context: FocusedTextContext) -> [CGRect]? {
        guard !context.textFragments.isEmpty else { return nil }
        var rects: [CGRect] = []
        for fragment in context.textFragments {
            let overlap = NSIntersectionRange(range, fragment.range)
            guard overlap.length > 0 else { continue }
            if let rect = TextoraCharacterGeometry.rect(for: overlap, in: fragment) {
                rects.append(rect)
            }
        }
        return rects
    }

    private func visualLineRanges(for range: NSRange, in context: FocusedTextContext) -> [NSRange] {
        if let axRanges = axVisualLineRanges(for: range, in: context), axRanges.count > 1 {
            return axRanges
        }
        let textRanges = textLineRanges(for: range, in: context.text as NSString)
        return textRanges.isEmpty ? [range] : textRanges
    }

    private func axVisualLineRanges(for range: NSRange, in context: FocusedTextContext) -> [NSRange]? {
        guard let absoluteRange = absoluteAXRange(for: range, in: context) else { return nil }
        let absoluteEnd = absoluteRange.location + absoluteRange.length
        var current = absoluteRange.location
        var ranges: [NSRange] = []
        var guardCount = 0

        while current < absoluteEnd, guardCount < 128 {
            guardCount += 1
            guard let lineRange = axLineRangeForTextIndex(current, of: context.targetElement) else {
                break
            }
            let lineNS = NSRange(location: lineRange.location, length: lineRange.length)
            let overlap = NSIntersectionRange(lineNS, absoluteRange)
            if overlap.length > 0 {
                let localLocation = range.location + max(0, overlap.location - absoluteRange.location)
                ranges.append(NSRange(location: localLocation, length: overlap.length))
            }
            let next = max(current + 1, lineNS.location + max(1, lineNS.length))
            current = min(next, absoluteEnd)
        }

        return ranges.isEmpty ? nil : ranges
    }

    private func textLineRanges(for range: NSRange, in text: NSString) -> [NSRange] {
        let rangeEnd = range.location + range.length
        var lineStart = 0
        var index = 0
        var ranges: [NSRange] = []

        func appendLine(upTo lineEnd: Int) {
            let lineRange = NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
            let overlap = NSIntersectionRange(lineRange, range)
            if overlap.length > 0 {
                ranges.append(overlap)
            }
        }

        while index < text.length {
            let ch = text.character(at: index)
            if ch == 10 || ch == 13 {
                appendLine(upTo: index)
                if ch == 13, index + 1 < text.length, text.character(at: index + 1) == 10 {
                    index += 1
                }
                lineStart = index + 1
            }
            index += 1
            if lineStart > rangeEnd { break }
        }
        appendLine(upTo: text.length)

        return ranges
    }

    private func preferredGeometryReference(for context: FocusedTextContext, fallbackFrame: CGRect) -> CGRect {
        if isBrowserBundleID(context.targetBundleID),
           !context.anchor.rect.isEmpty,
           !isUsableBrowserContextFrame(context.anchor.rect),
           let windowFrame = focusedWindowFrame(),
           !windowFrame.isEmpty {
            return windowFrame
        }
        if context.anchor.confidence != .weak, !context.anchor.rect.isEmpty {
            return context.anchor.rect
        }
        if isBrowserBundleID(context.targetBundleID),
           let windowFrame = focusedWindowFrame(),
           !windowFrame.isEmpty {
            return windowFrame
        }
        if !context.frame.isEmpty {
            return context.frame
        }
        return fallbackFrame
    }

    private func isPlausibleIssueBounds(
        _ bounds: CGRect,
        context: FocusedTextContext,
        fallbackFrame: CGRect
    ) -> Bool {
        let textRunHeightLooksRight = bounds.height >= 3 && bounds.height <= 80
        let textRunWidthLooksRight = bounds.width >= 2 && bounds.width <= 1400
        guard textRunHeightLooksRight, textRunWidthLooksRight else { return false }
        if let windowFrame = focusedWindowFrame(), !windowFrame.isEmpty {
            let windowArea = windowFrame.insetBy(dx: -2, dy: -2)
            guard windowArea.intersects(bounds) || windowArea.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else {
                return false
            }
        }

        if isSlackBundleID(context.targetBundleID) {
            var localAreas: [CGRect] = []
            if !fallbackFrame.isEmpty {
                localAreas.append(
                    fallbackFrame.insetBy(
                        dx: -max(72, fallbackFrame.width * 0.20),
                        dy: -max(18, fallbackFrame.height * 0.65)
                    )
                )
            }
            let anchor = context.anchor.rect
            if !anchor.isEmpty, anchor.height <= 140, anchor.width <= 2200 {
                localAreas.append(anchor.insetBy(dx: -max(72, anchor.width * 0.20), dy: -max(18, anchor.height * 0.85)))
            }
            if !context.frame.isEmpty, context.frame.height <= 140, context.frame.width <= 2200 {
                localAreas.append(context.frame.insetBy(dx: -max(72, context.frame.width * 0.20), dy: -max(18, context.frame.height * 0.85)))
            }
            guard !localAreas.isEmpty else { return false }
            return localAreas.contains { $0.intersects(bounds) || $0.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
        }

        if shouldRequireLocalIssueBounds(for: context) {
            var localAreas: [CGRect] = []
            let anchor = context.anchor.rect
            if !anchor.isEmpty {
                localAreas.append(
                    anchor.insetBy(
                        dx: max(80, anchor.width * 0.5),
                        dy: max(80, anchor.height * 3.0)
                    )
                )
            }
            if !context.frame.isEmpty {
                localAreas.append(context.frame.insetBy(dx: 80, dy: 80))
            }
            if !fallbackFrame.isEmpty,
               localAreas.contains(where: { $0.intersects(fallbackFrame) || $0.contains(CGPoint(x: fallbackFrame.midX, y: fallbackFrame.midY)) }) {
                localAreas.append(fallbackFrame.insetBy(dx: 48, dy: 48))
            }
            return localAreas.contains { $0.intersects(bounds) || $0.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
        }

        var plausibleAreas: [CGRect] = []
        if !fallbackFrame.isEmpty {
            plausibleAreas.append(fallbackFrame.insetBy(dx: -96, dy: -96))
        }
        if !context.anchor.rect.isEmpty {
            plausibleAreas.append(context.anchor.rect.insetBy(dx: -160, dy: -96))
        }
        if !context.frame.isEmpty {
            plausibleAreas.append(context.frame.insetBy(dx: -64, dy: -64))
        }
        if let windowFrame = focusedWindowFrame(), !windowFrame.isEmpty {
            plausibleAreas.append(windowFrame.insetBy(dx: -24, dy: -24))
        }

        return plausibleAreas.contains { $0.intersects(bounds) || $0.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
    }

    private func shouldRequireLocalIssueBounds(for context: FocusedTextContext) -> Bool {
        guard isBrowserBundleID(context.targetBundleID) else { return false }
        guard context.anchor.confidence != .weak, !context.anchor.rect.isEmpty else { return false }
        return context.anchor.rect.height <= 140 && context.anchor.rect.width <= 2200
    }

    func hasFocusedEditableElement() -> Bool {
        if isGoogleDocsFrontmost() {
            return googleDocsVisibleTextContext(minLength: 1, maxLength: maxContextCharacters) != nil
        }
        guard let focused = focusedEditableElement() else { return false }
        // Keep helper visible for unknown apps so we can ask per-app consent on hover.
        if !shouldIgnoreCurrentFocusedInput(element: focused, includeAppConsent: false) {
            return true
        }
        return false
    }

    func hasAllowedFocusedEditableElement() -> Bool {
        if isGoogleDocsFrontmost() {
            guard currentAppConsentStatus() == .allowed else { return false }
            return googleDocsVisibleTextContext(minLength: 1, maxLength: maxContextCharacters) != nil
        }
        guard let focused = focusedEditableElement() else { return false }
        return !shouldIgnoreCurrentFocusedInput(element: focused, includeAppConsent: true)
    }

    func focusedCaretFrame() -> CGRect? {
        guard let focused = focusedEditableElement() else { return nil }
        guard let selectedRangeValue = selectedRangeValue(of: focused) else { return nil }
        let rawFrame = elementFrame(of: focused)
        let reference = geometryReference(for: focused, rawFrame: rawFrame)
        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &boundsRef
        )
        guard status == .success, let raw = boundsRef else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return normalizedAXRect(rect, reference: reference)
    }

    func focusedTextSignature() -> String? {
        if isGoogleDocsFrontmost() {
            guard currentAppConsentStatus() == .allowed else { return nil }
            guard let docsContext = googleDocsVisibleTextContext(minLength: 1, maxLength: maxContextCharacters) else {
                return nil
            }
            return "google-docs-visible|\(docsContext.text)"
        }
        guard let focused = focusedEditableElement() else { return nil }
        guard !shouldIgnoreCurrentFocusedInput(element: focused, includeAppConsent: true) else { return nil }
        let valuePart = valueText(of: focused) ?? ""
        let rangePart = selectedRangeString(of: focused) ?? "no-range"
        return "\(rangePart)|\(valuePart)"
    }

    func focusedTextContext(
        minLength: Int = 1,
        maxLength: Int = 1600,
        allowClipboardFallback: Bool = false
    ) -> FocusedTextContext? {
        if isGoogleDocsFrontmost() {
            guard currentAppConsentStatus() == .allowed else { return nil }
            return googleDocsVisibleTextContext(minLength: minLength, maxLength: maxLength)
        }
        // 1) Deepest focused element first (Slack/Electron often put selection on a leaf; parents hold value).
        var current: AXUIElement? = focusedElement()
        var depth = 0
        while let el = current, depth < 24 {
            if !shouldIgnoreCurrentFocusedInput(element: el, includeAppConsent: true),
               let ctx = makeFocusedTextContext(
                from: el,
                minLength: minLength,
                maxLength: maxLength,
                allowClipboardFallback: allowClipboardFallback
               ) {
                return ctx
            }
            current = axElement(of: el, attribute: kAXParentAttribute as String)
            depth += 1
        }
        // 2) Editable ancestor (classic text fields).
        if let ed = focusedEditableElement(),
           !shouldIgnoreCurrentFocusedInput(element: ed, includeAppConsent: true),
           let ctx = makeFocusedTextContext(
            from: ed,
            minLength: minLength,
            maxLength: maxLength,
            allowClipboardFallback: allowClipboardFallback
           ) {
            return ctx
        }
        return nil
    }

    /// Builds context from a single AX node; frame falls back to window or mouse (Slack/WebView often omit position on leaf nodes).
    private func makeFocusedTextContext(
        from focused: AXUIElement,
        minLength: Int,
        maxLength: Int,
        allowClipboardFallback: Bool
    ) -> FocusedTextContext? {
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        let bundleID = resolvedBundleID(forOwningPID: pid)

        let range = selectedRange(of: focused)
        let selected = selectedText(of: focused)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawFrame = rectForTextContext(anchorElement: focused)
        let frame = textContextFrame(
            for: focused,
            bundleID: bundleID,
            rawFrame: rawFrame,
            selectedRange: range
        )
        let full = valueText(of: focused)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasRealSelection = (range?.length ?? 0) > 0
        if selected.count >= minLength, hasRealSelection || full.isEmpty {
            let anchor = textAnchor(
                for: focused,
                range: range,
                fallbackFrame: frame,
                selectedTextWasReadFromAX: true
            )
            return FocusedTextContext(
                text: selected,
                frame: frame,
                usesSelection: true,
                selectedRange: range,
                targetElement: focused,
                targetAppPID: pid,
                targetBundleID: bundleID,
                anchor: anchor
            )
        }

        if full.isEmpty, allowClipboardFallback, bundleID != "com.apple.mail" {
            if (range?.length ?? 0) > 0 {
                let copied = readClipboardAfterCopyIfSelectionLikely()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if copied.count >= minLength {
                    let anchor = textAnchor(
                        for: focused,
                        range: range,
                        fallbackFrame: frame,
                        selectedTextWasReadFromAX: false
                    )
                    return FocusedTextContext(
                        text: copied,
                        frame: frame,
                        usesSelection: true,
                        selectedRange: range,
                        targetElement: focused,
                        targetAppPID: pid,
                        targetBundleID: bundleID,
                        anchor: anchor
                    )
                }
            }
        }
        let contextual = contextualSlice(from: full, around: range, maxLength: maxLength)
        guard contextual.count >= minLength else { return nil }
        let anchor = textAnchor(
            for: focused,
            range: range,
            fallbackFrame: frame,
            selectedTextWasReadFromAX: true
        )
        return FocusedTextContext(
            text: contextual,
            frame: frame,
            usesSelection: false,
            selectedRange: range,
            targetElement: focused,
            targetAppPID: pid,
            targetBundleID: bundleID,
            anchor: anchor
        )
    }

    private func rectForTextContext(anchorElement: AXUIElement) -> CGRect {
        if let r = elementFrame(of: anchorElement) {
            return r
        }
        if let w = focusedWindowFrame() {
            return w
        }
        let m = NSEvent.mouseLocation
        return CGRect(x: m.x - 4, y: m.y - 4, width: 8, height: 8)
    }

    private func textContextFrame(
        for element: AXUIElement,
        bundleID: String,
        rawFrame: CGRect,
        selectedRange: CFRange?
    ) -> CGRect {
        guard isBrowserBundleID(bundleID), !isUsableBrowserContextFrame(rawFrame) else {
            return rawFrame
        }
        let reference = focusedWindowFrame()
        if let selectedRange {
            var range = selectedRange
            if let rangeValue = AXValueCreate(.cfRange, &range),
               let bounds = rangeBounds(of: element, rangeValue: rangeValue, reference: reference ?? rawFrame)?.normalized,
               isUsableBrowserContextFrame(bounds) {
                return bounds
            }
        }
        if let windowFrame = reference, !windowFrame.isEmpty {
            return windowFrame
        }
        return rawFrame
    }

    private func geometryReference(for element: AXUIElement, rawFrame: CGRect?) -> CGRect? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let bundleID = resolvedBundleID(forOwningPID: pid)
        if isBrowserBundleID(bundleID),
           let rawFrame,
           !isUsableBrowserContextFrame(rawFrame),
           let windowFrame = focusedWindowFrame(),
           !windowFrame.isEmpty {
            return windowFrame
        }
        return rawFrame ?? focusedWindowFrame()
    }

    private func isUsableBrowserContextFrame(_ frame: CGRect) -> Bool {
        guard !frame.isEmpty, frame.height >= 3, frame.width >= 2 else { return false }
        guard let windowFrame = focusedWindowFrame(), !windowFrame.isEmpty else {
            return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        }
        let windowArea = windowFrame.insetBy(dx: -24, dy: -24)
        return windowArea.intersects(frame) || windowArea.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Electron/WebView (e.g. Slack) often shows a selection but does not expose `kAXSelectedText` / range via AX.
    /// After per-app **Allow**, we send Cmd+C and accept text only if the pasteboard changeCount proves a copy happened (avoids stale clipboard).
    func focusedTextContextFromLiveCopy(minLength: Int = 1, maxLength: Int = 1600) -> FocusedTextContext? {
        guard hasAccessibilityPermission() else { return nil }
        guard let focused = focusedElement() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        let bundleID = resolvedBundleID(forOwningPID: pid)
        // Mail-safe mode: never do background copy probes in timer/auto paths.
        guard bundleID != "com.apple.mail" else { return nil }
        guard appConsentStatus(for: bundleID) == .allowed else { return nil }
        guard !isSecureInputField(focused), !hasSensitiveFieldHint(focused) else { return nil }
        guard let copied = readClipboardAfterCopyIfSelectionLikely(), copied.count >= minLength else { return nil }
        let clipped = clipToMaxLength(copied, maxLength: maxLength)
        let frame = rectForTextContext(anchorElement: focused)
        let anchor = textAnchor(
            for: focused,
            range: selectedRange(of: focused),
            fallbackFrame: frame,
            selectedTextWasReadFromAX: false
        )
        return FocusedTextContext(
            text: clipped,
            frame: frame,
            usesSelection: true,
            selectedRange: nil,
            targetElement: focused,
            targetAppPID: pid,
            targetBundleID: bundleID,
            anchor: anchor
        )
    }

    private func readClipboardAfterCopyIfSelectionLikely(
        allowGoogleSheetsGrid: Bool = false
    ) -> String? {
        if isGoogleSheetsFrontmost(), !allowGoogleSheetsGrid {
            let isActiveCellEditor = focusedElement().map(isGoogleSheetsTextEditFocus) ?? false
            guard isActiveCellEditor else {
                textoraDiagLog("clipboardProbe", "blocked in Google Sheets outside active cell editor")
                return nil
            }
        }
        guard !isCopyProbeInProgress else { return nil }
        // Guard against rapid-fire copy probes that can freeze app menus.
        if Date().timeIntervalSince(lastCopyProbeAt) < 0.35 {
            return nil
        }
        isCopyProbeInProgress = true
        defer {
            isCopyProbeInProgress = false
            lastCopyProbeAt = Date()
        }
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let oldChangeCount = pasteboard.changeCount
        triggerCopyShortcut()
        // Poll: Electron/Slack sometimes applies the copy slightly after the shortcut.
        for _ in 0 ..< 14 {
            usleep(50_000)
            if pasteboard.changeCount != oldChangeCount { break }
        }
        guard pasteboard.changeCount != oldChangeCount else {
            textoraDiagLog("clipboardProbe", "no pasteboard change after copy; refusing stale clipboard")
            return nil
        }
        let containsObjectPayload = pasteboardContainsObjectPayload(pasteboard)
        let copied = containsObjectPayload ? nil : extractPlainTextFromPasteboard(pasteboard)
        if containsObjectPayload {
            textoraDiagLog("clipboardProbe", "rejected non-text pasteboard payload")
        }
        restorePasteboard(pasteboard, snapshot: snapshot)
        return copied
    }

    private func pasteboardContainsObjectPayload(_ pasteboard: NSPasteboard) -> Bool {
        let allowedRichText = Set([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.rtfd.rawValue,
            NSPasteboard.PasteboardType.html.rawValue,
            "public.utf8-plain-text",
            "public.utf16-external-plain-text"
        ])
        let identifiers = (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        return Self.containsObjectPasteboardType(identifiers, allowedRichText: allowedRichText)
    }

    static func containsObjectPasteboardType(
        _ identifiers: [String],
        allowedRichText: Set<String> = [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.rtfd.rawValue,
            NSPasteboard.PasteboardType.html.rawValue,
            "public.utf8-plain-text",
            "public.utf16-external-plain-text"
        ]
    ) -> Bool {
        identifiers.contains { raw in
            let identifier = raw.lowercased()
            if allowedRichText.contains(raw) { return false }
            return identifier.contains("image")
                || identifier.contains("file-url")
                || identifier.contains("adobe")
                || identifier.contains("photoshop")
                || identifier.contains("illustrator")
                || identifier.contains("svg")
                || identifier == UTType.pdf.identifier.lowercased()
                || UTType(identifier)?.conforms(to: .image) == true
                || UTType(identifier)?.conforms(to: .fileURL) == true
        }
    }

    /// After a successful copy, plain `NSStringPboardType` may still be empty (rich text only).
    private func extractPlainTextFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        if let s = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let utf8Plain = NSPasteboard.PasteboardType("public.utf8-plain-text")
        if let s = pasteboard.string(forType: utf8Plain)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let attr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            let s = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        if let html = pasteboard.data(forType: .html),
           let attr = try? NSAttributedString(
            data: html,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           ) {
            let s = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// Returns a lightweight "selection exists" signal for the currently focused AX element.
    /// This is used to decide whether the floating helper can appear in "selection mode"
    /// without necessarily reading the selected text (e.g. before per-app consent is granted).
    func selectedTextSignalAnyFocus() -> SelectedTextSignal? {
        guard let start = focusedElement() else { return nil }
        guard !shouldIgnoreCurrentFocusedInput(element: start, includeAppConsent: false) else { return nil }
        if isGoogleSheetsFrontmost(), !isGoogleSheetsTextEditFocus(start) { return nil }
        // Walk ancestors: Electron/WebView may report selection on a parent, not the deepest focus leaf.
        var element: AXUIElement? = start
        var depth = 0
        while let el = element, depth < 24 {
            guard !shouldIgnoreCurrentFocusedInput(element: el, includeAppConsent: false) else {
                element = axElement(of: el, attribute: kAXParentAttribute as String)
                depth += 1
                continue
            }
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            let bundleID = resolvedBundleID(forOwningPID: pid)
            let range = selectedRange(of: el)
            if let range, range.length > 0 {
                guard hasTextualSelectionSignal(on: el, range: range, bundleID: bundleID) else {
                    element = axElement(of: el, attribute: kAXParentAttribute as String)
                    depth += 1
                    continue
                }
                let fallback = elementFrame(of: el) ?? focusedWindowFrame()
                let bounds = selectionBounds(of: el, rangeValue: selectedRangeValue(of: el), reference: fallback)
                    ?? elementFrame(of: el)
                    ?? focusedWindowFrame()
                return SelectedTextSignal(
                    hasSelection: true,
                    bounds: bounds,
                    selectedRange: range,
                    targetElement: el,
                    targetAppPID: pid,
                    targetBundleID: bundleID
                )
            }
            element = axElement(of: el, attribute: kAXParentAttribute as String)
            depth += 1
        }

        var pid: pid_t = 0
        AXUIElementGetPid(start, &pid)
        let bundleID = resolvedBundleID(forOwningPID: pid)
        return SelectedTextSignal(
            hasSelection: false,
            bounds: nil,
            selectedRange: selectedRange(of: start),
            targetElement: start,
            targetAppPID: pid,
            targetBundleID: bundleID
        )
    }

    private func hasTextualSelectionSignal(on element: AXUIElement, range: CFRange, bundleID: String) -> Bool {
        if let selected = selectedText(of: element)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return true
        }
        if isTextualSelectionElement(element), let value = valueText(of: element) {
            let nsValue = value as NSString
            let location = max(0, range.location)
            let length = max(0, range.length)
            if location < nsValue.length {
                let boundedLength = min(length, nsValue.length - location)
                if boundedLength > 0,
                   !nsValue.substring(with: NSRange(location: location, length: boundedLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    return true
                }
            }
        }
        // PDF readers often expose a range/bounds signal for text selection but hide
        // the actual selected text from AX; the later context read verifies via Cmd+C.
        return isPDFReaderBundleID(bundleID)
    }

    private func isTextualSelectionElement(_ element: AXUIElement) -> Bool {
        let role = axString(of: element, attribute: kAXRoleAttribute) ?? ""
        let subrole = axString(of: element, attribute: kAXSubroleAttribute) ?? ""
        let textualRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXStaticTextRole as String,
            "AXWebArea",
            "AXDocument"
        ]
        return textualRoles.contains(role) || textualRoles.contains(subrole)
    }

    /// Reads the currently selected text even when the focused element is not an editable input.
    /// Requires per-app consent (same as `focusedTextContext`).
    func selectedTextContextAnyFocus(
        minLength: Int = 1,
        maxLength: Int = 1600,
        allowClipboardFallback: Bool = true,
        allowBrowserClipboardSelection: Bool = false
    ) -> FocusedTextContext? {
        if allowClipboardFallback,
           allowBrowserClipboardSelection,
           let front = frontmostAppInfo(),
           prefersClipboardSelectionContextForBundle(front.bundleID) {
            if let focused = focusedElement(),
               shouldBlockBrowserClipboardSelectionProbe(focused) {
                return nil
            }
            return selectedTextContextFromFrontmostClipboardSelection(
                minLength: minLength,
                maxLength: maxLength
            )
        }
        guard let start = focusedElement() else {
            guard allowClipboardFallback, allowBrowserClipboardSelection else { return nil }
            return selectedTextContextFromFrontmostClipboardSelection(
                minLength: minLength,
                maxLength: maxLength
            )
        }
        var element: AXUIElement? = start
        var depth = 0
        while let focused = element, depth < 24 {
            guard !shouldIgnoreCurrentFocusedInput(element: focused, includeAppConsent: true) else {
                element = axElement(of: focused, attribute: kAXParentAttribute as String)
                depth += 1
                continue
            }

            var pid: pid_t = 0
            AXUIElementGetPid(focused, &pid)
            let bundleID = resolvedBundleID(forOwningPID: pid)

            let range = selectedRange(of: focused)
            guard let range, range.length > 0 else {
                element = axElement(of: focused, attribute: kAXParentAttribute as String)
                depth += 1
                continue
            }

            let frameFallback = rectForTextContext(anchorElement: focused)
            let bounds = selectionBounds(of: focused, rangeValue: selectedRangeValue(of: focused), reference: frameFallback)
                ?? elementFrame(of: focused)
                ?? focusedWindowFrame()

            let selectedAX = selectedText(of: focused)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var selected = selectedAX
            if selected.isEmpty, allowClipboardFallback, bundleID != "com.apple.mail" {
                // Mail/Electron can expose selection without returning AXSelectedText; use robust live-copy probe.
                selected = readClipboardAfterCopyIfSelectionLikely(
                    allowGoogleSheetsGrid: allowBrowserClipboardSelection
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if selected.isEmpty {
                    textoraDiagLog("clipboardProbe", "live copy returned no plain text")
                }
            }

            let clipped = clipToMaxLength(selected, maxLength: maxLength)
            if clipped.count >= minLength {
                let frame = bounds
                    ?? frameFallback
                let anchor = textAnchor(
                    for: focused,
                    range: range,
                    fallbackFrame: frame,
                    selectedTextWasReadFromAX: !selectedAX.isEmpty
                )
                return FocusedTextContext(
                    text: clipped,
                    frame: frame,
                    usesSelection: true,
                    selectedRange: range,
                    targetElement: focused,
                    targetAppPID: pid,
                    targetBundleID: bundleID,
                    anchor: anchor
                )
            }

            element = axElement(of: focused, attribute: kAXParentAttribute as String)
            depth += 1
        }
        // Some editors (notably Mail) may hide AX selectedRange but still allow Cmd+C for highlighted text.
        if allowClipboardFallback {
            var pid: pid_t = 0
            AXUIElementGetPid(start, &pid)
            let bundleID = resolvedBundleID(forOwningPID: pid)
            guard bundleID != "com.apple.mail",
                  appConsentStatus(for: bundleID) == .allowed,
                  let copied = readClipboardAfterCopyIfSelectionLikely(
                    allowGoogleSheetsGrid: allowBrowserClipboardSelection
                  )?.trimmingCharacters(in: .whitespacesAndNewlines),
                  copied.count >= minLength else {
                return nil
            }
            let frame = focusedWindowFrame() ?? rectForTextContext(anchorElement: start)
            let anchor = TextAnchor(
                rect: frame,
                source: .clipboardFallback,
                confidence: .weak,
                rawRect: nil
            )
            return FocusedTextContext(
                text: clipToMaxLength(copied, maxLength: maxLength),
                frame: frame,
                usesSelection: true,
                selectedRange: nil,
                targetElement: start,
                targetAppPID: pid,
                targetBundleID: bundleID,
                anchor: anchor
            )
        }
        return nil
    }

    private func shouldBlockBrowserClipboardSelectionProbe(_ element: AXUIElement) -> Bool {
        if isGoogleSheetsFrontmost() {
            return isSecureInputField(element)
                || isTransientPopupLike(element)
                || hasSensitiveFieldHint(element)
                || isBrowserChromeInputField(element)
        }
        return shouldIgnoreCurrentFocusedInput(element: element, includeAppConsent: false)
    }

    private func selectedTextContextFromFrontmostClipboardSelection(
        minLength: Int,
        maxLength: Int
    ) -> FocusedTextContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              !bundleID.isEmpty,
              appConsentStatus(for: bundleID) == .allowed,
              bundleID != "com.apple.mail" else {
            return nil
        }
        guard let copied = readClipboardAfterCopyIfSelectionLikely(
            allowGoogleSheetsGrid: true
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              copied.count >= minLength else {
            return nil
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let target: AXUIElement
        if let focused = focusedElement() {
            var focusedPID: pid_t = 0
            AXUIElementGetPid(focused, &focusedPID)
            if focusedPID == pid,
               !isSecureInputField(focused),
               !hasSensitiveFieldHint(focused) {
                target = focused
            } else {
                target = appElement
            }
        } else {
            target = appElement
        }
        let targetFrame = rectForTextContext(anchorElement: target)
        let frame = (isUsableBrowserContextFrame(targetFrame) ? targetFrame : nil)
            ?? focusedWindowFrame()
            ?? frontmostBrowserCGWindowFrame()
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let anchor = TextAnchor(
            rect: frame,
            source: .clipboardFallback,
            confidence: .weak,
            rawRect: nil
        )
        return FocusedTextContext(
            text: clipToMaxLength(copied, maxLength: maxLength),
            frame: frame,
            usesSelection: true,
            selectedRange: nil,
            targetElement: target,
            targetAppPID: pid,
            targetBundleID: bundleID,
            anchor: anchor
        )
    }

    func manualCaptureSelectionFromMail(minLength: Int = 1, maxLength: Int = 1600) -> MailManualCaptureResult {
        guard hasAccessibilityPermission() else { return .notAllowed }
        let mailBundle = "com.apple.mail"
        guard appConsentStatus(for: mailBundle) == .allowed else { return .notAllowed }
        guard let mailApp = NSRunningApplication.runningApplications(withBundleIdentifier: mailBundle).first else {
            return .notMail
        }

        let previousFront = NSWorkspace.shared.frontmostApplication
        var didActivateMail = false

        let anchor: AXUIElement
        if let start = focusedElement() {
            var pid: pid_t = 0
            AXUIElementGetPid(start, &pid)
            if resolvedBundleID(forOwningPID: pid) == mailBundle {
                anchor = start
            } else {
                mailApp.activate()
                didActivateMail = true
                usleep(220_000)
                guard let after = focusedElement() else {
                    previousFront?.activate()
                    return .noSelection
                }
                var apid: pid_t = 0
                AXUIElementGetPid(after, &apid)
                guard resolvedBundleID(forOwningPID: apid) == mailBundle else {
                    previousFront?.activate()
                    return .notMail
                }
                anchor = after
            }
        } else {
            mailApp.activate()
            didActivateMail = true
            usleep(220_000)
            guard let after = focusedElement() else {
                previousFront?.activate()
                return .noSelection
            }
            var apid: pid_t = 0
            AXUIElementGetPid(after, &apid)
            guard resolvedBundleID(forOwningPID: apid) == mailBundle else {
                previousFront?.activate()
                return .notMail
            }
            anchor = after
        }

        guard !isSecureInputField(anchor), !hasSensitiveFieldHint(anchor) else {
            if didActivateMail { previousFront?.activate() }
            return .notAllowed
        }

        if isCopyProbeInProgress {
            if didActivateMail { previousFront?.activate() }
            return .busy
        }
        guard let copied = readClipboardAfterCopyIfSelectionLikely()?.trimmingCharacters(in: .whitespacesAndNewlines),
              copied.count >= minLength else {
            if didActivateMail { previousFront?.activate() }
            return .noSelection
        }

        var pid: pid_t = 0
        AXUIElementGetPid(anchor, &pid)
        let frame = rectForTextContext(anchorElement: anchor)
        let clipped = clipToMaxLength(copied, maxLength: maxLength)
        let textAnchor = textAnchor(
            for: anchor,
            range: selectedRange(of: anchor),
            fallbackFrame: frame,
            selectedTextWasReadFromAX: false
        )
        let context = FocusedTextContext(
            text: clipped,
            frame: frame,
            usesSelection: true,
            selectedRange: nil,
            targetElement: anchor,
            targetAppPID: pid,
            targetBundleID: mailBundle,
            anchor: textAnchor
        )
        if didActivateMail {
            previousFront?.activate()
            usleep(60_000)
        }
        return .success(context)
    }

    func shouldIgnoreCurrentFocusedInput() -> Bool {
        shouldIgnoreCurrentFocusedInput(element: nil, includeAppConsent: false)
    }

    func frontmostAppInfo() -> FrontmostAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FrontmostAppInfo(bundleID: bundleID, displayName: name?.isEmpty == false ? name! : bundleID)
    }

    func isFrontmostAppSuppressedForHelper() -> Bool {
        guard let app = frontmostAppInfo() else { return false }
        return helperSuppressedBundleIDs.contains(app.bundleID)
    }

    /// Hard-stop cases for helper visibility regardless of consent flow.
    func shouldHardIgnoreCurrentFocusedInput() -> Bool {
        guard let element = focusedElement() else { return false }
        if isGoogleSheetsFrontmost(), !isGoogleSheetsTextEditFocus(element) { return true }
        if isSecureInputField(element) { return true }
        if isCurrentFocusInTransientPopupOrMenu() { return true }
        if hasSensitiveFieldHint(element) { return true }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid != 0 {
            let bundleID = resolvedBundleID(forOwningPID: pid)
            if helperSuppressedBundleIDs.contains(bundleID) {
                return true
            }
        }
        return false
    }

    static func attributedReplacementPreservingFormatting(
        source: NSAttributedString,
        rewritten: String
    ) -> NSAttributedString {
        guard source.string != rewritten else { return NSAttributedString(attributedString: source) }
        guard source.length > 0 else { return NSAttributedString(string: rewritten) }

        let sourceCharacters = Array(source.string)
        let rewrittenCharacters = Array(rewritten)
        let difference = rewrittenCharacters.difference(from: sourceCharacters)
        let removedOffsets = Set(difference.compactMap { change -> Int? in
            guard case let .remove(offset, _, _) = change else { return nil }
            return offset
        })
        let insertedOffsets = Set(difference.compactMap { change -> Int? in
            guard case let .insert(offset, _, _) = change else { return nil }
            return offset
        })
        let sourceUTF16Offsets: [Int] = sourceCharacters.reduce(into: [0]) { offsets, character in
            offsets.append(offsets.last! + String(character).utf16.count)
        }

        let result = NSMutableAttributedString()
        var sourceIndex = 0
        var rewrittenIndex = 0
        var firstRemovedIndex: Int?
        while rewrittenIndex < rewrittenCharacters.count {
            while sourceIndex < sourceCharacters.count, removedOffsets.contains(sourceIndex) {
                if firstRemovedIndex == nil { firstRemovedIndex = sourceIndex }
                sourceIndex += 1
            }

            let isInsertion = insertedOffsets.contains(rewrittenIndex)
            let styleCharacterIndex: Int
            if !isInsertion,
               sourceIndex < sourceCharacters.count,
               sourceCharacters[sourceIndex] == rewrittenCharacters[rewrittenIndex] {
                styleCharacterIndex = sourceIndex
                sourceIndex += 1
                firstRemovedIndex = nil
            } else {
                styleCharacterIndex = firstRemovedIndex
                    ?? min(sourceCharacters.count - 1, sourceIndex)
            }

            let utf16Index = sourceUTF16Offsets[styleCharacterIndex]
            var attributes = source.attributes(at: utf16Index, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            if isInsertion, firstRemovedIndex == nil {
                let leftIndex = sourceIndex > 0 ? sourceUTF16Offsets[sourceIndex - 1] : nil
                let rightIndex = sourceIndex < sourceCharacters.count ? sourceUTF16Offsets[sourceIndex] : nil
                let leftLink = leftIndex.map { source.attribute(.link, at: $0, effectiveRange: nil) }
                let rightLink = rightIndex.map { source.attribute(.link, at: $0, effectiveRange: nil) }
                if leftLink == nil || rightLink == nil
                    || String(describing: leftLink) != String(describing: rightLink) {
                    attributes.removeValue(forKey: .link)
                }
            }
            result.append(NSAttributedString(
                string: String(rewrittenCharacters[rewrittenIndex]),
                attributes: attributes
            ))
            rewrittenIndex += 1
        }
        return result
    }

    /// Per-app consent for the application that owns this AX node (not `frontmostApplication`).
    func consentStatus(forOwningAXElement element: AXUIElement) -> AppConsentStatus {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else {
            return .unknown
        }
        return appConsentStatus(for: resolvedBundleID(forOwningPID: pid))
    }

    /// Bundle ID for consent keys and `FocusedTextContext.targetBundleID` when `bundleIdentifier` is nil on the running application.
    private func resolvedBundleID(forOwningPID pid: pid_t) -> String {
        let running = NSRunningApplication(processIdentifier: pid)
        if let bid = running?.bundleIdentifier, !bid.isEmpty {
            return bid
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == pid,
           let bid = front.bundleIdentifier, !bid.isEmpty {
            return bid
        }
        var url = running?.executableURL?.resolvingSymlinksInPath()
        while let u = url {
            if u.pathExtension == "app" {
                if let b = Bundle(url: u)?.bundleIdentifier, !b.isEmpty {
                    return b
                }
                break
            }
            let parent = u.deletingLastPathComponent()
            if parent.standardizedFileURL == u.standardizedFileURL { break }
            url = parent
        }
        return "unknown"
    }

    func appConsentStatus(for bundleID: String) -> AppConsentStatus {
        let map = appConsentMap()
        guard let raw = map[bundleID], let status = AppConsentStatus(rawValue: raw) else {
            return .unknown
        }
        return status
    }

    func currentAppConsentStatus() -> AppConsentStatus {
        guard let app = frontmostAppInfo() else { return .unknown }
        return appConsentStatus(for: app.bundleID)
    }

    func setAppConsentStatus(_ status: AppConsentStatus, for bundleID: String) {
        var map = appConsentMap()
        map[bundleID] = status.rawValue
        UserDefaults.standard.set(map, forKey: appConsentKey)
    }

    func allAppConsents() -> [(bundleID: String, status: AppConsentStatus)] {
        let map = appConsentMap()
        return map.compactMap { key, raw in
            guard let status = AppConsentStatus(rawValue: raw) else { return nil }
            return (bundleID: key, status: status)
        }
        .sorted { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }
    }

    func removeAppConsent(for bundleID: String) {
        var map = appConsentMap()
        map.removeValue(forKey: bundleID)
        UserDefaults.standard.set(map, forKey: appConsentKey)
    }

    private func appConsentMap() -> [String: String] {
        let defaults = UserDefaults.standard
        if let current = defaults.dictionary(forKey: appConsentKey) as? [String: String], !current.isEmpty {
            return current
        }
        if let legacy = defaults.dictionary(forKey: legacyAppConsentKey) as? [String: String], !legacy.isEmpty {
            defaults.set(legacy, forKey: appConsentKey)
            defaults.removeObject(forKey: legacyAppConsentKey)
            return legacy
        }
        return [:]
    }

    func applyRewrittenText(_ rewritten: String, basedOn context: FocusedTextContext) -> ApplyResult {
        guard appConsentStatus(for: context.targetBundleID) == .allowed else {
            textoraDiagLog(
                "applyRewrittenText",
                "blocked app-consent bundle=\(context.targetBundleID) status=\(appConsentStatus(for: context.targetBundleID).rawValue)"
            )
            return .failed
        }
        focusTargetAppAndElement(context)
        textoraDiagLog(
            "applyRewrittenText",
            "enter bundle=\(context.targetBundleID) usesSelection=\(context.usesSelection) "
            + "selectedRange=\(context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil") "
            + "strategy=unifiedPhysicalRewrite"
        )
        if context.usesSelection {
            let shouldUseClipboardSelectionPaste = prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID)
                || context.anchor.source == .clipboardFallback
            if shouldUseClipboardSelectionPaste,
               applyClipboardSelectionPasteReplace(rewritten, basedOn: context) {
                textoraDiagLog("applyRewrittenText", "success via clipboardSelectionPasteReplace")
                return .success
            }
            if !shouldUseClipboardSelectionPaste,
               applySelectedTextDirect(rewritten, basedOn: context) {
                textoraDiagLog("applyRewrittenText", "success via selectedTextDirect")
                return .success
            }
        }
        if applyProtectedPhysicalRewritePlan(rewritten, basedOn: context) {
            textoraDiagLog("applyRewrittenText", "success via unifiedPhysicalRewrite")
            return .success
        }
        textoraDiagLog("applyRewrittenText", "unifiedPhysicalRewrite failed")
        return .failed
    }

    // MARK: - Browser Rewrite Apply

    /// Browser editors (Gmail, web mail, docs-like composers) expose AX
    /// ranges that can drift from the physical DOM caret. Keep them out of
    /// the general Electron path: no caret-backspace rewrite, no Cmd+A full
    /// replacement. The primary browser strategy is the same physical
    /// retyping path: select the changed range, then type the replacement
    /// over that selection without touching the pasteboard.
    private func applyBrowserRewrittenText(
        _ rewritten: String,
        basedOn context: FocusedTextContext,
        envelopeWouldTouchRichTokens: Bool
    ) -> ApplyResult {
        textoraDiagLog(
            "applyBrowserRewrittenText",
            "enter bundle=\(context.targetBundleID) usesSelection=\(context.usesSelection) "
            + "selectedRange=\(context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil") "
            + "envelopeTouchesRichTokens=\(envelopeWouldTouchRichTokens)"
        )

        if applyBrowserRewriteStrategies(
            rewritten,
            basedOn: context,
            envelopeWouldTouchRichTokens: envelopeWouldTouchRichTokens
        ) {
            return .success
        }

        guard let fresh = focusedElement(), isEditable(element: fresh) else {
            textoraDiagLog("applyBrowserRewrittenText", "no editable fresh element -> failed")
            return .failed
        }
        let refreshed = FocusedTextContext(
            text: context.text,
            frame: context.frame,
            usesSelection: context.usesSelection,
            selectedRange: context.selectedRange,
            targetElement: fresh,
            targetAppPID: context.targetAppPID,
            targetBundleID: context.targetBundleID,
            anchor: context.anchor,
            textFragments: context.textFragments
        )
        focusTargetAppAndElement(refreshed)
        textoraDiagLog("applyBrowserRewrittenText", "retrying with refreshed element")
        if applyBrowserRewriteStrategies(
            rewritten,
            basedOn: refreshed,
            envelopeWouldTouchRichTokens: envelopeWouldTouchRichTokens
        ) {
            return .success
        }

        textoraDiagLog("applyBrowserRewrittenText", "exhausted browser strategies -> failed")
        return .failed
    }

    private func applyBrowserRewriteStrategies(
        _ rewritten: String,
        basedOn context: FocusedTextContext,
        envelopeWouldTouchRichTokens: Bool
    ) -> Bool {
        guard normalized(rewritten) != normalized(context.text) else {
            textoraDiagLog("applyBrowserRewrittenText", "no-op: rewritten equals original")
            return true
        }

        if applyProtectedPhysicalRewritePlan(rewritten, basedOn: context) {
            textoraDiagLog("applyBrowserRewrittenText", "success via protectedPhysicalRewritePlan")
            return true
        }

        if context.usesSelection,
           applySelectedTextDirect(rewritten, basedOn: context) {
            textoraDiagLog("applyBrowserRewrittenText", "success via selectedTextDirect")
            return true
        }

        return false
    }

    func applyLocalizedRewrite(
        _ rewritten: String,
        basedOn context: FocusedTextContext,
        preferredLocalRange: NSRange?
    ) -> ApplyResult {
        guard appConsentStatus(for: context.targetBundleID) == .allowed else {
            textoraDiagLog(
                "applyLocalizedRewrite",
                "blocked app-consent bundle=\(context.targetBundleID) status=\(appConsentStatus(for: context.targetBundleID).rawValue)"
            )
            return .failed
        }
        textoraDiagLog(
            "applyLocalizedRewrite",
            "enter bundle=\(context.targetBundleID) preferredLocal=\(preferredLocalRange.map { "\($0.location):\($0.length)" } ?? "nil") "
            + "original=\(textoraDiagPreview(context.text)) rewritten=\(textoraDiagPreview(rewritten))"
        )
        if applyProtectedPhysicalRewritePlan(rewritten, basedOn: context) {
            textoraDiagLog("applyLocalizedRewrite", "success via unifiedPhysicalRewrite")
            return .success
        }
        textoraDiagLog("applyLocalizedRewrite", "unifiedPhysicalRewrite failed")
        return .failed
    }

    func applyIterativeLocalizedRewrite(
        _ rewritten: String,
        basedOn context: FocusedTextContext
    ) -> ApplyResult {
        textoraDiagLog(
            "applyIterativeLocalizedRewrite",
            "enter bundle=\(context.targetBundleID) original=\(textoraDiagPreview(context.text)) rewritten=\(textoraDiagPreview(rewritten))"
        )
        if applyProtectedPhysicalRewritePlan(rewritten, basedOn: context) {
            textoraDiagLog("applyIterativeLocalizedRewrite", "success via unifiedPhysicalRewrite")
            return .success
        }
        textoraDiagLog("applyIterativeLocalizedRewrite", "unifiedPhysicalRewrite failed")
        return .failed
    }

    private func safeIterativeRewriteChanges(
        original: String,
        corrected: String
    ) -> [WordDiff.TextChange] {
        let changes = WordDiff.changes(original: original, corrected: corrected)
        guard !changes.isEmpty else { return [] }
        let originalNS = original as NSString
        let protectedRanges = rewriteProtectedRanges(in: original)
        return changes.filter { change in
            guard change.range.location >= 0,
                  NSMaxRange(change.range) <= originalNS.length else {
                return false
            }
            if protectedRanges.contains(where: { NSIntersectionRange($0, change.range).length > 0 }) {
                return false
            }
            let originalSpan = change.range.length > 0 ? originalNS.substring(with: change.range) : ""
            if protectedTokens(in: originalSpan) != protectedTokens(in: change.replacement) {
                return false
            }
            return normalized(originalSpan) != normalized(change.replacement)
        }
    }

    /// True iff a full-field Cmd+A + Cmd+V paste in an Electron-style
    /// composer (Slack/Teams/Discord/Telegram/…) would destroy adjacent
    /// layout that the user didn't ask us to change.
    ///
    /// Slack's Quill paste handler strips every rich format we can put
    /// on the pasteboard (`public.html`, `public.rtf`, even their legacy
    /// aliases) and treats every internal `\n` in plain-text paste as a
    /// *soft break* inside the currently focused block. Consequences of
    /// that are:
    /// 1. Every paragraph block (URL, mention, empty paragraph, …) that
    ///    lived *outside* the correction scope loses its block identity
    ///    and fuses into one block with our replacement.
    /// 2. URLs we didn't touch get re-autolinked in the new single
    ///    block, visually merging with surrounding text.
    ///
    /// Neither of these changes is acceptable because the user only
    /// asked us to rewrite `context.text`. So if there is *anything*
    /// outside the scope that indicates block structure (rich tokens
    /// such as URLs/mentions, or paragraph breaks), we refuse the
    /// destructive full-field paste.
    private func fullValuePasteWouldDamageSlackLayout(
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID) else {
            return false
        }
        guard let full = valueText(of: context.targetElement), !full.isEmpty else {
            return false
        }
        let fullNS = full as NSString
        let scopeRange = fullNS.range(of: context.text)
        // If the scope spans the whole field, Cmd+A + Cmd+V is safe —
        // there's nothing outside the scope that could be damaged.
        if scopeRange.location == 0, scopeRange.length == fullNS.length {
            return false
        }

        var outside = ""
        if scopeRange.location != NSNotFound {
            if scopeRange.location > 0 {
                outside += fullNS.substring(
                    with: NSRange(location: 0, length: scopeRange.location)
                )
            }
            let scopeEnd = scopeRange.location + scopeRange.length
            if scopeEnd < fullNS.length {
                outside += fullNS.substring(
                    with: NSRange(location: scopeEnd, length: fullNS.length - scopeEnd)
                )
            }
        } else {
            // Couldn't locate the scope reliably — be conservative.
            outside = full
        }

        if outside.isEmpty { return false }

        // Any newline outside scope is a block boundary in Slack's
        // composer. A full-field paste flattens them all.
        if outside.contains("\n") { return true }

        // No newlines but a rich token (URL/mention/…) outside the
        // scope — the auto-linker will re-fuse it into our paste.
        return !richTokenRanges(in: outside).isEmpty
    }

    /// Publish `replacement` on the system pasteboard as plain text so
    /// the user can apply a pending Electron-host fix via ⌘V. We do
    /// **not** snapshot + restore the previous pasteboard contents here
    /// (unlike the paste-based strategies) because the whole point is to
    /// hand the clipboard off to the user as the active write channel.
    private func armClipboardForManualPaste(_ replacement: String) -> Bool {
        let pasteboard = NSPasteboard.general
        return writePlainTextToPasteboard(replacement, pasteboard: pasteboard)
    }

    private func writePlainTextToPasteboard(
        _ text: String,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        guard pasteboard.changeCount != before else { return false }
        return pasteboard.string(forType: .string) == text
    }

    /// True iff the absolute replacement range would overlap a URL, email, phone,
    /// or @mention/#channel token in the current full value. Used to avoid damaging
    /// Slack's rich formatting when we apply a localized clipboard paste.
    private func rangeDamagesRichSlackTokens(
        absoluteRange: NSRange,
        in context: FocusedTextContext
    ) -> Bool {
        guard isSlackBundleID(context.targetBundleID) else { return false }
        guard absoluteRange.length >= 0 else { return false }
        guard let full = valueText(of: context.targetElement), !full.isEmpty else { return false }
        let ns = full as NSString
        guard ns.length > 0 else { return false }
        for match in richTokenRanges(in: full)
            where NSIntersectionRange(match, absoluteRange).length > 0 {
                return true
        }
        return false
    }

    /// True iff the envelope paste that `applyRewrittenText` would attempt for an
    /// atomic-paste app would overlap a Slack rich token. When true, we skip the
    /// envelope paste and let the AX-native fallbacks handle the rewrite.
    private func atomicPasteEnvelopeOverlapsRichTokens(
        rewritten: String,
        in context: FocusedTextContext
    ) -> Bool {
        guard isSlackBundleID(context.targetBundleID) else { return false }
        guard let envelope = changedEnvelope(original: context.text, corrected: rewritten) else {
            return false
        }
        guard let absoluteRange = absoluteRangeForAtomicPaste(envelope.originalRange, in: context) else {
            return false
        }
        return rangeDamagesRichSlackTokens(absoluteRange: absoluteRange, in: context)
    }

    /// Scoped contexts (where `context.text` is a proper substring of the field's
    /// full value) must not go through `applyFullReplacement`: that writes the
    /// scoped substring to `kAXValueAttribute` of the whole field and would wipe
    /// URLs, @mentions and other content that lives outside the scope.
    private func shouldAvoidScopedFullReplacement(_ context: FocusedTextContext) -> Bool {
        guard let full = valueText(of: context.targetElement) else { return false }
        let trimmedFull = normalized(full)
        let trimmedContext = normalized(context.text)
        guard !trimmedFull.isEmpty, !trimmedContext.isEmpty else { return false }
        if trimmedFull == trimmedContext { return false }
        // If our scope is a strict substring of the full value we are editing
        // only a portion of a larger field — replacing everything is unsafe.
        return trimmedFull.contains(trimmedContext)
    }

    private func richTokenRanges(in text: String) -> [NSRange] {
        let pattern = #"(?im)^\s*(?:[-*•]|\d+[.)])\s+|(?i)(?:https?://|www\.)\S+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|[@#][\p{L}\p{N}_][\p{L}\p{N}_-]*|\d+(?:[.,:/()\s-]\d+)*%?"#
        let ns = text as NSString
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

    private func rewriteProtectedRanges(in text: String) -> [NSRange] {
        richTokenRanges(in: text)
    }

    private func protectedTokens(in text: String) -> [String] {
        let ns = text as NSString
        return rewriteProtectedRanges(in: text).map { ns.substring(with: $0) }
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

    private func isBrowserBundleID(_ bundleID: String) -> Bool {
        let b = bundleID.lowercased()
        return b == "com.google.chrome"
            || b == "com.apple.safari"
            || b == "company.thebrowser.browser"
            || b.contains("arc")
            || b.contains("chrome")
            || b.contains("firefox")
            || b.contains("brave")
            || b.contains("opera")
    }

    private func isPDFReaderBundleID(_ bundleID: String) -> Bool {
        let b = bundleID.lowercased()
        return b == "com.adobe.reader"
            || b == "com.adobe.acrobat.pro"
            || b == "com.apple.preview"
            || b.contains("adobe.reader")
            || b.contains("adobe.acrobat")
            || b.contains("pdf")
    }

    /// Browsers and Electron/WebView messengers (Slack, Telegram, …) often ignore AX writes on selection; Cmd+C / Cmd+V works.
    private func prefersClipboardSelectionPasteReplaceForBundle(_ bundleID: String) -> Bool {
        if isBrowserBundleID(bundleID) || isPDFReaderBundleID(bundleID) { return true }
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
    }

    private func prefersClipboardSelectionContextForBundle(_ bundleID: String) -> Bool {
        isBrowserBundleID(bundleID) || isSlackBundleID(bundleID) || isPDFReaderBundleID(bundleID)
    }

    private func prefersAtomicClipboardRangePaste(for context: FocusedTextContext) -> Bool {
        !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyClipboardSelectionPasteReplace(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount
        let originalValue = valueText(of: context.targetElement)

        // Best effort: restore original selection before browser-native copy/paste.
        if let range = context.selectedRange {
            var r = range
            if let value = AXValueCreate(.cfRange, &r) {
                _ = AXUIElementSetAttributeValue(
                    context.targetElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    value
                )
                usleep(35_000)
            }
        }

        // 1) Copy current selection (app-native; works for browsers + Electron webviews)
        triggerCopyShortcut()
        usleep(120_000)
        let copiedBefore = pasteboard.string(forType: .string) ?? ""
        // In Docs multi-line selections can serialize differently (\n vs paragraph separators),
        // so keep this guard minimal: only require some selection signal.
        let hasSelectionSignal = !copiedBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (context.selectedRange?.length ?? 0) > 0
        guard hasSelectionSignal else {
            restorePasteboard(pasteboard, snapshot: snapshot)
            return false
        }
        let richSource = richTextFromPasteboard(pasteboard, matching: copiedBefore)

        // 2) Paste rewritten text over selection.
        guard writeReplacementToPasteboard(rewritten, preserving: richSource, pasteboard: pasteboard) else {
            restorePasteboard(pasteboard, snapshot: snapshot)
            return false
        }
        guard triggerPasteShortcut() else {
            restorePasteboard(pasteboard, snapshot: snapshot)
            return false
        }
        usleep(140_000)

        if let originalValue, let updatedValue = valueText(of: context.targetElement) {
            let changed = normalized(updatedValue) != normalized(originalValue)
            let containsReplacement = normalized(updatedValue).contains(normalized(rewritten))
            textoraDiagLog(
                "clipboardSelectionPasteReplace",
                "post-paste valueChanged=\(changed) containsReplacement=\(containsReplacement) "
                + "original=\(textoraDiagPreview(originalValue)) updated=\(textoraDiagPreview(updatedValue))"
            )
            if changed, containsReplacement {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return true
            }
            if !changed {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
        }

        // 3) Verify by selecting previous range and copying again (best effort).
        if let range = context.selectedRange {
            var r = range
            if let value = AXValueCreate(.cfRange, &r) {
                _ = AXUIElementSetAttributeValue(
                    context.targetElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    value
                )
                usleep(35_000)
            }
        }
        triggerCopyShortcut()
        usleep(120_000)
        let copiedAfter = pasteboard.string(forType: .string) ?? ""
        let rewrittenNorm = normalized(rewritten)
        let copiedAfterNorm = normalized(copiedAfter)
        let ok = copiedAfterNorm == rewrittenNorm
            || (!rewrittenNorm.isEmpty && copiedAfterNorm.contains(rewrittenNorm))

        // Always restore user clipboard after our flow.
        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        textoraDiagLog(
            "clipboardSelectionPasteReplace",
            "verify copiedAfterOK=\(ok) copiedAfter=\(textoraDiagPreview(copiedAfter))"
        )
        return ok
    }

    private func applyDiffBasedClipboardSelectionPaste(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        guard context.usesSelection, let selectedRange = context.selectedRange else { return false }
        let diffs = WordDiff.changes(original: context.text, corrected: rewritten)
        guard !diffs.isEmpty else { return true }

        // Very large rewrites are intentionally left to the full-selection fallback; partial ranges
        // are best for Grammarly-style localized edits that preserve surrounding rich formatting.
        let originalLength = max(1, (context.text as NSString).length)
        let changedLength = diffs.reduce(0) { $0 + $1.range.length }
        guard Double(changedLength) / Double(originalLength) <= 0.65 else { return false }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        for diff in diffs.reversed() {
            var absoluteRange = CFRange(
                location: selectedRange.location + diff.range.location,
                length: diff.range.length
            )
            guard let rangeValue = AXValueCreate(.cfRange, &absoluteRange) else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            let selectStatus = AXUIElementSetAttributeValue(
                context.targetElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
            guard selectStatus == .success else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            usleep(35_000)

            let expected = (context.text as NSString).substring(with: diff.range)
            let richSource = captureRichTextFromActiveSelection(expectedText: expected, pasteboard: pasteboard)
            guard writeReplacementToPasteboard(
                diff.replacement,
                preserving: richSource,
                pasteboard: pasteboard
            ) else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            guard triggerPasteShortcut() else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            usleep(90_000)
        }

        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        return true
    }

    private func applyDiffBasedClipboardRangePaste(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        let diffs = WordDiff.changes(original: context.text, corrected: rewritten)
        guard !diffs.isEmpty else { return true }

        if isSlackBundleID(context.targetBundleID) {
            return applySingleEnvelopeClipboardRangePaste(rewritten, basedOn: context)
        }

        let originalLength = max(1, (context.text as NSString).length)
        let changedLength = diffs.reduce(0) { $0 + $1.range.length }
        guard Double(changedLength) / Double(originalLength) <= 0.65 else { return false }

        let target = context.targetElement
        let originalValue = valueText(of: target)
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        for diff in diffs.reversed() {
            guard let absoluteRange = absoluteAXRange(for: diff.range, in: context) else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            var cfRange = CFRange(location: absoluteRange.location, length: absoluteRange.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            let selectStatus = AXUIElementSetAttributeValue(
                target,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
            guard selectStatus == .success else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            usleep(45_000)

            let expected = (context.text as NSString).substring(with: diff.range)
            let richSource = captureRichTextFromActiveSelection(expectedText: expected, pasteboard: pasteboard)
            guard writeReplacementToPasteboard(
                diff.replacement,
                preserving: richSource,
                pasteboard: pasteboard
            ) else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            guard triggerPasteShortcut() else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                return false
            }
            usleep(110_000)
        }

        let didChange: Bool = {
            guard let originalValue, let updatedValue = valueText(of: target) else {
                return true
            }
            return normalized(originalValue) != normalized(updatedValue)
        }()
        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        return didChange
    }

    private func applySingleEnvelopeClipboardRangePaste(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        guard let envelope = changedEnvelope(original: context.text, corrected: rewritten) else {
            return true
        }
        return applyClipboardRangePaste(
            replacement: envelope.replacement,
            localRange: envelope.originalRange,
            basedOn: context,
            requireSelectionVerification: prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID)
        )
    }

    private func applySingleEnvelopePhysicalRewrite(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        guard let envelope = changedEnvelope(original: context.text, corrected: rewritten) else {
            return true
        }
        guard let absoluteRange = absoluteRangeForAtomicPaste(envelope.originalRange, in: context) else {
            textoraDiagLog(
                "countedPhysicalRangeRewrite",
                "envelope abort: no absoluteRange local=\(envelope.originalRange.location):\(envelope.originalRange.length)"
            )
            return false
        }
        guard !rangeDamagesRichSlackTokens(absoluteRange: absoluteRange, in: context) else {
            textoraDiagLog(
                "countedPhysicalRangeRewrite",
                "envelope abort: damages rich token absolute=\(absoluteRange.location):\(absoluteRange.length)"
            )
            return false
        }
        if prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID) {
            return applyStartAnchoredDeletePhysicalRewrite(
                replacement: envelope.replacement,
                absoluteRange: absoluteRange,
                basedOn: context
            )
        }
        return applyCountedPhysicalRangeRewrite(
            replacement: envelope.replacement,
            absoluteRange: absoluteRange,
            basedOn: context
        )
    }

    /// Convenience wrapper: compute the minimal diff envelope between
    /// `context.text` and `rewritten`, then run `applyKeystrokeSelectionRangePaste`
    /// for that envelope.
    private func applyKeystrokeSelectionEnvelopePaste(
        _ rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard let envelope = changedEnvelope(original: context.text, corrected: rewritten) else {
            textoraDiagLog("keystrokeRangePaste", "envelope: no diff — nothing to apply")
            return true
        }
        return applyKeystrokeSelectionRangePaste(
            replacement: envelope.replacement,
            localRange: envelope.originalRange,
            basedOn: context
        )
    }

    /// Same idea as `applyKeystrokeSelectionEnvelopePaste` but using the
    /// caret-anchored (Cmd+↓ + ← + Shift+←) selection strategy — used when
    /// the composer refuses to honour AX caret placement at any absolute
    /// offset > 0 (Slack's multi-block case).
    private func applyCaretAnchoredKeystrokeEnvelopePaste(
        _ rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard let envelope = changedEnvelope(original: context.text, corrected: rewritten) else {
            textoraDiagLog("caretAnchoredRangePaste", "envelope: no diff — nothing to apply")
            return true
        }
        return applyCaretAnchoredKeystrokeRangePaste(
            replacement: envelope.replacement,
            localRange: envelope.originalRange,
            basedOn: context
        )
    }

    /// Caret-anchored, fully-keyboard range replacement for Electron
    /// composers (Slack/Teams/Discord) that silently shift AX-positioned
    /// carets inside multi-block DOM trees.
    ///
    /// Steps:
    ///   1. `Cmd+↓` — move caret to end of document (reliable in Slack).
    ///   2. `←` × (fullLen − absoluteRange.end) — walk back to the right
    ///      edge of the replacement range.
    ///   3. `Shift+←` × absoluteRange.length — select the scope.
    ///   4. `Cmd+V` — paste replacement.
    ///   5. Validate with the same length + prefix/suffix + anchor probes
    ///      as `applyClipboardRangePaste`; undo on mismatch.
    private func applyCaretAnchoredKeystrokeRangePaste(
        replacement: String,
        localRange: NSRange,
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard let absoluteRange = absoluteRangeForAtomicPaste(localRange, in: context) else {
            textoraDiagLog("caretAnchoredRangePaste", "abort: no absoluteRange for local=\(localRange.location):\(localRange.length)")
            return false
        }
        guard absoluteRange.length > 0 else {
            textoraDiagLog("caretAnchoredRangePaste", "abort: zero-length range — nothing to select")
            return false
        }
        guard let originalValue = valueText(of: context.targetElement) else {
            textoraDiagLog("caretAnchoredRangePaste", "abort: no value readback available")
            return false
        }
        let originalNS = originalValue as NSString
        let originalLen = originalNS.length
        let absoluteEnd = absoluteRange.location + absoluteRange.length
        guard absoluteEnd <= originalLen else {
            textoraDiagLog(
                "caretAnchoredRangePaste",
                "abort: absoluteRange=\(absoluteRange.location):\(absoluteRange.length) exceeds originalLen=\(originalLen)"
            )
            return false
        }
        let rightDistance = originalLen - absoluteEnd
        let totalKeystrokes = rightDistance + absoluteRange.length
        // Keep the keystroke budget bounded so we don't stall the UI for
        // giant documents. Fallback is `applyReconstructedFullValuePaste`.
        let maxKeystrokes = 800
        guard totalKeystrokes <= maxKeystrokes else {
            textoraDiagLog(
                "caretAnchoredRangePaste",
                "abort: total keystrokes=\(totalKeystrokes) > \(maxKeystrokes) (right=\(rightDistance) len=\(absoluteRange.length))"
            )
            return false
        }

        textoraDiagLog(
            "caretAnchoredRangePaste",
            "enter bundle=\(context.targetBundleID) "
            + "localRange=\(localRange.location):\(localRange.length) "
            + "absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
            + "originalLen=\(originalLen) rightDistance=\(rightDistance) "
            + "replacement=\(textoraDiagPreview(replacement))"
        )

        let target = context.targetElement
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        focusTargetAppAndElement(context)

        // 1) Anchor caret at end-of-document.
        triggerCmdDownArrowKey()
        usleep(90_000)

        // 2) Walk back to the right edge of the replacement range.
        textoraDiagLog(
            "caretAnchoredRangePaste",
            "dispatching \(rightDistance)x Left then \(absoluteRange.length)x Shift+Left"
        )
        for _ in 0..<rightDistance {
            triggerLeftArrowKey()
        }
        if rightDistance > 0 {
            usleep(UInt32(40_000 + rightDistance * 150))
        }

        // 3) Extend selection leftwards to cover the scope.
        for _ in 0..<absoluteRange.length {
            triggerShiftLeftArrowKey()
        }
        usleep(UInt32(60_000 + absoluteRange.length * 200))

        // 4) Paste replacement.
        let selectedSource = (originalValue as NSString).substring(with: absoluteRange)
        let richSource = captureRichTextFromActiveSelection(expectedText: selectedSource, pasteboard: pasteboard)
        guard writeReplacementToPasteboard(
            replacement,
            preserving: richSource,
            pasteboard: pasteboard
        ) else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            return false
        }
        guard triggerPasteShortcut() else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("caretAnchoredRangePaste", "exit false (triggerPasteShortcut failed)")
            return false
        }
        usleep(180_000)

        // 5) Validate.
        if let updatedValue = valueText(of: target) {
            let expectedValue = replacingText(in: originalValue, range: absoluteRange, with: replacement)
            let exactMatch = normalized(updatedValue) == normalized(expectedValue)
            let valueActuallyChanged = normalized(originalValue) != normalized(updatedValue)
            let landed = pasteLandedAtAnchor(
                originalValue: originalValue,
                updatedValue: updatedValue,
                absoluteRange: absoluteRange,
                replacement: replacement
            )
            let updatedLen = (updatedValue as NSString).length
            let replacementLen = (replacement as NSString).length
            let expectedLen = max(0, originalLen - absoluteRange.length + replacementLen)
            textoraDiagLog(
                "caretAnchoredRangePaste",
                "post-paste exactMatch=\(exactMatch) valueChanged=\(valueActuallyChanged) "
                + "landedAtAnchor=\(landed) "
                + "lens origLen=\(originalLen) updLen=\(updatedLen) expLen=\(expectedLen) drift=\(updatedLen - expectedLen)"
            )
            if exactMatch {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("caretAnchoredRangePaste", "exit true (exact match)")
                return true
            }
            if valueActuallyChanged, landed {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("caretAnchoredRangePaste", "exit true (landedAtAnchor + valueChanged)")
                return true
            }
            if valueActuallyChanged {
                triggerUndoShortcut()
                usleep(90_000)
                textoraDiagLog("caretAnchoredRangePaste", "undo triggered (value changed but not at anchor)")
            }
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("caretAnchoredRangePaste", "exit false (paste not confirmed at anchor)")
            return false
        }

        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        textoraDiagLog("caretAnchoredRangePaste", "exit true (no value readback available)")
        return true
    }

    /// Range-replace fallback for Electron/webview composers (Slack, Teams,
    /// Discord, …) that accept caret placement via AX but silently drop
    /// multi-character range selections. We place the caret at the start of
    /// the range using `kAXSelectedTextRangeAttribute` with `length=0`
    /// (all hosts treat this as "move caret"), then extend the selection
    /// one character at a time with Shift+Right keystrokes, and paste over
    /// the selection. Finally we validate the result with the same length
    /// budget + anchor locality checks as `applyClipboardRangePaste`, so a
    /// silently failed selection still triggers an Undo instead of
    /// corrupting the user's text.
    private func applyKeystrokeSelectionRangePaste(
        replacement: String,
        localRange: NSRange,
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard let absoluteRange = absoluteRangeForAtomicPaste(localRange, in: context) else {
            textoraDiagLog("keystrokeRangePaste", "abort: no absoluteRange for local=\(localRange.location):\(localRange.length)")
            return false
        }
        guard absoluteRange.length > 0 else {
            textoraDiagLog("keystrokeRangePaste", "abort: zero-length range — nothing to select")
            return false
        }
        // Keep the keystroke budget bounded so we don't stall the UI for
        // giant selections. Full-field replacements should use the
        // reconstructed paste fallback instead.
        let maxKeystrokes = 600
        guard absoluteRange.length <= maxKeystrokes else {
            textoraDiagLog(
                "keystrokeRangePaste",
                "abort: range too long (\(absoluteRange.length) > \(maxKeystrokes))"
            )
            return false
        }

        textoraDiagLog(
            "keystrokeRangePaste",
            "enter bundle=\(context.targetBundleID) localRange=\(localRange.location):\(localRange.length) "
            + "absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
            + "replacement=\(textoraDiagPreview(replacement))"
        )

        let target = context.targetElement
        let originalValue = valueText(of: target)
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        focusTargetAppAndElement(context)

        var caretRange = CFRange(location: absoluteRange.location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &caretRange) else {
            textoraDiagLog("keystrokeRangePaste", "abort: AXValueCreate failed")
            return false
        }
        let caretStatus = AXUIElementSetAttributeValue(
            target,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard caretStatus == .success else {
            textoraDiagLog("keystrokeRangePaste", "abort: caret set status=\(caretStatus.rawValue)")
            return false
        }
        usleep(60_000)

        textoraDiagLog(
            "keystrokeRangePaste",
            "dispatching \(absoluteRange.length)x Shift+Right from location=\(absoluteRange.location)"
        )
        for _ in 0..<absoluteRange.length {
            triggerShiftRightArrowKey()
        }
        // Settle time proportional to the number of keystrokes so the
        // composer has a chance to coalesce them before we paste.
        usleep(UInt32(80_000 + absoluteRange.length * 200))

        let selectedSource = originalValue.map { ($0 as NSString).substring(with: absoluteRange) } ?? ""
        let richSource = captureRichTextFromActiveSelection(expectedText: selectedSource, pasteboard: pasteboard)
        guard writeReplacementToPasteboard(
            replacement,
            preserving: richSource,
            pasteboard: pasteboard
        ) else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            return false
        }
        guard triggerPasteShortcut() else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("keystrokeRangePaste", "exit false (triggerPasteShortcut failed)")
            return false
        }
        usleep(180_000)

        if let originalValue, let updatedValue = valueText(of: target) {
            let expectedValue = replacingText(in: originalValue, range: absoluteRange, with: replacement)
            let exactMatch = normalized(updatedValue) == normalized(expectedValue)
            let valueActuallyChanged = normalized(originalValue) != normalized(updatedValue)
            let landed = pasteLandedAtAnchor(
                originalValue: originalValue,
                updatedValue: updatedValue,
                absoluteRange: absoluteRange,
                replacement: replacement
            )
            let originalLen = (originalValue as NSString).length
            let updatedLen = (updatedValue as NSString).length
            let replacementLen = (replacement as NSString).length
            let expectedLen = max(0, originalLen - absoluteRange.length + replacementLen)
            textoraDiagLog(
                "keystrokeRangePaste",
                "post-paste exactMatch=\(exactMatch) valueChanged=\(valueActuallyChanged) landedAtAnchor=\(landed) "
                + "lens origLen=\(originalLen) updLen=\(updatedLen) expLen=\(expectedLen) drift=\(updatedLen - expectedLen)"
            )
            if exactMatch {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("keystrokeRangePaste", "exit true (exact match)")
                return true
            }
            if valueActuallyChanged, landed {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("keystrokeRangePaste", "exit true (landedAtAnchor + valueChanged)")
                return true
            }
            if valueActuallyChanged {
                triggerUndoShortcut()
                usleep(90_000)
                textoraDiagLog("keystrokeRangePaste", "undo triggered (value changed but not at anchor)")
            }
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("keystrokeRangePaste", "exit false (paste not confirmed at anchor)")
            return false
        }

        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        textoraDiagLog("keystrokeRangePaste", "exit true (no value readback available)")
        return true
    }

    /// Last-resort strategy for multi-block Electron composers (Slack, Teams, …):
    /// rebuild the full field value with the scoped correction applied and paste
    /// it over a `Cmd+A` selection. AX range writes silently fail in these hosts
    /// when the composer has multiple paragraph blocks (URL lines, mentions),
    /// but `Cmd+A` + `Cmd+V` is always honoured. Rich tokens (URLs) are
    /// re-parsed by Slack after the paste; @mention/#channel pills are lost and
    /// the user keeps them intact by editing normally.
    private func applyReconstructedFullValuePaste(
        _ rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        textoraDiagLog(
            "reconstructedFullValuePaste",
            "enter bundle=\(context.targetBundleID) "
            + "scope=\(textoraDiagPreview(context.text)) "
            + "rewritten=\(textoraDiagPreview(rewritten))"
        )
        guard prefersAtomicClipboardRangePaste(for: context) else {
            textoraDiagLog("reconstructedFullValuePaste", "abort: not an atomic-paste host")
            return false
        }
        guard !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            textoraDiagLog("reconstructedFullValuePaste", "abort: empty scope text")
            return false
        }
        guard let full = valueText(of: context.targetElement) else {
            textoraDiagLog("reconstructedFullValuePaste", "abort: no full value")
            return false
        }
        let fullNS = full as NSString
        guard fullNS.length > 0 else {
            textoraDiagLog("reconstructedFullValuePaste", "abort: empty full value")
            return false
        }

        let contextRange: NSRange = {
            let direct = fullNS.range(of: context.text)
            if direct.location != NSNotFound { return direct }
            let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != context.text {
                let trimmedRange = fullNS.range(of: trimmed)
                if trimmedRange.location != NSNotFound { return trimmedRange }
            }
            return NSRange(location: NSNotFound, length: 0)
        }()
        guard contextRange.location != NSNotFound else {
            textoraDiagLog("reconstructedFullValuePaste", "abort: scope not found in full value")
            return false
        }

        let reconstructed = fullNS.replacingCharacters(in: contextRange, with: rewritten)
        guard normalized(reconstructed) != normalized(full) else {
            textoraDiagLog("reconstructedFullValuePaste", "no-op: reconstructed == full (returning true)")
            return true
        }

        textoraDiagLog(
            "reconstructedFullValuePaste",
            "about to Cmd+A + paste contextRange=\(contextRange.location):\(contextRange.length) "
            + "reconstructedPreview=\(textoraDiagPreview(reconstructed))"
        )

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        focusTargetAppAndElement(context)
        pasteboard.clearContents()

        // Electron/webview composers (Slack, Teams, Discord, …) expose
        // their value as concatenated plain text via AX, but internally
        // render each logical block (URL, mention, paragraph) as its own
        // DOM paragraph element with CSS padding between them. Visual
        // "blank lines" between blocks come from that inter-block margin,
        // not from empty-paragraph characters in the string. When we
        // paste reconstructed plain text via Cmd+A + Cmd+V, Slack's
        // paste handler treats every internal `\n` as a *soft break*
        // within the current block and collapses the whole message into
        // a single block, erasing those visual blank lines and forcing
        // URLs to be auto-linked in the new single block.
        //
        // To preserve block boundaries we publish three formats on the
        // pasteboard through a single `NSPasteboardItem`:
        //   * RTF with explicit `\par` paragraph breaks (richest format,
        //     preferred by most Cocoa + Electron paste handlers),
        //   * HTML with `<p>…</p>` wrappers for each line,
        //   * plain text as a fallback.
        // We write through `NSPasteboardItem` (instead of bare
        // `setString` + `setData`) because the latter re-declares
        // pasteboard types in ways that can make earlier-written rich
        // representations "invisible" to some paste handlers.
        let isElectronLikeHost = prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID)
        let wantsRichFormats = isElectronLikeHost && reconstructed.contains("\n")

        let item = NSPasteboardItem()
        item.setString(reconstructed, forType: .string)
        var wroteHTML = false
        var wroteRTF = false
        if wantsRichFormats {
            if let html = htmlForParagraphPaste(reconstructed).data(using: .utf8) {
                item.setData(html, forType: .html)
                wroteHTML = true
            }
            if let rtf = rtfForParagraphPaste(reconstructed) {
                item.setData(rtf, forType: .rtf)
                wroteRTF = true
            }
        }
        pasteboard.writeObjects([item])

        let declaredTypes = pasteboard.types?.map(\.rawValue) ?? []
        textoraDiagLog(
            "reconstructedFullValuePaste",
            "pasteboard formats set plainText=true html=\(wroteHTML) rtf=\(wroteRTF) "
            + "declaredTypes=[\(declaredTypes.joined(separator: ", "))]"
        )

        triggerSelectAllShortcut()
        usleep(110_000)
        guard triggerPasteShortcut() else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("reconstructedFullValuePaste", "exit false (triggerPasteShortcut failed)")
            return false
        }
        let confirmed = waitForReconstructedPasteConfirmation(
            target: context.targetElement,
            originalValue: full,
            expectedValue: reconstructed,
            timeout: isElectronLikeHost ? 1.25 : 0.65
        )
        guard confirmed else {
            if let current = valueText(of: context.targetElement),
               normalized(current) != normalized(full),
               normalized(current) != normalized(reconstructed) {
                triggerUndoShortcut()
                usleep(90_000)
                textoraDiagLog(
                    "reconstructedFullValuePaste",
                    "undo triggered after unconfirmed paste current=\(textoraDiagPreview(current))"
                )
            }
            if isElectronLikeHost {
                pasteboard.clearContents()
                textoraDiagLog(
                    "reconstructedFullValuePaste",
                    "cleared pasteboard after unconfirmed Electron paste"
                )
            } else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            }
            textoraDiagLog("reconstructedFullValuePaste", "exit false (paste not confirmed)")
            return false
        }
        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        textoraDiagLog("reconstructedFullValuePaste", "exit true (confirmed)")
        return true
    }

    private func waitForReconstructedPasteConfirmation(
        target: AXUIElement,
        originalValue: String,
        expectedValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastObserved: String?
        repeat {
            usleep(45_000)
            guard let current = valueText(of: target) else {
                textoraDiagLog("reconstructedFullValuePaste", "confirm unavailable: no value readback")
                return true
            }
            lastObserved = current
            if normalized(current) == normalized(expectedValue) {
                textoraDiagLog("reconstructedFullValuePaste", "confirm exact expected value")
                return true
            }
        } while Date() < deadline

        textoraDiagLog(
            "reconstructedFullValuePaste",
            "confirm timeout original=\(textoraDiagPreview(originalValue)) "
            + "expected=\(textoraDiagPreview(expectedValue)) "
            + "observed=\(textoraDiagPreview(lastObserved ?? "nil"))"
        )
        return false
    }

    /// Build an HTML *fragment* (no `<html>`/`<body>` wrapper) that puts
    /// every line of `text` in its own `<p>` element. Empty lines become
    /// `<p><br></p>` so that inter-block visual padding is preserved
    /// after paste into Slack/Teams/Discord composers.
    ///
    /// Quill-style paste handlers read `text/html` from the clipboard
    /// and apply their paragraph matcher line-by-line, so handing them
    /// a plain fragment is both smaller and more tolerant than a full
    /// HTML document.
    private func htmlForParagraphPaste(_ text: String) -> String {
        let escape: (String) -> String = { raw in
            raw
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let lines = text.components(separatedBy: "\n")
        return lines.map { line -> String in
            if line.isEmpty { return "<p><br></p>" }
            return "<p>\(escape(line))</p>"
        }.joined()
    }

    /// Build RTF data using `NSAttributedString` with explicit paragraph
    /// styles per line. Electron and Cocoa paste handlers that honour
    /// `public.rtf` will recreate separate paragraph blocks from the
    /// `\par` tokens this serialisation emits.
    private func rtfForParagraphPaste(_ text: String) -> Data? {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        let full = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if !line.isEmpty {
                full.append(NSAttributedString(string: line, attributes: attrs))
            }
            if index < lines.count - 1 {
                full.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        return try? full.data(
            from: NSRange(location: 0, length: full.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private func applyClipboardRangePaste(
        replacement: String,
        localRange: NSRange,
        basedOn context: FocusedTextContext,
        requireSelectionVerification: Bool
    ) -> Bool {
        guard let absoluteRange = absoluteRangeForAtomicPaste(localRange, in: context) else {
            textoraDiagLog(
                "clipboardRangePaste",
                "abort: absoluteRangeForAtomicPaste=nil localRange=\(localRange.location):\(localRange.length)"
            )
            return false
        }

        let contextNS = context.text as NSString
        let safeLocation = max(0, min(localRange.location, contextNS.length))
        let safeLength = max(0, min(localRange.length, contextNS.length - safeLocation))
        let safeLocalRange = NSRange(location: safeLocation, length: safeLength)
        let expectedSelectedText = safeLocalRange.length > 0 ? contextNS.substring(with: safeLocalRange) : ""
        return applyClipboardRangePaste(
            replacement: replacement,
            localRange: safeLocalRange,
            absoluteRange: absoluteRange,
            expectedSelectedText: expectedSelectedText,
            basedOn: context,
            requireSelectionVerification: requireSelectionVerification
        )
    }

    private func applyClipboardRangePaste(
        replacement: String,
        localRange: NSRange,
        absoluteRange: NSRange,
        expectedSelectedText: String,
        basedOn context: FocusedTextContext,
        requireSelectionVerification: Bool
    ) -> Bool {

        // Electron/webview composers (Slack, Teams, Discord, …) accept
        // `AXUIElementSetAttributeValue(kAXSelectedTextRangeAttribute)` and
        // actually move the caret, but *both* verification channels lie:
        //  • `kAXSelectedTextRangeAttribute` read-back returns (0,0) or the
        //    previous range;
        //  • `Cmd+C` dumps an empty/stale pasteboard.
        // Forcing pre-paste verification in these hosts is what pushes the
        // pipeline into the last-resort `applyReconstructedFullValuePaste`
        // (Cmd+A + Cmd+V of the whole field), which is exactly what
        // autolinks URLs and collapses blank lines. For these hosts we
        // trust `selectStatus == .success` and instead verify **after**
        // the paste by checking that `replacement` materialized at the
        // expected absolute offset.
        let isHostWithUnreliableSelectionReadback =
            prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID)

        textoraDiagLog(
            "clipboardRangePaste",
            "enter localRange=\(localRange.location):\(localRange.length) "
            + "absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
            + "expectedSelected=\(textoraDiagPreview(expectedSelectedText)) "
            + "replacement=\(textoraDiagPreview(replacement)) "
            + "requireSelectionVerification=\(requireSelectionVerification) "
            + "hostUnreliableReadback=\(isHostWithUnreliableSelectionReadback)"
        )

        let target = context.targetElement
        let originalValue = valueText(of: target)
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        var cfRange = CFRange(location: absoluteRange.location, length: absoluteRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            textoraDiagLog("clipboardRangePaste", "abort: AXValueCreate failed")
            return false
        }
        let selectStatus = AXUIElementSetAttributeValue(
            target,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard selectStatus == .success else {
            textoraDiagLog("clipboardRangePaste", "abort: selectStatus=\(selectStatus.rawValue)")
            return false
        }
        usleep(90_000)

        // AX read-back is cheap; use it as an early positive signal for
        // well-behaved hosts (Notes, Mail, TextEdit). For Electron hosts we
        // ignore its negative result.
        let axConfirmedSelection = axSelectionMatches(target, absoluteRange: absoluteRange)
        textoraDiagLog("clipboardRangePaste", "axConfirmedSelection=\(axConfirmedSelection)")

        if !axConfirmedSelection,
           requireSelectionVerification,
           !isHostWithUnreliableSelectionReadback {
            let verified = verifyActiveSelection(expectedText: expectedSelectedText, pasteboard: pasteboard)
            textoraDiagLog("clipboardRangePaste", "verifyActiveSelection=\(verified)")
            if !verified {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("clipboardRangePaste", "exit false (selection not verified)")
                return false
            }
        }

        let richSource = captureRichTextFromActiveSelection(
            expectedText: expectedSelectedText,
            pasteboard: pasteboard
        )
        guard writeReplacementToPasteboard(
            replacement,
            preserving: richSource,
            pasteboard: pasteboard
        ) else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            return false
        }
        guard triggerPasteShortcut() else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("clipboardRangePaste", "exit false (triggerPasteShortcut failed)")
            return false
        }
        usleep(160_000)

        if let originalValue, let updatedValue = valueText(of: target) {
            let expectedValue = replacingText(in: originalValue, range: absoluteRange, with: replacement)
            let exactMatch = normalized(updatedValue) == normalized(expectedValue)
            let valueActuallyChanged = normalized(originalValue) != normalized(updatedValue)
            let replacementLandedNearAnchor = pasteLandedAtAnchor(
                originalValue: originalValue,
                updatedValue: updatedValue,
                absoluteRange: absoluteRange,
                replacement: replacement
            )
            let originalLen = (originalValue as NSString).length
            let updatedLen = (updatedValue as NSString).length
            let replacementLen = (replacement as NSString).length
            let expectedLen = max(0, originalLen - absoluteRange.length + replacementLen)
            textoraDiagLog(
                "clipboardRangePaste",
                "post-paste exactMatch=\(exactMatch) "
                + "valueChanged=\(valueActuallyChanged) "
                + "landedAtAnchor=\(replacementLandedNearAnchor) "
                + "lens origLen=\(originalLen) updLen=\(updatedLen) expLen=\(expectedLen) drift=\(updatedLen - expectedLen) "
                + "expected=\(textoraDiagPreview(expectedValue)) "
                + "updated=\(textoraDiagPreview(updatedValue))"
            )
            if exactMatch {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("clipboardRangePaste", "exit true (exact match)")
                return true
            }
            // Electron composers post-process the pasted text (auto-link URLs,
            // normalize whitespace, insert zero-width joiners), so a strict
            // equality check against `expectedValue` frequently fails even
            // when the paste produced the correct visible text. `pasteLandedAtAnchor`
            // is our ground truth: length budget + prefix/suffix stability +
            // replacement locality.
            //
            // NOTE: we deliberately no longer short-circuit on
            // `axConfirmedSelection`. Slack has been observed to accept the
            // AX set-range, report it back verbatim through
            // `kAXSelectedTextRangeAttribute`, *and still* apply the
            // selection with a small byte offset inside its DOM — producing
            // results like `"TheThey're … figure oute connections."` while
            // AX insists everything is fine. Only the post-paste content
            // check can catch that.
            if valueActuallyChanged, replacementLandedNearAnchor {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
                textoraDiagLog("clipboardRangePaste", "exit true (landedAtAnchor + valueChanged)")
                return true
            }
            if valueActuallyChanged {
                // The value changed but our replacement is not where we
                // expected it — the selection ended up elsewhere. Undo so
                // we do not silently corrupt the user's text.
                triggerUndoShortcut()
                usleep(90_000)
                textoraDiagLog("clipboardRangePaste", "undo triggered (value changed but replacement not at anchor)")
            }
            if isHostWithUnreliableSelectionReadback {
                pasteboard.clearContents()
                textoraDiagLog(
                    "clipboardRangePaste",
                    "cleared pasteboard after unconfirmed Electron paste"
                )
            } else {
                restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            }
            textoraDiagLog("clipboardRangePaste", "exit false (paste not confirmed at anchor)")
            return false
        }

        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        textoraDiagLog("clipboardRangePaste", "exit true (no value readback available)")
        return true
    }

    private func applyTrustedClipboardRangePaste(
        replacement: String,
        localRange: NSRange,
        absoluteRange: NSRange,
        expectedSelectedText: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        textoraDiagLog(
            "trustedRangePaste",
            "enter localRange=\(localRange.location):\(localRange.length) "
            + "absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
            + "expectedSelected=\(textoraDiagPreview(expectedSelectedText)) "
            + "replacement=\(textoraDiagPreview(replacement))"
        )

        let target = context.targetElement
        let originalValue = valueText(of: target)
        var cfRange = CFRange(location: absoluteRange.location, length: absoluteRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            textoraDiagLog("trustedRangePaste", "abort: AXValueCreate failed")
            return false
        }
        let selectStatus = AXUIElementSetAttributeValue(
            target,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard selectStatus == .success else {
            textoraDiagLog("trustedRangePaste", "abort: selectStatus=\(selectStatus.rawValue)")
            return false
        }
        usleep(90_000)

        if replacement.isEmpty {
            let directStatus = AXUIElementSetAttributeValue(
                target,
                kAXSelectedTextAttribute as CFString,
                "" as CFTypeRef
            )
            if directStatus == .success {
                usleep(120_000)
                if trustedRangePasteConfirmed(
                    originalValue: originalValue,
                    updatedValue: valueText(of: target),
                    absoluteRange: absoluteRange,
                    replacement: replacement
                ) {
                    textoraDiagLog("trustedRangePaste", "exit true (empty replacement via AX selected text)")
                    return true
                }
                undoUnconfirmedTrustedRangeMutation(
                    originalValue: originalValue,
                    currentValue: valueText(of: target),
                    reason: "AX selected text deletion"
                )
                textoraDiagLog("trustedRangePaste", "AX selected text reported success but deletion was not confirmed")
            }
            triggerDeleteKey()
            usleep(140_000)
            if trustedRangePasteConfirmed(
                originalValue: originalValue,
                updatedValue: valueText(of: target),
                absoluteRange: absoluteRange,
                replacement: replacement
            ) {
                textoraDiagLog("trustedRangePaste", "exit true (empty replacement via Delete)")
                return true
            }
            undoUnconfirmedTrustedRangeMutation(
                originalValue: originalValue,
                currentValue: valueText(of: target),
                reason: "Delete"
            )
            textoraDiagLog("trustedRangePaste", "Delete did not confirm deletion; trying physical rewrite fallback")
            return applyTrustedPhysicalRangeRewrite(
                replacement: replacement,
                requestedRange: absoluteRange,
                confirmationRange: absoluteRange,
                originalValue: originalValue,
                basedOn: context
            )
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let baselineChangeCount = pasteboard.changeCount
        let richSource = captureRichTextFromActiveSelection(
            expectedText: expectedSelectedText,
            pasteboard: pasteboard
        )
        guard writeReplacementToPasteboard(
            replacement,
            preserving: richSource,
            pasteboard: pasteboard
        ) else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            return false
        }
        guard triggerPasteShortcut() else {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("trustedRangePaste", "exit false (triggerPasteShortcut failed)")
            return false
        }
        usleep(240_000)
        if trustedRangePasteConfirmed(
            originalValue: originalValue,
            updatedValue: valueText(of: target),
            absoluteRange: absoluteRange,
            replacement: replacement
        ) {
            restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
            textoraDiagLog("trustedRangePaste", "exit true (paste confirmed)")
            return true
        }

        undoUnconfirmedTrustedRangeMutation(
            originalValue: originalValue,
            currentValue: valueText(of: target),
            reason: "paste"
        )
        textoraDiagLog("trustedRangePaste", "paste dispatched but not confirmed; trying physical rewrite fallback")
        let physicalOK = applyTrustedPhysicalRangeRewrite(
            replacement: replacement,
            requestedRange: absoluteRange,
            confirmationRange: absoluteRange,
            originalValue: originalValue,
            basedOn: context
        )
        restorePasteboardIfNeeded(pasteboard, snapshot: snapshot, baselineChangeCount: baselineChangeCount)
        textoraDiagLog("trustedRangePaste", "physical fallback result=\(physicalOK)")
        return physicalOK
    }

    private func undoUnconfirmedTrustedRangeMutation(
        originalValue: String?,
        currentValue: String?,
        reason: String
    ) {
        guard let originalValue, let currentValue, originalValue != currentValue else { return }
        triggerUndoShortcut()
        usleep(100_000)
        textoraDiagLog("trustedRangePaste", "undo triggered after unconfirmed \(reason)")
    }

    private func applyBatchedCountedPhysicalRewrite(
        changes: [(range: NSRange, replacement: String)],
        rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let sorted = changes.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
        guard !sorted.isEmpty else { return true }

        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("batchedPhysicalRewrite", "abort: no value readback available")
            return false
        }
        let originalLen = (originalValue as NSString).length
        var previousEnd = 0
        var cumulativeDelta = 0
        var cursorLocation = 0
        var keystrokeBudget = 0

        for change in sorted {
            let end = change.range.location + change.range.length
            guard change.range.location >= previousEnd,
                  change.range.location >= 0,
                  change.range.length >= 0,
                  end <= originalLen else {
                textoraDiagLog(
                    "batchedPhysicalRewrite",
                    "abort: invalid/overlapping range=\(change.range.location):\(change.range.length) "
                    + "previousEnd=\(previousEnd) originalLen=\(originalLen)"
                )
                return false
            }
            let currentLocation = change.range.location + cumulativeDelta
            guard currentLocation >= cursorLocation else {
                textoraDiagLog(
                    "batchedPhysicalRewrite",
                    "abort: currentLocation=\(currentLocation) before cursor=\(cursorLocation)"
                )
                return false
            }
            keystrokeBudget += currentLocation - cursorLocation + change.range.length
            cumulativeDelta += (change.replacement as NSString).length - change.range.length
            cursorLocation = currentLocation + (change.replacement as NSString).length
            previousEnd = end
        }

        let maxKeystrokes = 1800
        guard keystrokeBudget <= maxKeystrokes else {
            textoraDiagLog(
                "batchedPhysicalRewrite",
                "abort: keystrokeBudget=\(keystrokeBudget) > \(maxKeystrokes)"
            )
            return false
        }

        let expectedValue = expectedFullValue(
            originalValue: originalValue,
            rewritten: rewritten,
            basedOn: context,
            changes: sorted
        )

        textoraDiagLog(
            "batchedPhysicalRewrite",
            "enter bundle=\(context.targetBundleID) changes=\(sorted.count) "
            + "originalLen=\(originalLen) expectedLen=\((expectedValue as NSString).length) "
            + "keystrokeBudget=\(keystrokeBudget)"
        )

        focusTargetAppAndElement(context)
        usleep(180_000)
        triggerCmdLeftArrowKey()
        usleep(80_000)
        triggerCmdLeftArrowKey()
        usleep(120_000)

        cumulativeDelta = 0
        cursorLocation = 0
        for change in sorted {
            let currentLocation = change.range.location + cumulativeDelta
            let moveRightCount = currentLocation - cursorLocation
            if moveRightCount > 0 {
                textoraDiagLog(
                    "batchedPhysicalRewrite",
                    "moveRight=\(moveRightCount) delete=\(change.range.length) "
                    + "replacement=\(textoraDiagPreview(change.replacement))"
                )
            } else {
                textoraDiagLog(
                    "batchedPhysicalRewrite",
                    "moveRight=0 delete=\(change.range.length) "
                    + "replacement=\(textoraDiagPreview(change.replacement))"
                )
            }

            for _ in 0..<moveRightCount {
                triggerRightArrowKey()
            }
            if moveRightCount > 0 {
                usleep(UInt32(35_000 + moveRightCount * 120))
            }

            if change.range.length > 0 {
                for _ in 0..<change.range.length {
                    triggerDeleteKey()
                    usleep(6_000)
                }
                usleep(UInt32(45_000 + change.range.length * 220))
            }

            if !change.replacement.isEmpty {
                guard triggerUnicodeText(change.replacement) else {
                    textoraDiagLog("batchedPhysicalRewrite", "abort: unicode typing failed")
                    return false
                }
                usleep(UInt32(70_000 + min(180_000, change.replacement.utf16.count * 2_000)))
            }

            cumulativeDelta += (change.replacement as NSString).length - change.range.length
            cursorLocation = currentLocation + (change.replacement as NSString).length
        }

        guard let updatedValue = valueText(of: target) else {
            textoraDiagLog("batchedPhysicalRewrite", "exit true (no value readback after typing)")
            return true
        }
        if normalized(updatedValue) == normalized(expectedValue) {
            textoraDiagLog("batchedPhysicalRewrite", "exit true (confirmed)")
            return true
        }

        if originalValue != updatedValue {
            triggerUndoShortcut()
            usleep(120_000)
            textoraDiagLog("batchedPhysicalRewrite", "undo triggered (not confirmed)")
        }
        textoraDiagLog(
            "batchedPhysicalRewrite",
            "exit false expected=\(textoraDiagPreview(expectedValue)) updated=\(textoraDiagPreview(updatedValue))"
        )
        return false
    }

    private func applyProtectedPhysicalRewritePlan(
        _ rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard let localChanges = GrammarlyRewritePlanner.physicalChanges(
            original: context.text,
            corrected: rewritten
        ) else {
            textoraDiagLog("protectedPhysicalRewritePlan", "abort: unsafe protected-token change")
            return false
        }
        guard !localChanges.isEmpty else {
            textoraDiagLog("protectedPhysicalRewritePlan", "exit true (no changes)")
            return true
        }

        var safeLocalChanges: [GrammarlyRewritePlanner.Change] = []
        var absoluteChanges: [(range: NSRange, replacement: String)] = []
        var skippedChanges = 0

        for change in localChanges {
            guard let absoluteRange = absoluteRangeForAtomicPaste(change.range, in: context) else {
                textoraDiagLog(
                    "protectedPhysicalRewritePlan",
                    "skip: no absoluteRange local=\(change.range.location):\(change.range.length)"
                )
                skippedChanges += 1
                continue
            }
            guard !rangeDamagesRichSlackTokens(absoluteRange: absoluteRange, in: context) else {
                textoraDiagLog(
                    "protectedPhysicalRewritePlan",
                    "skip: damages rich token absolute=\(absoluteRange.location):\(absoluteRange.length)"
                )
                skippedChanges += 1
                continue
            }
            safeLocalChanges.append(change)
            absoluteChanges.append((range: absoluteRange, replacement: change.replacement))
        }

        guard !absoluteChanges.isEmpty else {
            textoraDiagLog(
                "protectedPhysicalRewritePlan",
                "abort: no safe physical changes planned skipped=\(skippedChanges)/\(localChanges.count)"
            )
            return false
        }

        let plannedRewritten = skippedChanges == 0
            ? rewritten
            : GrammarlyRewritePlanner.applying(safeLocalChanges, to: context.text)

        textoraDiagLog(
            "protectedPhysicalRewritePlan",
            "enter changes=\(absoluteChanges.count) skipped=\(skippedChanges) "
            + "originalLen=\((context.text as NSString).length) "
            + "rewrittenLen=\((plannedRewritten as NSString).length)"
        )
        return applyBackspaceAnchoredPhysicalRewrite(
            changes: absoluteChanges,
            rewritten: plannedRewritten,
            basedOn: context
        )
    }

    private func applyBackspaceAnchoredPhysicalRewrite(
        changes: [(range: NSRange, replacement: String)],
        rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let sorted = changes.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
        guard !sorted.isEmpty else { return true }

        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("backspacePhysicalRewrite", "abort: no value readback available")
            return false
        }
        let originalLen = (originalValue as NSString).length
        var previousEnd = originalLen
        var keystrokeBudget = 0
        for change in sorted.reversed() {
            let end = NSMaxRange(change.range)
            guard change.range.location >= 0,
                  change.range.length >= 0,
                  end <= previousEnd,
                  end <= originalLen else {
                textoraDiagLog(
                    "backspacePhysicalRewrite",
                    "abort: invalid/overlapping range=\(change.range.location):\(change.range.length) "
                    + "previousEnd=\(previousEnd) originalLen=\(originalLen)"
                )
                return false
            }
            keystrokeBudget += previousEnd - end + change.range.length
            previousEnd = change.range.location
        }
        let maxKeystrokes = 1800
        guard keystrokeBudget <= maxKeystrokes else {
            textoraDiagLog(
                "backspacePhysicalRewrite",
                "abort: keystrokeBudget=\(keystrokeBudget) > \(maxKeystrokes)"
            )
            return false
        }

        let expectedValue = expectedFullValue(
            originalValue: originalValue,
            rewritten: rewritten,
            basedOn: context,
            changes: sorted
        )

        textoraDiagLog(
            "backspacePhysicalRewrite",
            "enter bundle=\(context.targetBundleID) changes=\(sorted.count) "
            + "originalLen=\(originalLen) expectedLen=\((expectedValue as NSString).length) "
            + "keystrokeBudget=\(keystrokeBudget)"
        )

        if let selectedRangeResult = applySelectedRangePhysicalRewrite(
            changes: sorted,
            expectedValue: expectedValue,
            originalValue: originalValue,
            basedOn: context
        ) {
            return selectedRangeResult
        }

        focusTargetAppAndElement(context)
        usleep(130_000)
        triggerCmdRightArrowKey()
        usleep(45_000)
        triggerCmdRightArrowKey()
        usleep(70_000)

        var currentCaret = originalLen
        for change in sorted.reversed() {
            let targetEnd = NSMaxRange(change.range)
            let moveLeftCount = currentCaret - targetEnd
            guard moveLeftCount >= 0 else {
                textoraDiagLog(
                    "backspacePhysicalRewrite",
                    "abort: currentCaret=\(currentCaret) before targetEnd=\(targetEnd)"
                )
                return false
            }

            textoraDiagLog(
                "backspacePhysicalRewrite",
                "moveLeft=\(moveLeftCount) backspace=\(change.range.length) "
                + "replacement=\(textoraDiagPreview(change.replacement))"
            )

            for _ in 0..<moveLeftCount {
                triggerLeftArrowKey()
                usleep(4_000)
            }
            if moveLeftCount > 0 {
                usleep(UInt32(35_000 + min(160_000, moveLeftCount * 700)))
            }

            if change.range.length > 0 {
                for _ in 0..<change.range.length {
                    triggerBackspaceKey()
                    usleep(6_000)
                }
                usleep(UInt32(70_000 + min(220_000, change.range.length * 2_000)))
            }

            if !change.replacement.isEmpty {
                guard triggerPhysicalReplacementText(change.replacement) else {
                    textoraDiagLog("backspacePhysicalRewrite", "abort: replacement physical typing failed")
                    return false
                }
                usleep(UInt32(90_000 + min(260_000, change.replacement.utf16.count * 2_000)))
            }

            currentCaret = change.range.location + (change.replacement as NSString).length
        }

        guard let updatedValue = waitForPhysicalRewriteValue(
            target: target,
            expectedValue: expectedValue,
            originalValue: originalValue
        ) else {
            textoraDiagLog("backspacePhysicalRewrite", "exit true (no value readback after typing)")
            return true
        }
        if matchesExpectedValuePreservingCase(updatedValue, expectedValue) {
            textoraDiagLog("backspacePhysicalRewrite", "exit true (confirmed)")
            return true
        }

        if originalValue != updatedValue {
            triggerUndoShortcut()
            usleep(120_000)
            textoraDiagLog("backspacePhysicalRewrite", "undo triggered (not confirmed)")
        }
        textoraDiagLog(
            "backspacePhysicalRewrite",
            "exit false expected=\(textoraDiagPreview(expectedValue)) updated=\(textoraDiagPreview(updatedValue))"
        )
        return false
    }

    private func applySelectedRangePhysicalRewrite(
        changes: [(range: NSRange, replacement: String)],
        expectedValue: String,
        originalValue: String,
        basedOn context: FocusedTextContext
    ) -> Bool? {
        guard !context.usesSelection else {
            textoraDiagLog("selectedRangePhysicalRewrite", "skip: active selection uses atomic selection paste")
            return nil
        }
        let target = context.targetElement
        var currentValue = originalValue
        var didMutateText = false
        var undoActionCount = 0

        textoraDiagLog(
            "selectedRangePhysicalRewrite",
            "enter changes=\(changes.count) bundle=\(context.targetBundleID)"
        )
        focusTargetAppAndElement(context)
        usleep(70_000)

        for change in changes.reversed() {
            guard change.range.location >= 0,
                  change.range.length >= 0,
                  NSMaxRange(change.range) <= (currentValue as NSString).length else {
                textoraDiagLog(
                    "selectedRangePhysicalRewrite",
                    "abort: invalid range=\(change.range.location):\(change.range.length) "
                    + "currentLen=\((currentValue as NSString).length)"
                )
                if undoActionCount > 0 {
                    undoPhysicalRewriteSteps(typingUndoCount: undoActionCount, deletionUndoCount: 0)
                    usleep(120_000)
                    return false
                }
                return nil
            }

            guard setSelectedTextRange(change.range, on: target, logScope: "selectedRangePhysicalRewrite") else {
                if undoActionCount > 0 {
                    undoPhysicalRewriteSteps(typingUndoCount: undoActionCount, deletionUndoCount: 0)
                    usleep(120_000)
                    return false
                }
                return nil
            }
            usleep(25_000)

            let expectedAfterDelete = replacingText(in: currentValue, range: change.range, with: "")
            if change.range.length > 0 {
                triggerBackspaceKey()
                guard let afterDelete = waitForPhysicalRewriteValue(
                    target: target,
                    expectedValue: expectedAfterDelete,
                    originalValue: currentValue
                ) else {
                    textoraDiagLog("selectedRangePhysicalRewrite", "abort: no readback after delete")
                    return false
                }
                guard matchesExpectedValuePreservingCase(afterDelete, expectedAfterDelete) else {
                    textoraDiagLog(
                        "selectedRangePhysicalRewrite",
                        "deleteMismatch expected=\(textoraDiagPreview(expectedAfterDelete)) "
                        + "updated=\(textoraDiagPreview(afterDelete))"
                    )
                    if currentValue != afterDelete {
                        if undoSelectedRangeMutationAndCanFallback(
                            target: target,
                            originalValue: originalValue,
                            typingUndoCount: undoActionCount + 1,
                            deletionUndoCount: 0,
                            logScope: "selectedRangePhysicalRewrite",
                            reason: "dirty delete mismatch"
                        ) {
                            return nil
                        }
                        return false
                    }
                    return nil
                }
                currentValue = afterDelete
                didMutateText = true
                undoActionCount += 1
            }

            if !change.replacement.isEmpty {
                let caretRange = NSRange(location: change.range.location, length: 0)
                _ = setSelectedTextRange(caretRange, on: target, logScope: "selectedRangePhysicalRewrite")
                usleep(20_000)
                guard triggerExactReplacementText(change.replacement) else {
                    textoraDiagLog("selectedRangePhysicalRewrite", "abort: exact replacement typing failed")
                    if undoActionCount > 0 {
                        undoPhysicalRewriteSteps(typingUndoCount: undoActionCount, deletionUndoCount: 0)
                        usleep(120_000)
                    }
                    return false
                }

                let expectedAfterInsert = replacingText(in: currentValue, range: caretRange, with: change.replacement)
                guard let afterInsert = waitForPhysicalRewriteValue(
                    target: target,
                    expectedValue: expectedAfterInsert,
                    originalValue: currentValue
                ) else {
                    textoraDiagLog("selectedRangePhysicalRewrite", "exit true (no readback after insert)")
                    return true
                }
                guard matchesExpectedValuePreservingCase(afterInsert, expectedAfterInsert) else {
                    textoraDiagLog(
                        "selectedRangePhysicalRewrite",
                        "insertMismatch expected=\(textoraDiagPreview(expectedAfterInsert)) "
                        + "updated=\(textoraDiagPreview(afterInsert))"
                    )
                    if afterInsert == currentValue,
                       prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID),
                       retryPhysicalInsertion(
                            change.replacement,
                            caretRange: caretRange,
                            target: target,
                            currentValue: currentValue,
                            expectedAfterInsert: expectedAfterInsert,
                            logScope: "selectedRangePhysicalRewrite"
                       ) {
                        currentValue = expectedAfterInsert
                        didMutateText = true
                        undoActionCount += 1
                        continue
                    }
                    if currentValue != afterInsert {
                        if undoSelectedRangeMutationAndCanFallback(
                            target: target,
                            originalValue: originalValue,
                            typingUndoCount: undoActionCount + 1,
                            deletionUndoCount: 0,
                            logScope: "selectedRangePhysicalRewrite",
                            reason: "dirty insert mismatch"
                        ) {
                            return nil
                        }
                        return false
                    }
                    if didMutateText {
                        undoPhysicalRewriteSteps(typingUndoCount: undoActionCount, deletionUndoCount: 0)
                        usleep(120_000)
                        textoraDiagLog("selectedRangePhysicalRewrite", "clean insert mismatch after delete; skip fallback")
                        return false
                    }
                    return nil
                }
                currentValue = afterInsert
                didMutateText = true
                undoActionCount += 1
            }
        }

        if matchesExpectedValuePreservingCase(currentValue, expectedValue) {
            textoraDiagLog("selectedRangePhysicalRewrite", "exit true (confirmed from step readback)")
            return true
        }

        guard let updatedValue = waitForPhysicalRewriteValue(
            target: target,
            expectedValue: expectedValue,
            originalValue: originalValue
        ) else {
            textoraDiagLog("selectedRangePhysicalRewrite", "exit true (no final readback)")
            return true
        }
        guard matchesExpectedValuePreservingCase(updatedValue, expectedValue) else {
            textoraDiagLog(
                "selectedRangePhysicalRewrite",
                "exit false expected=\(textoraDiagPreview(expectedValue)) "
                + "updated=\(textoraDiagPreview(updatedValue))"
            )
            if didMutateText {
                undoPhysicalRewriteSteps(typingUndoCount: undoActionCount, deletionUndoCount: 0)
                usleep(120_000)
            }
            return updatedValue == originalValue && !didMutateText ? nil : false
        }

        textoraDiagLog("selectedRangePhysicalRewrite", "exit true (confirmed)")
        return true
    }

    private func retryPhysicalInsertion(
        _ replacement: String,
        caretRange: NSRange,
        target: AXUIElement,
        currentValue: String,
        expectedAfterInsert: String,
        logScope: String
    ) -> Bool {
        textoraDiagLog(
            logScope,
            "retry physical insertion replacement=\(textoraDiagPreview(replacement))"
        )
        _ = setSelectedTextRange(caretRange, on: target, logScope: logScope)
        usleep(25_000)
        guard triggerPhysicalReplacementText(replacement) else {
            textoraDiagLog(logScope, "physical insertion retry failed to type")
            return false
        }
        guard let afterPhysical = waitForPhysicalRewriteValue(
            target: target,
            expectedValue: expectedAfterInsert,
            originalValue: currentValue
        ) else {
            textoraDiagLog(logScope, "physical insertion retry accepted without readback")
            return true
        }
        if matchesExpectedValuePreservingCase(afterPhysical, expectedAfterInsert) {
            textoraDiagLog(logScope, "physical insertion retry confirmed")
            return true
        }
        if afterPhysical != currentValue {
            undoPhysicalRewriteSteps(typingUndoCount: 1, deletionUndoCount: 0)
            usleep(90_000)
        }
        textoraDiagLog(
            logScope,
            "physical insertion retry mismatch expected=\(textoraDiagPreview(expectedAfterInsert)) "
            + "updated=\(textoraDiagPreview(afterPhysical))"
        )
        return false
    }

    private func undoSelectedRangeMutationAndCanFallback(
        target: AXUIElement,
        originalValue: String,
        typingUndoCount: Int,
        deletionUndoCount: Int,
        logScope: String,
        reason: String
    ) -> Bool {
        undoPhysicalRewriteSteps(
            typingUndoCount: typingUndoCount,
            deletionUndoCount: deletionUndoCount
        )
        usleep(140_000)
        guard let restoredValue = valueText(of: target) else {
            textoraDiagLog(logScope, "\(reason); undo issued but no readback")
            return false
        }
        guard matchesExpectedValuePreservingCase(restoredValue, originalValue) else {
            textoraDiagLog(
                logScope,
                "\(reason); undo did not restore original updated=\(textoraDiagPreview(restoredValue))"
            )
            return false
        }
        textoraDiagLog(logScope, "\(reason); reverted, allow anchored fallback")
        return true
    }

    private func setSelectedTextRange(_ range: NSRange, on target: AXUIElement, logScope: String) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            textoraDiagLog(logScope, "abort: AXValueCreate failed range=\(range.location):\(range.length)")
            return false
        }
        let status = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value)
        guard status == .success else {
            textoraDiagLog(logScope, "abort: set selected range status=\(status.rawValue) range=\(range.location):\(range.length)")
            return false
        }
        usleep(20_000)
        if let current = currentSelectedRange(of: target),
           current.location == range.location,
           current.length == range.length {
            return true
        }
        if range.length == 0,
           let current = currentSelectedRange(of: target),
           current.location == range.location {
            return true
        }
        let currentDescription = currentSelectedRange(of: target).map { "\($0.location):\($0.length)" } ?? "nil"
        textoraDiagLog(
            logScope,
            "selected range not confirmed requested=\(range.location):\(range.length) current=\(currentDescription)"
        )
        return true
    }

    private func triggerExactReplacementText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return triggerUnicodeTextInChunks(text)
    }

    private func waitForPhysicalRewriteValue(
        target: AXUIElement,
        expectedValue: String,
        originalValue: String
    ) -> String? {
        var lastValue: String?
        for attempt in 0..<12 {
            usleep(attempt == 0 ? 55_000 : 70_000)
            guard let value = valueText(of: target) else {
                return nil
            }
            lastValue = value
            if matchesExpectedValuePreservingCase(value, expectedValue) {
                return value
            }
            if value != originalValue {
                // Once the host exposes a changed value, give it one more
                // turn of the run loop to finish editor normalization.
                usleep(55_000)
                if let settled = valueText(of: target) {
                    return settled
                }
                return value
            }
        }
        return lastValue
    }

    private func matchesExpectedValuePreservingCase(_ actual: String, _ expected: String) -> Bool {
        actual == expected || whitespaceNormalizedPreservingCase(actual) == whitespaceNormalizedPreservingCase(expected)
    }

    private func whitespaceNormalizedPreservingCase(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func expectedFullValue(
        originalValue: String,
        rewritten: String,
        basedOn context: FocusedTextContext,
        changes: [(range: NSRange, replacement: String)]
    ) -> String {
        let fullNS = originalValue as NSString
        let contextRange = fullNS.range(of: context.text)
        if contextRange.location != NSNotFound {
            return fullNS.replacingCharacters(in: contextRange, with: rewritten)
        }

        var result = originalValue
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            result = (result as NSString).replacingCharacters(in: change.range, with: change.replacement)
        }
        return result
    }

    private func applyFullPhysicalRewriteIfSafe(
        _ rewritten: String,
        basedOn context: FocusedTextContext
    ) -> Bool {
        guard rewriteProtectedRanges(in: context.text).isEmpty,
              rewriteProtectedRanges(in: rewritten).isEmpty else {
            textoraDiagLog("fullPhysicalRewrite", "abort: protected token present")
            return false
        }
        let maxCharacters = 1500
        guard context.text.utf16.count <= maxCharacters,
              rewritten.utf16.count <= maxCharacters else {
            textoraDiagLog(
                "fullPhysicalRewrite",
                "abort: text too long originalLen=\(context.text.utf16.count) rewrittenLen=\(rewritten.utf16.count)"
            )
            return false
        }

        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("fullPhysicalRewrite", "abort: no value readback available")
            return false
        }
        guard normalized(originalValue) != normalized(rewritten) else {
            textoraDiagLog("fullPhysicalRewrite", "exit true (already matches)")
            return true
        }

        textoraDiagLog(
            "fullPhysicalRewrite",
            "enter bundle=\(context.targetBundleID) originalLen=\(originalValue.utf16.count) rewrittenLen=\(rewritten.utf16.count)"
        )

        focusTargetAppAndElement(context)
        usleep(180_000)
        triggerSelectAllShortcut()
        usleep(80_000)
        triggerSelectAllShortcut()
        usleep(110_000)
        triggerBackspaceKey()
        usleep(130_000)

        if !rewritten.isEmpty {
            guard triggerUnicodeTextInChunks(rewritten) else {
                textoraDiagLog("fullPhysicalRewrite", "abort: chunked unicode typing failed")
                return false
            }
        }
        usleep(UInt32(180_000 + min(500_000, rewritten.utf16.count * 1_500)))

        guard let updatedValue = valueText(of: target) else {
            textoraDiagLog("fullPhysicalRewrite", "exit true (no value readback after typing)")
            return true
        }
        if normalized(updatedValue) == normalized(rewritten) {
            textoraDiagLog("fullPhysicalRewrite", "exit true (confirmed)")
            return true
        }

        if originalValue != updatedValue {
            triggerUndoShortcut()
            usleep(120_000)
            textoraDiagLog("fullPhysicalRewrite", "undo triggered (not confirmed)")
        }
        textoraDiagLog(
            "fullPhysicalRewrite",
            "exit false expected=\(textoraDiagPreview(rewritten)) updated=\(textoraDiagPreview(updatedValue))"
        )
        return false
    }

    private func applyStartAnchoredDeletePhysicalRewrite(
        replacement: String,
        absoluteRange: NSRange,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("startAnchoredDeleteRewrite", "abort: no value readback available")
            return false
        }
        let originalLen = (originalValue as NSString).length
        let absoluteEnd = absoluteRange.location + absoluteRange.length
        guard absoluteRange.location >= 0,
              absoluteRange.length >= 0,
              absoluteEnd <= originalLen else {
            textoraDiagLog(
                "startAnchoredDeleteRewrite",
                "abort: absoluteRange=\(absoluteRange.location):\(absoluteRange.length) originalLen=\(originalLen)"
            )
            return false
        }

        let totalKeystrokes = absoluteRange.location + absoluteRange.length
        let maxKeystrokes = 900
        guard totalKeystrokes <= maxKeystrokes else {
            textoraDiagLog(
                "startAnchoredDeleteRewrite",
                "abort: totalKeystrokes=\(totalKeystrokes) > \(maxKeystrokes)"
            )
            return false
        }

        textoraDiagLog(
            "startAnchoredDeleteRewrite",
            "enter bundle=\(context.targetBundleID) absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
            + "originalLen=\(originalLen) replacement=\(textoraDiagPreview(replacement))"
        )

        focusTargetAppAndElement(context)
        usleep(110_000)
        triggerCmdLeftArrowKey()
        usleep(45_000)
        triggerCmdLeftArrowKey()
        usleep(75_000)

        for _ in 0..<absoluteRange.location {
            triggerRightArrowKey()
            usleep(4_000)
        }
        if absoluteRange.location > 0 {
            usleep(UInt32(45_000 + min(120_000, absoluteRange.location * 700)))
        }

        for _ in 0..<absoluteRange.length {
            triggerDeleteKey()
            usleep(6_000)
        }
        usleep(UInt32(90_000 + min(180_000, absoluteRange.length * 2_000)))

        let expectedAfterDelete = replacingText(in: originalValue, range: absoluteRange, with: "")
        guard let afterDelete = valueText(of: target) else {
            textoraDiagLog("startAnchoredDeleteRewrite", "abort: no readback after delete")
            return false
        }
        guard afterDelete == expectedAfterDelete || normalized(afterDelete) == normalized(expectedAfterDelete) else {
            if originalValue != afterDelete {
                undoPhysicalRewriteSteps(typingUndoCount: 0, deletionUndoCount: absoluteRange.length)
                usleep(90_000)
            }
            let restored = valueText(of: target)
            textoraDiagLog(
                "startAnchoredDeleteRewrite",
                "deleteMismatch expectedDelete=\(textoraDiagPreview(expectedAfterDelete)) "
                + "afterDelete=\(textoraDiagPreview(afterDelete)) "
                + "restored=\(restored.map { normalized($0) == normalized(originalValue) } ?? false)"
            )
            return false
        }

        let typedEvents: Int
        if replacement.isEmpty {
            typedEvents = 0
        } else {
            typedEvents = triggerUnicodeTextForReplacement(replacement)
            guard typedEvents > 0 else {
                undoPhysicalRewriteSteps(typingUndoCount: 0, deletionUndoCount: absoluteRange.length)
                textoraDiagLog("startAnchoredDeleteRewrite", "abort: unicode replacement typing failed")
                return false
            }
            usleep(UInt32(100_000 + min(180_000, replacement.utf16.count * 1_600)))
        }

        guard let updatedValue = valueText(of: target) else {
            textoraDiagLog("startAnchoredDeleteRewrite", "exit true (no value readback after typing)")
            return true
        }
        if trustedRangePasteConfirmed(
            originalValue: originalValue,
            updatedValue: updatedValue,
            absoluteRange: absoluteRange,
            replacement: replacement
        ) {
            textoraDiagLog("startAnchoredDeleteRewrite", "exit true (confirmed)")
            return true
        }

        if originalValue != updatedValue {
            undoPhysicalRewriteSteps(typingUndoCount: typedEvents, deletionUndoCount: absoluteRange.length)
            usleep(90_000)
            textoraDiagLog(
                "startAnchoredDeleteRewrite",
                "undo triggered (not confirmed) expected=\(textoraDiagPreview(replacingText(in: originalValue, range: absoluteRange, with: replacement))) "
                + "updated=\(textoraDiagPreview(updatedValue))"
            )
        }
        return false
    }

    private func applyCountedPhysicalRangeRewrite(
        replacement: String,
        absoluteRange: NSRange,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("countedPhysicalRangeRewrite", "abort: no value readback available")
            return false
        }
        let originalLen = (originalValue as NSString).length
        let absoluteEnd = absoluteRange.location + absoluteRange.length
        guard absoluteRange.location >= 0,
              absoluteRange.length >= 0,
              absoluteEnd <= originalLen else {
            textoraDiagLog(
                "countedPhysicalRangeRewrite",
                "abort: absoluteRange=\(absoluteRange.location):\(absoluteRange.length) originalLen=\(originalLen)"
            )
            return false
        }

        let distanceFromStart = absoluteRange.location
        let distanceFromEnd = originalLen - absoluteEnd
        let isElectronLikeHost = prefersClipboardSelectionPasteReplaceForBundle(context.targetBundleID)
        // Web/Electron composers frequently treat Cmd+Right as "line end" or
        // drop it while focus is settling. Starting from the left edge and
        // walking to the edit point is slower for tiny fields, but much more
        // deterministic and prevents the replacement from being typed at 0.
        let useStartAnchor = isElectronLikeHost ? true : (distanceFromStart <= distanceFromEnd)
        let travelDistance = useStartAnchor ? distanceFromStart : distanceFromEnd
        let totalKeystrokes = travelDistance + absoluteRange.length
        let maxKeystrokes = 900
        guard totalKeystrokes <= maxKeystrokes else {
            textoraDiagLog(
                "countedPhysicalRangeRewrite",
                "abort: total keystrokes=\(totalKeystrokes) > \(maxKeystrokes) "
                + "travel=\(travelDistance) len=\(absoluteRange.length)"
            )
            return false
        }

        textoraDiagLog(
            "countedPhysicalRangeRewrite",
            "enter bundle=\(context.targetBundleID) "
            + "absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
            + "originalLen=\(originalLen) anchor=\(useStartAnchor ? "start" : "end") "
            + "travel=\(travelDistance) replacement=\(textoraDiagPreview(replacement))"
        )

        focusTargetAppAndElement(context)
        // Slack may consume the first navigation event while its composer
        // is being reactivated. Anchor twice for Electron hosts; a second
        // Cmd+Left/Right at the same edge is harmless, but it makes
        // first-press rewrites land.
        usleep(isElectronLikeHost ? 90_000 : 180_000)
        if useStartAnchor {
            triggerCmdLeftArrowKey()
            usleep(isElectronLikeHost ? 35_000 : 80_000)
            if isElectronLikeHost {
                triggerCmdLeftArrowKey()
            }
            usleep(isElectronLikeHost ? 55_000 : 110_000)
            for _ in 0..<distanceFromStart {
                triggerRightArrowKey()
            }
            if distanceFromStart > 0 {
                usleep(UInt32((isElectronLikeHost ? 20_000 : 50_000) + distanceFromStart * (isElectronLikeHost ? 80 : 180)))
            }
            for _ in 0..<absoluteRange.length {
                triggerShiftRightArrowKey()
            }
        } else {
            triggerCmdRightArrowKey()
            usleep(isElectronLikeHost ? 35_000 : 80_000)
            if isElectronLikeHost {
                triggerCmdRightArrowKey()
            }
            usleep(isElectronLikeHost ? 55_000 : 110_000)
            for _ in 0..<distanceFromEnd {
                triggerLeftArrowKey()
            }
            if distanceFromEnd > 0 {
                usleep(UInt32((isElectronLikeHost ? 20_000 : 50_000) + distanceFromEnd * (isElectronLikeHost ? 80 : 180)))
            }
            for _ in 0..<absoluteRange.length {
                triggerShiftLeftArrowKey()
            }
        }
        usleep(UInt32((isElectronLikeHost ? 35_000 : 80_000) + absoluteRange.length * (isElectronLikeHost ? 120 : 250)))

        let undoCount: Int
        if replacement.isEmpty {
            triggerBackspaceKey()
            undoCount = 1
            usleep(isElectronLikeHost ? 55_000 : 130_000)
        } else {
            let typedEvents = triggerUnicodeTextForReplacement(replacement)
            guard typedEvents > 0 else {
                textoraDiagLog("countedPhysicalRangeRewrite", "abort: unicode replacement typing failed")
                return false
            }
            undoCount = typedEvents
            usleep(UInt32((isElectronLikeHost ? 70_000 : 120_000) + min(isElectronLikeHost ? 140_000 : 200_000, replacement.utf16.count * (isElectronLikeHost ? 1_200 : 2_400))))
        }

        guard let updatedValue = valueText(of: target) else {
            textoraDiagLog("countedPhysicalRangeRewrite", "exit true (no value readback after typing)")
            return true
        }
        if trustedRangePasteConfirmed(
            originalValue: originalValue,
            updatedValue: updatedValue,
            absoluteRange: absoluteRange,
            replacement: replacement
        ) {
            textoraDiagLog("countedPhysicalRangeRewrite", "exit true (confirmed)")
            return true
        }

        if originalValue != updatedValue {
            for _ in 0..<max(1, undoCount) {
                triggerUndoShortcut()
                usleep(65_000)
            }
            textoraDiagLog("countedPhysicalRangeRewrite", "undo triggered \(max(1, undoCount))x (not confirmed)")
        }
        textoraDiagLog(
            "countedPhysicalRangeRewrite",
            "exit false expected=\(textoraDiagPreview(replacingText(in: originalValue, range: absoluteRange, with: replacement))) "
            + "updated=\(textoraDiagPreview(updatedValue))"
        )
        return false
    }

    private func applyCaretAnchoredPhysicalRangeRewrite(
        replacement: String,
        localRange: NSRange,
        absoluteRange: NSRange,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("caretAnchoredPhysicalRewrite", "abort: no value readback available")
            return false
        }
        let originalLen = (originalValue as NSString).length
        let absoluteEnd = absoluteRange.location + absoluteRange.length
        guard absoluteRange.location >= 0,
              absoluteRange.length >= 0,
              absoluteEnd <= originalLen else {
            textoraDiagLog(
                "caretAnchoredPhysicalRewrite",
                "abort: absoluteRange=\(absoluteRange.location):\(absoluteRange.length) originalLen=\(originalLen)"
            )
            return false
        }

        let rightDistance = originalLen - absoluteEnd
        let totalKeystrokes = rightDistance + absoluteRange.length
        let maxKeystrokes = 900
        guard totalKeystrokes <= maxKeystrokes else {
            textoraDiagLog(
                "caretAnchoredPhysicalRewrite",
                "abort: total keystrokes=\(totalKeystrokes) > \(maxKeystrokes) "
                + "right=\(rightDistance) len=\(absoluteRange.length)"
            )
            return false
        }

        textoraDiagLog(
            "caretAnchoredPhysicalRewrite",
            "enter bundle=\(context.targetBundleID) localRange=\(localRange.location):\(localRange.length) "
            + "absoluteRange=\(absoluteRange.location):\(absoluteRange.length) originalLen=\(originalLen) "
            + "rightDistance=\(rightDistance) replacement=\(textoraDiagPreview(replacement))"
        )

        focusTargetAppAndElement(context)
        usleep(110_000)

        triggerCmdDownArrowKey()
        usleep(45_000)
        triggerCmdDownArrowKey()
        usleep(75_000)

        for _ in 0..<rightDistance {
            triggerLeftArrowKey()
        }
        if rightDistance > 0 {
            usleep(UInt32(35_000 + min(160_000, rightDistance * 500)))
        }

        for _ in 0..<absoluteRange.length {
            triggerShiftLeftArrowKey()
        }
        if absoluteRange.length > 0 {
            usleep(UInt32(55_000 + min(180_000, absoluteRange.length * 900)))
        }

        let undoCount: Int
        if replacement.isEmpty {
            guard absoluteRange.length > 0 else {
                textoraDiagLog("caretAnchoredPhysicalRewrite", "no-op empty replacement for empty range")
                return true
            }
            triggerBackspaceKey()
            undoCount = 1
            usleep(85_000)
        } else {
            let typedEvents = triggerUnicodeTextForReplacement(replacement)
            guard typedEvents > 0 else {
                textoraDiagLog("caretAnchoredPhysicalRewrite", "abort: unicode replacement typing failed")
                return false
            }
            undoCount = typedEvents
            usleep(UInt32(120_000 + min(260_000, replacement.utf16.count * 1_600)))
        }

        guard let updatedValue = valueText(of: target) else {
            textoraDiagLog("caretAnchoredPhysicalRewrite", "exit true (no value readback after typing)")
            return true
        }
        if trustedRangePasteConfirmed(
            originalValue: originalValue,
            updatedValue: updatedValue,
            absoluteRange: absoluteRange,
            replacement: replacement
        ) {
            textoraDiagLog("caretAnchoredPhysicalRewrite", "exit true (confirmed)")
            return true
        }

        if originalValue != updatedValue {
            for _ in 0..<max(1, undoCount) {
                triggerUndoShortcut()
                usleep(65_000)
            }
            textoraDiagLog("caretAnchoredPhysicalRewrite", "undo triggered \(max(1, undoCount))x (not confirmed)")
        }
        textoraDiagLog(
            "caretAnchoredPhysicalRewrite",
            "exit false expected=\(textoraDiagPreview(replacingText(in: originalValue, range: absoluteRange, with: replacement))) "
            + "updated=\(textoraDiagPreview(updatedValue))"
        )
        return false
    }

    private func applyCaretBackspacePhysicalRewrite(
        replacement: String,
        localRange: NSRange,
        absoluteRange: NSRange,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let target = context.targetElement
        guard let originalValue = valueText(of: target) else {
            textoraDiagLog("caretBackspaceRewrite", "abort: no value readback available")
            return false
        }
        let originalLen = (originalValue as NSString).length
        let absoluteEnd = absoluteRange.location + absoluteRange.length
        guard absoluteRange.location >= 0,
              absoluteRange.length >= 0,
              absoluteEnd <= originalLen else {
            textoraDiagLog(
                "caretBackspaceRewrite",
                "abort: absoluteRange=\(absoluteRange.location):\(absoluteRange.length) originalLen=\(originalLen)"
            )
            return false
        }

        let maxTravel = 240
        guard absoluteRange.length <= 240 else {
            textoraDiagLog(
                "caretBackspaceRewrite",
                "abort: len=\(absoluteRange.length) exceeds budget"
            )
            return false
        }

        focusTargetAppAndElement(context)
        usleep(100_000)

        var caretCandidates: [(label: String, location: Int)] = []
        func appendCaretCandidate(_ label: String, _ location: Int?) {
            guard let location else { return }
            let safeLocation = max(0, min(location, originalLen))
            guard !caretCandidates.contains(where: { $0.location == safeLocation }) else { return }
            caretCandidates.append((label: label, location: safeLocation))
        }
        func mappedVisibleCaret(_ range: CFRange?) -> Int? {
            guard let range else { return nil }
            let localCaret = range.location + range.length
            let contextLen = (context.text as NSString).length
            guard localCaret >= 0, localCaret <= contextLen else { return nil }
            let prefixOffset = absoluteRange.location - localRange.location
            guard prefixOffset >= 0 else { return nil }
            let mapped = prefixOffset + localCaret
            // Slack reports the visible caret at the logical end of the text
            // even when the physical caret is just before a preserved trailing
            // punctuation character. In that case treating it as valueEnd makes
            // us step left once and delete one char too early.
            if isSlackBundleID(context.targetBundleID),
               localCaret == contextLen,
               originalLen > absoluteEnd,
               originalLen - absoluteEnd <= 4 {
                return absoluteEnd
            }
            return mapped
        }

        appendCaretCandidate(
            "liveAXVisible",
            mappedVisibleCaret(currentSelectedRange(of: target))
        )
        appendCaretCandidate(
            "contextVisible",
            mappedVisibleCaret(context.selectedRange)
        )
        // Slack/Electron can report an AX caret that is one logical text
        // scope behind the physical insertion point when the focused value
        // has a hidden prefix and the diff preserves trailing punctuation.
        // If the range ends just before the value end, try the physical end
        // first so we can step left once before deleting, without relying on
        // an Undo cycle to reposition the caret.
        if originalLen > absoluteEnd, originalLen - absoluteEnd <= 4 {
            appendCaretCandidate("valueEnd", originalLen)
        }
        appendCaretCandidate(
            "liveAX",
            currentSelectedRange(of: target).map { $0.location + $0.length }
        )
        appendCaretCandidate(
            "context",
            context.selectedRange.map { $0.location + $0.length }
        )
        appendCaretCandidate("valueEnd", originalLen)

        let expectedAfterDelete = replacingText(in: originalValue, range: absoluteRange, with: "")

        for candidate in caretCandidates {
            let currentCaret = candidate.location
            let travel = currentCaret - absoluteEnd
            guard abs(travel) <= maxTravel else {
                textoraDiagLog(
                    "caretBackspaceRewrite",
                    "skip candidate=\(candidate.label) currentCaret=\(currentCaret) targetCaret=\(absoluteEnd) "
                    + "travel=\(travel) exceeds budget"
                )
                continue
            }

            textoraDiagLog(
                "caretBackspaceRewrite",
                "enter bundle=\(context.targetBundleID) absoluteRange=\(absoluteRange.location):\(absoluteRange.length) "
                + "candidate=\(candidate.label) currentCaret=\(currentCaret) targetCaret=\(absoluteEnd) travel=\(travel) "
                + "replacement=\(textoraDiagPreview(replacement))"
            )

            if travel > 0 {
                for _ in 0..<travel {
                    triggerLeftArrowKey()
                    usleep(4_000)
                }
            } else if travel < 0 {
                for _ in 0..<abs(travel) {
                    triggerRightArrowKey()
                    usleep(4_000)
                }
            }
            if travel != 0 {
                usleep(UInt32(50_000 + min(120_000, abs(travel) * 1_000)))
            }

            for _ in 0..<absoluteRange.length {
                triggerBackspaceKey()
                usleep(6_000)
            }
            usleep(UInt32(90_000 + min(180_000, absoluteRange.length * 2_000)))

            guard let afterDelete = valueText(of: target) else {
                textoraDiagLog("caretBackspaceRewrite", "abort: no readback after delete")
                return false
            }
            guard afterDelete == expectedAfterDelete || normalized(afterDelete) == normalized(expectedAfterDelete) else {
                undoPhysicalRewriteSteps(typingUndoCount: 0, deletionUndoCount: absoluteRange.length)
                usleep(90_000)
                let restored = valueText(of: target)
                textoraDiagLog(
                    "caretBackspaceRewrite",
                    "deleteMismatch candidate=\(candidate.label) expectedDelete=\(textoraDiagPreview(expectedAfterDelete)) "
                    + "afterDelete=\(textoraDiagPreview(afterDelete)) "
                    + "restored=\(restored.map { normalized($0) == normalized(originalValue) } ?? false)"
                )
                guard let restored,
                      restored == originalValue || normalized(restored) == normalized(originalValue) else {
                    textoraDiagLog("caretBackspaceRewrite", "exit false (undo did not restore original)")
                    return false
                }
                continue
            }

            let typedEvents: Int
            if replacement.isEmpty {
                typedEvents = 0
            } else {
                typedEvents = triggerUnicodeTextForReplacement(replacement)
                guard typedEvents > 0 else {
                    undoPhysicalRewriteSteps(typingUndoCount: 0, deletionUndoCount: absoluteRange.length)
                    textoraDiagLog("caretBackspaceRewrite", "abort: unicode replacement typing failed")
                    return false
                }
                usleep(UInt32(100_000 + min(180_000, replacement.utf16.count * 1_600)))
            }

            guard let updatedValue = valueText(of: target) else {
                textoraDiagLog("caretBackspaceRewrite", "exit true (no value readback after typing)")
                return true
            }
            if trustedRangePasteConfirmed(
                originalValue: originalValue,
                updatedValue: updatedValue,
                absoluteRange: absoluteRange,
                replacement: replacement
            ) {
                textoraDiagLog("caretBackspaceRewrite", "exit true (confirmed candidate=\(candidate.label))")
                return true
            }

            undoPhysicalRewriteSteps(typingUndoCount: typedEvents, deletionUndoCount: absoluteRange.length)
            usleep(90_000)
            let restored = valueText(of: target)
            textoraDiagLog(
                "caretBackspaceRewrite",
                "candidate=\(candidate.label) not confirmed expected=\(textoraDiagPreview(replacingText(in: originalValue, range: absoluteRange, with: replacement))) "
                + "updated=\(textoraDiagPreview(updatedValue)) "
                + "restored=\(restored.map { normalized($0) == normalized(originalValue) } ?? false)"
            )
            guard let restored,
                  restored == originalValue || normalized(restored) == normalized(originalValue) else {
                textoraDiagLog("caretBackspaceRewrite", "exit false (undo did not restore original)")
                return false
            }
        }

        textoraDiagLog("caretBackspaceRewrite", "exit false (all caret candidates failed)")
        return false
    }

    private func currentSelectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = selectedRangeValue(of: element) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private func undoPhysicalRewriteSteps(typingUndoCount: Int, deletionUndoCount: Int) {
        let count = max(1, typingUndoCount + deletionUndoCount)
        for _ in 0..<count {
            triggerUndoShortcut()
            usleep(45_000)
        }
    }

    private func trustedRangePasteConfirmed(
        originalValue: String?,
        updatedValue: String?,
        absoluteRange: NSRange,
        replacement: String
    ) -> Bool {
        guard let originalValue, let updatedValue else {
            // Some secure fields do not expose readback. If the host accepted
            // the event, preserve the previous best-effort behaviour.
            return true
        }
        let expectedValue = replacingText(in: originalValue, range: absoluteRange, with: replacement)
        if updatedValue == expectedValue { return true }
        if normalized(updatedValue) == normalized(expectedValue),
           originalValue != updatedValue {
            return true
        }
        guard originalValue != updatedValue else { return false }
        return pasteLandedAtAnchor(
            originalValue: originalValue,
            updatedValue: updatedValue,
            absoluteRange: absoluteRange,
            replacement: replacement
        )
    }

    private func applyTrustedPhysicalRangeRewrite(
        replacement: String,
        requestedRange: NSRange,
        confirmationRange: NSRange,
        originalValue: String?,
        basedOn context: FocusedTextContext
    ) -> Bool {
        let target = context.targetElement
        textoraDiagLog(
            "trustedPhysicalRangeRewrite",
            "enter bundle=\(context.targetBundleID) requestedRange=\(requestedRange.location):\(requestedRange.length) "
            + "confirmationRange=\(confirmationRange.location):\(confirmationRange.length) "
            + "replacement=\(textoraDiagPreview(replacement))"
        )
        focusTargetAppAndElement(context)

        var cfRange = CFRange(location: requestedRange.location, length: requestedRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            textoraDiagLog("trustedPhysicalRangeRewrite", "abort: AXValueCreate failed")
            return false
        }
        let selectStatus = AXUIElementSetAttributeValue(
            target,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard selectStatus == .success else {
            textoraDiagLog("trustedPhysicalRangeRewrite", "abort: selectStatus=\(selectStatus.rawValue)")
            return false
        }
        usleep(90_000)

        triggerBackspaceKey()
        usleep(120_000)

        if let originalValue, let afterDelete = valueText(of: target) {
            let expectedAfterDelete = replacingText(in: originalValue, range: confirmationRange, with: "")
            guard afterDelete == expectedAfterDelete
                || normalized(afterDelete) == normalized(expectedAfterDelete) else {
                triggerUndoShortcut()
                usleep(90_000)
                textoraDiagLog(
                    "trustedPhysicalRangeRewrite",
                    "undo triggered (delete not confirmed) expectedDelete=\(textoraDiagPreview(expectedAfterDelete)) "
                    + "afterDelete=\(textoraDiagPreview(afterDelete))"
                )
                textoraDiagLog("trustedPhysicalRangeRewrite", "exit false")
                return false
            }

            if !replacement.isEmpty {
                let afterDeleteLen = (afterDelete as NSString).length
                var caretRange = CFRange(
                    location: max(0, min(confirmationRange.location, afterDeleteLen)),
                    length: 0
                )
                if let caretValue = AXValueCreate(.cfRange, &caretRange) {
                    _ = AXUIElementSetAttributeValue(
                        target,
                        kAXSelectedTextRangeAttribute as CFString,
                        caretValue
                    )
                    usleep(55_000)
                }
            }
        }

        if !replacement.isEmpty {
            if triggerUnicodeText(replacement) {
                usleep(UInt32(120_000 + min(160_000, replacement.utf16.count * 2_000)))
            } else {
                textoraDiagLog("trustedPhysicalRangeRewrite", "abort: unicode typing failed")
                return false
            }
        }

        let updatedValue = valueText(of: target)
        if trustedRangePasteConfirmed(
            originalValue: originalValue,
            updatedValue: updatedValue,
            absoluteRange: confirmationRange,
            replacement: replacement
        ) {
            textoraDiagLog("trustedPhysicalRangeRewrite", "exit true (confirmed)")
            return true
        }

        if let originalValue, let updatedValue, originalValue != updatedValue {
            triggerUndoShortcut()
            usleep(90_000)
            textoraDiagLog(
                "trustedPhysicalRangeRewrite",
                "undo triggered (not confirmed) expected=\(textoraDiagPreview(replacingText(in: originalValue, range: confirmationRange, with: replacement))) "
                + "updated=\(textoraDiagPreview(updatedValue))"
            )
        }
        textoraDiagLog("trustedPhysicalRangeRewrite", "exit false")
        return false
    }

    /// Verify that a paste actually replaced `absoluteRange` with
    /// `replacement` in the field's value, tolerating small host-specific
    /// drift (zero-width joiners, auto-linked whitespace). This is the
    /// ground-truth signal for Electron/webview hosts where BOTH the AX
    /// selection read-back and the Cmd+C clipboard read-back lie — in
    /// particular Slack is known to accept `AXUIElementSetAttributeValue
    /// (kAXSelectedTextRangeAttribute)` AND report it back verbatim, but
    /// still apply the selection with a small byte offset inside the DOM,
    /// so the paste lands near — but not at — the expected anchor.
    ///
    /// We validate four invariants. All must hold:
    ///   1. Length budget — `updatedLen ≈ originalLen − absoluteRange.length
    ///      + replacement.length`. If the field grew by roughly
    ///      `replacement.length` the paste merely inserted (caret moved but
    ///      selection wasn't honoured).
    ///   2. Prefix stability — the text immediately before
    ///      `absoluteRange.location` must be unchanged. Any deviation means
    ///      the paste landed earlier than expected.
    ///   3. Suffix stability — the text immediately *after* the written
    ///      replacement must match the tail of the original value. This is
    ///      the probe that catches the "shifted by +N chars" Slack case —
    ///      length and prefix can still look fine while the suffix is
    ///      clearly wrong.
    ///   4. Anchor locality — `replacement` (or its trimmed form) must
    ///      materialize in a narrow window centred on the expected anchor.
    private func pasteLandedAtAnchor(
        originalValue: String,
        updatedValue: String,
        absoluteRange: NSRange,
        replacement: String
    ) -> Bool {
        let originalNS = originalValue as NSString
        let updatedNS = updatedValue as NSString
        let replacementNS = replacement as NSString
        let originalLen = originalNS.length
        let updatedLen = updatedNS.length
        let replacementLen = replacementNS.length

        // (1) Length budget. Host-specific drift (ZW joiners, auto-link
        // markers, whitespace normalization) tends to add/remove a handful
        // of characters. Keep the tolerance small but proportional.
        let expectedLen = max(0, originalLen - absoluteRange.length + replacementLen)
        let lenTolerance = 4 + max(0, absoluteRange.length / 16)
        let lenDrift = updatedLen - expectedLen
        if abs(lenDrift) > lenTolerance {
            return false
        }

        // (2) Prefix stability. Compare the window just before
        // `absoluteRange.location` in original vs updated. These must agree
        // byte-for-byte after normalization, otherwise the paste landed at
        // a different offset than we asked for.
        let prefixProbeLen = min(24, absoluteRange.location)
        if prefixProbeLen > 0 {
            guard absoluteRange.location <= updatedLen else { return false }
            let origPrefix = originalNS.substring(
                with: NSRange(location: absoluteRange.location - prefixProbeLen, length: prefixProbeLen)
            )
            let updPrefix = updatedNS.substring(
                with: NSRange(location: absoluteRange.location - prefixProbeLen, length: prefixProbeLen)
            )
            if normalized(origPrefix) != normalized(updPrefix) {
                return false
            }
        }

        // (3) Suffix stability. The text immediately after the written
        // replacement must match the tail of the original value. This is
        // the probe that detects Slack's "shift by a few chars" bug —
        // length/prefix may match while the suffix is clearly wrong.
        let origTailStart = absoluteRange.location + absoluteRange.length
        let updTailStart = absoluteRange.location + replacementLen
        if origTailStart <= originalLen, updTailStart <= updatedLen {
            let maxProbe = 24
            let tailProbeLen = min(maxProbe, min(originalLen - origTailStart, updatedLen - updTailStart))
            if tailProbeLen > 0 {
                let origTail = originalNS.substring(
                    with: NSRange(location: origTailStart, length: tailProbeLen)
                )
                let updTail = updatedNS.substring(
                    with: NSRange(location: updTailStart, length: tailProbeLen)
                )
                if normalized(origTail) != normalized(updTail) {
                    return false
                }
            }
        }

        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty else {
            // Pure deletion — invariants 1-3 already cover it.
            return true
        }
        guard updatedLen > 0 else { return false }

        // (4) Anchor locality — `replacement` must materialize in a narrow
        // window centred on the expected anchor. Wide enough to absorb
        // normalization drift, strict enough to reject a paste that landed
        // elsewhere entirely.
        let expectedAnchor = max(0, min(absoluteRange.location, updatedLen))
        let windowPadding = max(12, replacementLen / 4 + 8)
        let windowStart = max(0, expectedAnchor - windowPadding)
        let windowEnd = min(updatedLen, expectedAnchor + replacementLen + windowPadding)
        guard windowEnd > windowStart else { return false }
        let window = updatedNS.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
        let hay = window as NSString
        if hay.range(of: replacement).location != NSNotFound { return true }
        // Fall back to a trimmed match for hosts that collapse whitespace.
        if hay.range(of: trimmedReplacement).location != NSNotFound { return true }
        return false
    }

    private func absoluteRangeForAtomicPaste(_ localRange: NSRange, in context: FocusedTextContext) -> NSRange? {
        let contextNS = context.text as NSString
        let safeLocation = max(0, min(localRange.location, contextNS.length))
        let safeLength = max(0, min(localRange.length, contextNS.length - safeLocation))
        let safeLocal = NSRange(location: safeLocation, length: safeLength)

        if let full = valueText(of: context.targetElement) {
            let fullNS = full as NSString
            if let contextRange = bestRangeForCurrentEditScope(
                needle: context.text,
                in: full,
                selectedRange: context.selectedRange
            ) {
                let location = max(0, min(contextRange.location + safeLocal.location, fullNS.length))
                let length = max(0, min(safeLocal.length, fullNS.length - location))
                return NSRange(location: location, length: length)
            }

            if safeLocal.length > 0 {
                let needle = contextNS.substring(with: safeLocal)
                if let needleRange = bestRangeForCurrentEditScope(
                    needle: needle,
                    in: full,
                    selectedRange: context.selectedRange
                ) {
                    return needleRange
                }
            }
        }

        return absoluteAXRange(for: safeLocal, in: context)
    }

    private func bestRangeForCurrentEditScope(
        needle: String,
        in full: String,
        selectedRange: CFRange?
    ) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let fullNS = full as NSString
        let needleNS = needle as NSString
        guard needleNS.length > 0, needleNS.length <= fullNS.length else { return nil }

        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: fullNS.length)
        while searchRange.length > 0 {
            let found = fullNS.range(of: needle, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let nextLocation = found.location + max(1, found.length)
            guard nextLocation <= fullNS.length else { break }
            searchRange = NSRange(location: nextLocation, length: fullNS.length - nextLocation)
        }
        guard !matches.isEmpty else { return nil }
        guard let selectedRange else { return matches.first }

        let caret = selectedRange.location + selectedRange.length
        let tolerance = max(2, min(32, needleNS.length / 2 + 2))
        if let containing = matches.last(where: {
            selectedRange.location >= $0.location && selectedRange.location <= $0.location + $0.length + tolerance
        }) {
            return containing
        }
        if let beforeCaret = matches.last(where: { $0.location + $0.length <= caret + tolerance }) {
            return beforeCaret
        }
        return matches.min { lhs, rhs in
            abs(lhs.location - caret) < abs(rhs.location - caret)
        }
    }

    private func verifyActiveSelection(expectedText: String, pasteboard: NSPasteboard) -> Bool {
        guard !expectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let beforeCopyChangeCount = pasteboard.changeCount
        triggerCopyShortcut()
        usleep(130_000)
        guard pasteboard.changeCount != beforeCopyChangeCount,
              let copied = extractPlainTextFromPasteboard(pasteboard) else {
            return false
        }
        return normalized(copied) == normalized(expectedText)
    }

    private func replacingText(in text: String, range: NSRange, with replacement: String) -> String {
        let ns = text as NSString
        let location = max(0, min(range.location, ns.length))
        let length = max(0, min(range.length, ns.length - location))
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
        return mutable as String
    }

    private func localizedPatch(
        original: String,
        corrected: String,
        preferredLocalRange: NSRange
    ) -> (range: NSRange, replacement: String)? {
        guard let envelope = changedEnvelope(original: original, corrected: corrected) else {
            textoraDiagLog("localizedPatch", "changedEnvelope returned nil (texts equal?)")
            return nil
        }
        let originalNS = original as NSString
        guard originalNS.length > 0 else {
            textoraDiagLog("localizedPatch", "empty original")
            return nil
        }
        let safePreferred = NSRange(
            location: max(0, min(preferredLocalRange.location, max(0, originalNS.length - 1))),
            length: max(1, min(preferredLocalRange.length, originalNS.length - max(0, min(preferredLocalRange.location, originalNS.length))))
        )
        textoraDiagLog(
            "localizedPatch",
            "envelope.originalRange=\(envelope.originalRange.location):\(envelope.originalRange.length) "
            + "envelope.replacement=\(textoraDiagPreview(envelope.replacement)) "
            + "preferredLocal=\(preferredLocalRange.location):\(preferredLocalRange.length) "
            + "safePreferred=\(safePreferred.location):\(safePreferred.length)"
        )
        let intersectsPreferred = NSIntersectionRange(envelope.originalRange, safePreferred).length > 0
        let insertionInsidePreferred = envelope.originalRange.length == 0
            && envelope.originalRange.location >= safePreferred.location
            && envelope.originalRange.location <= safePreferred.location + safePreferred.length
        guard intersectsPreferred || insertionInsidePreferred else {
            textoraDiagLog("localizedPatch", "reject: envelope does not intersect preferred local range")
            return nil
        }

        let maxAllowedLength = max(160, safePreferred.length * 6)
        guard envelope.originalRange.length <= maxAllowedLength else {
            textoraDiagLog(
                "localizedPatch",
                "reject: envelope.originalRange.length=\(envelope.originalRange.length) > max=\(maxAllowedLength)"
            )
            return nil
        }
        return (range: envelope.originalRange, replacement: envelope.replacement)
    }

    private func changedEnvelope(original: String, corrected: String) -> (originalRange: NSRange, replacement: String)? {
        let originalNS = original as NSString
        let correctedNS = corrected as NSString
        guard originalNS.length > 0 || correctedNS.length > 0 else { return nil }

        // Common prefix length (character-level).
        let limit = min(originalNS.length, correctedNS.length)
        var prefix = 0
        while prefix < limit, originalNS.character(at: prefix) == correctedNS.character(at: prefix) {
            prefix += 1
        }
        if prefix == originalNS.length, prefix == correctedNS.length {
            return nil
        }

        // Common suffix length, not allowed to overlap with the prefix in
        // either string.
        var suffix = 0
        while suffix < originalNS.length - prefix,
              suffix < correctedNS.length - prefix,
              originalNS.character(at: originalNS.length - 1 - suffix) == correctedNS.character(at: correctedNS.length - 1 - suffix) {
            suffix += 1
        }

        // Start the change window exactly at the first differing character
        // in BOTH strings. The previous implementation shifted `originalStart`
        // by −1 when `prefix == originalNS.length` (pure-suffix insertions
        // like adding a period) without applying the same shift to
        // `correctedStart`, which produced a persistent off-by-one between
        // the two windows. For e.g. "…question" → "…question." this made
        // the replacement `"uestion."` instead of `"question."`.
        var originalStart = prefix
        var originalEnd = originalNS.length - suffix
        var correctedStart = prefix
        var correctedEnd = correctedNS.length - suffix

        // Expand the window outward until we hit a boundary (whitespace /
        // punctuation) on BOTH sides simultaneously. Comparing characters
        // from both strings keeps the original and replacement windows in
        // lock-step so inserted/removed characters never slip out of the
        // window.
        while originalStart > 0, correctedStart > 0 {
            let chOriginal = originalNS.character(at: originalStart - 1)
            let chCorrected = correctedNS.character(at: correctedStart - 1)
            guard chOriginal == chCorrected else { break }
            if isReplacementBoundary(chOriginal) { break }
            originalStart -= 1
            correctedStart -= 1
        }
        while originalEnd < originalNS.length, correctedEnd < correctedNS.length {
            let chOriginal = originalNS.character(at: originalEnd)
            let chCorrected = correctedNS.character(at: correctedEnd)
            guard chOriginal == chCorrected else { break }
            if isReplacementBoundary(chOriginal) { break }
            originalEnd += 1
            correctedEnd += 1
        }

        let originalRange = NSRange(location: originalStart, length: max(0, originalEnd - originalStart))
        let replacementRange = NSRange(location: correctedStart, length: max(0, correctedEnd - correctedStart))
        guard originalRange.length > 0 || replacementRange.length > 0 else { return nil }
        return (originalRange, correctedNS.substring(with: replacementRange))
    }

    private func isReplacementBoundary(_ utf16: unichar) -> Bool {
        guard let scalar = UnicodeScalar(utf16) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
    }

    private func isSlackBundleID(_ bundleID: String) -> Bool {
        bundleID.lowercased().contains("slack")
    }

    private func shouldAvoidWholeTextReplacement(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        let originalLength = (context.text as NSString).length
        guard originalLength >= 280 else { return false }
        let diffs = WordDiff.changes(original: context.text, corrected: rewritten)
        guard !diffs.isEmpty else { return false }
        let changedLength = diffs.reduce(0) { $0 + $1.range.length }
        return Double(changedLength) / Double(max(1, originalLength)) <= 0.75
    }

    private func restorePasteboardIfNeeded(
        _ pasteboard: NSPasteboard,
        snapshot: [PasteboardSnapshotItem],
        baselineChangeCount: Int
    ) {
        if pasteboard.changeCount != baselineChangeCount {
            restorePasteboard(pasteboard, snapshot: snapshot)
        }
    }

    private func applySelectedTextDirect(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        let target = context.targetElement
        let status = AXUIElementSetAttributeValue(
            target,
            kAXSelectedTextAttribute as CFString,
            rewritten as CFTypeRef
        )
        guard status == .success else { return false }
        usleep(40_000)

        // Best-effort verification for editors that expose value.
        if let current = valueText(of: target) {
            let currentNorm = normalized(current)
            let expectedNorm = normalized(rewritten)
            if !expectedNorm.isEmpty, currentNorm.contains(expectedNorm) {
                return true
            }
        }
        // If value is not exposed, AX already reported success for selected replacement.
        return true
    }

    private func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }


    private struct PasteboardSnapshotItem {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private func richTextFromPasteboard(
        _ pasteboard: NSPasteboard,
        matching expectedText: String
    ) -> NSAttributedString? {
        let candidates: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [
            (.rtf, .rtf),
            (.html, .html)
        ]
        for (pasteboardType, documentType) in candidates {
            guard let data = pasteboard.data(forType: pasteboardType) else { continue }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: documentType
            ]
            if documentType == .html {
                options[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            guard let attributed = try? NSAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            ), normalized(attributed.string) == normalized(expectedText) else {
                continue
            }
            return attributed
        }
        return nil
    }

    private func captureRichTextFromActiveSelection(
        expectedText: String,
        pasteboard: NSPasteboard
    ) -> NSAttributedString? {
        guard !expectedText.isEmpty else { return nil }
        let beforeCopyChangeCount = pasteboard.changeCount
        triggerCopyShortcut()
        for _ in 0..<8 {
            usleep(30_000)
            if pasteboard.changeCount != beforeCopyChangeCount { break }
        }
        guard pasteboard.changeCount != beforeCopyChangeCount,
              let copied = extractPlainTextFromPasteboard(pasteboard),
              normalized(copied) == normalized(expectedText) else {
            return nil
        }
        return richTextFromPasteboard(pasteboard, matching: expectedText)
    }

    @discardableResult
    private func writeReplacementToPasteboard(
        _ replacement: String,
        preserving source: NSAttributedString?,
        pasteboard: NSPasteboard
    ) -> Bool {
        let item = NSPasteboardItem()
        item.setString(replacement, forType: .string)

        if let source, source.length > 0 {
            let styled = Self.attributedReplacementPreservingFormatting(
                source: source,
                rewritten: replacement
            )
            let fullRange = NSRange(location: 0, length: styled.length)
            if let rtf = try? styled.data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                item.setData(rtf, forType: .rtf)
            }
            if let html = try? styled.data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            ) {
                item.setData(html, forType: .html)
            }
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardSnapshotItem] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        return items.map { item in
            let reps: [(NSPasteboard.PasteboardType, Data)] =
                (item.types).compactMap { t in
                    guard let d = item.data(forType: t) else { return nil }
                    return (t, d)
                }
            return PasteboardSnapshotItem(representations: reps)
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, snapshot: [PasteboardSnapshotItem]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        var newItems: [NSPasteboardItem] = []
        newItems.reserveCapacity(snapshot.count)
        for snap in snapshot {
            let item = NSPasteboardItem()
            for (t, d) in snap.representations {
                item.setData(d, forType: t)
            }
            newItems.append(item)
        }
        _ = pasteboard.writeObjects(newItems)
    }

    private func focusTargetAppAndElement(_ context: FocusedTextContext) {
        if context.targetAppPID != 0, context.targetAppPID != getpid() {
            NSRunningApplication(processIdentifier: context.targetAppPID)?
                .activate(options: [.activateAllWindows])
            let appElement = AXUIElementCreateApplication(context.targetAppPID)
            AXUIElementSetAttributeValue(
                appElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue as CFTypeRef
            )
            usleep(120_000)
        }
        AXUIElementSetAttributeValue(
            context.targetElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue as CFTypeRef
        )
        usleep(60_000)
    }

    // MARK: - Diff-based replacement (preserves formatting on unchanged text)

    private func applyDiffBased(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        let target = context.targetElement
        let originalText = context.text

        let diffs = WordDiff.changes(original: originalText, corrected: rewritten)
        if diffs.isEmpty { return true }

        // Heavy rewrite (single change covering >80% of text) — diff won't preserve much formatting.
        if diffs.count == 1 {
            let origLen = (originalText as NSString).length
            if origLen > 0, Double(diffs[0].range.length) / Double(origLen) > 0.8 {
                return false
            }
        }

        let originalValue = valueText(of: target)

        for diff in diffs.reversed() {
            guard let absoluteRange = absoluteRangeForAtomicPaste(diff.range, in: context) else {
                return false
            }
            var cfRange = CFRange(location: absoluteRange.location, length: absoluteRange.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }

            let selectStatus = AXUIElementSetAttributeValue(
                target,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
            guard selectStatus == .success else { return false }

            let replaceStatus = AXUIElementSetAttributeValue(
                target,
                kAXSelectedTextAttribute as CFString,
                diff.replacement as CFTypeRef
            )
            guard replaceStatus == .success else { return false }

            if diffs.count > 1 {
                usleep(30_000)
            }
        }

        // Some apps (Electron, web views) report AX success but silently ignore
        // the kAXSelectedTextAttribute write — verify the text actually changed.
        usleep(30_000)
        if let originalValue, let updatedValue = valueText(of: target) {
            return normalized(originalValue) != normalized(updatedValue)
        }
        return true
    }

    // MARK: - Full replacement fallback (original behaviour)

    private func applyFullReplacement(_ rewritten: String, basedOn context: FocusedTextContext) -> Bool {
        if context.anchor.source == .visiblePageText, !context.usesSelection {
            return false
        }
        let target = context.targetElement
        if context.usesSelection, let range = context.selectedRange {
            if let currentValue = valueText(of: target) {
                let ns = currentValue as NSString
                let safeLocation = max(0, min(range.location, ns.length))
                let safeLength = max(0, min(range.length, ns.length - safeLocation))
                let safeRange = NSRange(location: safeLocation, length: safeLength)
                let replaced = ns.replacingCharacters(in: safeRange, with: rewritten)
                let setResult = AXUIElementSetAttributeValue(
                    target,
                    kAXValueAttribute as CFString,
                    replaced as CFTypeRef
                )
                if setResult == .success {
                    return true
                }
            }
        }

        // Last resort: replace the entire AX value (can change formatting in some apps).
        let setAllResult = AXUIElementSetAttributeValue(
            target,
            kAXValueAttribute as CFString,
            rewritten as CFTypeRef
        )
        if setAllResult == .success { return true }
        return false
    }

    func highlightContext(_ context: FocusedTextContext) {
        let target = context.targetElement
        if let range = context.selectedRange {
            var r = range
            let value = AXValueCreate(.cfRange, &r)
            if let value {
                _ = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return
        }
        if let full = valueText(of: target) {
            var r = CFRange(location: 0, length: (full as NSString).length)
            let value = AXValueCreate(.cfRange, &r)
            if let value {
                _ = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
    }

    private func readViaAccessibility() -> String? {
        guard let focused = focusedElement() else { return nil }
        return selectedText(of: focused)
    }

    private func replaceViaAccessibility(_ text: String) -> Bool {
        guard let focused = focusedElement() else { return false }
        let result = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return result == .success
    }

    private func selectedText(of element: AXUIElement) -> String? {
        var selectedText: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        guard selectedStatus == .success else { return nil }
        return selectedText as? String
    }

    private func selectedRangeValue(of element: AXUIElement) -> AXValue? {
        var selectedRange: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard status == .success, let raw = selectedRange else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        return axValue
    }

    private func selectedRangeString(of element: AXUIElement) -> String? {
        guard let axRange = selectedRangeValue(of: element) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range) else { return nil }
        return "\(range.location):\(range.length)"
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let axRange = selectedRangeValue(of: element) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range) else { return nil }
        return range
    }

    /// Returns true iff the element's current AX selection matches
    /// `absoluteRange` (same location AND length). Used after writing
    /// `kAXSelectedTextRangeAttribute` to confirm the target actually
    /// accepted the range — Electron/webview composers often honour the
    /// AX write even when their Cmd+C plumbing does not surface the
    /// selection on the system pasteboard.
    private func axSelectionMatches(_ element: AXUIElement, absoluteRange: NSRange) -> Bool {
        guard let current = selectedRange(of: element) else { return false }
        return current.location == absoluteRange.location
            && current.length == absoluteRange.length
    }

    private func textAnchor(
        for element: AXUIElement,
        range: CFRange?,
        fallbackFrame: CGRect,
        selectedTextWasReadFromAX: Bool
    ) -> TextAnchor {
        if let range {
            var r = range
            if let value = AXValueCreate(.cfRange, &r),
               let bounds = rangeBounds(of: element, rangeValue: value, reference: fallbackFrame),
               isUsableTextGeometry(bounds.normalized, fallbackFrame: fallbackFrame) {
                let source: TextAnchor.Source = range.length == 0 ? .axCaret : .axBoundsForRange
                let confidence: TextAnchor.Confidence
                if range.length > 0, selectedTextWasReadFromAX {
                    confidence = .exact
                } else if range.length > 0 {
                    confidence = .good
                } else {
                    confidence = .good
                }
                return TextAnchor(
                    rect: bounds.normalized,
                    source: source,
                    confidence: confidence,
                    rawRect: bounds.raw
                )
            }
            if let lineBounds = lineBoundsForTextIndex(
                range.location,
                of: element,
                reference: fallbackFrame
            ),
               isUsableTextGeometry(lineBounds.normalized, fallbackFrame: fallbackFrame) {
                return TextAnchor(
                    rect: lineBounds.normalized,
                    source: .axLineBounds,
                    confidence: .good,
                    rawRect: lineBounds.raw
                )
            }
        }

        if let elementFrame = elementFrame(of: element) {
            return TextAnchor(
                rect: elementFrame,
                source: .axElementFrame,
                confidence: .approximate,
                rawRect: nil
            )
        }

        if let windowFrame = focusedWindowFrame() {
            let source: TextAnchor.Source = selectedTextWasReadFromAX ? .focusedWindow : .clipboardFallback
            return TextAnchor(
                rect: windowFrame,
                source: source,
                confidence: .weak,
                rawRect: nil
            )
        }

        let m = NSEvent.mouseLocation
        return TextAnchor(
            rect: CGRect(x: m.x - 4, y: m.y - 4, width: 8, height: 8),
            source: .mouseFallback,
            confidence: .weak,
            rawRect: nil
        )
    }

    private func selectionBounds(of element: AXUIElement, rangeValue: AXValue?, reference: CGRect? = nil) -> CGRect? {
        rangeBounds(of: element, rangeValue: rangeValue, reference: reference)?.normalized
    }

    private func isUsableTextGeometry(_ rect: CGRect, fallbackFrame: CGRect) -> Bool {
        guard !rect.isEmpty else { return false }
        guard rect.height >= 2, rect.height <= 90, rect.width >= 1, rect.width <= 1800 else { return false }

        if let windowFrame = focusedWindowFrame(), !windowFrame.isEmpty {
            let windowArea = windowFrame.insetBy(dx: -2, dy: -2)
            guard windowArea.intersects(rect) || windowArea.contains(CGPoint(x: rect.midX, y: rect.midY)) else {
                return false
            }
        }

        guard !fallbackFrame.isEmpty else { return true }
        let fallbackArea = fallbackFrame.insetBy(dx: -160, dy: -120)
        return fallbackArea.intersects(rect)
            || fallbackArea.contains(CGPoint(x: rect.midX, y: rect.midY))
            || (focusedWindowFrame()?.insetBy(dx: -2, dy: -2).intersects(rect) == true)
    }

    private func lineBoundsForTextIndex(
        _ index: Int,
        of element: AXUIElement,
        reference: CGRect?
    ) -> (raw: CGRect, normalized: CGRect)? {
        var lineRef: CFTypeRef?
        let lineStatus = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: max(0, index)) as CFTypeRef,
            &lineRef
        )
        guard lineStatus == .success, let lineNumber = (lineRef as? NSNumber)?.intValue else {
            return nil
        }

        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            NSNumber(value: lineNumber) as CFTypeRef,
            &rangeRef
        )
        guard rangeStatus == .success, let rawRange = rangeRef else { return nil }
        guard CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeBitCast(rawRange, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        return rangeBounds(of: element, rangeValue: rangeValue, reference: reference)
    }

    private func axLineRangeForTextIndex(_ index: Int, of element: AXUIElement) -> CFRange? {
        var lineRef: CFTypeRef?
        let lineStatus = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: max(0, index)) as CFTypeRef,
            &lineRef
        )
        guard lineStatus == .success, let lineNumber = (lineRef as? NSNumber)?.intValue else {
            return nil
        }

        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            NSNumber(value: lineNumber) as CFTypeRef,
            &rangeRef
        )
        guard rangeStatus == .success, let rawRange = rangeRef else { return nil }
        guard CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeBitCast(rawRange, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private func rangeBounds(
        of element: AXUIElement,
        rangeValue: AXValue?,
        reference: CGRect?
    ) -> (raw: CGRect, normalized: CGRect)? {
        guard let rangeValue else { return nil }
        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard status == .success, let raw = boundsRef else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return (raw: rect, normalized: normalizedAXRect(rect, reference: reference))
    }

    private func elementFrame(of element: AXUIElement) -> CGRect? {
        guard
            let point = axPoint(of: element, attribute: kAXPositionAttribute),
            let size = axSize(of: element, attribute: kAXSizeAttribute)
        else { return nil }
        return normalizedAXRect(CGRect(origin: point, size: size))
    }

    private func queryFocusedWindowElementFromSystem() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedWindow: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        let systemWindow = (status == .success && focusedWindow != nil) ? (focusedWindow as! AXUIElement) : nil
        guard let elementWindow = focusedWindowElementFromFocusedElement() else {
            return systemWindow
        }
        guard let systemWindow else { return elementWindow }

        let elementBundle = bundleID(for: elementWindow)
        let systemBundle = bundleID(for: systemWindow)
        if elementBundle == "com.google.Chrome" || isBrowserBundleID(elementBundle ?? "") {
            return elementWindow
        }
        return elementBundle == systemBundle ? systemWindow : elementWindow
    }

    private func focusedWindowElementFromFocusedElement() -> AXUIElement? {
        guard var current = queryFocusedUIElementFromSystem() else { return nil }
        if let directWindow = axElement(of: current, attribute: "AXWindow") {
            return directWindow
        }
        for _ in 0..<24 {
            let role = axString(of: current, attribute: kAXRoleAttribute) ?? ""
            if role == "AXWindow" {
                return current
            }
            guard let parent = axElement(of: current, attribute: kAXParentAttribute as String) else { break }
            current = parent
        }
        return nil
    }

    private func bundleID(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else { return nil }
        return resolvedBundleID(forOwningPID: pid)
    }

    private func mainCGWindowFrame(for pid: pid_t) -> CGRect? {
        mainCGWindowCaptureInfo(for: pid)?.rect
    }

    private func mainCGWindowFrame(
        for pid: pid_t,
        requireMainAppWindow: Bool
    ) -> CGRect? {
        mainCGWindowCaptureInfo(
            for: pid,
            requireMainAppWindow: requireMainAppWindow
        )?.rect
    }

    private func focusedCGWindowFrame(
        for pid: pid_t,
        matching reference: CGRect?,
        requireMainBrowserWindow: Bool = false
    ) -> CGRect? {
        mainCGWindowCaptureInfo(
            for: pid,
            matching: reference,
            requireMainBrowserWindow: requireMainBrowserWindow
        )?.rect
    }

    private func frontmostCGWindowFrame(
        for pid: pid_t,
        requireMainAppWindow: Bool = false,
        requireMainBrowserWindow: Bool = false
    ) -> CGRect? {
        frontmostCGWindowCaptureInfo(
            for: pid,
            requireMainAppWindow: requireMainAppWindow,
            requireMainBrowserWindow: requireMainBrowserWindow
        )?.rect
    }

    private func frontmostCGWindowCaptureInfo(
        for pid: pid_t,
        requireMainAppWindow: Bool = false,
        requireMainBrowserWindow: Bool = false
    ) -> (windowID: CGWindowID, rect: CGRect)? {
        var candidates = cgWindowCaptureCandidates(for: pid)
        if requireMainAppWindow {
            candidates = candidates.filter { isMainAppWindowFrame($0.rect) }
        }
        if requireMainBrowserWindow {
            candidates = candidates.filter { isMainBrowserWindowFrame($0.rect) }
        }
        return (candidates.first(where: \.isVisible) ?? candidates.first).map { ($0.windowID, $0.rect) }
    }

    private func mainCGWindowCaptureInfo(
        for pid: pid_t,
        matching reference: CGRect? = nil,
        requireMainAppWindow: Bool = false,
        requireMainBrowserWindow: Bool = false
    ) -> (windowID: CGWindowID, rect: CGRect)? {
        var candidates = cgWindowCaptureCandidates(for: pid)
        if requireMainAppWindow {
            candidates = candidates.filter { isMainAppWindowFrame($0.rect) }
        }
        if requireMainBrowserWindow {
            candidates = candidates.filter { isMainBrowserWindowFrame($0.rect) }
        }
        let visibleCandidates = candidates.filter(\.isVisible)
        let pool = visibleCandidates.isEmpty ? candidates : visibleCandidates
        if let reference, !reference.isEmpty {
            return pool.max { lhs, rhs in
                cgWindowMatchScore(lhs.rect, reference: reference) < cgWindowMatchScore(rhs.rect, reference: reference)
            }.map { ($0.windowID, $0.rect) }
        }
        return pool
            .max { lhs, rhs in
                (lhs.rect.width * lhs.rect.height) < (rhs.rect.width * rhs.rect.height)
            }.map { ($0.windowID, $0.rect) }
    }

    private func cgWindowCaptureCandidates(
        for pid: pid_t
    ) -> [(windowID: CGWindowID, rect: CGRect, isVisible: Bool)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return rawList.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else {
                return nil
            }
            guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.max
            guard layer == 0 else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { return nil }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let raw = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return nil
            }
            let normalized = normalizedCGWindowRect(raw)
            guard normalized.width >= 260, normalized.height >= 180 else { return nil }
            let isVisible = NSScreen.screens.contains { screen in
                screen.visibleFrame.insetBy(dx: -64, dy: -64).intersects(normalized)
                    || screen.frame.insetBy(dx: -64, dy: -64).intersects(normalized)
            }
            return (CGWindowID(number.uint32Value), normalized, isVisible)
        }
    }

    private func cgWindowMatchScore(_ rect: CGRect, reference: CGRect) -> CGFloat {
        let overlap = rect.intersection(reference)
        let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
        let centerDistance = hypot(rect.midX - reference.midX, rect.midY - reference.midY)
        let sizeDelta = abs(rect.width - reference.width) + abs(rect.height - reference.height)
        return overlapArea - centerDistance * 18 - sizeDelta * 4
    }

    private func isMainBrowserWindowFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 520, frame.height >= 360 else { return false }
        return !isSmallDetachedPopupFrame(frame)
    }

    private func isMainAppWindowFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 420, frame.height >= 260 else { return false }
        return !isSmallDetachedPopupFrame(frame)
    }

    private func isUsableFloatingHelperWindowFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 360, frame.height >= 220 else { return false }
        return !isSmallDetachedPopupFrame(frame)
    }

    private func normalizedCGWindowRect(_ raw: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { screen in
            let horizontallyIntersects = raw.maxX > screen.frame.minX && raw.minX < screen.frame.maxX
            let yInScreenRange = raw.minY >= 0 && raw.minY <= screen.frame.height + abs(screen.frame.minY)
            return horizontallyIntersects && yInScreenRange
        }) ?? NSScreen.main else {
            return raw
        }
        // CGWindowList reports bounds in Quartz coordinates (origin at the top-left of the display).
        // AppKit panels use bottom-left screen coordinates. AX rects are normalized separately.
        return CGRect(
            x: raw.minX,
            y: screen.frame.maxY - raw.minY - raw.height,
            width: raw.width,
            height: raw.height
        )
    }

    private func shouldPreferCGWindowFrame(_ cgFrame: CGRect, overAXFrame axFrame: CGRect) -> Bool {
        guard cgFrame.intersects(axFrame) || cgFrame.contains(CGPoint(x: axFrame.midX, y: axFrame.midY)) else {
            return false
        }
        if cgFrame.height > axFrame.height * 1.22 || cgFrame.width > axFrame.width * 1.22 {
            return true
        }
        let axLooksLikeTopRegion = axFrame.minY > cgFrame.midY && axFrame.height < cgFrame.height * 0.55
        return axLooksLikeTopRegion
    }

    private struct GoogleDocsViewportPayload: Decodable {
        let href: String
        let outerWidth: CGFloat
        let outerHeight: CGFloat
        let chromeLeft: CGFloat
        let chromeTop: CGFloat
        let lines: [Line]

        struct Line: Decodable {
            let text: String
            let left: CGFloat
            let top: CGFloat
            let width: CGFloat
            let height: CGFloat
        }
    }

    private func googleDocsVisibleTextContext(minLength: Int, maxLength: Int) -> FocusedTextContext? {
        if let cached = googleDocsContextCache,
           cached.maxLength == maxLength,
           Date().timeIntervalSince(cached.createdAt) < 1.0 {
            if let context = cached.context, (context.text as NSString).length >= minLength {
                return context
            }
            return nil
        }

        let context = buildGoogleDocsVisibleTextContext(maxLength: maxLength)
        googleDocsContextCache = (Date(), maxLength, context)
        guard let context, (context.text as NSString).length >= minLength else { return nil }
        return context
    }

    private func buildGoogleDocsVisibleTextContext(maxLength: Int) -> FocusedTextContext? {
        guard let front = frontmostAppInfo(), front.bundleID == "com.google.Chrome" else { return nil }
        guard appConsentStatus(for: front.bundleID) == .allowed else {
            postGoogleDocsDebug("blocked app-consent status=\(appConsentStatus(for: front.bundleID).rawValue)")
            return nil
        }
        guard let focused = focusedElement() else {
            postGoogleDocsDebug("blocked focused-element=nil")
            return nil
        }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        let bundleID = resolvedBundleID(forOwningPID: pid)
        guard bundleID == "com.google.Chrome" else {
            postGoogleDocsDebug("blocked focused-bundle=\(bundleID)")
            return nil
        }
        guard !isSecureInputField(focused), !hasSensitiveFieldHint(focused) else {
            postGoogleDocsDebug("blocked sensitive-field")
            return nil
        }
        guard let windowFrame = focusedWindowFrame() ?? mainCGWindowFrame(for: pid), !windowFrame.isEmpty else {
            postGoogleDocsDebug("blocked window-frame=nil")
            return nil
        }
        guard let payload = googleDocsViewportPayloadFromChrome() else {
            postGoogleDocsDebug("blocked payload=nil title=\(chromeFocusedWindowTitle() ?? "nil")")
            return nil
        }
        guard payload.href.contains("docs.google.com/document") else {
            postGoogleDocsDebug("blocked href=\(payload.href)")
            return nil
        }

        let scaleX = payload.outerWidth > 0 ? windowFrame.width / payload.outerWidth : 1
        let scaleY = payload.outerHeight > 0 ? windowFrame.height / payload.outerHeight : 1

        var text = ""
        var fragments: [TextFragment] = []
        let maxUTF16Length = max(1, maxLength)

        for line in payload.lines {
            let lineText = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty else { continue }
            let separator = text.isEmpty ? "" : "\n"
            let remaining = maxUTF16Length - (text as NSString).length - (separator as NSString).length
            guard remaining > 0 else { break }

            let clippedLine: String
            if (lineText as NSString).length > remaining {
                clippedLine = String(lineText.prefix(remaining))
            } else {
                clippedLine = lineText
            }

            let start = (text as NSString).length + (separator as NSString).length
            text += separator + clippedLine

            let windowX = payload.chromeLeft + line.left
            let windowYFromTop = payload.chromeTop + line.top
            let rect = CGRect(
                x: windowFrame.minX + windowX * scaleX,
                y: windowFrame.maxY - (windowYFromTop + line.height) * scaleY,
                width: max(12, line.width * scaleX),
                height: max(12, line.height * scaleY)
            )
            fragments.append(
                TextFragment(
                    text: clippedLine,
                    range: NSRange(location: start, length: (clippedLine as NSString).length),
                    rect: rect
                )
            )
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (cleaned as NSString).length > 0, !fragments.isEmpty else {
            postGoogleDocsDebug("blocked empty-visible-text rawLines=\(payload.lines.count)")
            return nil
        }
        let frame = fragments.map(\.rect).reduce(fragments[0].rect) { $0.union($1) }
        let anchor = TextAnchor(
            rect: frame,
            source: .visiblePageText,
            confidence: .good,
            rawRect: nil
        )
        postGoogleDocsDebug("visiblePageText/good lines=\(fragments.count) chars=\((cleaned as NSString).length)")
        return FocusedTextContext(
            text: cleaned,
            frame: frame,
            usesSelection: false,
            selectedRange: nil,
            targetElement: focused,
            targetAppPID: pid,
            targetBundleID: bundleID,
            anchor: anchor,
            textFragments: fragments
        )
    }

    private func isGoogleDocsFrontmost() -> Bool {
        guard let front = frontmostAppInfo(), front.bundleID == "com.google.Chrome" else { return false }
        if let cached = googleDocsFrontmostCache,
           Date().timeIntervalSince(cached.createdAt) < 1.0 {
            return cached.isDocs
        }
        let activeURL = chromeActiveTabURL()
        let title = chromeFocusedWindowTitle()
        let titleLower = (title ?? "").lowercased()
        let urlLooksLikeDocs = activeURL?.contains("docs.google.com/document") == true
        let titleLooksLikeDocs = titleLower.contains("google docs")
            || titleLower.contains("docs.google.com")
            || titleLower.contains("google документ")
            || titleLower.contains("google документы")
        let isDocs = urlLooksLikeDocs || titleLooksLikeDocs
        if isDocs || titleLower.contains("google") || activeURL != nil {
            postGoogleDocsDebug(
                "detect isDocs=\(isDocs) urlDocs=\(urlLooksLikeDocs) titleDocs=\(titleLooksLikeDocs) title=\(title ?? "nil")"
            )
        }
        googleDocsFrontmostCache = (Date(), isDocs)
        return isDocs
    }

    private func isGoogleSheetsFrontmost() -> Bool {
        guard let front = frontmostAppInfo(), front.bundleID == "com.google.Chrome" else { return false }
        if let cached = googleSheetsFrontmostCache,
           Date().timeIntervalSince(cached.createdAt) < 1.0 {
            return cached.isSheets
        }
        let title = chromeFocusedWindowTitle()
        let titleLower = (title ?? "").lowercased()
        let isSheets = titleLower.contains("google sheets")
            || titleLower.contains("sheets.google.com")
            || titleLower.contains("google табли")
            || titleLower.contains("google spreadsheets")
        if isSheets {
            postGoogleDocsDebug("sheets blocked title=\(title ?? "nil")")
        }
        googleSheetsFrontmostCache = (Date(), isSheets)
        return isSheets
    }

    private func isGoogleSheetsTextEditFocus(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 8 {
            if isGoogleSheetsTextEditElement(candidate) {
                return true
            }
            current = axElement(of: candidate, attribute: kAXParentAttribute as String)
            depth += 1
        }
        return false
    }

    private func isGoogleSheetsTextEditElement(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              resolvedBundleID(forOwningPID: pid) == "com.google.Chrome" else {
            return false
        }
        guard !isSecureInputField(element),
              !isTransientPopupLike(element),
              !hasSensitiveFieldHint(element) else {
            return false
        }

        let role = axString(of: element, attribute: kAXRoleAttribute) ?? ""
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        let roleLooksTextual = textRoles.contains(role)
        let exposesEditableText = valueText(of: element) != nil
            && selectedRangeValue(of: element) != nil
            && isAXAttributeSettable(element, attribute: kAXValueAttribute as String)
        guard roleLooksTextual || exposesEditableText else { return false }

        guard let frame = elementFrame(of: element), !frame.isEmpty else { return false }
        if frame.width > 900 || frame.height > 180 {
            return false
        }
        guard let window = focusedWindowFrame(), !window.isEmpty else {
            return true
        }
        let contentArea = window.insetBy(dx: -8, dy: -8)
        guard contentArea.intersects(frame) || contentArea.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            return false
        }
        // Exclude Chrome's toolbar/omnibox region while still allowing the
        // Sheets formula bar and in-cell editor inside the page.
        return frame.maxY < window.maxY - 72
    }

    private func chromeFocusedWindowLooksLikeGoogleDocs() -> Bool {
        guard let window = queryFocusedWindowElementFromSystem() else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              resolvedBundleID(forOwningPID: pid) == "com.google.Chrome" else {
            return false
        }
        let title = (chromeFocusedWindowTitle(window: window) ?? "").lowercased()
        return title.contains("google docs")
            || title.contains("docs.google.com")
            || title.contains("google документ")
            || title.contains("google документы")
    }

    private func chromeFocusedWindowTitle(window provided: AXUIElement? = nil) -> String? {
        let window = provided ?? queryFocusedWindowElementFromSystem()
        guard let window else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              resolvedBundleID(forOwningPID: pid) == "com.google.Chrome" else {
            return nil
        }
        return axString(of: window, attribute: kAXTitleAttribute)
    }

    private func chromeActiveTabURL() -> String? {
        let script = """
tell application "Google Chrome"
    if not (exists front window) then return ""
    return URL of active tab of front window
end tell
"""
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return result?.stringValue
    }

    private func postGoogleDocsDebug(_ message: String) {
        let signature = "Docs reader \(message)"
        guard signature != lastGoogleDocsDebugSignature else { return }
        lastGoogleDocsDebugSignature = signature
        textoraDiagLog("googleDocs", signature)
    }

    private func googleDocsViewportPayloadFromChrome() -> GoogleDocsViewportPayload? {
        let js = #"""
(() => {
  if (!location.href.includes('docs.google.com/document')) return JSON.stringify({href: location.href, outerWidth: outerWidth, outerHeight: outerHeight, chromeLeft: 0, chromeTop: 0, lines: []});
  const chromeLeft = Math.max(0, (outerWidth - innerWidth) / 2);
  const chromeTop = Math.max(0, outerHeight - innerHeight);
  const textOf = (el) => {
    let value = (el.innerText || el.textContent || '').replace(/\u200b/g, '').replace(/\s+/g, ' ').trim();
    if (value) return value;
    const labelled = Array.from(el.querySelectorAll('[aria-label],[data-text],[data-value]')).map((n) => n.getAttribute('aria-label') || n.getAttribute('data-text') || n.getAttribute('data-value') || '').join(' ');
    return labelled.replace(/\s+/g, ' ').trim();
  };
  let nodes = Array.from(document.querySelectorAll('.kix-lineview'));
  if (!nodes.length) nodes = Array.from(document.querySelectorAll('[class*="kix-lineview"]')).filter((el) => !el.querySelector('[class*="kix-lineview"]'));
  if (!nodes.length) nodes = Array.from(document.querySelectorAll('[role="textbox"] [aria-label], [contenteditable="true"] div'));
  const seen = new Set();
  const lines = [];
  for (const el of nodes) {
    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) continue;
    if (rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) continue;
    const text = textOf(el);
    if (!text) continue;
    const key = `${Math.round(rect.left)}:${Math.round(rect.top)}:${text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    lines.push({ text, left: rect.left, top: rect.top, width: rect.width, height: rect.height });
  }
  lines.sort((a, b) => Math.abs(a.top - b.top) > 3 ? a.top - b.top : a.left - b.left);
  return JSON.stringify({ href: location.href, outerWidth, outerHeight, chromeLeft, chromeTop, lines: lines.slice(0, 80) });
})()
"""#
        let script = """
tell application "Google Chrome"
    if not (exists front window) then return ""
    return execute active tab of front window javascript \(appleScriptStringLiteral(js))
end tell
"""
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              let data = result.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleDocsViewportPayload.self, from: data)
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func absoluteAXRange(for localRange: NSRange, in context: FocusedTextContext) -> NSRange? {
        if context.usesSelection, let selected = context.selectedRange {
            let location = max(0, selected.location + localRange.location)
            let remaining = max(0, selected.length - localRange.location)
            return NSRange(location: location, length: max(1, min(localRange.length, remaining)))
        }
        guard let full = valueText(of: context.targetElement) else { return localRange }
        let fullNS = full as NSString
        let needle = context.text as NSString
        guard needle.length > 0 else { return nil }
        let found = fullNS.range(of: context.text)
        guard found.location != NSNotFound else { return localRange }
        let location = max(0, min(found.location + localRange.location, fullNS.length))
        let length = max(1, min(localRange.length, fullNS.length - location))
        return NSRange(location: location, length: length)
    }

    private func clipToMaxLength(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<idx])
    }

    private func valueText(of element: AXUIElement) -> String? {
        var valueText: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueText)
        guard status == .success else { return nil }
        return valueText as? String
    }

    private func focusedElement() -> AXUIElement? {
        if focusCoalesceDepth > 0 {
            if coalesceMemoFocusedInitialized {
                return coalesceMemoFocused
            }
            let v = queryFocusedUIElementFromSystem()
            coalesceMemoFocused = v
            coalesceMemoFocusedInitialized = true
            return v
        }
        return queryFocusedUIElementFromSystem()
    }

    private func queryFocusedUIElementFromSystem() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard status == .success, let focusedObject else { return nil }
        return (focusedObject as! AXUIElement)
    }

    /// Some hosts (notably Electron/WebView on newer macOS) focus a nested text node while
    /// editability is exposed on a parent AX element. Walk up the chain to find editable target.
    private func focusedEditableElement() -> AXUIElement? {
        if focusCoalesceDepth > 0 {
            if coalesceMemoEditableInitialized {
                return coalesceMemoEditable
            }
            let v = resolveFocusedEditableElement()
            coalesceMemoEditable = v
            coalesceMemoEditableInitialized = true
            return v
        }
        return resolveFocusedEditableElement()
    }

    private func resolveFocusedEditableElement() -> AXUIElement? {
        guard var current = focusedElement() else { return nil }
        if isEditable(element: current) {
            return current
        }
        for _ in 0..<24 {
            guard let parent = axElement(of: current, attribute: kAXParentAttribute as String) else { break }
            current = parent
            if isEditable(element: current) {
                return current
            }
        }
        return nil
    }

    private func isEditable(element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleStatus == .success ? (roleValue as? String ?? "") : ""
        let subrole = axString(of: element, attribute: kAXSubroleAttribute) ?? ""
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if editableRoles.contains(role) {
            return true
        }
        var editableValue: CFTypeRef?
        let editableStatus = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableValue)
        if editableStatus == .success, let bool = editableValue as? Bool {
            return bool
        }
        // Electron/WebView hosts can expose editable text on roles other than AXTextField/AXTextArea.
        // If selected range is available, treat element as text-editable.
        if selectedRangeValue(of: element) != nil {
            return true
        }
        if neverEditableRoles.contains(role) || neverEditableRoles.contains(subrole) {
            return false
        }
        // Some hosts expose string value but miss AXEditable flag. Treat it
        // as an input only when AX says the value can actually be changed;
        // otherwise browser/app labels are indistinguishable from user text
        // and produce false overlays.
        if valueText(of: element) != nil,
           isAXAttributeSettable(element, attribute: kAXValueAttribute as String) {
            return true
        }
        return false
    }

    private func shouldIgnoreCurrentFocusedInput(element provided: AXUIElement?, includeAppConsent: Bool) -> Bool {
        guard let element = provided ?? focusedElement() else { return false }
        if isGoogleSheetsFrontmost(), !isGoogleSheetsTextEditFocus(element) { return true }
        if isSecureInputField(element) { return true }
        if isTransientPopupLike(element) { return true }
        if hasSensitiveFieldHint(element) { return true }
        if isBrowserChromeInputField(element) { return true }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid != 0 {
            let bundleID = resolvedBundleID(forOwningPID: pid)
            if helperSuppressedBundleIDs.contains(bundleID) {
                return true
            }
        }
        let ownerConsent = consentStatus(forOwningAXElement: element)
        if ownerConsent == .denied { return true }
        if includeAppConsent, ownerConsent != .allowed { return true }
        return false
    }

    private func isSecureInputField(_ element: AXUIElement) -> Bool {
        let role = (axString(of: element, attribute: kAXRoleAttribute) ?? "").lowercased()
        let subrole = (axString(of: element, attribute: kAXSubroleAttribute) ?? "").lowercased()
        if role.contains("secure") || subrole.contains("secure") {
            return true
        }
        let secureAttributes = ["AXProtected", "AXSecure", "AXIsSecure"]
        return secureAttributes.contains { axBool(of: element, attribute: $0) == true }
    }

    private func isTransientPopupLike(_ element: AXUIElement) -> Bool {
        let role = axString(of: element, attribute: kAXRoleAttribute) ?? ""
        let subrole = axString(of: element, attribute: kAXSubroleAttribute) ?? ""
        if transientPopupRoles.contains(role) || transientPopupRoles.contains(subrole) {
            return true
        }
        let lowerRole = role.lowercased()
        let lowerSubrole = subrole.lowercased()
        if lowerRole.contains("menu") || lowerSubrole.contains("menu") || lowerRole.contains("popover") || lowerSubrole.contains("popover") {
            return true
        }
        let title = (axString(of: element, attribute: kAXTitleAttribute) ?? "").lowercased()
        let description = (axString(of: element, attribute: kAXDescriptionAttribute) ?? "").lowercased()
        let identifier = (axString(of: element, attribute: "AXIdentifier") ?? "").lowercased()
        let popupHints = ["menu", "popover", "popup", "suggestion", "autocomplete", "completion", "dropdown"]
        if popupHints.contains(where: { title.contains($0) || description.contains($0) || identifier.contains($0) }) {
            return true
        }
        if role == "AXList" || role == "AXTable" || role == "AXOutline" {
            guard let frame = elementFrame(of: element) else { return false }
            return isSmallDetachedPopupFrame(frame)
        }
        guard role == "AXDialog" || role == "AXWindow" || role == "AXSheet" else { return false }
        guard lowerSubrole.contains("dialog")
                || lowerSubrole.contains("floating")
                || lowerSubrole.contains("system")
                || lowerSubrole.contains("unknown")
                || lowerSubrole.contains("popover")
                || lowerSubrole.contains("popup")
                || subrole.isEmpty else {
            return false
        }
        guard let frame = elementFrame(of: element) else { return false }
        return isSmallDetachedPopupFrame(frame)
    }

    private func isSmallDetachedPopupFrame(_ frame: CGRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else {
            return frame.width <= 820 && frame.height <= 620
        }
        let vf = screen.visibleFrame
        let isDetachedFromNormalContent = frame.minY > vf.midY || frame.maxY > vf.maxY - 24
        let isSmallTransientSurface = frame.width <= 820 && frame.height <= 620
        return isSmallTransientSurface && isDetachedFromNormalContent
    }

    private func hasSensitiveFieldHint(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 10 {
            if isSecureInputField(candidate) {
                return true
            }
            let metadata = sensitiveMetadataText(of: candidate)
            if depth <= 3, sensitiveFieldHints.contains(where: { containsSensitivePhrase($0, in: metadata) }) {
                return true
            }
            if isHighRiskSensitiveContext(candidate),
               highRiskSensitiveFieldHints.contains(where: { containsSensitivePhrase($0, in: metadata) }) {
                return true
            }
            current = axElement(of: candidate, attribute: kAXParentAttribute as String)
            depth += 1
        }
        return false
    }

    private func containsSensitivePhrase(_ phrase: String, in metadata: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return metadata.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }

    private func isHighRiskSensitiveContext(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else { return false }
        let bundleID = resolvedBundleID(forOwningPID: pid)
        if highRiskSensitiveBundleIDs.contains(bundleID) {
            return true
        }
        let lowerBundleID = bundleID.lowercased()
        return highRiskSensitiveBundleFragments.contains { lowerBundleID.contains($0) }
    }

    private func isBrowserChromeInputField(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else { return false }
        let bundleID = resolvedBundleID(forOwningPID: pid)
        guard isBrowserBundleID(bundleID) else { return false }
        let role = axString(of: element, attribute: kAXRoleAttribute) ?? ""
        let subrole = axString(of: element, attribute: kAXSubroleAttribute) ?? ""
        let textLikeRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        guard textLikeRoles.contains(role) || textLikeRoles.contains(subrole) else { return false }

        let hintSource = [
            axString(of: element, attribute: "AXPlaceholderValue"),
            axString(of: element, attribute: kAXTitleAttribute),
            axString(of: element, attribute: kAXDescriptionAttribute),
            axString(of: element, attribute: "AXIdentifier")
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        let addressHints = [
            "address", "url", "search", "omnibox", "location", "web address",
            "адрес", "поиск"
        ]
        if addressHints.contains(where: { hintSource.contains($0) }) {
            return true
        }

        guard let frame = elementFrame(of: element),
              let window = focusedWindowFrame(),
              !frame.isEmpty,
              !window.isEmpty else {
            return false
        }
        return frame.maxY > window.maxY - 76 && frame.height <= 64
    }

    private func contextualSlice(from fullText: String, around range: CFRange?, maxLength: Int) -> String {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let ns = trimmed as NSString
        let caretLocation = max(0, min((range?.location ?? ns.length), ns.length))
        let half = maxLength / 2
        var start = max(0, caretLocation - half)
        var end = min(ns.length, start + maxLength)
        if end - start < maxLength {
            start = max(0, end - maxLength)
        }
        // Expand to nearest whitespace boundaries for more natural snippets.
        while start > 0 {
            let ch = ns.character(at: start)
            if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        while end < ns.length {
            let ch = ns.character(at: end - 1)
            if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            end += 1
        }
        let snippet = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet
    }

    private func axString(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func axBool(of element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        if let boolValue = value as? Bool {
            return boolValue
        }
        return (value as? NSNumber)?.boolValue
    }

    private func sensitiveMetadataText(of element: AXUIElement) -> String {
        [
            axString(of: element, attribute: kAXRoleAttribute),
            axString(of: element, attribute: kAXSubroleAttribute),
            axString(of: element, attribute: kAXTitleAttribute),
            axString(of: element, attribute: kAXDescriptionAttribute),
            axString(of: element, attribute: kAXHelpAttribute),
            axString(of: element, attribute: "AXPlaceholderValue"),
            axString(of: element, attribute: "AXIdentifier"),
            axString(of: element, attribute: "AXRoleDescription")
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func isAXAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private func elementSignature(_ element: AXUIElement) -> String {
        let role = axString(of: element, attribute: kAXRoleAttribute) ?? "nil"
        let subrole = axString(of: element, attribute: kAXSubroleAttribute) ?? "nil"
        let includeTitle = role == "AXWindow" || role == "AXDialog" || role == "AXSheet"
        let title = includeTitle ? (axString(of: element, attribute: kAXTitleAttribute) ?? "") : ""
        let identifier = axString(of: element, attribute: "AXIdentifier") ?? ""
        let frame = elementFrame(of: element)
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return "pid=\(pid) role=\(role) subrole=\(subrole) id=\(identifier) title=\(title) frame=\(textoraDiagRect(frame))"
    }

    private func axElement(of element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func axPoint(of element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let rawValue = value else { return nil }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func axSize(of element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let rawValue = value else { return nil }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    // Normalize AX rects into AppKit screen coordinates used by NSPanel.
    // AX parameterized bounds are commonly reported in top-left screen coordinates; when both direct
    // and flipped rects are visible, prefer the candidate closer to the related text/window reference.
    private func normalizedAXRect(_ raw: CGRect, reference: CGRect? = nil) -> CGRect {
        let direct = raw
        guard let screen = NSScreen.screens.first(where: { $0.frame.minX <= raw.minX && raw.minX <= $0.frame.maxX }) ?? NSScreen.main else {
            return direct
        }

        let flippedY = screen.frame.maxY - raw.minY - raw.height
        let flipped = CGRect(x: raw.minX, y: flippedY, width: raw.width, height: raw.height)

        if let reference, !reference.isEmpty {
            let directScore = screenCoordinateScore(direct, reference: reference)
            let flippedScore = screenCoordinateScore(flipped, reference: reference)
            if abs(directScore - flippedScore) > 0.001 {
                return flippedScore > directScore ? flipped : direct
            }
        }

        let directVisible = NSScreen.screens.contains { $0.frame.intersects(direct) }
        let flippedVisible = NSScreen.screens.contains { $0.frame.intersects(flipped) }

        if flippedVisible && directVisible {
            return flipped
        }
        if flippedVisible && !directVisible {
            return flipped
        }
        return direct
    }

    private func screenCoordinateScore(_ rect: CGRect, reference: CGRect) -> CGFloat {
        var score: CGFloat = 0
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
            score += 1000
        }
        if reference.intersects(rect) {
            score += 200
        }
        if reference.insetBy(dx: -48, dy: -48).contains(CGPoint(x: rect.midX, y: rect.midY)) {
            score += 120
        }
        let dx = max(0, abs(rect.midX - reference.midX) - reference.width / 2)
        let dy = max(0, abs(rect.midY - reference.midY) - reference.height / 2)
        score -= hypot(dx, dy)
        return score
    }

    private func triggerCopyShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        cUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
    }

    private func triggerPasteShortcut() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        cmdDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        return cmdDown != nil && vUp != nil
    }

    private func triggerUndoShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true)
        cmdDown?.flags = .maskCommand
        let zUp = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false)
        zUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        zUp?.post(tap: .cghidEventTap)
    }

    private func triggerDeleteKey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Forward delete key.
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x75, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x75, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func triggerBackspaceKey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Backspace/delete key. More consistently honoured by web composers
        // for deleting an active selection than the forward-delete key.
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func triggerRightArrowKey() {
        // 0x7C is the right-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func triggerUnicodeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        guard !units.isEmpty else { return true }

        return units.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            return down != nil && up != nil
        }
    }

    private func triggerPhysicalASCIIText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard text.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            guard let key = physicalASCIIKey(for: scalar),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else {
                return false
            }
            down.flags = key.shift ? .maskShift : CGEventFlags()
            up.flags = key.shift ? .maskShift : CGEventFlags()
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_500)
        }
        return true
    }

    private func triggerPhysicalReplacementText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let finalLayout = preferredKeyboardLayout(forReplacement: text)
        var activeLayout = KeyboardInputSource.currentLayout()

        func select(_ layout: TextInputKeyboardLayout) -> Bool {
            if activeLayout != layout {
                textoraDiagLog(
                    "physicalReplacement",
                    "select layout from=\(activeLayout) to=\(layout)"
                )
            }
            let selected = KeyboardInputSource.select(layout)
            for _ in 0..<8 {
                usleep(25_000)
                let current = KeyboardInputSource.currentLayout()
                if current == layout {
                    activeLayout = current
                    return true
                }
            }
            activeLayout = KeyboardInputSource.currentLayout()
            textoraDiagLog(
                "physicalReplacement",
                "layout select \(selected ? "not confirmed" : "failed") target=\(layout) current=\(activeLayout)"
            )
            return activeLayout == layout
        }

        for character in text {
            if character == "\n" || character == "\r" {
                guard triggerUnicodeText(String(character)) else { return false }
                usleep(4_000)
                continue
            }

            let characterLayout = preferredKeyboardLayout(forReplacementCharacter: character)
            if let characterLayout {
                guard select(characterLayout) else { return false }
            }

            let layoutForKey = characterLayout ?? activeLayout
            guard let key = physicalKey(forReplacementCharacter: character, layout: layoutForKey),
                  postPhysicalKey(code: key.code, shift: key.shift) else {
                return false
            }
            usleep(2_500)
        }

        if let finalLayout {
            _ = select(finalLayout)
        }
        return true
    }

    private func preferredKeyboardLayout(forReplacement text: String) -> TextInputKeyboardLayout? {
        var latin = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if isCyrillicScalar(scalar) {
                cyrillic += 1
            } else if isLatinScalar(scalar) {
                latin += 1
            }
        }
        if cyrillic > latin { return .russian }
        if latin > cyrillic { return .english }
        return nil
    }

    private func preferredKeyboardLayout(forReplacementCharacter character: Character) -> TextInputKeyboardLayout? {
        if character.unicodeScalars.contains(where: isCyrillicScalar) {
            return .russian
        }
        if character.unicodeScalars.contains(where: isLatinScalar) {
            return .english
        }
        if character.unicodeScalars.allSatisfy({ $0.value < 128 }),
           !character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .english
        }
        return nil
    }

    private func physicalKey(
        forReplacementCharacter character: Character,
        layout: TextInputKeyboardLayout
    ) -> (code: CGKeyCode, shift: Bool)? {
        if character.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
            return physicalASCIIKey(for: " ")
        }

        switch layout {
        case .english, .other:
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  scalar.value < 128 else {
                return nil
            }
            return physicalASCIIKey(for: scalar)
        case .russian:
            let lower = Character(String(character).lowercased())
            guard let latinKey = TextKeyboardLayoutMapper.ruToEn[lower],
                  let scalar = String(latinKey).unicodeScalars.first,
                  let key = physicalASCIIKey(for: scalar) else {
                return nil
            }
            return (key.code, key.shift || character.isUppercase)
        }
    }

    private func isLatinScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value)
            || (0x0061...0x007A).contains(scalar.value)
            || (0x00C0...0x024F).contains(scalar.value)
            || (0x1E00...0x1EFF).contains(scalar.value)
    }

    private func isCyrillicScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
            || (0x0500...0x052F).contains(scalar.value)
    }

    private func postPhysicalKey(code: CGKeyCode, shift: Bool) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return false
        }
        down.flags = shift ? .maskShift : CGEventFlags()
        up.flags = shift ? .maskShift : CGEventFlags()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func physicalASCIIKey(for scalar: Unicode.Scalar) -> (code: CGKeyCode, shift: Bool)? {
        switch scalar {
        case "a": return (0x00, false)
        case "A": return (0x00, true)
        case "s": return (0x01, false)
        case "S": return (0x01, true)
        case "d": return (0x02, false)
        case "D": return (0x02, true)
        case "f": return (0x03, false)
        case "F": return (0x03, true)
        case "h": return (0x04, false)
        case "H": return (0x04, true)
        case "g": return (0x05, false)
        case "G": return (0x05, true)
        case "z": return (0x06, false)
        case "Z": return (0x06, true)
        case "x": return (0x07, false)
        case "X": return (0x07, true)
        case "c": return (0x08, false)
        case "C": return (0x08, true)
        case "v": return (0x09, false)
        case "V": return (0x09, true)
        case "b": return (0x0B, false)
        case "B": return (0x0B, true)
        case "q": return (0x0C, false)
        case "Q": return (0x0C, true)
        case "w": return (0x0D, false)
        case "W": return (0x0D, true)
        case "e": return (0x0E, false)
        case "E": return (0x0E, true)
        case "r": return (0x0F, false)
        case "R": return (0x0F, true)
        case "y": return (0x10, false)
        case "Y": return (0x10, true)
        case "t": return (0x11, false)
        case "T": return (0x11, true)
        case "1": return (0x12, false)
        case "!": return (0x12, true)
        case "2": return (0x13, false)
        case "@": return (0x13, true)
        case "3": return (0x14, false)
        case "#": return (0x14, true)
        case "4": return (0x15, false)
        case "$": return (0x15, true)
        case "6": return (0x16, false)
        case "^": return (0x16, true)
        case "5": return (0x17, false)
        case "%": return (0x17, true)
        case "=": return (0x18, false)
        case "+": return (0x18, true)
        case "9": return (0x19, false)
        case "(": return (0x19, true)
        case "7": return (0x1A, false)
        case "&": return (0x1A, true)
        case "-": return (0x1B, false)
        case "_": return (0x1B, true)
        case "8": return (0x1C, false)
        case "*": return (0x1C, true)
        case "0": return (0x1D, false)
        case ")": return (0x1D, true)
        case "]": return (0x1E, false)
        case "}": return (0x1E, true)
        case "o": return (0x1F, false)
        case "O": return (0x1F, true)
        case "u": return (0x20, false)
        case "U": return (0x20, true)
        case "[": return (0x21, false)
        case "{": return (0x21, true)
        case "i": return (0x22, false)
        case "I": return (0x22, true)
        case "p": return (0x23, false)
        case "P": return (0x23, true)
        case "l": return (0x25, false)
        case "L": return (0x25, true)
        case "j": return (0x26, false)
        case "J": return (0x26, true)
        case "'": return (0x27, false)
        case "\"": return (0x27, true)
        case "k": return (0x28, false)
        case "K": return (0x28, true)
        case ";": return (0x29, false)
        case ":": return (0x29, true)
        case "\\": return (0x2A, false)
        case "|": return (0x2A, true)
        case ",": return (0x2B, false)
        case "<": return (0x2B, true)
        case "/": return (0x2C, false)
        case "?": return (0x2C, true)
        case "n": return (0x2D, false)
        case "N": return (0x2D, true)
        case "m": return (0x2E, false)
        case "M": return (0x2E, true)
        case ".": return (0x2F, false)
        case ">": return (0x2F, true)
        case " ": return (0x31, false)
        case "`": return (0x32, false)
        case "~": return (0x32, true)
        default: return nil
        }
    }

    private func triggerUnicodeTextInChunks(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        var chunk = ""
        var chunkUnits = 0
        let maxUnitsPerChunk = 8

        func flushChunk() -> Bool {
            guard !chunk.isEmpty else { return true }
            let current = chunk
            chunk = ""
            chunkUnits = 0
            guard triggerUnicodeText(current) else { return false }
            usleep(UInt32(18_000 + min(55_000, current.utf16.count * 4_000)))
            return true
        }

        for character in text {
            let units = String(character).utf16.count
            if chunkUnits > 0, chunkUnits + units > maxUnitsPerChunk {
                guard flushChunk() else { return false }
            }
            chunk.append(character)
            chunkUnits += units
        }

        return flushChunk()
    }

    private func triggerUnicodeTextForReplacement(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        // A single Unicode keyboard event replaces an active selection without
        // touching the pasteboard. Prefer one event so a failed verification
        // can be undone in one step.
        if text.utf16.count <= 120 {
            return triggerUnicodeText(text) ? 1 : 0
        }

        var chunk = ""
        var chunkUnits = 0
        var posted = 0
        let maxUnitsPerChunk = 48

        func flushChunk() -> Bool {
            guard !chunk.isEmpty else { return true }
            let current = chunk
            chunk = ""
            chunkUnits = 0
            guard triggerUnicodeText(current) else { return false }
            posted += 1
            usleep(UInt32(8_000 + min(24_000, current.utf16.count * 1_000)))
            return true
        }

        for character in text {
            let units = String(character).utf16.count
            if chunkUnits > 0, chunkUnits + units > maxUnitsPerChunk {
                guard flushChunk() else { return posted }
            }
            chunk.append(character)
            chunkUnits += units
        }

        return flushChunk() ? posted : posted
    }

    private func triggerSelectAllShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 'a' key = 0x00
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true)
        cmdDown?.flags = .maskCommand
        let aUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false)
        aUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        aUp?.post(tap: .cghidEventTap)
    }

    /// Post a single Shift+Right keystroke. Used to extend the selection one
    /// character at a time in composers (Slack, Teams, Discord, …) that honour
    /// caret placement but ignore AX range selections for spans larger than a
    /// single DOM block.
    private func triggerShiftRightArrowKey() {
        // 0x7C is the right-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: true)
        down?.flags = .maskShift
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: false)
        up?.flags = .maskShift
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Left arrow. Moves the caret one character to the left.
    private func triggerLeftArrowKey() {
        // 0x7B is the left-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Shift+Left. Extends the current selection one character to the left.
    private func triggerShiftLeftArrowKey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: true)
        down?.flags = .maskShift
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: false)
        up?.flags = .maskShift
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func triggerCmdLeftArrowKey() {
        // 0x7B is the left-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func triggerCmdRightArrowKey() {
        // 0x7C is the right-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Cmd+Down. Standard macOS "move caret to end of document" shortcut.
    /// Used by `applyCaretAnchoredKeystrokeRangePaste` to reliably anchor
    /// the caret in Electron composers that refuse to honour AX caret
    /// placement at an absolute offset.
    private func triggerCmdDownArrowKey() {
        // 0x7D is the down-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7D, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7D, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func triggerCmdUpArrowKey() {
        // 0x7E is the up-arrow virtual key.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x7E, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x7E, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

}

// MARK: - Word-level diff engine (used by diff-based replacement above)

private enum WordDiff {
    struct TextChange {
        let range: NSRange
        let replacement: String
    }

    struct Token {
        let text: String
        let range: NSRange
    }

    static func changes(original: String, corrected: String) -> [TextChange] {
        let origTokens = tokenize(original)
        let corrTokens = tokenize(corrected)

        let matched = lcsIndices(origTokens.map(\.text), corrTokens.map(\.text))

        let anchors: [(oi: Int, ci: Int)] =
            [(-1, -1)] + matched + [(origTokens.count, corrTokens.count)]

        let origNS = original as NSString
        let corrNS = corrected as NSString
        var result: [TextChange] = []

        for k in 0..<(anchors.count - 1) {
            let prev = anchors[k]
            let next = anchors[k + 1]

            let oGapStart = prev.oi + 1
            let oGapEnd   = next.oi
            let cGapStart = prev.ci + 1
            let cGapEnd   = next.ci

            if oGapStart == oGapEnd && cGapStart == cGapEnd { continue }

            let origFrom = prev.oi >= 0
                ? origTokens[prev.oi].range.location + origTokens[prev.oi].range.length
                : 0
            let origTo = next.oi < origTokens.count
                ? origTokens[next.oi].range.location
                : origNS.length

            let corrFrom = prev.ci >= 0
                ? corrTokens[prev.ci].range.location + corrTokens[prev.ci].range.length
                : 0
            let corrTo = next.ci < corrTokens.count
                ? corrTokens[next.ci].range.location
                : corrNS.length

            let range = NSRange(location: origFrom, length: origTo - origFrom)
            let replacement = corrNS.substring(with: NSRange(location: corrFrom, length: corrTo - corrFrom))

            if origNS.substring(with: range) == replacement { continue }

            result.append(TextChange(range: range, replacement: replacement))
        }

        return result
    }

    // MARK: Tokenization

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        var i = 0
        while i < ns.length {
            while i < ns.length {
                let ch = ns.character(at: i)
                guard let scalar = UnicodeScalar(ch),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                    break
                }
                i += 1
            }
            guard i < ns.length else { break }
            let start = i
            while i < ns.length {
                let ch = ns.character(at: i)
                if let scalar = UnicodeScalar(ch),
                   CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    break
                }
                i += 1
            }
            let word = ns.substring(with: NSRange(location: start, length: i - start))
            tokens.append(Token(text: word, range: NSRange(location: start, length: i - start)))
        }
        return tokens
    }

    // MARK: LCS (Longest Common Subsequence)

    static func lcsIndices(_ a: [String], _ b: [String]) -> [(oi: Int, ci: Int)] {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var pairs: [(oi: Int, ci: Int)] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                pairs.append((oi: i - 1, ci: j - 1))
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
