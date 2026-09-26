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
import OpenEmuBase

final class CheatSearchViewController: NSViewController {

    // MARK: - UserDefaults keys
    private static let dataSizeKey = "cheatSearch.dataSize"
    private static let dataTypeKey = "cheatSearch.dataType"
    private static let comparisonKey = "cheatSearch.comparison"
    private static let compareToKey = "cheatSearch.compareTo"

    // MARK: - Enums

    private enum DataType: Int {
        case unsigned = 0
        case signed = 1
        case hexadecimal = 2
    }

    private enum Comparison: Int {
        case lessThan = 0
        case greaterThan = 1
        case lessOrEqual = 2
        case greaterOrEqual = 3
        case equal = 4
        case notEqual = 5
    }

    private enum CompareTo: Int {
        case storedValue = 0
        case previousValue = 1
        case thisValue = 2
    }

    private static let dataTypeTagBase = 100
    private static let compareToTagBase = 200

    private var selectedDataType: DataType {
        DataType(rawValue: dataTypeRadios.firstIndex(where: { $0.state == .on }) ?? 0) ?? .unsigned
    }

    private var selectedComparison: Comparison {
        Comparison(rawValue: comparisonCombo.indexOfSelectedItem) ?? .equal
    }

    private var selectedCompareTo: CompareTo {
        CompareTo(rawValue: compareToRadios.firstIndex(where: { $0.state == .on }) ?? 0) ?? .storedValue
    }

    // MARK: - Document reference
    weak var gameDocument: OEGameDocument?

    // MARK: - Memory Cache
    private(set) var memoryRegions: [OEMemoryRegionDescriptor] = []

    // MARK: - Search Results

    private struct SearchResult {
        let address: UInt32
        var currentValue: UInt64
        var previousValue: UInt64?
        var storedValue: UInt64?
    }

    private var searchResults: [SearchResult] = []
    private var loadingSpinner: NSProgressIndicator?
    private var isPopulating = false

    private var addressHexDigits: Int {
        memoryRegions.map { Int($0.addressBytes) * 2 }.max() ?? 8
    }

    private var addressFormatString: String {
        "%0\(addressHexDigits)X"
    }

    /// Address as shown in the results table / Add Cheat sheet. PSP is rendered in CwCheat form —
    /// `<typeNibble><7-hex relative address>` (type nibble 0/1/2 = 8/16/32-bit from the selected data
    /// size, relative = absolute − user RAM base) — so it lines up with published `_L` codes. This is
    /// display only; the absolute `result.address` still drives the actual code conversion.
    private func displayAddress(_ address: UInt32) -> String {
        guard gameDocument?.systemIdentifier == OESystemIdentifierPSP else {
            return String(format: addressFormatString, address)
        }
        let relative = (address >= 0x0880_0000 ? address - 0x0880_0000 : address) & 0x0FFF_FFFF
        let typeNibble: UInt32
        switch selectedDataSize {
        case 1: typeNibble = 0
        case 2: typeNibble = 1
        default: typeNibble = 2
        }
        return String(format: "%01X%07X", typeNibble, relative)
    }

    private var minDataBytes: Int {
        memoryRegions.map { Int($0.minDataBytes) }.max() ?? 1
    }

    // MARK: - Table View
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    // MARK: - Data Size combo
    private var dataSizeCombo: NSPopUpButton!
    private var availableDataSizes: [Int] = [1, 2, 3, 4]

    private var selectedDataSize: Int {
        let index = dataSizeCombo.indexOfSelectedItem
        guard index >= 0, index < availableDataSizes.count else {
            return availableDataSizes.first ?? 1
        }
        return availableDataSizes[index]
    }

    // MARK: - Data Type radios
    private var dataTypeRadios: [NSButton] = []

    // MARK: - Comparison combo
    private var comparisonCombo: NSPopUpButton!

    // MARK: - Compare To radios
    private var compareToRadios: [NSButton] = []
    private var thisValueTextField: NSTextField!

    // MARK: - Buttons
    private var resetButton: NSButton!
    private var searchButton: NSButton!
    private var storeValuesButton: NSButton!
    private var addCheatButton: NSButton!
    private var resultsCountLabel: NSTextField!

    // MARK: - Result display cap
    /// Maximum rows handed to the table view. Matches are kept in full in
    /// `searchResults` so narrowing still works against every hit; only the
    /// number of rows the table has to build is bounded.
    ///
    /// Without this, a broad first search (searching for 0 is common, and RAM is
    /// full of zeroes) produces millions of rows. AppKit allocates an
    /// accessibility element per row, which pushed the app past 5 GB and hung
    /// the main thread in AX serialisation on N64-sized RAM.
    ///
    /// 1000 is set for what is actually readable rather than what is survivable.
    /// The list is a surface you narrow down, not one you scroll to the end of,
    /// and a realistic narrowed result set fits well inside this.
    private static let displayLimit = 1_000

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)

        let mainSplit = NSStackView()
        mainSplit.orientation = .horizontal
        mainSplit.spacing = 12
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.addSubview(mainSplit)

        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: view.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        scrollView = makeTableView()
        mainSplit.addArrangedSubview(scrollView)

        let rightSide = makeRightSide()
        mainSplit.addArrangedSubview(rightSide)

        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightSide.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rightSide.widthAnchor.constraint(equalTo: mainSplit.widthAnchor, multiplier: 0.38).isActive = true

        restoreSavedSelections()
        updateControlStates()
    }

    // MARK: - Persist / Restore Selections

    private func restoreSavedSelections() {
        let defaults = UserDefaults.standard

        let dataSize = defaults.integer(forKey: Self.dataSizeKey)
        if dataSize >= 0 && dataSize < dataSizeCombo.numberOfItems {
            dataSizeCombo.selectItem(at: dataSize)
        }

        let dataType = defaults.integer(forKey: Self.dataTypeKey)
        selectRadio(in: dataTypeRadios, index: dataType)

        // Default to "=" rather than the first item, "<". With the other defaults
        // (unsigned, This Value 0) a "<" search asks for an unsigned number below
        // zero, which can never match, so a first search always came back empty.
        let comparison = defaults.object(forKey: Self.comparisonKey) as? Int ?? Comparison.equal.rawValue
        if comparison >= 0 && comparison < comparisonCombo.numberOfItems {
            comparisonCombo.selectItem(at: comparison)
        }

        let compareTo = defaults.integer(forKey: Self.compareToKey)
        selectRadio(in: compareToRadios, index: compareTo)
    }

    private func selectRadio(in radios: [NSButton], index: Int) {
        for (i, radio) in radios.enumerated() {
            radio.state = (i == index) ? .on : .off
        }
    }

    // MARK: - Loading Indicator

    private func reloadTable() {
        tableView.reloadData()
        tableView.deselectAll(nil)
        updateResultsCountLabel()
    }

    /// Reports the match count, and says so plainly when the table is only
    /// showing a capped subset of them (searching for 0 is common, and RAM is
    /// full of zeroes, so a broad first search can produce millions of hits).
    private func updateResultsCountLabel() {
        let count = searchResults.count
        if count == 0 {
            resultsCountLabel.stringValue = ""
        } else if count > Self.displayLimit {
            resultsCountLabel.stringValue = String(
                format: NSLocalizedString("Showing first %1$@ of %2$@ matches, narrow your search",
                                          comment: "Cheat Search result count when capped"),
                NumberFormatter.localizedString(from: NSNumber(value: Self.displayLimit), number: .decimal),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            )
        } else if count == 1 {
            resultsCountLabel.stringValue = String(
                format: NSLocalizedString("%@ result found 🎯", comment: "Cheat Search single result count"),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            )
        } else {
            resultsCountLabel.stringValue = String(
                format: NSLocalizedString("%@ results found", comment: "Cheat Search result count"),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            )
        }
    }

    private func showLoadingIndicator() {
        isPopulating = true
        searchButton.isEnabled = false
        addCheatButton.isEnabled = false
        resetButton.isEnabled = false
        storeValuesButton.isEnabled = false

        if loadingSpinner == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .regular
            spinner.translatesAutoresizingMaskIntoConstraints = false
            scrollView.superview?.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            ])
            loadingSpinner = spinner
        }
        loadingSpinner?.startAnimation(nil)
        loadingSpinner?.isHidden = false
        tableView.deselectAll(nil)
        tableView.isEnabled = false
    }

    private func hideLoadingIndicator() {
        isPopulating = false
        searchButton.isEnabled = true
        resetButton.isEnabled = true
        updateControlStates()
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
        tableView.isEnabled = true
    }

    // MARK: - Memory Reading

    func readMemoryFromCore() {
        guard let document = gameDocument else { return }

        document.fetchReadableMemoryRegions { [weak self] regions in
            guard let self = self else { return }
            self.memoryRegions = regions.sorted { $0.address < $1.address }
            self.rebuildDataSizeCombo()
            if !self.searchResults.isEmpty {
                self.updateCurrentValues()
            }
        }
    }

    private var isUpdatingValues = false

    private func updateCurrentValues() {
        guard !searchResults.isEmpty, !memoryRegions.isEmpty, !isUpdatingValues else { return }
        isUpdatingValues = true
        showLoadingIndicator()

        let regions = memoryRegions
        var results = searchResults

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for region in regions {
                let regionStart = UInt32(region.address)
                let regionEnd = regionStart + UInt32(region.data.count)
                let byteCount = region.data.count

                region.data.withUnsafeBytes { buffer in
                    for i in 0..<results.count {
                        let address = results[i].address
                        guard address >= regionStart && address < regionEnd else { continue }

                        let offset = Int(address - regionStart)
                        let available = min(4, byteCount - offset)
                        guard available > 0 else { continue }

                        var value: UInt64 = 0
                        for b in 0..<available {
                            value |= UInt64(buffer[offset + b]) << (b * 8)
                        }
                        results[i].previousValue = results[i].currentValue
                        results[i].currentValue = value
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.searchResults = results
                self.isUpdatingValues = false
                self.hideLoadingIndicator()
                self.reloadTable()
            }
        }
    }

    // MARK: - Left Side (Table)

    private func makeTableView() -> NSScrollView {
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.style = .fullWidth
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        let addressColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address"))
        addressColumn.title = NSLocalizedString("Address", comment: "Cheat Search table column header")
        addressColumn.width = 80
        addressColumn.minWidth = 60
        tableView.addTableColumn(addressColumn)

        let currentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("current"))
        currentColumn.title = NSLocalizedString("Current", comment: "Cheat Search table column header")
        currentColumn.width = 70
        currentColumn.minWidth = 50
        tableView.addTableColumn(currentColumn)

        let previousColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("previous"))
        previousColumn.title = NSLocalizedString("Previous", comment: "Cheat Search table column header")
        previousColumn.width = 70
        previousColumn.minWidth = 50
        tableView.addTableColumn(previousColumn)

        let storedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stored"))
        storedColumn.title = NSLocalizedString("Stored", comment: "Cheat Search table column header")
        storedColumn.width = 70
        storedColumn.minWidth = 50
        tableView.addTableColumn(storedColumn)

        let sv = NSScrollView()
        sv.documentView = tableView
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.borderType = .bezelBorder

        return sv
    }

    // MARK: - Right Side (Controls)

    private func makeRightSide() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        let dataTypePanel = makeDataTypePanel()
        stack.addArrangedSubview(dataTypePanel)
        dataTypePanel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let comparisonPanel = makeComparisonPanel()
        stack.addArrangedSubview(comparisonPanel)
        comparisonPanel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let searchRow = makeButtonRow(
            leftTitle: NSLocalizedString("Reset", comment: "Cheat Search button"),
            leftAction: #selector(resetClicked(_:)),
            rightTitle: NSLocalizedString("Search", comment: "Cheat Search button"),
            rightAction: #selector(searchClicked(_:))
        )
        resetButton = searchRow.0
        searchButton = searchRow.1
        stack.addArrangedSubview(searchRow.2)
        searchRow.2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let storeRow = makeButtonRow(
            leftTitle: NSLocalizedString("Store Values", comment: "Cheat Search button"),
            leftAction: #selector(storeValuesClicked(_:)),
            rightTitle: NSLocalizedString("Add Cheat…", comment: "Cheat Search button"),
            rightAction: #selector(addCheatClicked(_:))
        )
        storeValuesButton = storeRow.0
        addCheatButton = storeRow.1
        addCheatButton.isEnabled = false
        stack.addArrangedSubview(storeRow.2)
        storeRow.2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        resultsCountLabel = NSTextField(labelWithString: "")
        resultsCountLabel.alignment = .center
        resultsCountLabel.textColor = .secondaryLabelColor
        resultsCountLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        resultsCountLabel.maximumNumberOfLines = 0
        resultsCountLabel.lineBreakMode = .byWordWrapping
        resultsCountLabel.drawsBackground = false
        resultsCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(resultsCountLabel)
        resultsCountLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(bottomSpacer)

        return stack
    }

    // MARK: - Data Type Panel

    private func makeDataTypePanel() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 8
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        box.contentView?.addSubview(outerStack)
        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            ])
        }

        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        let sizeLabel = NSTextField(labelWithString: NSLocalizedString("Data Size", comment: "Cheat Search options group"))
        sizeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        dataSizeCombo = NSPopUpButton(frame: .zero, pullsDown: false)
        dataSizeCombo.target = self
        dataSizeCombo.action = #selector(dataSizeChanged(_:))
        rebuildDataSizeCombo()
        dataSizeCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sizeRow.addArrangedSubview(sizeLabel)
        sizeRow.addArrangedSubview(dataSizeCombo)
        outerStack.addArrangedSubview(sizeRow)
        sizeRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        let dataTypeOptions = [
            NSLocalizedString("Unsigned (>=0)", comment: "Cheat Search data type option"),
            NSLocalizedString("Signed (+/-)", comment: "Cheat Search data type option"),
            NSLocalizedString("Hexadecimal", comment: "Cheat Search data type option"),
        ]

        for (index, option) in dataTypeOptions.enumerated() {
            let radio = NSButton(radioButtonWithTitle: option, target: self, action: #selector(radioChanged(_:)))
            radio.tag = Self.dataTypeTagBase + index
            radio.state = (index == 0) ? .on : .off
            outerStack.addArrangedSubview(radio)
            dataTypeRadios.append(radio)
        }

        return box
    }

    // MARK: - Comparison Panel

    private func makeComparisonPanel() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 8
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        box.contentView?.addSubview(outerStack)
        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            ])
        }

        let compRow = NSStackView()
        compRow.orientation = .horizontal
        compRow.spacing = 8

        let compLabel = NSTextField(labelWithString: NSLocalizedString("Comparison", comment: "Cheat Search options group"))
        compLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        comparisonCombo = NSPopUpButton(frame: .zero, pullsDown: false)
        comparisonCombo.target = self
        comparisonCombo.action = #selector(comparisonChanged(_:))
        comparisonCombo.addItems(withTitles: ["<", ">", "<=", ">=", "=", "!="])
        comparisonCombo.selectItem(at: 4)
        comparisonCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)

        compRow.addArrangedSubview(compLabel)
        compRow.addArrangedSubview(comparisonCombo)
        outerStack.addArrangedSubview(compRow)
        compRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        let storedRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Stored Value", comment: "Cheat Search compare to option"), target: self, action: #selector(radioChanged(_:)))
        storedRadio.tag = Self.compareToTagBase + CompareTo.storedValue.rawValue
        storedRadio.state = .on
        outerStack.addArrangedSubview(storedRadio)
        compareToRadios.append(storedRadio)

        let previousRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Previous Value", comment: "Cheat Search compare to option"), target: self, action: #selector(radioChanged(_:)))
        previousRadio.tag = Self.compareToTagBase + CompareTo.previousValue.rawValue
        previousRadio.state = .off
        outerStack.addArrangedSubview(previousRadio)
        compareToRadios.append(previousRadio)

        let thisValueRow = NSStackView()
        thisValueRow.orientation = .horizontal
        thisValueRow.spacing = 8

        let thisValueRadio = NSButton(radioButtonWithTitle: NSLocalizedString("This Value:", comment: "Cheat Search compare to option"), target: self, action: #selector(radioChanged(_:)))
        thisValueRadio.tag = Self.compareToTagBase + CompareTo.thisValue.rawValue
        thisValueRadio.state = .off
        thisValueRadio.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        compareToRadios.append(thisValueRadio)

        thisValueTextField = NSTextField()
        thisValueTextField.placeholderString = "0"
        thisValueTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        thisValueRow.addArrangedSubview(thisValueRadio)
        thisValueRow.addArrangedSubview(thisValueTextField)
        outerStack.addArrangedSubview(thisValueRow)
        thisValueRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        return box
    }

    // MARK: - Button Row Helper

    private func makeButtonRow(leftTitle: String, leftAction: Selector, rightTitle: String, rightAction: Selector) -> (NSButton, NSButton, NSView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually

        let leftButton = NSButton(title: leftTitle, target: self, action: leftAction)
        leftButton.bezelStyle = .rounded

        let rightButton = NSButton(title: rightTitle, target: self, action: rightAction)
        rightButton.bezelStyle = .rounded

        row.addArrangedSubview(leftButton)
        row.addArrangedSubview(rightButton)

        return (leftButton, rightButton, row)
    }

    // MARK: - Actions

    @objc private func searchClicked(_ sender: Any?) {
        guard !isPopulating else { return }

        // Fetch memory regions first if not yet loaded
        if memoryRegions.isEmpty {
            guard let document = gameDocument else { return }
            showLoadingIndicator()
            document.fetchReadableMemoryRegions { [weak self] regions in
                guard let self = self else { return }
                self.memoryRegions = regions.sorted { $0.address < $1.address }
                self.rebuildDataSizeCombo()
                self.hideLoadingIndicator()
                // Cores return no regions before a ROM is loaded and during
                // teardown. Re-entering unconditionally would fetch again on an
                // empty result and loop over XPC forever.
                guard !self.memoryRegions.isEmpty else {
                    NSSound.beep()
                    return
                }
                self.searchClicked(nil)
            }
            return
        }

        let dataSize = selectedDataSize
        let dataType = selectedDataType
        let comparison = selectedComparison
        let compareTo = selectedCompareTo

        var targetValue: UInt64 = 0
        if compareTo == .thisValue {
            targetValue = parseInputValue(thisValueTextField.stringValue, dataType: dataType, dataSize: dataSize)
        }

        if !searchResults.isEmpty {
            if compareTo == .storedValue && searchResults.first?.storedValue == nil {
                NSSound.beep()
                return
            }
            if compareTo == .previousValue && searchResults.first?.previousValue == nil {
                NSSound.beep()
                return
            }
        }

        if searchResults.isEmpty {
            let regions = memoryRegions
            showLoadingIndicator()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var results: [SearchResult] = []

                for region in regions {
                    let data = region.data
                    let baseAddress = UInt32(region.address)
                    let byteCount = data.count
                    let stride = Int(region.minDataBytes)

                    guard byteCount >= dataSize else { continue }

                    data.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset <= byteCount - dataSize {
                            let fullValue = self?.readValue(from: buffer, at: offset, size: min(4, byteCount - offset)) ?? 0

                            let referenceValue: UInt64
                            switch compareTo {
                            case .thisValue:
                                referenceValue = targetValue
                            default:
                                referenceValue = fullValue
                            }

                            if self?.compare(fullValue, to: referenceValue, operation: comparison, dataType: dataType, dataSize: dataSize) == true {
                                results.append(SearchResult(
                                    address: baseAddress + UInt32(offset),
                                    currentValue: fullValue,
                                    previousValue: nil,
                                    storedValue: nil
                                ))
                            }
                            offset += stride
                        }
                    }
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.searchResults = results
                    self.hideLoadingIndicator()
                    // print("[CheatSearch] Search results: \(results.count)")
                    self.reloadTable()
                }
            }
        } else {
            showLoadingIndicator()
            let currentResults = searchResults

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let filtered = currentResults.compactMap { result -> SearchResult? in
                    let referenceValue: UInt64?
                    switch compareTo {
                    case .storedValue:
                        referenceValue = result.storedValue
                    case .previousValue:
                        referenceValue = result.previousValue
                    case .thisValue:
                        referenceValue = targetValue
                    }

                    guard let ref = referenceValue else { return result }

                    guard self?.compare(result.currentValue, to: ref, operation: comparison, dataType: dataType, dataSize: dataSize) == true else {
                        return nil
                    }

                    return result
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.searchResults = filtered
                    self.hideLoadingIndicator()
                    // print("[CheatSearch] Search results: \(filtered.count)")
                    self.reloadTable()
                }
            }
        }
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard tableView.selectedRow >= 0 else { return }
        addCheatClicked(sender)
    }

    @objc private func addCheatClicked(_ sender: Any?) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < searchResults.count else { return }
        let result = searchResults[selectedRow]
        let addressString = String(format: addressFormatString, result.address)

        guard let parentWindow = view.window else { return }

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                             styleMask: [.titled],
                             backing: .buffered,
                             defer: true)
        sheet.title = NSLocalizedString("Add Cheat", comment: "Cheat Search add cheat sheet title")

        let contentView = sheet.contentView!

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .lastBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        contentView.addSubview(grid)

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("Title:", comment: ""))
        let titleField = NSTextField()
        titleField.placeholderString = NSLocalizedString("Cheat Description", comment: "")
        grid.addRow(with: [titleLabel, titleField])

        let addressLabel = NSTextField(labelWithString: NSLocalizedString("Address:", comment: ""))
        let addressField = NSTextField(labelWithString: displayAddress(result.address))
        addressField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        grid.addRow(with: [addressLabel, addressField])

        let valueLabel = NSTextField(labelWithString: NSLocalizedString("Value (Hex):", comment: ""))
        let valueField = NSTextField()
        valueField.placeholderString = "FF"
        grid.addRow(with: [valueLabel, valueField])

        grid.column(at: 1).width = 220

        let enableCheck = NSButton(checkboxWithTitle: NSLocalizedString("Enable now", comment: "Cheats button label"), target: nil, action: nil)
        enableCheck.state = .on
        enableCheck.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(enableCheck)

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let addButton = NSButton(title: NSLocalizedString("Add Cheat", comment: ""), target: nil, action: nil)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(addButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            contentView.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 20),

            enableCheck.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            enableCheck.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            addButton.topAnchor.constraint(equalTo: enableCheck.bottomAnchor, constant: 16),
            contentView.trailingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 20),
            contentView.bottomAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 20),

            cancelButton.lastBaselineAnchor.constraint(equalTo: addButton.lastBaselineAnchor),
            addButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 8),
        ])

        cancelButton.target = self
        cancelButton.action = #selector(sheetCancel(_:))
        addButton.target = self
        addButton.action = #selector(sheetAddCheat(_:))

        self.sheetTitleField = titleField
        self.sheetValueField = valueField
        self.sheetAddressString = addressString
        self.sheetEnableCheck = enableCheck

        parentWindow.beginSheet(sheet)
    }

    // MARK: - Add Cheat Sheet

    private var sheetTitleField: NSTextField?
    private var sheetValueField: NSTextField?
    private var sheetAddressString: String?
    private var sheetEnableCheck: NSButton?

    @objc private func sheetCancel(_ sender: Any?) {
        guard let sheet = view.window?.attachedSheet else { return }
        view.window?.endSheet(sheet, returnCode: .cancel)
    }

    @objc private func sheetAddCheat(_ sender: Any?) {
        guard let sheet = view.window?.attachedSheet,
              let titleField = sheetTitleField,
              let valueField = sheetValueField,
              let address = sheetAddressString,
              let enableCheck = sheetEnableCheck,
              let document = gameDocument
        else { return }

        let hexValue = valueField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !hexValue.isEmpty else {
            NSSound.beep()
            return
        }

        let paddedValue = String(repeating: "0", count: max(0, selectedDataSize * 2 - hexValue.count)) + hexValue.uppercased()
        let rawCode = "\(address):\(paddedValue)"
        let name = titleField.stringValue.isEmpty ? rawCode : titleField.stringValue
        let enabled = enableCheck.state == .on

        // Derive addressBytes/minDataBytes from the region that contains this address
        let addressBytes = memoryRegions.first.map { $0.addressBytes } ?? 2
        let dataBytes = memoryRegions.first.map { $0.minDataBytes } ?? 1

        let converted = OEGameDocument.convertCheatSearchCode(
            rawCode,
            for: document.systemIdentifier,
            addressBytes: addressBytes,
            minDataBytes: dataBytes
        )

        document.addCheatFromSearch(code: converted.code, type: converted.type, name: name, enabled: enabled)

        view.window?.endSheet(sheet, returnCode: .OK)

        sheetTitleField = nil
        sheetValueField = nil
        sheetAddressString = nil
        sheetEnableCheck = nil
    }

    @objc private func resetClicked(_ sender: Any?) {
        searchResults = []
        reloadTable()
        updateControlStates()
        readMemoryFromCore()
    }

    @objc private func storeValuesClicked(_ sender: Any?) {
        showLoadingIndicator()
        var results = searchResults

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for i in 0..<results.count {
                results[i].storedValue = results[i].currentValue
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.searchResults = results
                self.hideLoadingIndicator()
                self.reloadTable()
            }
        }
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard notification.object as? NSWindow === view.window else { return }
        readMemoryFromCore()
    }

    @objc private func radioChanged(_ sender: Any?) {
        guard let radio = sender as? NSButton else { return }
        let tag = radio.tag

        if tag >= Self.dataTypeTagBase && tag < Self.compareToTagBase {
            let index = tag - Self.dataTypeTagBase
            selectRadio(in: dataTypeRadios, index: index)
            UserDefaults.standard.set(index, forKey: Self.dataTypeKey)
            reloadTable()
        } else if tag >= Self.compareToTagBase && tag < Self.compareToTagBase + 100 {
            let index = tag - Self.compareToTagBase
            selectRadio(in: compareToRadios, index: index)
            UserDefaults.standard.set(index, forKey: Self.compareToKey)
        }
    }

    private var isRebuildingCombo = false

    @objc private func dataSizeChanged(_ sender: Any?) {
        guard !isRebuildingCombo else { return }
        UserDefaults.standard.set(dataSizeCombo.indexOfSelectedItem, forKey: Self.dataSizeKey)
        reloadTable()
    }

    private func rebuildDataSizeCombo() {
        let min = minDataBytes
        let allSizes = [1, 2, 3, 4]
        let newSizes = allSizes.filter { $0 >= min && $0 % min == 0 }
        
        // Skip rebuild if the combo already starts with the correct minimum size
        if dataSizeCombo.numberOfItems > 0, let firstSize = newSizes.first, availableDataSizes.first == firstSize {
            return
        }
        
        isRebuildingCombo = true
        availableDataSizes = newSizes
        
        dataSizeCombo.removeAllItems()
        for size in availableDataSizes {
            let title = size == 1
                ? NSLocalizedString("1 byte", comment: "Cheat Search data size option")
                : String(format: NSLocalizedString("%d bytes", comment: "Cheat Search data size option"), size)
            dataSizeCombo.addItem(withTitle: title)
        }
        isRebuildingCombo = false
    }

    @objc private func comparisonChanged(_ sender: Any?) {
        UserDefaults.standard.set(comparisonCombo.indexOfSelectedItem, forKey: Self.comparisonKey)
    }

    /// Update enabled state of Stored/Previous radios and Store Values button
    private func updateControlStates() {
        let hasResults = !searchResults.isEmpty
        let hasPrevious = hasResults && searchResults.first?.previousValue != nil
        let hasStored = hasResults && searchResults.first?.storedValue != nil

        compareToRadios[CompareTo.storedValue.rawValue].isEnabled = hasStored
        compareToRadios[CompareTo.previousValue.rawValue].isEnabled = hasPrevious
        storeValuesButton.isEnabled = hasResults

        // If the selected radio is disabled, switch to This Value
        let selectedIdx = compareToRadios.firstIndex(where: { $0.state == .on }) ?? 0
        if !compareToRadios[selectedIdx].isEnabled {
            selectRadio(in: compareToRadios, index: CompareTo.thisValue.rawValue)
            UserDefaults.standard.set(CompareTo.thisValue.rawValue, forKey: Self.compareToKey)
        }
    }

    // MARK: - Search Helpers

    private func readValue(from buffer: UnsafeRawBufferPointer, at offset: Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<size {
            value |= UInt64(buffer[offset + i]) << (i * 8)
        }
        return value
    }

    private func compare(_ a: UInt64, to b: UInt64, operation: Comparison, dataType: DataType, dataSize: Int) -> Bool {
        if dataType == .signed {
            let sa = signExtend(a, size: dataSize)
            let sb = signExtend(b, size: dataSize)
            switch operation {
            case .lessThan:       return sa < sb
            case .greaterThan:    return sa > sb
            case .lessOrEqual:    return sa <= sb
            case .greaterOrEqual: return sa >= sb
            case .equal:          return sa == sb
            case .notEqual:       return sa != sb
            }
        } else {
            let mask: UInt64 = (1 << (dataSize * 8)) - 1
            let ma = a & mask
            let mb = b & mask
            switch operation {
            case .lessThan:       return ma < mb
            case .greaterThan:    return ma > mb
            case .lessOrEqual:    return ma <= mb
            case .greaterOrEqual: return ma >= mb
            case .equal:          return ma == mb
            case .notEqual:       return ma != mb
            }
        }
    }

    private func signExtend(_ value: UInt64, size: Int) -> Int64 {
        switch size {
        case 1: return Int64(Int8(bitPattern: UInt8(value & 0xFF)))
        case 2: return Int64(Int16(bitPattern: UInt16(value & 0xFFFF)))
        case 3:
            if value & 0x800000 != 0 {
                return Int64(bitPattern: value | 0xFFFFFFFFFF000000)
            }
            return Int64(value)
        case 4: return Int64(Int32(bitPattern: UInt32(value & 0xFFFFFFFF)))
        default: return Int64(bitPattern: value)
        }
    }

    private func parseInputValue(_ text: String, dataType: DataType, dataSize: Int) -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let mask: UInt64 = (1 << (dataSize * 8)) - 1

        switch dataType {
        case .hexadecimal:
            return (UInt64(trimmed, radix: 16) ?? 0) & mask
        case .signed:
            let signed = Int64(trimmed) ?? 0
            return UInt64(bitPattern: signed) & mask
        case .unsigned:
            return (UInt64(trimmed) ?? 0) & mask
        }
    }

    private func formatValue(_ value: UInt64, dataType: DataType, dataSize: Int) -> String {
        let mask: UInt64 = (1 << (dataSize * 8)) - 1
        let masked = value & mask

        switch dataType {
        case .hexadecimal:
            return String(format: "%0\(dataSize * 2)llX", masked)
        case .signed:
            return "\(signExtend(value, size: dataSize))"
        case .unsigned:
            return "\(masked)"
        }
    }
}

// MARK: - NSTableViewDataSource

extension CheatSearchViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return min(searchResults.count, Self.displayLimit)
    }
}

// MARK: - NSTableViewDelegate

extension CheatSearchViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let result = searchResults[row]
        let dataType = selectedDataType
        let dataSize = selectedDataSize

        let cellID = NSUserInterfaceItemIdentifier("CheatSearchCell")
        let cell: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = cellID
            cell.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }

        switch identifier.rawValue {
        case "address":
            cell.stringValue = displayAddress(result.address)
        case "current":
            cell.stringValue = formatValue(result.currentValue, dataType: dataType, dataSize: dataSize)
        case "previous":
            if let prev = result.previousValue {
                cell.stringValue = formatValue(prev, dataType: dataType, dataSize: dataSize)
            } else {
                cell.stringValue = ""
            }
        case "stored":
            if let stored = result.storedValue {
                cell.stringValue = formatValue(stored, dataType: dataType, dataSize: dataSize)
            } else {
                cell.stringValue = ""
            }
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addCheatButton.isEnabled = tableView.selectedRow >= 0
    }
}
