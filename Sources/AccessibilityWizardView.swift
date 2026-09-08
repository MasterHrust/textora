import SwiftUI
import AppKit

// MARK: - Accessibility Wizard (branded pop-up when AX permission is missing)

struct AccessibilityWizardView: View {
    let onRequestAccessibility: () -> Void
    let onOpenSettings: () -> Void

    private static let titleFont = Font.system(size: 22, weight: .semibold, design: .rounded)
    private static let bodyFont = Font.system(size: 14, weight: .regular, design: .default)
    private static let buttonFont = Font.system(size: 13, weight: .medium, design: .rounded)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accessibility Permission")
                .font(Self.titleFont)
                .foregroundStyle(.primary)

            Text(
                "Textora needs Accessibility permission to read selected text and replace text in input fields across apps."
            )
            .font(Self.bodyFont)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Grant this permission to enable rewriting and one-click apply.")
                .font(Self.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Settings Directly") {
                    onOpenSettings()
                }
                Spacer()
                Button {
                    onRequestAccessibility()
                } label: {
                    Text("Request Access")
                        .font(Self.buttonFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
