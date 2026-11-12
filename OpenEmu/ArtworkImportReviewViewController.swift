// Copyright (c) 2026, OpenEmu Team
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

/// Sheet that lists artwork files matched to games by filename, letting the
/// user deselect any before applying. Built programmatically (no xib) since
/// this is a small, self-contained review list.
@objc(OEArtworkImportReviewViewController)
final class ArtworkImportReviewViewController: NSViewController {

    @objc var onApply: (([ArtworkFolderMatcher.Match]) -> Void)?
    @objc var onCancel: (() -> Void)?

    private let matches: [ArtworkFolderMatcher.Match]
    private let unmatchedFileCount: Int
    private let selectedGameCount: Int
    private var includedIndices: Set<Int>

    private var tableView: NSTableView!

    @objc(initWithMatches:unmatchedFileCount:selectedGameCount:) init(matches: [ArtworkFolderMatcher.Match], unmatchedFileCount: Int, selectedGameCount: Int) {
        self.matches = matches
        self.unmatchedFileCount = unmatchedFileCount
        self.selectedGameCount = selectedGameCount
        self.includedIndices = Set(matches.indices)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {

        let headline = NSTextField(labelWithString: matches.isEmpty
            ? NSLocalizedString("No matching artwork found.", comment: "")
            : String(format: NSLocalizedString("Found artwork for %ld of %ld selected games.", comment: ""), matches.count, selectedGameCount))
        headline.font = .boldSystemFont(ofSize: 13)

        let subheadline = NSTextField(labelWithString: unmatchedFileCount > 0
            ? String(format: NSLocalizedString("%ld file(s) did not match any game and will be skipped.", comment: ""), unmatchedFileCount)
            : NSLocalizedString("Uncheck any game you don't want to update.", comment: ""))
        subheadline.textColor = .secondaryLabelColor
        subheadline.font = .systemFont(ofSize: 11)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 36

        let checkboxColumn = NSTableColumn(identifier: .init("checkbox"))
        checkboxColumn.width = 24
        checkboxColumn.resizingMask = []
        tableView.addTableColumn(checkboxColumn)

        let artworkColumn = NSTableColumn(identifier: .init("artwork"))
        artworkColumn.width = 28
        artworkColumn.resizingMask = []
        tableView.addTableColumn(artworkColumn)

        let matchColumn = NSTableColumn(identifier: .init("match"))
        matchColumn.width = 360
        matchColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(matchColumn)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancelPressed(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        let applyButton = NSButton(title: NSLocalizedString("Apply", comment: ""), target: self, action: #selector(applyPressed(_:)))
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = !matches.isEmpty

        let buttonRow = NSStackView(views: [cancelButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [headline, subheadline])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 420))
        container.addSubview(textStack)
        container.addSubview(scrollView)
        container.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        view = container
    }

    @objc private func toggleIncluded(_ sender: NSButton) {
        let row = sender.tag
        if sender.state == .on {
            includedIndices.insert(row)
        } else {
            includedIndices.remove(row)
        }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        dismiss(sender)
        onCancel?()
    }

    @objc private func applyPressed(_ sender: Any?) {
        let selected = matches.enumerated().filter { includedIndices.contains($0.offset) }.map { $0.element }
        dismiss(sender)
        onApply?(selected)
    }
}

extension ArtworkImportReviewViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }
}

extension ArtworkImportReviewViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = matches[row]

        switch tableColumn?.identifier.rawValue {
        case "checkbox":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleIncluded(_:)))
            checkbox.state = includedIndices.contains(row) ? .on : .off
            checkbox.tag = row
            return checkbox

        case "artwork":
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(contentsOf: match.fileURL)
            return imageView

        case "match":
            var text = "\(match.game.displayName) (\(match.slotName))  \u{2190}  \(match.fileURL.lastPathComponent)"
            if let warning = match.warning { text += "\n\u{26A0}\u{FE0E} \(warning)" }
            let label = NSTextField(labelWithString: text)
            label.lineBreakMode = .byTruncatingMiddle
            return label

        default:
            return nil
        }
    }
}
