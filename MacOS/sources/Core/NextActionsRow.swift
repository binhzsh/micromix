import SwiftUI

/// "NEXT ACTIONS" chaining row shown on a result screen once a job completes.
/// Operates on the newest result and routes through the WorkflowRouter, mirroring
/// the per-asset actions in the Library inspector.
struct NextActionsRow: View {
    let router: WorkflowRouter
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 7) {
            Typography.monoLabel("NEXT ACTIONS", size: 9)
                .foregroundColor(Palette.ink.opacity(0.64))
            ForEach(router.availableActions(for: item)) { action in
                Button {
                    router.execute(action, on: item)
                } label: {
                    Typography.monoLabel(action.label, size: 9)
                        .foregroundColor(Self.color(for: action))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Self.color(for: action), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.label) the result")
            }
            Spacer(minLength: 0)
        }
    }

    static func color(for action: AssetAction) -> Color {
        switch action {
        case .referenceGenerate, .remix, .repaint: return Palette.accentOrange
        case .stemSplit, .transcribe, .analyze: return Palette.accentBlue
        case .vocalSwap: return Palette.accentGreen
        }
    }
}
