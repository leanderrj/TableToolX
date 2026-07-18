import Foundation

public struct CSVSourceLocation: Codable, Equatable, Sendable {
    public var byteOffset: Int64
    public var record: Int64
    public var field: Int
    public var line: Int64

    public init(byteOffset: Int64, record: Int64, field: Int, line: Int64) {
        self.byteOffset = byteOffset
        self.record = record
        self.field = field
        self.line = line
    }
}

public struct CSVParseDiagnostic: Error, Codable, Equatable, LocalizedError, Sendable {
    public enum Reason: String, Codable, Sendable {
        case undecodableBytes
        case unexpectedQuote
        case unexpectedCharacterAfterQuote
        case unterminatedQuotedField
        case danglingEscape
        case invalidDialect
    }

    public var reason: Reason
    public var location: CSVSourceLocation
    public var detail: String

    public init(reason: Reason, location: CSVSourceLocation, detail: String) {
        self.reason = reason
        self.location = location
        self.detail = detail
    }

    public var errorDescription: String? { detail }

    public var recoverySuggestion: String? {
        "Check the encoding, delimiter, quote, and escape settings, or reopen explicitly in best-effort mode."
    }
}

public struct CSVRecord: Equatable, Sendable {
    public var values: [String]
    public var location: CSVSourceLocation

    public init(values: [String], location: CSVSourceLocation) {
        self.values = values
        self.location = location
    }
}

public enum CSVRecoveryPolicy: Sendable {
    case strict
    case bestEffort
}

public struct WorkspaceImportResult: Sendable {
    public var diagnostics: [CSVParseDiagnostic]
    public var totalDiagnosticCount: Int

    public init(diagnostics: [CSVParseDiagnostic], totalDiagnosticCount: Int) {
        self.diagnostics = diagnostics
        self.totalDiagnosticCount = totalDiagnosticCount
    }
}
