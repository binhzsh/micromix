import Foundation

/// Lifecycle state of a single long-running client job.
enum JobStatus: Equatable, Sendable {
    case idle
    case running
    case done
    case error(String)
    case cancelled
}
