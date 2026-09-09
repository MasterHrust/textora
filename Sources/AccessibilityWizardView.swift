import SwiftUI
import AppKit

// MARK: - Accessibility Wizard (branded pop-up when AX permission is missing)

struct AccessibilityWizardView: View {
    let onOpenAccessibility: () -> Void

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

            if !isRunningFromApplications {
                Label(
                    "Move Textora to the Applications folder and launch it from there before granting access.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Self.bodyFont.weight(.semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("If Textora is already enabled but this window stays open:")
                    .font(Self.bodyFont.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Remove the old Textora entry with the minus button, add the current Textora from Applications with the plus button, then enable it.")
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    onOpenAccessibility()
                } label: {
                    Label("Open Accessibility", systemImage: "gearshape.fill")
                        .font(Self.buttonFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isRunningFromApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }
}
