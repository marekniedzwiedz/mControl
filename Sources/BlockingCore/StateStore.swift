import Foundation

public protocol StateStore {
    func load() throws -> AppState
    func save(_ state: AppState) throws
}

public enum StateStoreError: Error, LocalizedError {
    case missingApplicationSupportDirectory

    public var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Unable to locate Application Support directory."
        }
    }
}

public final class JSONStateStore: StateStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> AppState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AppState()
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppState.self, from: data)
    }

    public func save(_ state: AppState) throws {
        let parent = fileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StateStoreError.missingApplicationSupportDirectory
        }

        return applicationSupport
            .appendingPathComponent("mControl", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
