import Foundation

/// Reads optional local Git metadata without coupling WarrenApplication to a
/// particular command executor. The production default is intentionally
/// conservative; adding a project never fails merely because Git metadata is
/// unavailable.
public protocol GitMetadataReader: Sendable {
    func branch(at path: String) async -> String?
}

public struct NoopGitMetadataReader: GitMetadataReader {
    public init() {}

    public func branch(at path: String) async -> String? { nil }
}
