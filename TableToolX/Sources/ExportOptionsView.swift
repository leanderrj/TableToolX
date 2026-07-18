import SwiftUI
import TableToolCore

@MainActor
final class ExportOptionsModel: ObservableObject {
    @Published var encoding: CSVEncoding
    @Published var delimiter: String
    @Published var quote: String
    @Published var quotePolicy: CSVQuotePolicy
    @Published var escapeMode: CSVEscapeMode
    @Published var lineEnding: CSVLineEnding
    @Published var hasHeader: Bool
    @Published var hasFinalNewline: Bool
    @Published var includesByteOrderMark: Bool
    let decimalMark: Character

    init(dialect: CSVDialect) {
        encoding = dialect.encoding
        delimiter = String(dialect.delimiter)
        quote = dialect.quote.map(String.init) ?? ""
        quotePolicy = dialect.quotePolicy
        escapeMode = dialect.escapeMode
        lineEnding = dialect.lineEnding
        hasHeader = dialect.hasHeader
        hasFinalNewline = dialect.hasFinalNewline
        includesByteOrderMark = dialect.includesByteOrderMark
        decimalMark = dialect.decimalMark
    }

    func makeDialect() throws -> CSVDialect {
        guard delimiter.count == 1, let delimiterCharacter = delimiter.first,
              delimiterCharacter != "\n", delimiterCharacter != "\r",
              quote.count <= 1, quote.first != delimiterCharacter else {
            throw CSVParseDiagnostic(
                reason: .invalidDialect,
                location: CSVSourceLocation(byteOffset: 0, record: 1, field: 1, line: 1),
                detail: "The export delimiter must be one character and differ from the optional quote character."
            )
        }
        return CSVDialect(
            encoding: encoding,
            includesByteOrderMark: includesByteOrderMark && encoding.isUnicode,
            delimiter: delimiterCharacter,
            quote: quote.first,
            quotePolicy: quote.isEmpty ? .minimal : quotePolicy,
            escapeMode: escapeMode,
            lineEnding: lineEnding,
            hasHeader: hasHeader,
            hasFinalNewline: hasFinalNewline,
            decimalMark: decimalMark
        )
    }
}

struct ExportOptionsView: View {
    @ObservedObject var options: ExportOptionsModel

    var body: some View {
        Form {
            Picker("Encoding", selection: $options.encoding) {
                ForEach(CSVEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Delimiter", text: $options.delimiter)
            Picker("Quote", selection: $options.quote) {
                Text("Double (\")").tag("\"")
                Text("Single (')").tag("'")
                Text("None").tag("")
            }
            Picker("Quote fields", selection: $options.quotePolicy) {
                Text("Only when needed").tag(CSVQuotePolicy.minimal)
                Text("Every field").tag(CSVQuotePolicy.allFields)
            }
            .disabled(options.quote.isEmpty)
            Picker("Escape", selection: $options.escapeMode) {
                Text("Doubled quote").tag(CSVEscapeMode.doubledQuote)
                Text("Backslash").tag(CSVEscapeMode.backslash)
            }
            Picker("Line endings", selection: $options.lineEnding) {
                Text("LF").tag(CSVLineEnding.lf)
                Text("CRLF").tag(CSVLineEnding.crlf)
                Text("CR").tag(CSVLineEnding.cr)
            }
            Toggle("Include column names", isOn: $options.hasHeader)
            Toggle("Include final newline", isOn: $options.hasFinalNewline)
            Toggle("Include byte-order mark", isOn: $options.includesByteOrderMark)
                .disabled(!options.encoding.isUnicode)
        }
        .formStyle(.grouped)
        .frame(width: 390, height: 340)
        .accessibilityLabel("Export format options")
    }
}
