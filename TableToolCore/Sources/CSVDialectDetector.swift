import Foundation

public struct DialectDetectionResult: Sendable {
    public var dialect: CSVDialect
    public var confidence: Double
    public var alternatives: [CSVDialect]
    public var sampleRecordCount: Int

    public init(dialect: CSVDialect, confidence: Double, alternatives: [CSVDialect], sampleRecordCount: Int) {
        self.dialect = dialect
        self.confidence = confidence
        self.alternatives = alternatives
        self.sampleRecordCount = sampleRecordCount
    }
}

public enum CSVDialectDetector {
    public static func detect(
        fileURL: URL,
        sampleLimit: Int = 1_048_576,
        prefersChineseEncoding: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    ) throws -> DialectDetectionResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let sample = try handle.read(upToCount: sampleLimit) ?? Data()
        var result = try detect(sample: sample, prefersChineseEncoding: prefersChineseEncoding)
        let fileSize = try handle.seekToEnd()
        result.dialect.hasFinalNewline = try hasFinalNewline(
            handle: handle,
            fileSize: fileSize,
            encoding: result.dialect.encoding
        )
        return result
    }

    public static func detect(
        sample: Data,
        prefersChineseEncoding: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    ) throws -> DialectDetectionResult {
        let (encoding, hasBOM) = detectEncoding(sample, prefersChineseEncoding: prefersChineseEncoding)
        let bom = hasBOM ? encoding.byteOrderMark.count : 0
        guard let text = String(data: sample.dropFirst(bom), encoding: encoding.foundationEncoding) else {
            throw CSVParseDiagnostic(
                reason: .undecodableBytes,
                location: CSVSourceLocation(byteOffset: 0, record: 1, field: 1, line: 1),
                detail: "The sample could not be decoded using a supported encoding."
            )
        }

        let lineEnding: CSVLineEnding = text.contains("\r\n") ? .crlf : (text.contains("\r") ? .cr : .lf)
        let finalNewline = text.hasSuffix("\n") || text.hasSuffix("\r")
        let textBytes = Array(text.utf8)
        let delimiters: [Character] = [",", ";", "\t", "|"]
        var scored: [(CSVDialect, Double, Int)] = []

        let quoteModes: [(Character?, CSVEscapeMode)] = [
            ("\"", .doubledQuote), ("\"", .backslash),
            ("'", .doubledQuote), ("'", .backslash),
            (nil, .doubledQuote)
        ]
        let doubleDoubled = occurrences(of: [34, 34], in: textBytes)
        let doubleBackslashed = occurrences(of: [92, 34], in: textBytes)
        let singleDoubled = occurrences(of: [39, 39], in: textBytes)
        let singleBackslashed = occurrences(of: [92, 39], in: textBytes)
        for delimiter in delimiters {
            let delimiterByte = String(delimiter).utf8.first!
            let doubleQuoteEvidence = quoteBoundaryEvidence(in: textBytes, delimiter: delimiterByte, quote: 34)
            let singleQuoteEvidence = quoteBoundaryEvidence(in: textBytes, delimiter: delimiterByte, quote: 39)
            for (quote, escapeMode) in quoteModes {
                var dialect = CSVDialect(
                    encoding: encoding,
                    includesByteOrderMark: hasBOM,
                    delimiter: delimiter,
                    quote: quote,
                    escapeMode: escapeMode,
                    lineEnding: lineEnding,
                    hasHeader: false,
                    hasFinalNewline: finalNewline,
                    decimalMark: delimiter == ";" ? "," : "."
                )
                // A bounded sample commonly ends halfway through a quoted field. Best-effort
                // parsing keeps that final partial record from disqualifying the correct dialect.
                guard let parser = try? CSVStreamParser(dialect: dialect, recoveryPolicy: .bestEffort),
                      let records = try? parser.parse(data: sample, recordLimit: 50), !records.isEmpty else { continue }
                let rows = records.map(\.values)
                let widths = rows.map(\.count)
                let mode = widths.reduce(into: [:]) { $0[$1, default: 0] += 1 }.max { $0.value < $1.value }
                let consistent = Double(mode?.value ?? 0) / Double(max(rows.count, 1))
                let width = Double(mode?.key ?? 1)
                let score = consistent * 10
                    + min(width, 20) / 2
                    - (width == 1 ? 3 : 0)
                    + Double(min(rows.count, 10)) / 10
                    + quotePreference(
                        quote: quote,
                        escapeMode: escapeMode,
                        doubleEvidence: doubleQuoteEvidence,
                        singleEvidence: singleQuoteEvidence,
                        doubleDoubled: doubleDoubled,
                        doubleBackslashed: doubleBackslashed,
                        singleDoubled: singleDoubled,
                        singleBackslashed: singleBackslashed
                    )
                    - Double(parser.diagnostics.count) * 0.5
                dialect.decimalMark = inferDecimalMark(rows)
                dialect.hasHeader = inferHeader(rows)
                scored.append((dialect, score, rows.count))
            }
        }

        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first else {
            throw CSVParseDiagnostic(
                reason: .invalidDialect,
                location: CSVSourceLocation(byteOffset: 0, record: 1, field: 1, line: 1),
                detail: "No supported delimiter and quote combination could parse the sample."
            )
        }
        let secondScore = scored.dropFirst().first?.1 ?? 0
        let confidence = min(1, max(0, (best.1 - secondScore + 1) / max(best.1, 1)))
        return DialectDetectionResult(
            dialect: best.0,
            confidence: confidence,
            alternatives: scored.dropFirst().prefix(3).map(\.0),
            sampleRecordCount: best.2
        )
    }

    private static func detectEncoding(_ data: Data, prefersChineseEncoding: Bool) -> (CSVEncoding, Bool) {
        let candidates: [CSVEncoding] = [.utf32BigEndian, .utf32LittleEndian, .utf8, .utf16BigEndian, .utf16LittleEndian]
        if let encoding = candidates.first(where: { !$0.byteOrderMark.isEmpty && data.starts(with: $0.byteOrderMark) }) {
            return (encoding, true)
        }
        if String(data: data, encoding: .utf8) != nil { return (.utf8, false) }
        // Windows-1252 accepts many byte sequences that are also valid GB18030. The original
        // Table Tool resolved that ambiguity from the user's preferred language; preserve the
        // same behavior so Chinese documents do not become Western mojibake on Chinese Macs.
        let legacy: [CSVEncoding] = prefersChineseEncoding
            ? [.gb18030, .windows1252, .macOSRoman, .shiftJIS, .eucJapanese]
            : [.windows1252, .macOSRoman, .gb18030, .shiftJIS, .eucJapanese]
        for encoding in legacy where String(data: data, encoding: encoding.foundationEncoding) != nil {
            return (encoding, false)
        }
        return (.utf8, false)
    }

    private static func hasFinalNewline(handle: FileHandle, fileSize: UInt64, encoding: CSVEncoding) throws -> Bool {
        let width: UInt64
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian: width = 2
        case .utf32LittleEndian, .utf32BigEndian: width = 4
        default: width = 1
        }
        guard fileSize >= width else { return false }
        try handle.seek(toOffset: fileSize - width)
        let suffix = try handle.read(upToCount: Int(width)) ?? Data()
        guard suffix.count == Int(width) else { return false }
        switch encoding {
        case .utf16LittleEndian:
            return suffix == Data([0x0A, 0x00]) || suffix == Data([0x0D, 0x00])
        case .utf16BigEndian:
            return suffix == Data([0x00, 0x0A]) || suffix == Data([0x00, 0x0D])
        case .utf32LittleEndian:
            return suffix == Data([0x0A, 0x00, 0x00, 0x00]) || suffix == Data([0x0D, 0x00, 0x00, 0x00])
        case .utf32BigEndian:
            return suffix == Data([0x00, 0x00, 0x00, 0x0A]) || suffix == Data([0x00, 0x00, 0x00, 0x0D])
        default:
            return suffix == Data([0x0A]) || suffix == Data([0x0D])
        }
    }

    private static func inferHeader(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2, !rows[0].isEmpty,
              rows.dropFirst().allSatisfy({ $0.count == rows[0].count }) else { return false }
        let firstLooksTextual = rows[0].allSatisfy { !$0.isEmpty && Double($0) == nil }
        let laterContainsTypedValue = rows.dropFirst().prefix(4).joined().contains { value in
            Double(value.replacingOccurrences(of: ",", with: ".")) != nil || ISO8601DateFormatter().date(from: value) != nil
        }
        return firstLooksTextual && (laterContainsTypedValue || Set(rows[0]).count == rows[0].count)
    }

    private static func inferDecimalMark(_ rows: [[String]]) -> Character {
        var commaEvidence = 0
        var pointEvidence = 0
        for value in rows.joined() {
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains(","), !candidate.contains("."),
               Double(candidate.replacingOccurrences(of: ",", with: ".")) != nil {
                commaEvidence += 1
            } else if candidate.contains("."), !candidate.contains(","), Double(candidate) != nil {
                pointEvidence += 1
            }
        }
        return commaEvidence > pointEvidence ? "," : "."
    }

    private static func quotePreference(
        quote: Character?,
        escapeMode: CSVEscapeMode,
        doubleEvidence: Int,
        singleEvidence: Int,
        doubleDoubled: Int,
        doubleBackslashed: Int,
        singleDoubled: Int,
        singleBackslashed: Int
    ) -> Double {
        guard let quote else {
            // Without this penalty an unquoted parse has exactly the same row widths as a
            // correctly quoted parse, but leaves the wrapper characters in every cell.
            return -min(4, Double(max(doubleEvidence, singleEvidence)) * 0.08)
        }

        let evidence = quote == "\"" ? doubleEvidence : singleEvidence
        var result: Double
        if evidence == 0 {
            result = quote == "\"" ? 0.02 : -0.02
        } else {
            result = min(4, Double(evidence) * 0.08)
        }
        let doubled = quote == "\"" ? doubleDoubled : singleDoubled
        let backslashed = quote == "\"" ? doubleBackslashed : singleBackslashed
        switch escapeMode {
        case .doubledQuote:
            result += doubled > 0 ? 0.2 : 0.01
            if backslashed > doubled { result -= 0.2 }
        case .backslash:
            result += backslashed > 0 ? 0.2 : 0
            if doubled > backslashed { result -= 0.2 }
        }
        return result
    }

    private static func quoteBoundaryEvidence(in bytes: [UInt8], delimiter: UInt8, quote: UInt8) -> Int {
        var openings = bytes.first == quote ? 1 : 0
        openings += occurrences(of: [delimiter, quote], in: bytes)
        openings += occurrences(of: [10, quote], in: bytes)
        openings += occurrences(of: [13, quote], in: bytes)

        var closings = bytes.last == quote ? 1 : 0
        closings += occurrences(of: [quote, delimiter], in: bytes)
        closings += occurrences(of: [quote, 10], in: bytes)
        closings += occurrences(of: [quote, 13], in: bytes)
        return min(openings, closings)
    }

    private static func occurrences(of needle: [UInt8], in bytes: [UInt8]) -> Int {
        guard !needle.isEmpty, needle.count <= bytes.count else { return 0 }
        var count = 0
        var index = 0
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0]
                && (needle.count == 1 || bytes[index + 1] == needle[1]) {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }
}
