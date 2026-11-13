import SwiftUI

/// "NEXT ACTIONS" chaining row shown on a result screen once a job completes.
/// Operates on the newest result and routes through the WorkflowRouter, mirroring
/// the per-asset actions in the Library inspector.
struct NextActionsRow: View {
    let router: WorkflowRouter
    let item: LibraryItem
    var resolveItem: (() -> LibraryItem?)? = nil
    var onUnavailable: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { actionContents }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 7) { actionContents }
        }
    }

    @ViewBuilder private var actionContents: some View {
        Typography.monoLabel("NEXT ACTIONS", size: 9)
            .foregroundColor(Palette.ink.opacity(0.64))
        ForEach(router.availableActions(for: item)) { action in
            Button {
                guard let target = resolveItem.map({ $0() }) ?? (resolveItem == nil ? item : nil) else {
                    onUnavailable?()
                    return
                }
                router.execute(action, on: target)
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
    }

    static func color(for action: AssetAction) -> Color {
        switch action {
        case .referenceGenerate, .remix, .repaint: return Palette.textOrange
        case .stemSplit, .transcribe, .analyze: return Palette.textBlue
        case .vocalSwap: return Palette.textGreen
        }
    }
}
