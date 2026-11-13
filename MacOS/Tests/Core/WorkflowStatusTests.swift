import Testing
@testable import Micromix

@Suite struct WorkflowStatusTests {
    @Test func transcriptionPhasesPreserveStatusAndError() {
        #expect(TranscribeViewModel.Phase.idle.workflowStatus == .idle)
        #expect(TranscribeViewModel.Phase.running.workflowStatus == .running)
        #expect(TranscribeViewModel.Phase.done.workflowStatus == .done)
        #expect(TranscribeViewModel.Phase.cancelled.workflowStatus == .cancelled)
        #expect(TranscribeViewModel.Phase.error("failed").workflowStatus == .error("failed"))
    }

    @Test func retryIsOnlyOfferedForTerminalFailureOrCancellation() {
        #expect(!JobStatus.idle.offersRetry)
        #expect(!JobStatus.running.offersRetry)
        #expect(!JobStatus.done.offersRetry)
        #expect(JobStatus.cancelled.offersRetry)
        #expect(JobStatus.error("failed").offersRetry)
    }
}
