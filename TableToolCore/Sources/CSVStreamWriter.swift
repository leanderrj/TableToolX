import Foundation
import Darwin

public struct CSVStreamWriter: Sendable {
    public let dialect: CSVDialect

    public init(dialect: CSVDialect) {
        self.dialect = dialect
    }

    public func serialize(_ rows: [[String]]) throws -> Data {
        var result = Data()
        if dialect.includesByteOrderMark { result.append(dialect.encoding.byteOrderMark) }
        for index in rows.indices {
            let line = try encodedRecord(rows[index])
            result.append(line)
            if index < rows.count - 1 || dialect.hasFinalNewline {
                result.append(try encoded(dialect.lineEnding.rawValue))
            }
        }
        return result
    }

    public func write(
        to url: URL,
        recordCount: Int64,
        rowAt: (Int64) throws -> [String],
        progress: ((Int64) -> Void)? = nil
    ) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tabletoolx-\(UUID().uuidString).tmp")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: temporary) } }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            if dialect.includesByteOrderMark { try handle.write(contentsOf: dialect.encoding.byteOrderMark) }
            for index in 0..<recordCount {
                if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
                try handle.write(contentsOf: encodedRecord(rowAt(index)))
                if index < recordCount - 1 || dialect.hasFinalNewline {
                    try handle.write(contentsOf: encoded(dialect.lineEnding.rawValue))
                }
                if index.isMultiple(of: 1_000) { progress?(index) }
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // POSIX rename atomically replaces an existing file on the same volume. In contrast,
        // FileManager.replaceItemAt can consume its replacement and still report that the
        // now-moved temporary URL is missing when NSDocument coordinates a close-time save.
        let result: Int32 = temporary.withUnsafeFileSystemRepresentation { sourcePath in
            url.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        committed = true
        progress?(recordCount)
    }

    private func encodedRecord(_ row: [String]) throws -> Data {
        let text = try row.map(encodeField).joined(separator: String(dialect.delimiter))
        return try encoded(text)
    }

    private func encodeField(_ value: String) throws -> String {
        let delimiter = String(dialect.delimiter)
        let requiresQuote = dialect.quotePolicy == .allFields
            || value.contains(delimiter)
            || value.contains("\n")
            || value.contains("\r")
            || (dialect.quote.map(value.contains) ?? false)
        guard requiresQuote else { return value }
        guard let quote = dialect.quote else {
            throw CSVParseDiagnostic(
                reason: .invalidDialect,
                location: CSVSourceLocation(byteOffset: 0, record: 0, field: 0, line: 0),
                detail: "A value contains a delimiter or line ending, but quoting is disabled."
            )
        }
        let quoteText = String(quote)
        let escaped: String
        switch dialect.escapeMode {
        case .doubledQuote:
            escaped = value.replacingOccurrences(of: quoteText, with: quoteText + quoteText)
        case .backslash:
            escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: quoteText, with: "\\" + quoteText)
        }
        return quoteText + escaped + quoteText
    }

    private func encoded(_ string: String) throws -> Data {
        guard let data = string.data(using: dialect.encoding.foundationEncoding, allowLossyConversion: false) else {
            throw CSVParseDiagnostic(
                reason: .undecodableBytes,
                location: CSVSourceLocation(byteOffset: 0, record: 0, field: 0, line: 0),
                detail: "A value cannot be represented using \(dialect.encoding.rawValue)."
            )
        }
        return data
    }
}
