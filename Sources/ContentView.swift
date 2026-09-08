import AppKit
import Carbon
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    private let bundleIDTextWidth: CGFloat = 210
    private let actionPickerWidth: CGFloat = 140
    private let donateURL = "https://paypal.me/RShytskou"

    var body: some View {
        ScrollView {
            settingsContent
        }
        .frame(width: 520, height: 520)
        .onAppear {
            viewModel.refreshAccessibilityPermissionStatus()
            viewModel.refreshAppConsents()
            Task { await viewModel.refreshAvailableModels() }
        }
        .onChange(of: viewModel.settingsAutosaveToken) { _, _ in
            viewModel.debouncedSave()
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerSection
            Divider().padding(.vertical, 4)
            interfaceSection
            Button("Save settings") {
                viewModel.saveSettings()
            }
            Divider().padding(.vertical, 4)
            donateSection
            Divider().padding(.vertical, 4)
            appPermissionsSection
        }
        .padding(12)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.headline)
            Text("Textora is free and works with your own AI key")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Select text to open the Textora toolbar with Fix, Shorten, Formal, Humanize, and Translate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: $viewModel.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            modelSelectionControl
            Text("Leave empty to let Textora use the recommended model for the selected provider.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            credentialFields
            providerSetupHelp
        }
    }

    @ViewBuilder
    private var modelSelectionControl: some View {
        if viewModel.provider == .other {
            TextField("Model", text: $viewModel.model)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Picker("Model", selection: $viewModel.model) {
                        Text("Auto (\(viewModel.recommendedModel))").tag("")
                        ForEach(viewModel.modelPickerOptions) { option in
                            Text(option.pickerLabel).tag(option.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await viewModel.refreshAvailableModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh available models")
                    .disabled(viewModel.isLoadingModels || !viewModel.hasCurrentProviderAPIKey)

                    if viewModel.isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if !viewModel.modelCatalogError.isEmpty {
                    Text(viewModel.modelCatalogError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interface")
                .font(.headline)
            Text("Choose one visual interface, add Hotkeys to it, or use Hotkeys on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
            InterfaceModeCards(
                toolboxEnabled: settingsModeBinding(.toolbox),
                floatingIconEnabled: settingsModeBinding(.floatingIcon),
                hotKeysEnabled: settingsModeBinding(.hotKeys),
                compact: true
            )

            HStack(spacing: 12) {
                Picker("Rewrite profile", selection: $viewModel.operation) {
                    ForEach(RewriteOperation.allCases) { operation in
                        Text(operation.rawValue).tag(operation)
                    }
                }
                Picker("Translation language", selection: $viewModel.translationLanguage) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text("\(language.flag) \(language.displayName)").tag(language)
                    }
                }
            }

            if viewModel.hotKeysModeEnabled {
                VStack(alignment: .leading, spacing: 7) {
                    HotKeySettingRow(title: "Rewrite selected text", hotKey: $viewModel.rewriteHotKey)
                    HotKeySettingRow(title: "Translate selected text", hotKey: $viewModel.translateHotKey)
                }
                if let error = GlobalHotKeyManager.shared.registrationError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func settingsModeBinding(_ mode: AppViewModel.OnboardingInterfaceMode) -> Binding<Bool> {
        Binding(
            get: {
                switch mode {
                case .toolbox: return viewModel.toolboxEnabled
                case .floatingIcon: return viewModel.floatingIconEnabled
                case .hotKeys: return viewModel.hotKeysModeEnabled
                }
            },
            set: { viewModel.setInterfaceMode(mode, enabled: $0) }
        )
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch viewModel.provider {
        case .openai:
            SecureField("GPT API key", text: $viewModel.openAIKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .gemini:
            SecureField("Gemini API key", text: $viewModel.geminiKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .claude:
            SecureField("Claude API key", text: $viewModel.claudeKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .other:
            TextField("API base URL (OpenAI-compatible)", text: $viewModel.customOpenAIBaseURL)
                .textContentType(.URL)
                .frame(maxWidth: .infinity, alignment: .leading)
            SecureField("API token", text: $viewModel.customToken)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Permissions")
                .font(.headline)
            Text("Manage apps you previously allowed/denied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            accessibilityRow
            appConsentRows
            HStack {
                Button("Refresh list") {
                    viewModel.refreshAppConsents()
                }
                Spacer()
            }
        }
    }

    private var accessibilityRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.hasAccessibilityPermission ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.hasAccessibilityPermission
                 ? "Accessibility granted"
                 : "Accessibility is required for the selection toolbar and text replacement")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.hasAccessibilityPermission {
                Button("Allow Accessibility") {
                    viewModel.requestAccessibilityPermission()
                }
            } else {
                Button("Re-check") {
                    viewModel.refreshAccessibilityPermissionStatus()
                }
            }
        }
    }

    @ViewBuilder
    private var appConsentRows: some View {
        if viewModel.appConsentRows.isEmpty {
            Text("No app decisions yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(viewModel.appConsentRows) { row in
                HStack(alignment: .center, spacing: 10) {
                    Text(row.bundleID)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: bundleIDTextWidth, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { row.status },
                        set: { newStatus in
                            viewModel.setConsentStatus(for: row.bundleID, status: newStatus)
                        }
                    )) {
                        Text("Allow").tag(TextAccessService.AppConsentStatus.allowed)
                        Text("Deny").tag(TextAccessService.AppConsentStatus.denied)
                        Text("Ask").tag(TextAccessService.AppConsentStatus.unknown)
                    }
                    .labelsHidden()
                    .frame(width: actionPickerWidth)
                    Button("Reset") {
                        viewModel.removeConsent(for: row.bundleID)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var donateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Support project")
                .font(.headline)
            Text("Textora is free and open-source. If it helps you, you can support development with a donation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Donate") {
                guard let url = URL(string: donateURL) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    @ViewBuilder
    private var providerSetupHelp: some View {
        switch viewModel.provider {
        case .openai:
            Link("Get GPT API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.caption)
        case .gemini:
            Link("Get Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                .font(.caption)
        case .claude:
            Link("Get Claude API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
        case .other:
            Link("OpenAI-compatible API docs", destination: URL(string: "https://platform.openai.com/docs/api-reference/chat/create")!)
                .font(.caption)
        }
    }
}

private struct HotKeySettingRow: View {
    let title: String
    @Binding var hotKey: TextoraHotKey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { hotKey.isEnabled },
                set: { hotKey.isEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            Spacer()
            Button(isRecording ? "Press shortcut…" : hotKey.displayName) {
                beginRecording()
            }
            .frame(minWidth: 112)
            .disabled(!hotKey.isEnabled)
        }
        .onDisappear { stopRecording() }
    }

    private func beginRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                NSSound.beep()
                return nil
            }
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            hotKey = TextoraHotKey(keyCode: UInt32(event.keyCode), modifiers: carbon, isEnabled: true)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

private struct InterfaceModeCards: View {
    @Binding var toolboxEnabled: Bool
    @Binding var floatingIconEnabled: Bool
    var hotKeysEnabled: Binding<Bool>? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            InterfaceModeCard(
                title: "Toolbox",
                subtitle: compact ? "Panel above selection" : "A focused toolbar above selected text with Fix, Formal, Humanize, and Translate.",
                isOn: $toolboxEnabled,
                accent: Color(red: 0.27, green: 0.73, blue: 1.0),
                preview: .toolbox,
                compact: compact
            )
            InterfaceModeCard(
                title: "Floating icon",
                subtitle: compact ? "Classic marker" : "The classic Textora marker near editable fields, with a pop-up for quick corrections.",
                isOn: $floatingIconEnabled,
                accent: Color(red: 0.89, green: 0.24, blue: 0.93),
                preview: .floating,
                compact: compact
            )
            if let hotKeysEnabled {
                InterfaceModeCard(
                    title: "Hotkeys",
                    subtitle: compact ? "Rewrite and Translate with global shortcuts" : "Run Rewrite or Translate only when you press a global shortcut.",
                    isOn: hotKeysEnabled,
                    accent: Color(red: 0.30, green: 0.78, blue: 0.62),
                    preview: .hotkeys,
                    compact: compact
                )
            }
        }
    }
}

private struct InterfaceModeCard: View {
    enum PreviewKind {
        case toolbox
        case floating
        case hotkeys
    }

    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let accent: Color
    let preview: PreviewKind
    var compact = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: compact ? 12.5 : 14, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: compact ? 15 : 17, weight: .semibold))
                        .foregroundStyle(isOn ? accent : Color.white.opacity(0.38))
                }
                modePreview
                    .frame(height: compact ? 54 : 72)
                Text(subtitle)
                    .font(.system(size: compact ? 10.5 : 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(compact ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(cardStroke)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modePreview: some View {
        switch preview {
        case .toolbox:
            toolboxPreview
        case .floating:
            floatingPreview
        case .hotkeys:
            hotKeysPreview
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isOn ? 0.11 : 0.055),
                        accent.opacity(isOn ? 0.16 : 0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isOn ? accent.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1)
    }

    private var toolboxPreview: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.25, green: 0.72, blue: 1.0), Color(red: 0.90, green: 0.20, blue: 0.92)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 14, height: 14)
                previewPill("Fix", color: Color(red: 0.25, green: 0.72, blue: 1.0))
                previewPill("Formal", color: Color(red: 0.66, green: 0.29, blue: 1.0))
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                previewTextBox(label: "Before", color: Color.white.opacity(0.52), lineColor: Color.white.opacity(0.42))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.32))
                previewTextBox(label: "After", color: Color(red: 0.25, green: 0.72, blue: 1.0), lineColor: Color(red: 0.25, green: 0.84, blue: 0.34))
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
    }

    private var floatingPreview: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 30, height: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.58))
                            .frame(width: 66, height: 5)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.34))
                            .frame(width: 42, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    previewPill("SmartAI", color: Color(red: 0.67, green: 0.32, blue: 1.0))
                    previewPill("Fix", color: Color(red: 0.25, green: 0.84, blue: 0.34))
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.black.opacity(0.26))
            )
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.25, green: 0.72, blue: 1.0), Color(red: 0.90, green: 0.20, blue: 0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
                .overlay(Image(systemName: "wand.and.stars").font(.system(size: compact ? 9 : 10, weight: .bold)).foregroundStyle(.white))
                .shadow(color: accent.opacity(0.45), radius: 9, x: 0, y: 0)
                .offset(x: 5, y: 5)
        }
    }

    private var hotKeysPreview: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                hotKeyPreviewKey("⌥⌘R")
                Text("Rewrite")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                hotKeyPreviewKey("⌥⌘T")
                Text("Translate")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
    }

    private func hotKeyPreviewKey(_ title: String) -> some View {
        Text(title)
            .font(.system(size: compact ? 8 : 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: compact ? 20 : 23)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }

    private func previewPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: compact ? 7.5 : 8.5, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func previewTextBox(label: String, color: Color, lineColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: compact ? 7 : 8, weight: .heavy))
                .foregroundStyle(color)
            RoundedRectangle(cornerRadius: 2)
                .fill(lineColor)
                .frame(height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.24))
                .frame(width: compact ? 44 : 54, height: 4)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }
}

struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onFinish: () -> Void
    
    private enum Theme {
        static let bg = Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
        static let cardBg = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
        static let border = Color.white.opacity(0.12)
        static let muted = Color.white.opacity(0.65)
        static let accentStart = Color(red: 62 / 255, green: 123 / 255, blue: 1)
        static let accentEnd = Color(red: 151 / 255, green: 71 / 255, blue: 1)
        static let success = Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch viewModel.onboardingStep {
            case 1:
                Text("Textora helps you fix and improve text in any app, including email, chats, documents, and browsers.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                Text("Before you start, add your API key. The setup wizard will guide you step by step.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            case 2:
                Text("Choose an AI provider and add your key. GPT is selected by default.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                Picker("Provider", selection: $viewModel.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case 3:
                Text("Add your key and verify the connection.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                onboardingCredentialFields
                if !viewModel.onboardingErrorText.isEmpty {
                    Text(viewModel.onboardingErrorText)
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.95))
                }
            case 4:
                Text("Choose how Textora should appear when you write.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                Text("Choose Toolbox, the classic Floating icon, or run Textora only with keyboard shortcuts.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                InterfaceModeCards(
                    toolboxEnabled: onboardingModeBinding(.toolbox),
                    floatingIconEnabled: onboardingModeBinding(.floatingIcon),
                    hotKeysEnabled: onboardingModeBinding(.hotKeys),
                    compact: false
                )
                if viewModel.onboardingInterfaceMode == .hotKeys {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Choose your shortcuts")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        HotKeySettingRow(title: "Rewrite selected text", hotKey: $viewModel.rewriteHotKey)
                        HotKeySettingRow(title: "Translate selected text", hotKey: $viewModel.translateHotKey)
                        Text("Suggested: ⌥⌘R for Rewrite and ⌥⌘T for Translate")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                if !viewModel.hasValidOnboardingInterfaceSelection {
                    Text("Enable at least one shortcut to continue.")
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.95))
                }
            default:
                Text("Done. Next, Accessibility will open to complete setup.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }

            Divider()

            HStack(spacing: 8) {
                if viewModel.onboardingStep > 1 && viewModel.onboardingStep < 5 {
                    Button("Back") {
                        viewModel.moveOnboardingBack()
                    }
                }
                if viewModel.onboardingStep < 3 {
                    Button(viewModel.onboardingStep == 1 ? "Start" : "Continue") {
                        viewModel.moveOnboardingNext()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else if viewModel.onboardingStep == 3 {
                    Button(viewModel.isOnboardingBusy ? "Connecting..." : "Continue") {
                        Task {
                            let valid = await viewModel.validateCurrentProviderSetup()
                            if valid {
                                viewModel.moveOnboardingNext()
                            }
                        }
                    }
                    .disabled(viewModel.isOnboardingBusy)
                    .buttonStyle(PrimaryButtonStyle())
                } else if viewModel.onboardingStep == 4 {
                    Button("Continue") {
                        viewModel.moveOnboardingNext()
                    }
                    .disabled(!viewModel.hasValidOnboardingInterfaceSelection)
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Finish") {
                        onFinish()
                    }
                    .buttonStyle(SuccessButtonStyle())
                    Button("Open advanced settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                if viewModel.onboardingStep < 5 {
                    Button("Skip for now") {
                        viewModel.skipOnboardingForNow()
                        onClose()
                    }
                    .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .background(popupBackground)
        .preferredColorScheme(.dark)
    }

    private func onboardingModeBinding(_ mode: AppViewModel.OnboardingInterfaceMode) -> Binding<Bool> {
        Binding(
            get: { viewModel.onboardingInterfaceMode == mode },
            set: { selected in
                guard selected else { return }
                viewModel.selectOnboardingInterfaceMode(mode)
            }
        )
    }
    
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Textora Quick setup")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("Step \(viewModel.onboardingStep) of 5")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            stepBadge
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }
    
    private var stepBadge: some View {
        Text("\(viewModel.onboardingStep)/5")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                LinearGradient(
                    colors: [Theme.accentStart, Theme.accentEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }
    
    private var popupBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.bg.opacity(0.92))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
    }

    @ViewBuilder
    private var onboardingCredentialFields: some View {
        if viewModel.provider == .other {
            Text("1. Add API details")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            Text("1. Paste your API key")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }

        switch viewModel.provider {
        case .openai:
            SecureField("GPT API key", text: $viewModel.openAIKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get GPT API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.caption)
                .foregroundStyle(.blue)
        case .gemini:
            SecureField("Gemini API key", text: $viewModel.geminiKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                .font(.caption)
                .foregroundStyle(.teal)
        case .claude:
            SecureField("Claude API key", text: $viewModel.claudeKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get Claude API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .other:
            TextField("API base URL (OpenAI-compatible)", text: $viewModel.customOpenAIBaseURL)
                .textContentType(.URL)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            SecureField("API token", text: $viewModel.customToken)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
        }

        if viewModel.provider == .other {
            Text("2. Enter the model name")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            TextField("Model", text: $viewModel.model)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
        } else {
            Text("2. Check available models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.refreshAvailableModels() }
                } label: {
                    Label(
                        viewModel.isLoadingModels ? "Checking..." : "Check key and load models",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isLoadingModels || !viewModel.hasCurrentProviderAPIKey)
                .buttonStyle(SecondaryButtonStyle())

                if viewModel.isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                } else if !viewModel.availableModels.isEmpty {
                    Label("\(viewModel.availableModels.count) available", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                }
                Spacer()
            }
            if !viewModel.modelCatalogError.isEmpty {
                Text(viewModel.modelCatalogError)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }

            Text("3. Choose a model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Picker("Model", selection: $viewModel.model) {
                Text("Auto (\(viewModel.recommendedModel))").tag("")
                ForEach(viewModel.modelPickerOptions) { option in
                    Text(option.pickerLabel).tag(option.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(viewModel.availableModels.isEmpty)
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 62 / 255, green: 123 / 255, blue: 1),
                        Color(red: 151 / 255, green: 71 / 255, blue: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(configuration.isPressed ? 0.88 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SuccessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255)
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}
