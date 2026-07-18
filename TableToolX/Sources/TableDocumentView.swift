import SwiftUI
import TableToolCore

struct TableDocumentView: View {
    @ObservedObject var viewModel: DocumentViewModel
    @State private var showingFilter = false
    @State private var showingFormat = false
    @State private var showingRename = false
    @State private var renamedColumn = ""
    @State private var formatDelimiter = ","
    @State private var formatQuote = "\""
    @State private var formatDialect = CSVDialect.standard

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.isFindVisible { findBar; Divider() }
            statusOverlay
            DataGridView(viewModel: viewModel)
                .allowsHitTesting(viewModel.activeOperation == nil)
            Divider()
            statusBar
        }
        .frame(minWidth: 700, minHeight: 420)
        .sheet(isPresented: $showingRename) { renameSheet }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false).fixedSize(horizontal: true, vertical: false)
            toolbarContent(compact: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .disabled(viewModel.activeOperation != nil)
    }

    private func toolbarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 8) {
            Menu {
                Button("Insert Row Above") { viewModel.addRow(after: false) }
                Button("Insert Row Below") { viewModel.addRow(after: true) }
            } label: {
                Label("Add Row", systemImage: "plus.rectangle.on.rectangle")
            }
                .menuStyle(.borderlessButton)
                .disabled(!viewModel.phase.isInteractive)
                .help("Insert Row Above or Below")
            Button { viewModel.deleteSelectedRows() } label: { Label("Delete Row", systemImage: "minus.rectangle") }
                .disabled(!viewModel.phase.isInteractive || viewModel.selectedRowIndexes.isEmpty)
                .help("Delete Selected Rows")
            Divider().frame(height: 22)
            Menu {
                Button("Insert Column Left") { viewModel.addColumn(relativeToSelectionAfter: false) }
                Button("Insert Column Right") { viewModel.addColumn(relativeToSelectionAfter: true) }
                Divider()
                Button("Append Column") { viewModel.addColumn() }
            } label: {
                Label("Add Column", systemImage: "rectangle.split.3x1")
            }
                .menuStyle(.borderlessButton)
                .disabled(!viewModel.phase.isInteractive)
                .help("Insert Column Left or Right")
            Button { viewModel.duplicateSelectedColumn() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .disabled(!viewModel.phase.isInteractive || selectedColumn == nil)
                .help("Duplicate Selected Column")
            Button { viewModel.deleteSelectedColumn() } label: { Label("Delete Column", systemImage: "rectangle.split.3x1.fill") }
                .disabled(!viewModel.phase.isInteractive || selectedColumn == nil || viewModel.columns.count <= viewModel.selectedColumnOrdinals.count)
                .help("Delete Selected Columns")
            Button { prepareRename() } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
                .disabled(!viewModel.phase.isInteractive || selectedColumn == nil)
                .help("Rename Selected Column")
            Button { viewModel.isFindVisible.toggle() } label: { Label("Find", systemImage: "magnifyingglass") }
                .disabled(!viewModel.phase.isInteractive)
                .help("Find and Replace")
            Button { showingFilter.toggle() } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                .popover(isPresented: $showingFilter, arrowEdge: .bottom) { filterPopover }
                .disabled(!viewModel.phase.isInteractive)
                .help("Filter Rows")
            Menu {
                if let selectedColumn {
                    Text("Sort \(selectedColumn.name)")
                    Button("Ascending") { viewModel.sortSelectedColumn(ascending: true) }
                    Button("Descending") { viewModel.sortSelectedColumn(ascending: false) }
                    Divider()
                    Picker("Compare Values As", selection: $viewModel.sortComparison) {
                        Text("Text").tag(ColumnComparison.text)
                        Text("Number").tag(ColumnComparison.number)
                        Text("ISO-8601 Date").tag(ColumnComparison.date)
                    }
                    Divider()
                    Text("Tip: double-click a column header to toggle direction")
                }
            } label: {
                Label("Sort", systemImage: sortSystemImage)
            }
                .menuStyle(.borderlessButton)
                .disabled(!viewModel.phase.isInteractive || selectedColumn == nil)
                .help(sortHelp)
            Button { viewModel.clearView() } label: { Label("Clear View", systemImage: "xmark.circle") }
                .disabled(!viewModel.phase.isInteractive)
                .help("Clear Sort and Filter")
            Spacer()
            Button { prepareFormat() } label: { Label("Format", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showingFormat, arrowEdge: .bottom) { formatPopover }
                .disabled(!viewModel.phase.allowsFormatChanges)
                .help("Document Format")
        }
        .buttonStyle(.borderless)
        .labelStyle(compact ? AnyLabelStyle.iconOnly : AnyLabelStyle.titleAndIcon)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $viewModel.findText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.runFind() }
            Button { viewModel.nextMatch(backwards: true) } label: { Image(systemName: "chevron.up") }
            Button { viewModel.nextMatch() } label: { Image(systemName: "chevron.down") }
            Toggle("Regex", isOn: $viewModel.findUsesRegex).toggleStyle(.checkbox)
            Toggle("Case", isOn: $viewModel.findIsCaseSensitive).toggleStyle(.checkbox)
            TextField("Replace", text: $viewModel.replaceText).textFieldStyle(.roundedBorder)
            Button("Replace All") { viewModel.replaceAll() }
                .disabled(!viewModel.phase.isInteractive || viewModel.findText.isEmpty)
            Button { viewModel.isFindVisible = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(8)
        .disabled(viewModel.activeOperation != nil)
    }

    @ViewBuilder private var statusOverlay: some View {
        if let operation = viewModel.activeOperation {
            HStack {
                ProgressView().controlSize(.small)
                Text(operation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { viewModel.cancelActiveOperation() }
            }
            .padding(8)
            .background(.bar)
        } else {
            switch viewModel.phase {
            case let .importing(fraction, rows):
                HStack {
                    ProgressView(value: fraction).frame(maxWidth: 260)
                    Text(viewModel.statusMessage.isEmpty ? "Indexing \(rows.formatted()) rows…" : viewModel.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { viewModel.cancelImport() }
                }
                .padding(8)
                .background(.bar)
            case .cancelled:
                HStack {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Import cancelled. The original file was not changed.")
                    Spacer()
                    Button("Retry") { viewModel.retryImport() }
                }
                .padding(8)
                .background(.bar)
            case let .failed(message):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("Open Best Effort") { viewModel.openBestEffort() }
                    Button("Adjust Format…") { prepareFormat() }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            default:
                EmptyView()
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(viewModel.statusMessage)
            if viewModel.warningCount > 0 {
                Label("\(viewModel.warningCount) warnings", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(viewModel.dialect.encoding.rawValue)
            Text("Delimiter \(display(viewModel.dialect.delimiter))")
            Text(viewModel.dialect.hasHeader ? "Header" : "No header")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    private var filterPopover: some View {
        Form {
            Picker("Column", selection: Binding(
                get: { viewModel.filterColumnID ?? viewModel.columns.first?.id ?? 0 },
                set: { viewModel.filterColumnID = $0 }
            )) {
                ForEach(viewModel.columns) { Text($0.name).tag($0.id) }
            }
            Picker("Compare as", selection: $viewModel.filterComparison) {
                Text("Text").tag(ColumnComparison.text)
                Text("Number").tag(ColumnComparison.number)
                Text("ISO-8601 Date").tag(ColumnComparison.date)
            }
            Picker("Rule", selection: $viewModel.filterOperation) {
                Text("Contains").tag(FilterOperator.contains)
                Text("Equals").tag(FilterOperator.equals)
                Text("Regular expression").tag(FilterOperator.regex)
                Text("Greater than").tag(FilterOperator.greaterThan)
                Text("Less than").tag(FilterOperator.lessThan)
                Text("Is empty").tag(FilterOperator.isEmpty)
                Text("Is not empty").tag(FilterOperator.isNotEmpty)
            }
            TextField("Value", text: $viewModel.filterValue)
                .disabled(viewModel.filterOperation == .isEmpty || viewModel.filterOperation == .isNotEmpty)
            HStack {
                Button("Clear") { viewModel.filterValue = ""; viewModel.clearView(); showingFilter = false }
                Spacer()
                Button("Apply") { viewModel.applyFilter(); showingFilter = false }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .padding(4)
    }

    private var formatPopover: some View {
        Form {
            Picker("Encoding", selection: $formatDialect.encoding) {
                ForEach(CSVEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Delimiter", text: $formatDelimiter)
            Picker("Quote", selection: $formatQuote) {
                Text("Double (\")").tag("\"")
                Text("Single (')").tag("'")
                Text("None").tag("")
            }
            Picker("Quote fields", selection: $formatDialect.quotePolicy) {
                Text("Only when needed").tag(CSVQuotePolicy.minimal)
                Text("Every field").tag(CSVQuotePolicy.allFields)
            }
            .disabled(formatQuote.isEmpty)
            Picker("Escape", selection: $formatDialect.escapeMode) {
                Text("Doubled quote").tag(CSVEscapeMode.doubledQuote)
                Text("Backslash").tag(CSVEscapeMode.backslash)
            }
            Picker("Line endings", selection: $formatDialect.lineEnding) {
                Text("LF").tag(CSVLineEnding.lf)
                Text("CRLF").tag(CSVLineEnding.crlf)
                Text("CR").tag(CSVLineEnding.cr)
            }
            Picker("Decimal mark", selection: $formatDialect.decimalMark) {
                Text(".").tag(Character("."))
                Text(",").tag(Character(","))
            }
            Toggle("First row is a header", isOn: $formatDialect.hasHeader)
            Toggle("Include final newline", isOn: $formatDialect.hasFinalNewline)
            Toggle("Include byte-order mark", isOn: $formatDialect.includesByteOrderMark)
                .disabled(!formatDialect.encoding.isUnicode)
            HStack {
                Spacer()
                Button(viewModel.formatActionTitle) {
                    viewModel.applyFormat(formatDialect, delimiterText: formatDelimiter, quoteText: formatQuote)
                    showingFormat = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding(4)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Column").font(.headline)
            TextField("Column name", text: $renamedColumn)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingRename = false }
                Button("Rename") {
                    if let selectedColumn { viewModel.renameColumn(selectedColumn, to: renamedColumn) }
                    showingRename = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var selectedColumn: WorkspaceColumn? {
        guard let index = viewModel.selectedColumnOrdinals.first, index < viewModel.columns.count else { return nil }
        return viewModel.columns[index]
    }

    private var sortSystemImage: String {
        guard selectedColumn?.id == viewModel.activeSortColumnID else { return "arrow.up.arrow.down" }
        return viewModel.activeSortAscending ? "arrow.up" : "arrow.down"
    }

    private var sortHelp: String {
        guard let id = viewModel.activeSortColumnID,
              let column = viewModel.columns.first(where: { $0.id == id }) else {
            return "Choose an ascending or descending sort for the selected column"
        }
        let direction = viewModel.activeSortAscending ? "ascending" : "descending"
        return "Sorted by \(column.name), \(direction), comparing values as \(viewModel.sortComparison.displayName.lowercased())"
    }

    private func prepareRename() {
        guard let selectedColumn else { return }
        renamedColumn = selectedColumn.name
        showingRename = true
    }

    private func prepareFormat() {
        formatDialect = viewModel.dialect
        formatDelimiter = String(viewModel.dialect.delimiter)
        formatQuote = viewModel.dialect.quote.map(String.init) ?? ""
        showingFormat = true
    }

    private func display(_ character: Character) -> String {
        switch character {
        case "\t": "Tab"
        case " ": "Space"
        default: String(character)
        }
    }
}

extension ColumnComparison {
    var displayName: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .date: "ISO-8601 Date"
        }
    }
}
