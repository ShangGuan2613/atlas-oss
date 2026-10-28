import Foundation

/// Errors surfaced by the AtlasOSS data layer.
public enum AtlasError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case libraryCreationFailed(String)
    case pathNotFound(String)
    case notADirectory(String)
    case database(String)
    case unsupported(String)
    case io(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .libraryCreationFailed(let message):
            return "Failed to create library: \(message)"
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .notADirectory(let path):
            return "Not a directory: \(path)"
        case .database(let message):
            return "Database error: \(message)"
        case .unsupported(let message):
            return "Unsupported operation: \(message)"
        case .io(let message):
            return "I/O error: \(message)"
        }
    }
}
