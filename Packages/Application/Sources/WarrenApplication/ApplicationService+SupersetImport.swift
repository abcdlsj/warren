import WarrenStateStore
import Foundation

extension WarrenApplicationService {
    public func previewSupersetImport(
        from databaseURL: URL,
        pathInspector: (any SupersetImportPathInspecting)? = nil
    ) async throws -> SupersetImportPreview {
        try requireReady()
        do {
            let source: SupersetImportSource
            if let pathInspector {
                source = try SupersetImportSource(
                    databaseURL: databaseURL,
                    pathInspector: pathInspector
                )
            } else {
                source = try SupersetImportSource(databaseURL: databaseURL)
            }
            return try await source.preview()
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "superset.import.preview")
            await publish()
            throw appError
        }
    }

    @discardableResult
    public func commitSupersetImport(
        _ preview: SupersetImportPreview
    ) async throws -> SupersetImportCommitResult {
        do {
            let result = try await withPersistenceMutation {
                try requireReady()
                guard let importer = repository as? any SupersetImportCommitting else {
                    throw WarrenApplicationError.repository(
                        "The configured Host store does not support Superset import."
                    )
                }
                let result = try await importer.importSuperset(preview, into: host.id)
                var loaded = try await repository.load()
                mergePendingSequences(into: &loaded)
                state = loaded
                return result
            }
            await publish()
            return result
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "superset.import.commit")
            await publish()
            throw appError
        }
    }
}
