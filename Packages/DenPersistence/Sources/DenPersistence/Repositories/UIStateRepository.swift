import Foundation
import GRDB
import DenCore

/// Repository for the singleton `UIState` row.
public struct UIStateRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Read

    public func fetch() throws -> UIState {
        let state = try database.reader.read { db in
            try UIStateRecord.fetchOne(db, key: 1)?.toModel()
        }
        // Missing state is normal on first launch.
        return state ?? UIState()
    }

    // MARK: - Write

    public func save(_ state: UIState) throws {
        let record = UIStateRecord(from: state)
        try database.writer.write { db in
            try record.save(db)
        }
    }
}
