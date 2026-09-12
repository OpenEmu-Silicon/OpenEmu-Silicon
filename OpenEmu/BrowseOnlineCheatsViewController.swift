// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Cocoa
import OpenEmuKit
import os.log

private let log = Logger(subsystem: "org.openemu.OpenEmu", category: "BrowseOnlineCheatsViewController")

final class BrowseOnlineCheatsViewController: NSViewController {

    // MARK: - Document reference
    weak var gameDocument: OEGameDocument?

    // MARK: - Game Info Panel
    private var gameLabel: NSTextField!
    private var serialLabel: NSTextField!
    private var systemLabel: NSTextField!
    private var md5Label: NSTextField!
    private var coreLabel: NSTextField!

    // MARK: - Filter Panel
    private var nameFilterField: NSTextField!
    private var statusFilterRadios: [NSButton] = []

    private var statusFilter: StatusFilter = .all
    private var nameFilter = ""

    /// Below this a name filter is treated as empty, so single letters don't wipe the list.
    private static let minimumNameFilterLength = 2

    enum StatusFilter: Int {
        case all = 0
        case working = 1
        case notWorking = 2
        case notSet = 3
    }

    // MARK: - Results Table
    private var resultsTableView: NSTableView!
    private var resultsScrollView: NSScrollView!
    private var loadingSpinner: NSProgressIndicator?
    private var isLoading = false
    private var hasLoaded = false

    /// Fetched cheats kept in memory so filtering can work off them without refetching.
    private var cheats: [DatabaseCheat] = []

    /// The subset the table actually shows.
    private var visibleCheats: [DatabaseCheat] = []

    private var resultsCountLabel: NSTextField!
    private var emptyStateLabel: NSTextField!

    /// Maximum rows handed to the table. Matches are kept in full in `visibleCheats`,
    /// so the count reported below the table is still the real one.
    private static let displayLimit = 100

    /// User-reported status for the current core build, keyed by normalized code.
    private var statuses: [String: CheatFeedbackStatus] = [:]
    private var notes: [String: String] = [:]

    /// Normalized codes of cheats already in the user's inventory that came from elsewhere
    /// (manual "Add Cheat" or Cheat Search) — these block Import rather than offering Remove.
    private var otherSourceCodeKeys: Set<String> = []
    /// Normalized codes of cheats this feature itself imported, recomputed whenever the table reloads.
    private var importedCodeKeys: Set<String> = []

    enum ImportState {
        case notImported
        case importedByThisFeature
        case usedElsewhere
    }

    enum CheatStatus: Int {
        case works = 0
        case doesNotWork = 1
        case unknown = 2
    }

    /// Applied to each row's cell so the content matches its column header.
    private var columnAlignments: [NSUserInterfaceItemIdentifier: NSTextAlignment] = [:]

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let infoPanel = makeGameInfoPanel()
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoPanel)

        let filterPanel = makeFilterPanel()
        filterPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterPanel)

        let resultsScrollView = makeResultsTable()
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultsScrollView)
        self.resultsScrollView = resultsScrollView

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.maximumNumberOfLines = 1
        countLabel.allowsExpansionToolTips = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countLabel)
        resultsCountLabel = countLabel

        let emptyLabel = NSTextField(labelWithString: NSLocalizedString("No cheats found", comment: "Browse online cheats empty table"))
        emptyLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        emptyStateLabel = emptyLabel

        NSLayoutConstraint.activate([
            infoPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            infoPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            infoPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            filterPanel.topAnchor.constraint(equalTo: infoPanel.bottomAnchor),
            filterPanel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor),
            filterPanel.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor),

            resultsScrollView.topAnchor.constraint(equalTo: filterPanel.bottomAnchor, constant: 12),
            resultsScrollView.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor),

            countLabel.topAnchor.constraint(equalTo: resultsScrollView.bottomAnchor, constant: 6),
            countLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor),
            countLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: resultsScrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: resultsScrollView.centerYAnchor),
        ])

        updateGameInfo()
        updateResultsCountLabel()
    }

    // MARK: - Results Table

    private func makeResultsTable() -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let header = ResultsHeaderView()
        header.infoIconRect = { [weak self] in self?.statusHeaderIconRect() }
        header.onInfoIconClick = { [weak self, weak header] rect in
            guard let self, let header else { return }
            self.showStatusHeaderInfo(from: rect, in: header)
        }
        tableView.headerView = header
        tableView.style = .fullWidth
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // Fixed, and does not grow for taller cell views — buttons and badges need this room.
        tableView.rowHeight = 28

        let columns: [(String, String, CGFloat, NSTextAlignment)] = [
            ("name", NSLocalizedString("Cheat Name", comment: "Browse online cheats table column header"), 362, .left),
            ("provider", NSLocalizedString("Provider", comment: "Browse online cheats table column header"), 100, .left),
            ("status", NSLocalizedString("Status", comment: "Browse online cheats table column header"), 100, .center),
            ("code", NSLocalizedString("Code", comment: "Browse online cheats table column header"), 40, .center),
            ("notes", NSLocalizedString("Notes", comment: "Browse online cheats table column header"), 40, .center),
            ("action", NSLocalizedString("Action", comment: "Browse online cheats table column header"), 80, .center),
        ]

        for (index, column) in columns.enumerated() {
            let (identifier, title, width, alignment) = column
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.headerCell.alignment = alignment

            if index == 0 {
                tableColumn.minWidth = 150
                tableColumn.maxWidth = .greatestFiniteMagnitude
                tableColumn.resizingMask = .autoresizingMask
            } else {
                // Locked so the first column is the only one that absorbs width changes.
                tableColumn.minWidth = width
                tableColumn.maxWidth = width
                tableColumn.resizingMask = []
            }

            tableView.addTableColumn(tableColumn)
            columnAlignments[tableColumn.identifier] = alignment
        }

        resultsTableView = tableView
        updateStatusHeader()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    // MARK: - Filter Panel

    // TODO: apply these controls to the results table.
    private func makeFilterPanel() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 8
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        let infoRow = makeFilterInfoRow()
        outerStack.addArrangedSubview(infoRow)

        let controlsRow = NSStackView(views: [makeNameFilterView(), makeStatusFilterView()])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .firstBaseline
        controlsRow.distribution = .fill
        controlsRow.spacing = 20
        outerStack.addArrangedSubview(controlsRow)

        box.contentView?.addSubview(outerStack)
        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            ])
        }
        controlsRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        return box
    }

    private func makeFilterInfoRow() -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        icon.contentTintColor = .systemBlue
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: NSLocalizedString("Use the controls below to filter by name and the status you chose",
                                                                  comment: "Browse online cheats filter panel hint"))
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemBlue
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.allowsExpansionToolTips = true

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func makeNameFilterView() -> NSView {
        let label = NSTextField(labelWithString: "\(NSLocalizedString("Name", comment: "Browse online cheats filter label")):")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let field = NSTextField()
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.stringValue = nameFilter
        field.delegate = self
        nameFilterField = field

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 6
        // Low hugging lets this column absorb the width the status column doesn't need.
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeStatusFilterView() -> NSView {
        let label = NSTextField(labelWithString: "\(NSLocalizedString("Status", comment: "Browse online cheats filter label")):")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let titles = [
            NSLocalizedString("All", comment: "Browse online cheats status filter option"),
            NSLocalizedString("Working", comment: "Browse online cheats status filter option"),
            NSLocalizedString("Not Working", comment: "Browse online cheats status filter option"),
            NSLocalizedString("Not set", comment: "Browse online cheats status filter option"),
        ]

        var views: [NSView] = [label]
        for (index, title) in titles.enumerated() {
            let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(statusFilterChanged(_:)))
            radio.controlSize = .small
            radio.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            radio.tag = index
            radio.state = index == statusFilter.rawValue ? .on : .off
            views.append(radio)
            statusFilterRadios.append(radio)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 8
        row.setContentHuggingPriority(.required, for: .horizontal)
        row.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    @objc private func statusFilterChanged(_ sender: NSButton) {
        guard let filter = StatusFilter(rawValue: sender.tag) else { return }
        statusFilter = filter
        applyFilters()
    }

    private func applyFilters() {
        // Kept untrimmed so a leading space is meaningful — " 1" matches "Level 1"
        // without also matching "10". Whitespace-only input still counts as no filter.
        let name = nameFilter
        let matchesName = name.count >= Self.minimumNameFilterLength
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        refreshImportedCodeKeys()

        visibleCheats = cheats.filter { cheat in
            if matchesName, !cheat.name.localizedCaseInsensitiveContains(name) {
                return false
            }

            switch statusFilter {
            case .all: return true
            case .working: return status(for: cheat) == .works
            case .notWorking: return status(for: cheat) == .doesNotWork
            case .notSet: return status(for: cheat) == .unknown
            }
        }

        resultsTableView?.reloadData()
        updateResultsCountLabel()
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyStateLabel?.isHidden = isLoading || !visibleCheats.isEmpty
    }

    /// Reports the match count, and says so plainly when the table is only showing
    /// a capped subset of them.
    private func updateResultsCountLabel() {
        guard let label = resultsCountLabel else { return }
        let count = visibleCheats.count

        if count == 0 {
            label.stringValue = ""
        } else if count > Self.displayLimit {
            label.stringValue = String(
                format: NSLocalizedString("Showing first %1$@ of %2$@ cheats. Narrow your search.",
                                          comment: "Browse online cheats result count when capped"),
                NumberFormatter.localizedString(from: NSNumber(value: Self.displayLimit), number: .decimal),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            )
        } else if count == 1 {
            label.stringValue = String(
                format: NSLocalizedString("%@ result found", comment: "Browse online cheats single result count"),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            )
        } else {
            label.stringValue = String(
                format: NSLocalizedString("%@ results found", comment: "Browse online cheats result count"),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            )
        }
    }

    // MARK: - Status Column Header

    private static let statusHeaderHint = NSLocalizedString("Mark if the cheat worked for you or not",
                                                           comment: "Browse online cheats status column tooltip")

    private var statusHeaderIconSize: NSSize = .zero
    private var statusHeaderTitle: NSAttributedString?
    private var statusHeaderPopover: NSPopover?

    /// Header cells take an attributed string but no subviews, so the icon rides
    /// along as a text attachment.
    private func updateStatusHeader() {
        guard let column = resultsTableView?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("status")) else { return }

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let title = NSMutableAttributedString(
            string: NSLocalizedString("Status", comment: "Browse online cheats table column header") + " ",
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )

        if let icon = statusHeaderIcon(font: font) {
            statusHeaderIconSize = icon.size
            let attachment = NSTextAttachment()
            attachment.image = icon
            // Centred on the text's cap height, otherwise it sits on the baseline.
            attachment.bounds = CGRect(x: 0,
                                       y: (font.capHeight - icon.size.height) / 2,
                                       width: icon.size.width,
                                       height: icon.size.height)
            let attachmentString = NSMutableAttributedString(attachment: attachment)
            attachmentString.addAttribute(.paragraphStyle, value: paragraph,
                                          range: NSRange(location: 0, length: attachmentString.length))
            title.append(attachmentString)
        }

        column.headerCell.attributedStringValue = title
        statusHeaderTitle = title
        resultsTableView?.headerView?.needsDisplay = true
    }

    /// Text attachments don't take the cell's text colour, so the symbol is tinted
    /// for the current appearance and rebuilt when that changes.
    private func statusHeaderIcon(font: NSFont) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "info.circle", accessibilityDescription: Self.statusHeaderHint)?
            .withSymbolConfiguration(config)
        else { return nil }

        var tint = NSColor.secondaryLabelColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .secondaryLabelColor
        }

        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// The icon's rect inside the header, derived from the centred title's measured
    /// width — header cells expose no layout information.
    private func statusHeaderIconRect() -> NSRect? {
        guard let tableView = resultsTableView,
              let header = tableView.headerView,
              let title = statusHeaderTitle,
              statusHeaderIconSize.width > 0
        else { return nil }

        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("status"))
        guard column >= 0 else { return nil }

        let headerRect = header.headerRect(ofColumn: column)
        let textWidth = title.size().width
        let iconSize = statusHeaderIconSize

        return NSRect(x: headerRect.midX + textWidth / 2 - iconSize.width,
                      y: headerRect.midY - iconSize.height / 2,
                      width: iconSize.width,
                      height: iconSize.height)
    }

    private func showStatusHeaderInfo(from rect: NSRect, in header: NSView) {
        let maxWidth: CGFloat = 220

        let label = NSTextField(wrappingLabelWithString: Self.statusHeaderHint)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        // Wrapping labels need this to resolve a height from a bounded width.
        label.preferredMaxLayoutWidth = maxWidth
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(equalToConstant: maxWidth),
        ])

        content.layoutSubtreeIfNeeded()
        content.frame = NSRect(origin: .zero, size: content.fittingSize)

        let controller = NSViewController()
        controller.view = content

        let popover = NSPopover()
        popover.contentViewController = controller
        // Without this the popover collapses to a default minimum.
        popover.contentSize = content.fittingSize
        popover.behavior = .transient
        popover.show(relativeTo: rect, of: header, preferredEdge: .maxY)
        statusHeaderPopover = popover
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Also covers appearance changes, which redraw the header and need a retinted icon.
        updateStatusHeader()
    }

    // MARK: - Game Info Panel

    private func makeGameInfoPanel() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle
        // Draws nothing, so the panel reads as part of the window rather than a second card.
        box.isTransparent = true

        let gameTitle = makeTitleLabel(NSLocalizedString("Game", comment: "Browse online cheats info label"), width: 60)
        gameLabel = makeValueLabel(width: 280)
        let md5Title = makeTitleLabel(NSLocalizedString("MD5", comment: "Browse online cheats info label"), width: 40)
        md5Label = makeValueLabel(width: 220)

        let systemTitle = makeTitleLabel(NSLocalizedString("System", comment: "Browse online cheats info label"), width: 60)
        systemLabel = makeValueLabel(width: 140)
        let coreTitle = makeTitleLabel(NSLocalizedString("Core", comment: "Browse online cheats info label"), width: 60)
        coreTitle.alignment = .right
        coreLabel = makeValueLabel(width: 140)
        let serialTitle = makeTitleLabel(NSLocalizedString("Version", comment: "Browse online cheats info label"), width: 60)
        serialTitle.alignment = .right
        serialLabel = makeValueLabel(width: 140)

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 6
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        outerStack.addArrangedSubview(makeInfoRow(cells: [gameTitle, gameLabel, md5Title, md5Label],
                                                 gapsAfter: [gameLabel]))
        outerStack.addArrangedSubview(makeInfoRow(cells: [systemTitle, systemLabel, coreTitle, coreLabel, serialTitle, serialLabel],
                                                 gapsAfter: [systemLabel, coreLabel]))

        box.contentView?.addSubview(outerStack)
        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                outerStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
                outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            ])
        }

        return box
    }

    /// `gapsAfter` marks the views that end a field, so the wider gap separates
    /// fields rather than a title from its own value.
    private func makeInfoRow(cells: [NSView], gapsAfter: [NSView] = []) -> NSStackView {
        let row = NSStackView(views: cells)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 4
        gapsAfter.forEach { row.setCustomSpacing(20, after: $0) }
        return row
    }

    private func makeTitleLabel(_ title: String, width: CGFloat) -> NSTextField {
        let label = makeInfoLabel(width: width)
        label.stringValue = "\(title):"
        label.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeValueLabel(width: CGFloat) -> NSTextField {
        let label = makeInfoLabel(width: width)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    private func makeInfoLabel(width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        // AppKit shows this only while the text is actually clipped.
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func updateGameInfo() {
        guard let document = gameDocument else { return }
        let placeholder = "—"
        gameLabel.stringValue = document.rom.game?.displayName ?? placeholder
        md5Label.stringValue = document.rom.md5Hash ?? placeholder
        systemLabel.stringValue = document.systemPlugin.systemName
        coreLabel.stringValue = document.corePlugin.displayName
        serialLabel.stringValue = document.rom.serial ?? placeholder
        view.needsLayout = true
    }

    // MARK: - Loading Indicator

    private func showLoadingIndicator() {
        isLoading = true

        if loadingSpinner == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .regular
            spinner.translatesAutoresizingMaskIntoConstraints = false
            resultsScrollView.superview?.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: resultsScrollView.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: resultsScrollView.centerYAnchor),
            ])
            loadingSpinner = spinner
        }
        loadingSpinner?.startAnimation(nil)
        loadingSpinner?.isHidden = false
        resultsTableView.isEnabled = false
        updateEmptyState()
    }

    private func hideLoadingIndicator() {
        isLoading = false
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
        resultsTableView.isEnabled = true
        updateEmptyState()
    }

    // MARK: - Online Cheats

    func fetchOnlineCheats() {
        guard !isLoading, !hasLoaded else { return }
        guard let document = gameDocument else { return }
        guard let md5 = document.rom.md5Hash else { return }
        let systemID = document.systemPlugin.systemIdentifier
        let coreID = document.corePlugin.bundleIdentifier
        let serial = document.rom.serial
        let gameName = document.rom.game?.displayName
        let romURL = document.rom.url

        showLoadingIndicator()

        statuses = CheatFeedbackService.shared.statuses(forMD5: md5,
                                                       systemIdentifier: systemID,
                                                       coreIdentifier: coreID,
                                                       coreVersion: document.corePlugin.version)
        notes = CheatFeedbackService.shared.notes(forMD5: md5,
                                                 systemIdentifier: systemID,
                                                 coreIdentifier: coreID,
                                                 coreVersion: document.corePlugin.version)

        Task {
            do {
                let results = try await CheatDatabaseService.shared.cheats(forMD5: md5, serial: serial, gameName: gameName, romURL: romURL, systemIdentifier: systemID, coreIdentifier: coreID)
                let sorted = results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                cheats = Self.disambiguatingDuplicateNames(sorted)
                hasLoaded = true
            } catch {
                // NSLog("[Cheats] Browse Online failed: %@", error.localizedDescription)
                cheats = []
            }
            applyFilters()
            hideLoadingIndicator()
        }
    }

    // The Libretro CHT format has no notion of grouping (e.g. per-character cheats in an RPG),
    // so identically named cheats are otherwise indistinguishable in the list.
    // Scoped per provider — one provider's naming collisions shouldn't inflate another's count.
    private static func disambiguatingDuplicateNames(_ cheats: [DatabaseCheat]) -> [DatabaseCheat] {
        func key(_ cheat: DatabaseCheat) -> String { "\(cheat.providerName)\0\(cheat.name)" }

        var totalCounts: [String: Int] = [:]
        for cheat in cheats { totalCounts[key(cheat), default: 0] += 1 }

        var seenCounts: [String: Int] = [:]
        return cheats.map { cheat in
            let total = totalCounts[key(cheat)] ?? 1
            guard total > 1 else { return cheat }
            let index = (seenCounts[key(cheat)] ?? 0) + 1
            seenCounts[key(cheat)] = index
            let disambiguatedName = String(
                format: NSLocalizedString("%1$@ (%2$d of %3$d)",
                                          comment: "Browse online cheats: disambiguates multiple cheats sharing the same name, e.g. \"99 Magic (2 of 7)\""),
                cheat.name, index, total
            )
            return DatabaseCheat(name: disambiguatedName, code: cheat.code, providerName: cheat.providerName, rawCode: cheat.rawCode)
        }
    }

    /// Feedback is scoped to a core build, so switching cores invalidates both the
    /// fetched list and the reports shown against it.
    func resetForCoreChange() {
        cheats = []
        visibleCheats = []
        statuses = [:]
        notes = [:]
        hasLoaded = false

        statusFilter = .all
        nameFilter = ""
        nameFilterField?.stringValue = ""
        for radio in statusFilterRadios {
            radio.state = radio.tag == StatusFilter.all.rawValue ? .on : .off
        }

        resultsTableView?.reloadData()
        updateGameInfo()
        fetchOnlineCheats()
    }

    /// Re-syncs status/import state without a refetch. Cheats can be added, edited, or removed
    /// from elsewhere (Cheat Search, the game menu, this window's own Remove button) while this
    /// window isn't focused, so the table would otherwise keep showing a stale Status/Import state.
    func refreshDynamicState() {
        guard hasLoaded else { return }
        refreshStatuses()
        refreshImportedCodeKeys()
        resultsTableView?.reloadData()
    }
}

// MARK: - Table Data Source

extension BrowseOnlineCheatsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        min(visibleCheats.count, Self.displayLimit)
    }
}

// MARK: - Name Filter

extension BrowseOnlineCheatsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameFilterField else { return }
        nameFilter = nameFilterField.stringValue
        applyFilters()
    }
}

// MARK: - Results Header View

/// Routes clicks on the Status info icon to a callback, leaving every other click
/// to the normal header behaviour.
final class ResultsHeaderView: NSTableHeaderView {

    var infoIconRect: (() -> NSRect?)?
    var onInfoIconClick: ((NSRect) -> Void)?

    private func hitRect() -> NSRect? {
        // Widened so the small glyph is comfortable to hit.
        infoIconRect?()?.insetBy(dx: -4, dy: -4)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let rect = hitRect(), rect.contains(point), let iconRect = infoIconRect?() {
            onInfoIconClick?(iconRect)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let rect = hitRect() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }
}

// MARK: - Table Delegate

extension BrowseOnlineCheatsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row < visibleCheats.count else { return nil }
        let cheat = visibleCheats[row]

        if identifier.rawValue == "action" {
            return makeActionCell(in: tableView, state: importState(for: cheat))
        }

        if identifier.rawValue == "code" {
            return makeCodeCell(in: tableView)
        }

        if identifier.rawValue == "notes" {
            let cell = makeNotesCell(in: tableView)
            cell.configure(hasNotes: hasNotes(for: cheat))
            return cell
        }

        if identifier.rawValue == "status" {
            let cell = makeStatusCell(in: tableView)
            cell.configure(status: status(for: cheat))
            return cell
        }

        if identifier.rawValue == "provider" {
            let cell = makeProviderCell(in: tableView)
            cell.textField?.stringValue = cheat.providerName
            cell.textField?.alignment = columnAlignments[identifier] ?? .left
            cell.imageView?.image = providerIcon(for: cheat.providerName)
            return cell
        }

        let cell = makeTextCell(in: tableView)

        switch identifier.rawValue {
        case "name":
            cell.textField?.stringValue = cheat.name
        default:
            cell.textField?.stringValue = ""
        }
        cell.textField?.alignment = columnAlignments[identifier] ?? .left

        return cell
    }

    private func providerIcon(for providerName: String) -> NSImage? {
        switch providerName {
        case "OpenEmu": return NSImage(named: "cheat_provider_openemu")
        case "Libretro": return NSImage(named: "cheat_provider_libretro")
        default: return nil
        }
    }

    private func makeProviderCell(in tableView: NSTableView) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier("BrowseOnlineCheatsProviderCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = cellID

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    private func makeTextCell(in tableView: NSTableView) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier("BrowseOnlineCheatsCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = cellID

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        // AppKit shows this only while the text is actually clipped.
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    private func refreshImportedCodeKeys() {
        let allCheats = gameDocument?.cheats ?? []
        otherSourceCodeKeys = Set(allCheats.filter { $0.cheatSource == nil }.map { CheatFeedbackService.key(for: $0.code) })
        importedCodeKeys = Set(allCheats.filter { $0.cheatSource != nil }.map { CheatFeedbackService.key(for: $0.code) })
    }

    private func importState(for cheat: DatabaseCheat) -> ImportState {
        let key = CheatFeedbackService.key(for: cheat.code)
        if importedCodeKeys.contains(key) { return .importedByThisFeature }
        if otherSourceCodeKeys.contains(key) { return .usedElsewhere }
        return .notImported
    }

    // Muted rather than fully saturated, so the buttons read as a hint, not an alert.
    private static let importButtonColor = NSColor.systemGreen.blended(withFraction: 0.65, of: .systemGray)?.withAlphaComponent(0.2)
    private static let removeButtonColor = NSColor.systemRed.blended(withFraction: 0.65, of: .systemGray)?.withAlphaComponent(0.35)

    private func makeActionCell(in tableView: NSTableView, state: ImportState) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("BrowseOnlineCheatsActionCell")
        let container: NSView
        let button: NSButton

        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil),
           let existingButton = existing.subviews.first as? NSButton {
            container = existing
            button = existingButton
        } else {
            container = NSView()
            container.identifier = cellID

            button = NSButton(title: "", target: self, action: #selector(importClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)

            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }

        switch state {
        case .notImported:
            button.title = NSLocalizedString("Import", comment: "Browse online cheats row action button")
            button.isEnabled = true
            button.toolTip = nil
            button.bezelColor = Self.importButtonColor
        case .importedByThisFeature:
            button.title = NSLocalizedString("Remove", comment: "Browse online cheats row action button, removes a previously imported cheat")
            button.isEnabled = true
            button.toolTip = nil
            button.bezelColor = Self.removeButtonColor
        case .usedElsewhere:
            button.title = NSLocalizedString("Import", comment: "Browse online cheats row action button")
            button.isEnabled = false
            button.toolTip = NSLocalizedString("Code already used", comment: "Browse online cheats import button tooltip when the code is already in the user's inventory")
            button.bezelColor = nil
        }

        return container
    }

    private func makeCodeCell(in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("BrowseOnlineCheatsCodeCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) {
            return existing
        }
        let container = NSView()
        container.identifier = cellID

        let description = NSLocalizedString("Click to see the code", comment: "Browse online cheats code button description")
        let button = NSButton(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: description) ?? NSImage(),
                              target: self,
                              action: #selector(showCodeClicked(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = description
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    @objc private func showCodeClicked(_ sender: NSButton) {
        let row = resultsTableView.row(for: sender)
        guard row >= 0, row < visibleCheats.count else { return }
        let cheat = visibleCheats[row]
        // log.debug("rawCode for '\(cheat.name, privacy: .public)': \(cheat.rawCode, privacy: .public)")
        presentCodeDialog(for: cheat)
    }

    // MARK: - Notes Column

    private func hasNotes(for cheat: DatabaseCheat) -> Bool {
        !(notes[statusKey(for: cheat)]?.isEmpty ?? true)
    }

    private func makeNotesCell(in tableView: NSTableView) -> NotesCellView {
        let cellID = NSUserInterfaceItemIdentifier("BrowseOnlineCheatsNotesCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? NotesCellView {
            return existing
        }

        let cell = NotesCellView(target: self, action: #selector(notesClicked(_:)))
        cell.identifier = cellID
        return cell
    }

    @objc private func notesClicked(_ sender: NSButton) {
        let row = resultsTableView.row(for: sender)
        guard row >= 0, row < visibleCheats.count else { return }
        presentNotesDialog(for: visibleCheats[row])
    }

    private func presentNotesDialog(for cheat: DatabaseCheat) {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Notes", comment: "Cheat notes dialog title")
        alert.informativeText = cheat.name
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "Cheat notes dialog button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cheat notes dialog button"))

        let accessory = makeNotesAccessoryView(notes: notes[statusKey(for: cheat)] ?? "",
                                               currentStatus: statuses[statusKey(for: cheat)])
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.textView

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.saveNotes(accessory.textView.string, feedbackSegment: accessory.feedback.selectedSegment, for: cheat)
        }
    }

    private func saveNotes(_ text: String, feedbackSegment: Int, for cheat: DatabaseCheat) {
        let key = statusKey(for: cheat)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[key] = trimmed.isEmpty ? nil : trimmed

        // Feedback here is optional: only write a status when the user actually picked a segment.
        let feedback: CheatFeedbackStatus?
        switch feedbackSegment {
        case 0: feedback = .works
        case 1: feedback = .doesNotWork
        case 2: feedback = .unknown
        default: feedback = nil
        }

        if let document = gameDocument, let md5 = document.rom.md5Hash {
            CheatFeedbackService.shared.setNotes(trimmed,
                                                forCode: cheat.code,
                                                md5: md5,
                                                systemIdentifier: document.systemPlugin.systemIdentifier,
                                                coreIdentifier: document.corePlugin.bundleIdentifier,
                                                coreVersion: document.corePlugin.version,
                                                rawCode: cheat.rawCode,
                                                provider: cheat.providerName,
                                                gameName: document.rom.game?.displayName,
                                                serial: document.rom.serial,
                                                raHash: document.retroAchievementsSessionInfo?[OERetroAchievementsGameHashKey] as? String)

            if let feedback {
                CheatFeedbackService.shared.setStatus(feedback,
                                                     forCode: cheat.code,
                                                     md5: md5,
                                                     systemIdentifier: document.systemPlugin.systemIdentifier,
                                                     coreIdentifier: document.corePlugin.bundleIdentifier,
                                                     coreVersion: document.corePlugin.version,
                                                     rawCode: cheat.rawCode,
                                                     provider: cheat.providerName,
                                                     gameName: document.rom.game?.displayName,
                                                     serial: document.rom.serial,
                                                     raHash: document.retroAchievementsSessionInfo?[OERetroAchievementsGameHashKey] as? String)
                statuses[key] = feedback
            }
        }

        // A new status can change status-based filtering; otherwise just refresh the notes indicator.
        if feedback != nil {
            applyFilters()
        } else {
            resultsTableView?.reloadData()
        }
    }

    /// Editable notes with an optional efficacy report below, so the user can leave a note
    /// without being forced to rate the cheat.
    private func makeNotesAccessoryView(notes: String, currentStatus: CheatFeedbackStatus?)
        -> (view: NSView, textView: NSTextView, feedback: NSSegmentedControl) {
        let width: CGFloat = 380

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        textView.string = notes
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: NSLocalizedString("Did it work?", comment: "Cheat notes dialog optional feedback prompt"))
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor

        let feedback = NSSegmentedControl(labels: [
            NSLocalizedString("Working", comment: "Cheat status feedback option"),
            NSLocalizedString("Not Working", comment: "Cheat status feedback option"),
            NSLocalizedString("I don't know", comment: "Cheat status feedback option"),
        ], trackingMode: .selectOne, target: nil, action: nil)
        feedback.selectedSegment = Self.notesFeedbackSegment(for: currentStatus)

        let feedbackRow = NSStackView(views: [label, feedback])
        feedbackRow.orientation = .horizontal
        feedbackRow.spacing = 8
        feedbackRow.alignment = .centerY

        let container = NSStackView(views: [scrollView, feedbackRow])
        container.orientation = .vertical
        container.spacing = 8
        container.alignment = .leading

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: width),
            scrollView.heightAnchor.constraint(equalToConstant: 120),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(origin: .zero, size: container.fittingSize)

        return (container, textView, feedback)
    }

    /// Segment index for the optional feedback control; -1 (no selection) when there's no report yet.
    private static func notesFeedbackSegment(for status: CheatFeedbackStatus?) -> Int {
        switch status {
        case .works: return 0
        case .doesNotWork: return 1
        case .unknown: return 2
        case nil: return -1
        }
    }

    // MARK: - Status Cell

    private func statusKey(for cheat: DatabaseCheat) -> String {
        CheatFeedbackService.key(for: cheat.code)
    }

    private func status(for cheat: DatabaseCheat) -> CheatStatus? {
        switch statuses[statusKey(for: cheat)] {
        case .works: return .works
        case .doesNotWork: return .doesNotWork
        case .unknown: return .unknown
        case nil: return nil
        }
    }

    private func makeStatusCell(in tableView: NSTableView) -> StatusCellView {
        let cellID = NSUserInterfaceItemIdentifier("BrowseOnlineCheatsStatusCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? StatusCellView {
            return existing
        }

        let cell = StatusCellView(target: self, action: #selector(statusClicked(_:)))
        cell.identifier = cellID
        return cell
    }

    @objc private func statusClicked(_ sender: NSButton) {
        let row = resultsTableView.row(for: sender)
        guard row >= 0, row < visibleCheats.count,
              let status = CheatStatus(rawValue: sender.tag)
        else { return }

        let cheat = visibleCheats[row]
        let key = statusKey(for: cheat)
        let feedback: CheatFeedbackStatus
        switch status {
        case .works: feedback = .works
        case .doesNotWork: feedback = .doesNotWork
        case .unknown: feedback = .unknown
        }

        statuses[key] = feedback

        if let document = gameDocument, let md5 = document.rom.md5Hash {
            CheatFeedbackService.shared.setStatus(feedback,
                                                 forCode: cheat.code,
                                                 md5: md5,
                                                 systemIdentifier: document.systemPlugin.systemIdentifier,
                                                 coreIdentifier: document.corePlugin.bundleIdentifier,
                                                 coreVersion: document.corePlugin.version,
                                                 rawCode: cheat.rawCode,
                                                 provider: cheat.providerName,
                                                 gameName: document.rom.game?.displayName,
                                                 serial: document.rom.serial,
                                                 raHash: document.retroAchievementsSessionInfo?[OERetroAchievementsGameHashKey] as? String)
        }

        // Re-filtered rather than redrawn: the new status may exclude this row.
        applyFilters()
    }

    private func presentCodeDialog(for cheat: DatabaseCheat) {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Cheat Code", comment: "Cheat code dialog title")
        alert.addButton(withTitle: NSLocalizedString("Copy", comment: "Cheat code dialog button"))
        alert.addButton(withTitle: NSLocalizedString("Close", comment: "Cheat code dialog button"))
        alert.accessoryView = makeCodeAccessoryView(code: cheat.code)

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cheat.code, forType: .string)
        }
    }

    /// Fixed size with its own scroller, so a one-line code and a long "+"-joined
    /// list both present the same way.
    private func makeCodeAccessoryView(code: String) -> NSScrollView {
        let size = NSSize(width: 380, height: 120)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.string = code
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    @objc private func importClicked(_ sender: NSButton) {
        // Asked at click time so the row stays correct across reloads and sorting.
        let row = resultsTableView.row(for: sender)
        guard row >= 0, row < visibleCheats.count else { return }
        let cheat = visibleCheats[row]
        let state = importState(for: cheat)

        switch state {
        case .notImported:
            gameDocument?.addImportedCheat(code: cheat.code, name: cheat.name, providerName: cheat.providerName, rawCode: cheat.rawCode)
        case .importedByThisFeature:
            // Blocks on the "did it work" prompt, so statuses are re-read once it returns.
            gameDocument?.removeImportedCheat(code: cheat.code)
            refreshStatuses()
        case .usedElsewhere:
            return
        }

        refreshImportedCodeKeys()
        resultsTableView?.reloadData()
    }

    private func refreshStatuses() {
        guard let document = gameDocument, let md5 = document.rom.md5Hash else { return }
        statuses = CheatFeedbackService.shared.statuses(forMD5: md5,
                                                       systemIdentifier: document.systemPlugin.systemIdentifier,
                                                       coreIdentifier: document.corePlugin.bundleIdentifier,
                                                       coreVersion: document.corePlugin.version)
    }
}

// MARK: - Notes Cell View

/// A single button whose icon/tint reflect whether a note is already saved for the row.
final class NotesCellView: NSView {

    private let button = NSButton()

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)

        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(hasNotes: Bool) {
        let description = NSLocalizedString("Click to add or edit notes for this cheat", comment: "Browse online cheats notes button description")
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        button.contentTintColor = hasNotes ? .systemYellow : .secondaryLabelColor
        button.toolTip = description
    }
}

// MARK: - Status Cell View

/// Three exclusive icon buttons. The filled symbol variant carries the selection
/// alongside the tint, so the state is still readable without colour.
final class StatusCellView: NSView {

    typealias CheatStatus = BrowseOnlineCheatsViewController.CheatStatus

    private struct Option {
        let status: CheatStatus
        let symbol: String
        let selectedColor: NSColor
        let description: String
    }

    /// Muted steel blue — the system blues are all fully saturated, which reads as
    /// loud as the green and red for what is only the neutral "not tested" state.
    /// Not private: reused by the game menu's "Set Status" submenu for the same icon set.
    static let unknownColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.52, green: 0.62, blue: 0.72, alpha: 1)
            : NSColor(calibratedRed: 0.35, green: 0.46, blue: 0.57, alpha: 1)
    }

    private static let options: [Option] = [
        Option(status: .works,
               symbol: "checkmark.circle",
               selectedColor: .systemGreen,
               description: NSLocalizedString("It works for me", comment: "Browse online cheats status option")),
        Option(status: .doesNotWork,
               symbol: "xmark.circle",
               selectedColor: .systemRed,
               description: NSLocalizedString("It does not work for me", comment: "Browse online cheats status option")),
        Option(status: .unknown,
               symbol: "questionmark.circle",
               selectedColor: unknownColor,
               description: NSLocalizedString("Not set", comment: "Browse online cheats status option")),
    ]

    private var buttons: [NSButton] = []

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for option in Self.options {
            let button = NSButton(image: NSImage(), target: target, action: action)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.tag = option.status.rawValue
            button.toolTip = option.description
            button.setAccessibilityLabel(option.description)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Re-applied on every configure pass — a recycled cell would otherwise keep
    /// the previous row's selection. `nil` highlights nothing (no report yet).
    func configure(status: CheatStatus?) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        for (button, option) in zip(buttons, Self.options) {
            let isSelected = option.status == status
            let symbol = isSelected ? "\(option.symbol).fill" : option.symbol
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: option.description)?
                .withSymbolConfiguration(config)
            button.contentTintColor = isSelected ? option.selectedColor : .tertiaryLabelColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
