import XCTest
@testable import TableToolCore

final class CSVCoreTests: XCTestCase {
    private enum FixtureError: Error {
        case intentionalFailure
        case missingFixture(String)
    }

    private struct ExpectedDialect {
        let delimiter: Character
        let decimalMark: Character
        let quote: Character?
        let escapeMode: CSVEscapeMode
        let hasHeader: Bool?
        var encoding: CSVEncoding = .utf8
        var prefersChineseEncoding = false
        var checksQuote = true
    }

    func testQuotedRoundTripPreservesText() throws {
        let rows = [
            ["identifier", "description", "amount"],
            ["000012", "contains, comma", "+1.2300"],
            ["42", "two\nlines and a \"quote\"", "1e10"]
        ]
        let dialect = CSVDialect(hasHeader: true)
        let data = try CSVStreamWriter(dialect: dialect).serialize(rows)
        let parsed = try CSVStreamParser(dialect: dialect).parse(data: data).map(\.values)
        XCTAssertEqual(parsed, rows)
    }

    func testAllFieldsQuotePolicyMatchesClassicTableToolOutput() throws {
        let dialect = CSVDialect(quotePolicy: .allFields, hasHeader: false, hasFinalNewline: false)
        let data = try CSVStreamWriter(dialect: dialect).serialize([["plain", "contains, comma", "a\"b"]])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"plain\",\"contains, comma\",\"a\"\"b\"")
        let parsed = try CSVStreamParser(dialect: dialect).parse(data: data).map(\.values)
        XCTAssertEqual(parsed, [["plain", "contains, comma", "a\"b"]])
    }

    func testChunkedQuotedNewline() throws {
        let dialect = CSVDialect(hasHeader: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("a,\"b\nc\"\nd,e\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var rows: [[String]] = []
        try CSVStreamParser(dialect: dialect).parse(fileURL: url, chunkSize: 2) { rows.append($0.values) }
        XCTAssertEqual(rows, [["a", "b\nc"], ["d", "e"]])
    }

    func testRecordLimitStopsAfterLeadingRows() throws {
        let data = Data(String(repeating: "a,b\n", count: 10_000).utf8)
        let rows = try CSVStreamParser(dialect: CSVDialect(hasHeader: false)).parse(data: data, recordLimit: 50)
        XCTAssertEqual(rows.count, 50)
    }

    func testStrictAndBestEffortMalformedInput() throws {
        let data = Data("a,b\n1,bad\"quote\n".utf8)
        let dialect = CSVDialect(hasHeader: false)
        XCTAssertThrowsError(try CSVStreamParser(dialect: dialect).parse(data: data))
        let parser = try CSVStreamParser(dialect: dialect, recoveryPolicy: .bestEffort)
        XCTAssertEqual(try parser.parse(data: data).count, 2)
        XCTAssertEqual(parser.diagnostics.count, 1)
    }

    func testBestEffortDiagnosticStorageIsBounded() throws {
        let rowCount = 10_000
        let data = Data(String(repeating: "bad\"quote\n", count: rowCount).utf8)
        let parser = try CSVStreamParser(
            dialect: CSVDialect(hasHeader: false),
            recoveryPolicy: .bestEffort
        )

        let rows = try parser.parse(data: data)

        XCTAssertEqual(rows.count, rowCount)
        XCTAssertEqual(parser.totalDiagnosticCount, rowCount)
        XCTAssertEqual(parser.diagnostics.count, 100)
    }

    func testPackedRows() throws {
        let values = ["", "hello", "🤖", String(repeating: "x", count: 10_000)]
        XCTAssertEqual(try PackedRowCodec.decode(PackedRowCodec.encode(values)), values)
    }

    func testDialectDetection() throws {
        let result = try CSVDialectDetector.detect(sample: Data("name;amount\nWidget;12,50\nOther;3,25\n".utf8))
        XCTAssertEqual(result.dialect.delimiter, ";")
        XCTAssertEqual(result.dialect.decimalMark, ",")
        XCTAssertTrue(result.dialect.hasHeader)
    }

    func testDialectDetectionRemovesDoubleQuoteWrappersFromTruncatedSample() throws {
        let complete = String(repeating: "\"name\",\"description\"\n\"Ada\",\"quoted value\"\n", count: 80)
        let sample = Data((complete + "\"partial\",\"unfinished").utf8)
        let result = try CSVDialectDetector.detect(sample: sample)
        XCTAssertEqual(result.dialect.delimiter, ",")
        XCTAssertEqual(result.dialect.quote, "\"")
        let rows = try CSVStreamParser(dialect: result.dialect, recoveryPolicy: .bestEffort).parse(data: sample)
        XCTAssertEqual(rows[0].values, ["name", "description"])
        XCTAssertEqual(rows[1].values, ["Ada", "quoted value"])
    }

    func testDialectDetectionSupportsSingleQuotedFields() throws {
        let sample = Data("'name','description'\n'Ada','contains, comma'\n'Bob','plain'\n".utf8)
        let result = try CSVDialectDetector.detect(sample: sample)
        XCTAssertEqual(result.dialect.delimiter, ",")
        XCTAssertEqual(result.dialect.quote, "'")
        let rows = try CSVStreamParser(dialect: result.dialect).parse(data: sample).map(\.values)
        XCTAssertEqual(rows[0], ["name", "description"])
        XCTAssertEqual(rows[1], ["Ada", "contains, comma"])
    }

    func testDialectDetectionPrefersGB18030ForChineseLocale() throws {
        let text = "item1,item2,item3\r\n你好,中文,中国\r\nHello,Chinese,China\r\n"
        guard let sample = text.data(using: CSVEncoding.gb18030.foundationEncoding) else {
            return XCTFail("The test fixture could not be represented as GB18030.")
        }

        let result = try CSVDialectDetector.detect(sample: sample, prefersChineseEncoding: true)

        XCTAssertEqual(result.dialect.encoding, .gb18030)
        let rows = try CSVStreamParser(dialect: result.dialect).parse(data: sample).map(\.values)
        XCTAssertEqual(rows[1], ["你好", "中文", "中国"])
    }

    func testFileDetectionReadsFinalNewlineBeyondBoundedSample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let withoutNewline = root.appendingPathComponent("without.csv")
        try Data((String(repeating: "a,b\n", count: 1_000) + "last,value").utf8).write(to: withoutNewline)
        let first = try CSVDialectDetector.detect(fileURL: withoutNewline, sampleLimit: 128)
        XCTAssertFalse(first.dialect.hasFinalNewline)

        let withNewline = root.appendingPathComponent("with.csv")
        try Data((String(repeating: "a,b\n", count: 1_000) + "last,value\n").utf8).write(to: withNewline)
        let second = try CSVDialectDetector.detect(fileURL: withNewline, sampleLimit: 127)
        XCTAssertTrue(second.dialect.hasFinalNewline)
    }

    func testStreamingWriterDoesNotReplaceDestinationWhenGenerationFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.csv")
        try Data("keep me".utf8).write(to: destination)

        XCTAssertThrowsError(
            try CSVStreamWriter(dialect: .standard).write(to: destination, recordCount: 2) { index in
                if index == 1 { throw FixtureError.intentionalFailure }
                return ["partial"]
            }
        )

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.csv"])
    }

    func testStreamingWriterAtomicallyReplacesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.csv")
        try Data("old contents".utf8).write(to: destination)

        try CSVStreamWriter(dialect: .standard).write(to: destination, recordCount: 2) { index in
            index == 0 ? ["name", "value"] : ["Ada", "42"]
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "name,value\nAda,42\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.csv"])
    }

    func testStreamingWriterCancellationPreservesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.csv")
        try Data("keep me".utf8).write(to: destination)

        let task = Task {
            try CSVStreamWriter(dialect: .standard).write(to: destination, recordCount: 10_000) { _ in
                ["value"]
            }
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected export cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.csv"])
    }

    func testUpstreamDialectFixtures() throws {
        let expected: [String: ExpectedDialect] = [
            "heuristic-comma-separated-people-1.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-comma-separated-people-2.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-comma-separated-places.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config1.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config2.csv": .init(delimiter: ";", decimalMark: ",", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config3.csv": .init(delimiter: "\t", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config4.csv": .init(delimiter: "\t", decimalMark: ",", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config5.csv": .init(delimiter: ";", decimalMark: ",", quote: "\"", escapeMode: .backslash, hasHeader: true),
            "heuristic-config6.csv": .init(delimiter: ",", decimalMark: ".", quote: nil, escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config7.csv": .init(delimiter: ";", decimalMark: ",", quote: nil, escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config8.csv": .init(delimiter: "\t", decimalMark: ".", quote: nil, escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config9.csv": .init(delimiter: "\t", decimalMark: ",", quote: nil, escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-config10.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .backslash, hasHeader: true),
            "heuristic-config11.csv": .init(delimiter: ",", decimalMark: ",", quote: "\"", escapeMode: .doubledQuote, hasHeader: true),
            "heuristic-first-row-with-number.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: false),
            "heuristic-first-row-one-row-shorter.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: false),
            "heuristic-first-row-longer.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: false),
            "heuristic-no-utf-encoding.csv": .init(delimiter: ",", decimalMark: ".", quote: "\"", escapeMode: .doubledQuote, hasHeader: nil, encoding: .windows1252),
            "heuristic-gbk.csv": .init(delimiter: ",", decimalMark: ".", quote: nil, escapeMode: .doubledQuote, hasHeader: true, encoding: .gb18030, prefersChineseEncoding: true, checksQuote: false),
            "issue-4-sample.csv": .init(delimiter: "\t", decimalMark: ".", quote: nil, escapeMode: .doubledQuote, hasHeader: true, encoding: .macOSRoman, checksQuote: false)
        ]

        for (name, expectedDialect) in expected.sorted(by: { $0.key < $1.key }) {
            let sample = try Data(contentsOf: fixtureURL(name, subdirectory: "Heuristics"))
            let actual = try CSVDialectDetector.detect(
                sample: sample,
                prefersChineseEncoding: expectedDialect.prefersChineseEncoding
            ).dialect
            XCTAssertEqual(actual.delimiter, expectedDialect.delimiter, name)
            XCTAssertEqual(actual.decimalMark, expectedDialect.decimalMark, name)
            if expectedDialect.checksQuote {
                XCTAssertEqual(actual.quote, expectedDialect.quote, name)
            }
            XCTAssertEqual(actual.escapeMode, expectedDialect.escapeMode, name)
            if let hasHeader = expectedDialect.hasHeader {
                XCTAssertEqual(actual.hasHeader, hasHeader, name)
            }
            XCTAssertEqual(actual.encoding, expectedDialect.encoding, name)
        }
    }

    func testUpstreamReaderFixtures() throws {
        let valid: [(String, CSVDialect, Int, Int?)] = [
            ("comma-separated.csv", CSVDialect(quote: nil, hasHeader: false), 3, 3),
            ("semicolon-separated.csv", CSVDialect(delimiter: ";", quote: nil, hasHeader: false, decimalMark: ","), 3, 3),
            ("comma-separated-quote.csv", CSVDialect(hasHeader: false, decimalMark: ","), 3, 3),
            ("quote-quote-escape.csv", CSVDialect(hasHeader: false), 2, 2),
            ("quote-backslash-escape.csv", CSVDialect(escapeMode: .backslash, hasHeader: false), 2, 2),
            ("blank-lines.csv", CSVDialect(hasHeader: false), 6, nil)
        ]
        let malformed: [(String, CSVDialect)] = [
            ("invalid-encoding.csv", CSVDialect(hasHeader: false)),
            ("missing-quote-atEnd.csv", CSVDialect(hasHeader: false)),
            ("missing-backslash-beforeValue.csv", CSVDialect(escapeMode: .backslash, hasHeader: false)),
            ("missing-backslash-afterValue.csv", CSVDialect(escapeMode: .backslash, hasHeader: false)),
            ("missing-value-for-backslash-inquote.csv", CSVDialect(escapeMode: .backslash, hasHeader: false)),
            ("missing-value-for-backslash.csv", CSVDialect(escapeMode: .backslash, hasHeader: false)),
            ("quote-in-unquoted-value.csv", CSVDialect(hasHeader: false))
        ]

        for (name, dialect, expectedRows, expectedWidth) in valid {
            let records = try CSVStreamParser(dialect: dialect).parse(
                data: Data(contentsOf: fixtureURL(name, subdirectory: "Reading"))
            )
            XCTAssertEqual(records.count, expectedRows, name)
            if let expectedWidth {
                XCTAssertTrue(records.allSatisfy { $0.values.count == expectedWidth }, name)
            }
        }
        for (name, dialect) in malformed {
            let data = try Data(contentsOf: fixtureURL(name, subdirectory: "Reading"))
            XCTAssertThrowsError(try CSVStreamParser(dialect: dialect).parse(data: data), name)
        }
    }

    private func fixtureURL(_ name: String, subdirectory: String) throws -> URL {
#if SWIFT_PACKAGE
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/Upstream/\(subdirectory)"
        ) else {
            throw FixtureError.missingFixture(name)
        }
#else
        guard let url = Bundle(for: CSVCoreTests.self).url(forResource: name, withExtension: nil) else {
            throw FixtureError.missingFixture(name)
        }
#endif
        return url
    }
}
