import Foundation

public final class CSVStreamParser {
    private enum ControlSignal: Error { case recordLimitReached }

    private enum State {
        case fieldStart
        case unquoted
        case quoted
        case afterQuote
        case escaped
    }

    public let dialect: CSVDialect
    public let recoveryPolicy: CSVRecoveryPolicy
    public private(set) var diagnostics: [CSVParseDiagnostic] = []
    public private(set) var totalDiagnosticCount = 0
    private let maximumStoredDiagnostics = 100

    private var state: State = .fieldStart
    private var currentField = String()
    private var currentRecord: [String] = []
    private var recordStart = CSVSourceLocation(byteOffset: 0, record: 1, field: 1, line: 1)
    private var logicalRecord: Int64 = 1
    private var physicalLine: Int64 = 1
    private var scalarOffset: Int64 = 0
    private var sawAnyInput = false
    private var justEndedRecord = false
    private var pendingCR = false

    public init(dialect: CSVDialect, recoveryPolicy: CSVRecoveryPolicy = .strict) throws {
        guard dialect.delimiter != "\n", dialect.delimiter != "\r", dialect.quote != dialect.delimiter else {
            throw CSVParseDiagnostic(
                reason: .invalidDialect,
                location: CSVSourceLocation(byteOffset: 0, record: 1, field: 1, line: 1),
                detail: "The delimiter must not be a line ending or the quote character."
            )
        }
        self.dialect = dialect
        self.recoveryPolicy = recoveryPolicy
    }

    public func parse(data: Data, recordLimit: Int? = nil) throws -> [CSVRecord] {
        if let recordLimit, recordLimit <= 0 { return [] }
        let bomCount = Self.byteOrderMarkLength(in: data, encoding: dialect.encoding)
        scalarOffset = Int64(bomCount)
        let content = data.dropFirst(bomCount)
        guard let text = String(data: content, encoding: dialect.encoding.foundationEncoding) else {
            throw diagnostic(.undecodableBytes, "The document contains bytes that are invalid for \(dialect.encoding.rawValue).")
        }
        var records: [CSVRecord] = []
        do {
            try consume(text, final: true) {
                records.append($0)
                if let recordLimit, records.count >= recordLimit { throw ControlSignal.recordLimitReached }
            }
        } catch ControlSignal.recordLimitReached {
            // Detection and previews only need the leading records; parser state is discarded.
        }
        return records
    }

    public func parse(
        fileURL: URL,
        chunkSize: Int = 1_048_576,
        progress: ((Int64) -> Void)? = nil,
        onRecord: (CSVRecord) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var decoder = CSVChunkDecoder(encoding: dialect.encoding)
        var firstChunk = true
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            var bytes = data
            if firstChunk {
                let bomCount = min(Self.byteOrderMarkLength(in: bytes, encoding: dialect.encoding), bytes.count)
                bytes.removeFirst(bomCount)
                scalarOffset = Int64(bomCount)
                firstChunk = false
            }
            let text = try decoder.decode(bytes, final: false, location: currentLocation)
            try consume(text, final: false, onRecord: onRecord)
            progress?(Int64(clamping: try handle.offset()))
        }
        let tail = try decoder.decode(Data(), final: true, location: currentLocation)
        try consume(tail, final: true, onRecord: onRecord)
    }

    private var currentLocation: CSVSourceLocation {
        CSVSourceLocation(byteOffset: scalarOffset, record: logicalRecord, field: currentRecord.count + 1, line: physicalLine)
    }

    private func consume(_ text: String, final: Bool, onRecord: (CSVRecord) throws -> Void) throws {
        for scalar in text.unicodeScalars {
            sawAnyInput = true
            scalarOffset += Int64(String(scalar).data(using: dialect.encoding.foundationEncoding)?.count ?? scalar.utf8.count)

            if pendingCR {
                pendingCR = false
                if scalar == "\n" {
                    physicalLine += 1
                    continue
                }
            }

            if state != .quoted && state != .escaped && (scalar == "\r" || scalar == "\n") {
                try endRecord(onRecord)
                if scalar == "\r" { pendingCR = true } else { physicalLine += 1 }
                continue
            }

            let character = Character(String(scalar))
            switch state {
            case .fieldStart:
                if character == dialect.delimiter {
                    currentRecord.append("")
                    justEndedRecord = false
                } else if let quote = dialect.quote, character == quote {
                    state = .quoted
                    justEndedRecord = false
                } else {
                    currentField.append(character)
                    state = .unquoted
                    justEndedRecord = false
                }

            case .unquoted:
                if character == dialect.delimiter {
                    finishField()
                } else if let quote = dialect.quote, character == quote {
                    try recoverOrThrow(.unexpectedQuote, "A quote appeared inside an unquoted field.", literal: character)
                } else {
                    currentField.append(character)
                }

            case .quoted:
                if dialect.escapeMode == .backslash && character == "\\" {
                    state = .escaped
                } else if let quote = dialect.quote, character == quote {
                    state = .afterQuote
                } else {
                    if scalar == "\n" { physicalLine += 1 }
                    currentField.append(character)
                }

            case .escaped:
                currentField.append(character)
                state = .quoted

            case .afterQuote:
                if dialect.escapeMode == .doubledQuote, let quote = dialect.quote, character == quote {
                    currentField.append(quote)
                    state = .quoted
                } else if character == dialect.delimiter {
                    finishField()
                } else {
                    try recoverOrThrow(
                        .unexpectedCharacterAfterQuote,
                        "Only a delimiter or record ending may follow a closing quote.",
                        literal: character
                    )
                }
            }
        }

        guard final else { return }
        pendingCR = false
        switch state {
        case .quoted:
            try recoverOrThrow(.unterminatedQuotedField, "The final quoted field has no closing quote.", literal: nil)
        case .escaped:
            try recoverOrThrow(.danglingEscape, "The document ends with an incomplete escape sequence.", literal: "\\")
        default:
            break
        }
        if sawAnyInput && !justEndedRecord {
            try endRecord(onRecord)
        }
    }

    private func finishField() {
        currentRecord.append(currentField)
        currentField.removeAll(keepingCapacity: true)
        state = .fieldStart
        justEndedRecord = false
    }

    private func endRecord(_ onRecord: (CSVRecord) throws -> Void) throws {
        currentRecord.append(currentField)
        currentField.removeAll(keepingCapacity: true)
        let record = CSVRecord(values: currentRecord, location: recordStart)
        try onRecord(record)
        currentRecord.removeAll(keepingCapacity: true)
        state = .fieldStart
        logicalRecord += 1
        recordStart = CSVSourceLocation(
            byteOffset: scalarOffset,
            record: logicalRecord,
            field: 1,
            line: physicalLine + 1
        )
        justEndedRecord = true
    }

    private func recoverOrThrow(_ reason: CSVParseDiagnostic.Reason, _ detail: String, literal: Character?) throws {
        let issue = diagnostic(reason, detail)
        guard recoveryPolicy == .bestEffort else { throw issue }
        totalDiagnosticCount += 1
        if diagnostics.count < maximumStoredDiagnostics { diagnostics.append(issue) }
        if let literal { currentField.append(literal) }
        state = .unquoted
    }

    private func diagnostic(_ reason: CSVParseDiagnostic.Reason, _ detail: String) -> CSVParseDiagnostic {
        CSVParseDiagnostic(reason: reason, location: currentLocation, detail: detail)
    }

    private static func byteOrderMarkLength(in data: Data, encoding: CSVEncoding) -> Int {
        let mark = encoding.byteOrderMark
        guard !mark.isEmpty, data.starts(with: mark) else { return 0 }
        return mark.count
    }
}

private struct CSVChunkDecoder {
    let encoding: CSVEncoding
    private var carry = Data()

    init(encoding: CSVEncoding) {
        self.encoding = encoding
    }

    mutating func decode(_ data: Data, final: Bool, location: CSVSourceLocation) throws -> String {
        carry.append(data)
        if carry.isEmpty { return "" }
        let maxCarry = final ? 0 : 4
        for suffix in 0...min(maxCarry, carry.count) {
            let prefixCount = carry.count - suffix
            guard prefixCount > 0 else { continue }
            let prefix = carry.prefix(prefixCount)
            if let text = String(data: prefix, encoding: encoding.foundationEncoding) {
                carry = Data(carry.suffix(suffix))
                return text
            }
        }
        if !final && carry.count <= 4 { return "" }
        throw CSVParseDiagnostic(
            reason: .undecodableBytes,
            location: location,
            detail: "The document contains bytes that are invalid for \(encoding.rawValue)."
        )
    }
}
