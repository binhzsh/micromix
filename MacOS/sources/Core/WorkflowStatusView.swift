import SwiftUI

/// Presents only the client lifecycle; it does not imply a server queue or model progress.
struct WorkflowStatusView: View {
    let status: JobStatus
    let elapsed: TimeInterval

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Work in progress; progress unavailable")
                Text("Working · \(Int(max(0, elapsed)))s elapsed · progress unavailable")
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        case .done:
            Text("Completed")
                .font(.caption)
        case .cancelled:
            Text("Stopped locally. Server cancellation may still be pending.")
                .font(.caption)
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Palette.textRed)
                .textSelection(.enabled)
        }
    }
}

extension TranscribeViewModel.Phase {
    var workflowStatus: JobStatus {
        switch self {
        case .idle: .idle
        case .running: .running
        case .done: .done
        case .cancelled: .cancelled
        case .error(let message): .error(message)
        }
    }
}

extension JobStatus {
    var offersRetry: Bool {
        switch self {
        case .cancelled, .error: true
        case .idle, .running, .done: false
        }
    }
}
