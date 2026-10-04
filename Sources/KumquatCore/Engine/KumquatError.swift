import Foundation

/// An operation stopped after publishing some complete outputs. Keep those URLs as data so
/// the engine can report them without interpreting an error message or deleting completed work.
public struct PartialOutputError: LocalizedError, Sendable {
    public let outputs: [URL]
    public let cancelled: Bool
    public let message: String

    public init(outputs: [URL], underlyingError: Error, cancelled: Bool = false) {
        if let partial = underlyingError as? PartialOutputError {
            self.outputs = outputs + partial.outputs
            self.cancelled = cancelled || partial.cancelled
            self.message = partial.message
        } else {
            self.outputs = outputs
            self.cancelled = cancelled || Self.isCancellation(underlyingError)
            self.message = underlyingError.localizedDescription
        }
    }

    public var errorDescription: String? { message }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let partial = error as? PartialOutputError { return partial.cancelled }
        if let error = error as? KumquatError, case .cancelled = error { return true }
        return false
    }
}

public enum KumquatError: LocalizedError, Sendable {
    case unsupportedInput(String)
    case unsupportedConversion(from: String, to: String)
    case decodeFailed(String)
    case encodeFailed(String)
    case toolMissing(String)
    case processFailed(String)
    case nothingToDo(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let name):
            return "\(name) isn't a file type Kumquat can open."
        case .unsupportedConversion(let from, let to):
            return "Can't convert \(from) to \(to)."
        case .decodeFailed(let name):
            return "Couldn't read \(name)."
        case .encodeFailed(let what):
            return "Couldn't write \(what)."
        case .toolMissing(let tool):
            return "This conversion needs \(tool). Install it with Homebrew: brew install \(tool)"
        case .processFailed(let message):
            return message
        case .nothingToDo(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}
