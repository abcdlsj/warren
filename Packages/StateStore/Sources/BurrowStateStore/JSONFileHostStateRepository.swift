import Foundation

/// A versioned JSON repository using a caller-injected URL.
public actor JSONFileHostStateRepository: HostStateRepository {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async throws -> PersistedHostState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if isMissingFile(error) {
                return .empty
            }
            throw HostStateRepositoryError.readFailed(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }

        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(SchemaEnvelope.self, from: data).schemaVersion
        } catch {
            throw HostStateRepositoryError.corruptedJSON(reason: String(describing: error))
        }
        guard version >= 1,
              version <= PersistedHostState.currentSchemaVersion else {
            throw HostStateRepositoryError.unsupportedSchemaVersion(
                found: version,
                supported: PersistedHostState.currentSchemaVersion
            )
        }

        do {
            let state = try decoder.decode(PersistedHostState.self, from: data)
            try HostStateRepositoryError.validateSupportedSchema(state)
            return state
        } catch let error as HostStateRepositoryError {
            throw error
        } catch {
            throw HostStateRepositoryError.corruptedJSON(reason: String(describing: error))
        }
    }

    public func save(_ state: PersistedHostState) async throws {
        try HostStateRepositoryError.validateSupportedSchema(state)

        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            throw HostStateRepositoryError.encodingFailed(reason: String(describing: error))
        }
        try writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw HostStateRepositoryError.directoryCreationFailed(
                path: directoryURL.path,
                reason: String(describing: error)
            )
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL)
        } catch {
            throw HostStateRepositoryError.atomicWriteFailed(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw HostStateRepositoryError.atomicWriteFailed(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain &&
            nsError.code == CocoaError.fileReadNoSuchFile.rawValue
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}
