import Foundation

public enum CSVEncoding: String, Codable, CaseIterable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case windows1252
    case macOSRoman
    case isoLatin2
    case windowsLatin2
    case windowsCyrillic
    case windowsGreek
    case windowsTurkish
    case shiftJIS
    case eucJapanese
    case iso2022JP
    case gb18030

    public var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .utf32LittleEndian: .utf32LittleEndian
        case .utf32BigEndian: .utf32BigEndian
        case .windows1252: .windowsCP1252
        case .macOSRoman: .macOSRoman
        case .isoLatin2: .isoLatin2
        case .windowsLatin2: String.Encoding(rawValue: 0x0F)
        case .windowsCyrillic: .windowsCP1251
        case .windowsGreek: .windowsCP1253
        case .windowsTurkish: .windowsCP1254
        case .shiftJIS: .shiftJIS
        case .eucJapanese: .japaneseEUC
        case .iso2022JP: .iso2022JP
        case .gb18030: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
    }

    public var isUnicode: Bool {
        switch self {
        case .utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian: true
        default: false
        }
    }

    public var byteOrderMark: Data {
        switch self {
        case .utf8: Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian: Data([0xFE, 0xFF])
        case .utf32LittleEndian: Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: Data([0x00, 0x00, 0xFE, 0xFF])
        default: Data()
        }
    }
}

public enum CSVLineEnding: String, Codable, CaseIterable, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

public enum CSVEscapeMode: String, Codable, CaseIterable, Sendable {
    case doubledQuote
    case backslash
}

public enum CSVQuotePolicy: String, Codable, CaseIterable, Sendable {
    case minimal
    case allFields
}

public struct CSVDialect: Codable, Equatable, Sendable {
    public var encoding: CSVEncoding
    public var includesByteOrderMark: Bool
    public var delimiter: Character
    public var quote: Character?
    public var quotePolicy: CSVQuotePolicy
    public var escapeMode: CSVEscapeMode
    public var lineEnding: CSVLineEnding
    public var hasHeader: Bool
    public var hasFinalNewline: Bool
    public var decimalMark: Character

    public init(
        encoding: CSVEncoding = .utf8,
        includesByteOrderMark: Bool = false,
        delimiter: Character = ",",
        quote: Character? = "\"",
        quotePolicy: CSVQuotePolicy = .minimal,
        escapeMode: CSVEscapeMode = .doubledQuote,
        lineEnding: CSVLineEnding = .lf,
        hasHeader: Bool = true,
        hasFinalNewline: Bool = true,
        decimalMark: Character = "."
    ) {
        self.encoding = encoding
        self.includesByteOrderMark = includesByteOrderMark
        self.delimiter = delimiter
        self.quote = quote
        self.quotePolicy = quotePolicy
        self.escapeMode = escapeMode
        self.lineEnding = lineEnding
        self.hasHeader = hasHeader
        self.hasFinalNewline = hasFinalNewline
        self.decimalMark = decimalMark
    }

    public static let standard = CSVDialect()
    public static let tsv = CSVDialect(delimiter: "\t")

    private enum CodingKeys: String, CodingKey {
        case encoding, includesByteOrderMark, delimiter, quote, quotePolicy, escapeMode
        case lineEnding, hasHeader, hasFinalNewline, decimalMark
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        encoding = try values.decode(CSVEncoding.self, forKey: .encoding)
        includesByteOrderMark = try values.decode(Bool.self, forKey: .includesByteOrderMark)
        delimiter = try Self.singleCharacter(values.decode(String.self, forKey: .delimiter), key: .delimiter)
        if let quoteString = try values.decodeIfPresent(String.self, forKey: .quote) {
            quote = try Self.singleCharacter(quoteString, key: .quote)
        } else {
            quote = nil
        }
        quotePolicy = try values.decodeIfPresent(CSVQuotePolicy.self, forKey: .quotePolicy) ?? .minimal
        escapeMode = try values.decode(CSVEscapeMode.self, forKey: .escapeMode)
        lineEnding = try values.decode(CSVLineEnding.self, forKey: .lineEnding)
        hasHeader = try values.decode(Bool.self, forKey: .hasHeader)
        hasFinalNewline = try values.decode(Bool.self, forKey: .hasFinalNewline)
        decimalMark = try Self.singleCharacter(values.decode(String.self, forKey: .decimalMark), key: .decimalMark)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(encoding, forKey: .encoding)
        try values.encode(includesByteOrderMark, forKey: .includesByteOrderMark)
        try values.encode(String(delimiter), forKey: .delimiter)
        try values.encode(quote.map(String.init), forKey: .quote)
        try values.encode(quotePolicy, forKey: .quotePolicy)
        try values.encode(escapeMode, forKey: .escapeMode)
        try values.encode(lineEnding, forKey: .lineEnding)
        try values.encode(hasHeader, forKey: .hasHeader)
        try values.encode(hasFinalNewline, forKey: .hasFinalNewline)
        try values.encode(String(decimalMark), forKey: .decimalMark)
    }

    private static func singleCharacter(_ string: String, key: CodingKeys) throws -> Character {
        guard string.count == 1, let value = string.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [key], debugDescription: "Expected one character."))
        }
        return value
    }
}
