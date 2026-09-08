import AppKit
import SwiftUI

struct SelectionToolbarView: View {
    @ObservedObject var viewModel: SelectionAssistantViewModel
    let onApply: () -> Void
    let onTranslationCopied: () -> Void
    let onClose: () -> Void

    @State private var isLogoHovering = false
    @State private var isHotKeyPickerExpanded = false

    private let panelWidth: CGFloat = 680
    static let hotKeyPanelWidth: CGFloat = 510
    static let tooltipTopReserve: CGFloat = 0

    static func hotKeyPanelHeight(for viewModel: SelectionAssistantViewModel) -> CGFloat {
        let resultText = viewModel.presentationMode == .hotKeyTranslate
            ? viewModel.translatedText
            : viewModel.rewrittenText
        return hotKeyPanelHeight(originalText: viewModel.originalText, resultText: resultText)
    }

    static func hotKeyPanelHeight(originalText: String, resultText: String) -> CGFloat {
        let textWidth = hotKeyPanelWidth - 64
        let originalHeight = hotKeyCardHeight(
            text: originalText,
            font: .systemFont(ofSize: 13.5),
            width: textWidth,
            minimum: 62,
            maximum: 126
        )
        let resultHeight = hotKeyCardHeight(
            text: resultText,
            font: .systemFont(ofSize: 15.5, weight: .semibold),
            width: textWidth,
            minimum: 80,
            maximum: 230
        )
        return min(max(147 + originalHeight + resultHeight, 292), 535)
    }

    private static func hotKeyCardHeight(
        text: String,
        font: NSFont,
        width: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return minimum }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(max(ceil(bounds.height) + 48, minimum), maximum)
    }

    var body: some View {
        if viewModel.presentationMode == .standard {
            standardPanel
        } else {
            hotKeyPanel
        }
    }

    private var standardPanel: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 7) {
                topRow

                if viewModel.isLanguagePickerExpanded {
                    compactLanguageDropdown
                } else if viewModel.hasTranslationContent {
                    translationPanel
                } else if viewModel.hasRewritePreview {
                    rewritePreviewPanel
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
            .background(panelBackground)
            .overlay(panelStroke)
            .shadow(color: Color(red: 0.36, green: 0.67, blue: 1.0).opacity(0.10), radius: 22, x: 0, y: 0)
            .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 14)
            .offset(y: Self.tooltipTopReserve)

        }
        .frame(width: panelWidth, height: panelHeight + Self.tooltipTopReserve, alignment: .topLeading)
    }

    private var hotKeyPanel: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                hotKeyHeader

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    hotKeyOriginalCard
                        .frame(height: hotKeyOriginalCardHeight)

                    hotKeyResultCard
                        .frame(height: hotKeyResultCardHeight)

                    hotKeyAction
                }
                .padding(14)
            }

            if isHotKeyPickerExpanded {
                hotKeyPickerDropdown
                    .padding(.top, 50)
                    .padding(.trailing, 58)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    .zIndex(20)
            }
        }
        .frame(
            width: Self.hotKeyPanelWidth,
            height: Self.hotKeyPanelHeight(for: viewModel),
            alignment: .topLeading
        )
        .background(hotKeyBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(red: 0.35, green: 0.46, blue: 1.0).opacity(0.12), radius: 26, x: 0, y: 0)
        .shadow(color: .black.opacity(0.52), radius: 24, x: 0, y: 14)
    }

    private var hotKeyHeader: some View {
        ZStack(alignment: .top) {
            SelectionWindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Capsule()
                .fill(Color.white.opacity(0.20))
                .frame(width: 30, height: 3)
                .padding(.top, 5)
                .allowsHitTesting(false)

            HStack(spacing: 12) {
                hotKeyLogo

                Text(viewModel.presentationMode == .hotKeyTranslate ? "Translate" : "Rewrite")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Spacer(minLength: 12)

                hotKeyHeaderPicker

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
        .frame(height: 58)
    }

    private var hotKeyHeaderPicker: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                isHotKeyPickerExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                if viewModel.presentationMode == .hotKeyTranslate {
                    Text(viewModel.translationLanguage.flag)
                        .font(.system(size: 15))
                        .frame(width: 18)
                    Text(viewModel.translationLanguage.displayName)
                        .font(.system(size: 12.5, weight: .bold))
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 18)
                    Text(viewModel.operation.rawValue)
                        .font(.system(size: 12.5, weight: .heavy))
                }
                Spacer(minLength: 3)
                Image(systemName: isHotKeyPickerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 10)
                    .fixedSize()
            }
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 12)
            .frame(width: 138, height: 34)
            .background(hotKeyBadgeBackground)
            .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(viewModel.presentationMode == .hotKeyTranslate ? "Translation language" : "Rewrite profile")
    }

    private var hotKeyPickerDropdown: some View {
        ScrollView {
            VStack(spacing: 3) {
                if viewModel.presentationMode == .hotKeyTranslate {
                    ForEach(TranslationLanguage.allCases) { language in
                        hotKeyPickerRow(
                            icon: language.flag,
                            title: language.displayName,
                            isSelected: language == viewModel.translationLanguage
                        ) {
                            isHotKeyPickerExpanded = false
                            viewModel.translationLanguage = language
                            viewModel.translate()
                        }
                    }
                } else {
                    ForEach(RewriteOperation.allCases) { operation in
                        hotKeyPickerRow(
                            icon: "✦",
                            title: operation.rawValue,
                            isSelected: operation == viewModel.operation
                        ) {
                            isHotKeyPickerExpanded = false
                            viewModel.operation = operation
                        }
                    }
                }
            }
            .padding(5)
        }
        .frame(width: 168)
        .frame(maxHeight: viewModel.presentationMode == .hotKeyTranslate ? 222 : 166)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.10, green: 0.105, blue: 0.125).opacity(0.99))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.17), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.48), radius: 16, x: 0, y: 8)
    }

    private func hotKeyPickerRow(
        icon: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(icon)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .opacity(isSelected ? 1 : 0)
            }
            .foregroundStyle(isSelected ? .white : Color.white.opacity(0.76))
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hotKeyLogo: some View {
        Group {
            if let image = NSImage(named: "helper-icon") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.92))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var hotKeyOriginalCard: some View {
        hotKeyCard(title: viewModel.presentationMode == .hotKeyTranslate ? "Original" : "Before") {
            ScrollView {
                Text(viewModel.originalText)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.66))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var hotKeyResultCard: some View {
        hotKeyCard(
            title: viewModel.presentationMode == .hotKeyTranslate ? "Translation" : "After",
            titleColor: Color(red: 0.42, green: 0.62, blue: 1.0)
        ) {
            Group {
                if viewModel.presentationMode == .hotKeyTranslate {
                    switch viewModel.translationStatus {
                    case .idle, .translating:
                        hotKeyProgress("Translating...")
                    case .ready:
                        hotKeyResultText(AttributedString(viewModel.translatedText))
                    case .error(let message):
                        hotKeyError(message)
                    }
                } else {
                    switch viewModel.status {
                    case .idle, .waiting, .checking:
                        hotKeyProgress("Improving...")
                    case .ready:
                        hotKeyResultText(highlightedAfterText(fontSize: 15.5))
                    case .noChanges:
                        hotKeyResultText(AttributedString("No changes needed."))
                    case .applying:
                        hotKeyProgress("Applying...")
                    case .error(let message):
                        hotKeyError(message)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func hotKeyCard<Content: View>(
        title: String,
        titleColor: Color = Color.white.opacity(0.56),
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                Text(title)
                .font(.system(size: 11.5, weight: .heavy))
                .foregroundStyle(titleColor)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func hotKeyResultText(_ text: AttributedString) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hotKeyAction: some View {
        HStack {
            Spacer(minLength: 0)
            if viewModel.presentationMode == .hotKeyTranslate {
                Button {
                    if viewModel.copyTranslation() { onTranslationCopied() }
                } label: {
                    hotKeyActionLabel("Copy", systemImage: "doc.on.doc")
                }
                .disabled(viewModel.translationStatus != .ready)
                .buttonStyle(.plain)
                .frame(width: 154, height: 42)
            } else {
                Button(action: onApply) {
                    hotKeyActionLabel("Apply", systemImage: "checkmark")
                }
                .disabled(!viewModel.canApply)
                .buttonStyle(.plain)
                .frame(width: 154, height: 42)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
    }

    private func hotKeyActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(.white.opacity(hotKeyActionEnabled ? 1 : 0.48))
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
            .background(hotKeyActionBackground)
            .overlay(Capsule().stroke(Color.white.opacity(hotKeyActionEnabled ? 0.30 : 0.10), lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: hotKeyActionEnabled ? Color(red: 0.52, green: 0.32, blue: 1.0).opacity(0.30) : .clear, radius: 12)
    }

    private var hotKeyActionEnabled: Bool {
        viewModel.presentationMode == .hotKeyTranslate
            ? viewModel.translationStatus == .ready
            : viewModel.canApply
    }

    private var hotKeyActionBackground: some View {
        Capsule()
            .fill(
                hotKeyActionEnabled
                    ? LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.68, blue: 1.0),
                            Color(red: 0.43, green: 0.36, blue: 1.0),
                            Color(red: 0.91, green: 0.21, blue: 0.84)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    : LinearGradient(
                        colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
            )
    }

    private var hotKeyBadgeBackground: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.07)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private var hotKeyBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.075, green: 0.08, blue: 0.10).opacity(0.99),
                        Color(red: 0.105, green: 0.105, blue: 0.125).opacity(0.99)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var hotKeyOriginalCardHeight: CGFloat {
        Self.hotKeyCardHeight(
            text: viewModel.originalText,
            font: .systemFont(ofSize: 13.5),
            width: Self.hotKeyPanelWidth - 64,
            minimum: 62,
            maximum: 126
        )
    }

    private var hotKeyResultCardHeight: CGFloat {
        let text = viewModel.presentationMode == .hotKeyTranslate
            ? viewModel.translatedText
            : viewModel.rewrittenText
        return Self.hotKeyCardHeight(
            text: text,
            font: .systemFont(ofSize: 15.5, weight: .semibold),
            width: Self.hotKeyPanelWidth - 64,
            minimum: 80,
            maximum: 230
        )
    }

    private func hotKeyProgress(_ title: String) -> some View {
        VStack(spacing: 13) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let duration = 1.8
                let phase = CGFloat(
                    context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration
                )

                GeometryReader { geometry in
                    let segmentWidth: CGFloat = 82
                    let travel = geometry.size.width + segmentWidth

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.075))

                        ForEach(0..<2, id: \.self) { index in
                            let segmentPhase = (phase + CGFloat(index) * 0.5)
                                .truncatingRemainder(dividingBy: 1)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.10, green: 0.70, blue: 1.0).opacity(0.25),
                                            Color(red: 0.20, green: 0.72, blue: 1.0),
                                            Color(red: 0.52, green: 0.36, blue: 1.0),
                                            Color(red: 0.92, green: 0.21, blue: 0.84),
                                            Color(red: 0.92, green: 0.21, blue: 0.84).opacity(0.20)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: segmentWidth)
                                .offset(x: travel * segmentPhase - segmentWidth)
                                .shadow(
                                    color: Color(red: 0.52, green: 0.35, blue: 1.0).opacity(0.58),
                                    radius: 7
                                )
                        }
                    }
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .frame(width: 190, height: 7)
            }

            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.25, green: 0.72, blue: 1.0),
                                Color(red: 0.88, green: 0.28, blue: 0.90)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func hotKeyError(_ message: String) -> some View {
        ScrollView {
            Text(message)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var topRow: some View {
        HStack(spacing: 7) {
            textoraLogo
                .frame(width: 42, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(RewriteOperation.allCases) { operation in
                    operationButton(operation)
                }
            }

            Button(action: onApply) {
                HStack(spacing: 6) {
                    statusIcon
                    Text(actionTitle)
                        .font(.system(size: 12.5, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(viewModel.canApply ? .white : Color.white.opacity(0.58))
                .padding(.horizontal, 10)
                .frame(width: 124, height: 31)
                .background(applyButtonBackground)
                .overlay(Capsule().stroke(Color.white.opacity(viewModel.canApply ? 0.30 : 0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canApply)

            toolbarDivider

            translationLanguagePickerButton

            Button {
                viewModel.translate()
            } label: {
                HStack(spacing: 6) {
                    translateStatusIcon
                    Text("Translate")
                        .font(.system(size: 12.5, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
                .foregroundStyle(viewModel.canTranslate ? .white : Color.white.opacity(0.54))
                .padding(.horizontal, 10)
                .frame(width: 102, height: 31)
                .background(Capsule().fill(Color.white.opacity(viewModel.canTranslate ? 0.11 : 0.055)))
                .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canTranslate)
        }
    }

    private var textoraLogo: some View {
        Group {
            if let image = NSImage(named: "helper-icon") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 31, height: 31)
            } else {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.24, green: 0.73, blue: 1.0),
                                Color(red: 0.88, green: 0.21, blue: 0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .scaleEffect(isLogoHovering ? 1.13 : 1.0)
        .padding(5)
        .background {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.66, blue: 1.0).opacity(isLogoHovering ? 0.26 : 0.0),
                                Color(red: 0.92, green: 0.20, blue: 0.94).opacity(isLogoHovering ? 0.24 : 0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .stroke(Color.white.opacity(isLogoHovering ? 0.28 : 0.0), lineWidth: 1)
            }
            .shadow(color: Color(red: 0.70, green: 0.34, blue: 1.0).opacity(isLogoHovering ? 0.34 : 0), radius: 12, x: 0, y: 0)
        }
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.64)) {
                isLogoHovering = hovering
            }
        }
        .help("Textora")
    }

    private func operationButton(_ operation: RewriteOperation) -> some View {
        let selected = viewModel.operation == operation
        let color = operationColor(operation)
        return Button {
            viewModel.operation = operation
        } label: {
            Text(operation.rawValue)
                .font(.system(size: 11.5, weight: .heavy))
                .foregroundStyle(selected ? .white : color.opacity(0.92))
                .lineLimit(1)
                .padding(.horizontal, operation == .humanize ? 6 : 7)
                .frame(height: 29)
                .background(
                    Capsule()
                        .fill(selected ? color.opacity(0.78) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(selected ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                )
                .shadow(color: selected ? color.opacity(0.22) : .clear, radius: 8, x: 0, y: 0)
        }
        .buttonStyle(.plain)
    }

    private var translationLanguagePickerButton: some View {
        Button {
            viewModel.isLanguagePickerExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.translationLanguage.flag)
                    .font(.system(size: 17))
                Image(systemName: viewModel.isLanguagePickerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(width: 50, height: 31)
            .background(Capsule().fill(Color.white.opacity(viewModel.isLanguagePickerExpanded ? 0.16 : 0.09)))
            .overlay(Capsule().stroke(Color.white.opacity(viewModel.isLanguagePickerExpanded ? 0.22 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var compactLanguageDropdown: some View {
        let columns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8)
        return LazyVGrid(columns: columns, alignment: .trailing, spacing: 6) {
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    viewModel.translationLanguage = language
                } label: {
                    Text(language.flag)
                        .font(.system(size: 19))
                        .frame(width: 36, height: 31)
                        .background(
                            Capsule()
                                .fill(language == viewModel.translationLanguage ? Color.white.opacity(0.17) : Color.white.opacity(0.055))
                        )
                        .overlay(
                            Capsule()
                                .stroke(language == viewModel.translationLanguage ? Color(red: 0.25, green: 0.69, blue: 1.0).opacity(0.70) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(language.displayName)
            }
        }
        .padding(6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.24))
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(viewModel.translationLanguage.flag)
                Text("Translation")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 0)
                if case .ready = viewModel.translationStatus {
                    Button {
                        if viewModel.copyTranslation() { onTranslationCopied() }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy translation")
                }
            }

            Group {
                switch viewModel.translationStatus {
                case .idle:
                    EmptyView()
                case .translating:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Translating")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                case .ready:
                    ScrollView {
                        Text(viewModel.translatedText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.90))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .error(let message):
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 98)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var rewritePreviewPanel: some View {
        HStack(spacing: 8) {
            rewritePreviewColumn(
                title: "Before",
                text: viewModel.originalText,
                tint: Color.white.opacity(0.58)
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.white.opacity(0.34))
                .frame(width: 16)
            rewritePreviewColumn(
                title: "After",
                text: viewModel.rewrittenText,
                tint: Color(red: 0.25, green: 0.72, blue: 1.0),
                highlightedText: highlightedAfterText()
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 98)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func rewritePreviewColumn(title: String, text: String, tint: Color, highlightedText: AttributedString? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundStyle(tint)
            ScrollView {
                Text(highlightedText ?? AttributedString(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.98),
                        Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.white.opacity(0.15), lineWidth: 1)
    }

    private var applyButtonBackground: some View {
        Capsule()
            .fill(
                viewModel.canApply
                ? LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.70, blue: 1.0),
                        Color(red: 0.42, green: 0.36, blue: 1.0),
                        Color(red: 0.90, green: 0.20, blue: 0.86)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                : LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private func operationColor(_ operation: RewriteOperation) -> Color {
        switch operation {
        case .fixGrammar:
            return Color(red: 0.12, green: 0.70, blue: 1.0)
        case .shorten:
            return Color(red: 1.0, green: 0.49, blue: 0.12)
        case .makeProfessional:
            return Color(red: 0.65, green: 0.35, blue: 1.0)
        case .humanize:
            return Color(red: 0.18, green: 0.78, blue: 0.68)
        }
    }

    private func highlightedAfterText(fontSize: CGFloat = 12.5) -> AttributedString {
        let text = viewModel.rewrittenText
        let ns = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88)
            ]
        )
        let success = NSColor(red: 40 / 255, green: 205 / 255, blue: 65 / 255, alpha: 1)
        let ranges = PreviewDiff.changedRangesInCorrected(original: viewModel.originalText, corrected: text)
        for range in ranges where range.location >= 0 && range.location + range.length <= ns.length {
            ns.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: success
                ],
                range: range
            )
        }
        return AttributedString(ns)
    }

    private var panelHeight: CGFloat {
        let baseHeight: CGFloat
        if viewModel.isLanguagePickerExpanded {
            baseHeight = 170
        } else if viewModel.hasTranslationContent {
            baseHeight = 164
        } else if viewModel.hasRewritePreview {
            baseHeight = 164
        } else {
            baseHeight = 50
        }
        return baseHeight
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
        case .checking, .waiting:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .ready:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .heavy))
        case .noChanges:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .applying:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .heavy))
        }
    }

    @ViewBuilder
    private var translateStatusIcon: some View {
        switch viewModel.translationStatus {
        case .translating:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .idle:
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .heavy))
        }
    }

    private var actionTitle: String {
        switch viewModel.status {
        case .checking, .waiting:
            return "Checking"
        case .ready, .idle:
            return "Let's Improve"
        case .noChanges:
            return "Ready"
        case .error:
            return "Retry"
        case .applying:
            return "Applying"
        }
    }
}

private struct SelectionWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct SelectionToolbarTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 220)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.42), radius: 12, x: 0, y: 7)
    }
}

private enum PreviewDiff {
    struct Token {
        let text: String
        let range: NSRange
    }

    static func changedRangesInCorrected(original: String, corrected: String) -> [NSRange] {
        let origTokens = tokenize(original)
        let corrTokens = tokenize(corrected)
        let matched = lcsIndices(origTokens.map(\.text), corrTokens.map(\.text))
        let anchors = [(-1, -1)] + matched + [(origTokens.count, corrTokens.count)]
        let corrNS = corrected as NSString
        var ranges: [NSRange] = []

        for index in 0..<(anchors.count - 1) {
            let prev = anchors[index]
            let next = anchors[index + 1]
            let originalGapStart = prev.0 + 1
            let originalGapEnd = next.0
            let correctedGapStart = prev.1 + 1
            let correctedGapEnd = next.1
            if originalGapStart == originalGapEnd && correctedGapStart == correctedGapEnd {
                continue
            }

            let correctedFrom = prev.1 >= 0
                ? corrTokens[prev.1].range.location + corrTokens[prev.1].range.length
                : 0
            let correctedTo = next.1 < corrTokens.count
                ? corrTokens[next.1].range.location
                : corrNS.length
            if correctedTo > correctedFrom {
                ranges.append(NSRange(location: correctedFrom, length: correctedTo - correctedFrom))
            }
        }

        return merge(ranges)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            while index < ns.length, !isTokenScalar(ns.character(at: index)) {
                index += 1
            }
            let start = index
            while index < ns.length, isTokenScalar(ns.character(at: index)) {
                index += 1
            }
            if index > start {
                let range = NSRange(location: start, length: index - start)
                tokens.append(Token(text: ns.substring(with: range).lowercased(), range: range))
            }
        }
        return tokens
    }

    private static func isTokenScalar(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
    }

    private static func lcsIndices(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0
        var j = 0
        var result: [(Int, Int)] = []
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            let lastEnd = last.location + last.length
            if range.location <= lastEnd {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(lastEnd, range.location + range.length) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
