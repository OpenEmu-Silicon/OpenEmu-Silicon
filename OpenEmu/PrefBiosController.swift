// Copyright (c) 2021, OpenEmu Team
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

private var PrefBiosCoreListKVOContext = 0

/// A single row in the System Files list — represents one required file,
/// potentially with multiple valid hash variants (e.g. regional dc_flash.bin dumps).
private struct BIOSFileGroup: Hashable {
    let name: String
    let description: String
    let size: Int
    let variants: [[String: Any]]

    /// True if the file exists on disk with any of the registered hashes.
    var isAvailable: Bool {
        variants.contains { BIOSFile.isBIOSFileAvailable(withFileInfo: $0) }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: BIOSFileGroup, rhs: BIOSFileGroup) -> Bool { lhs.name == rhs.name }
}

private extension NSUserInterfaceItemIdentifier {
    static let infoCell = NSUserInterfaceItemIdentifier("InfoCell")
    static let coreCell = NSUserInterfaceItemIdentifier("CoreCell")
    static let fileCell = NSUserInterfaceItemIdentifier("FileCell")
}

final class PrefBiosController: NSViewController {
    
    @IBOutlet var tableView: NSTableView!
    
    private var items: [AnyHashable] = []
    private var token: NSObjectProtocol?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.registerForDraggedTypes([.fileURL])
        
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        tableView.menu = menu
        
        token = NotificationCenter.default.addObserver(forName: .didImportBIOSFile, object: nil, queue: .main) { [weak self] notification in
            self?.biosFileWasImported(notification)
        }
        
        OECorePlugin.addObserver(self, forKeyPath: #keyPath(OECorePlugin.allPlugins), context: &PrefBiosCoreListKVOContext)
        
        reloadData()
    }
    
    deinit {
        if let token = token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
        OECorePlugin.removeObserver(self, forKeyPath: #keyPath(OECorePlugin.allPlugins), context: &PrefBiosCoreListKVOContext)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if context == &PrefBiosCoreListKVOContext {
            DispatchQueue.main.async { [weak self] in self?.reloadData() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func reloadData() {
        var items: [AnyHashable] = []

        for core in OECorePlugin.allPlugins {
            let entries = core.requiredFiles
            guard !entries.isEmpty else { continue }

            // Group entries by filename — multiple entries for the same filename are alternate hashes.
            var groups: [String: BIOSFileGroup] = [:]
            var order: [String] = []
            for entry in entries {
                let name = entry["Name"] as? String ?? ""
                if groups[name] == nil {
                    let desc = entry["Description"] as? String ?? name
                    let size = entry["Size"] as? Int ?? 0
                    groups[name] = BIOSFileGroup(name: name, description: desc, size: size, variants: [entry])
                    order.append(name)
                } else {
                    let existing = groups[name]!
                    groups[name] = BIOSFileGroup(name: name,
                                                 description: existing.description,
                                                 size: existing.size,
                                                 variants: existing.variants + [entry])
                }
            }

            let sorted = order.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            items.append(core)
            items.append(contentsOf: sorted.compactMap { groups[$0] })
        }

        self.items = items
        tableView.reloadData()
    }
    
    @objc private func deleteBIOSFile(_ sender: Any?) {
        guard let group = items[tableView.clickedRow - 1] as? BIOSFileGroup else { return }

        if BIOSFile.deleteBIOSFile(withFileName: group.name),
           let view = tableView.view(atColumn: 0, row: tableView.clickedRow, makeIfNecessary: false),
           view.identifier == .fileCell,
           let availabilityIndicator = view.viewWithTag(3) as? NSImageView {
            availabilityIndicator.image = NSImage(named: "bios_missing")
            availabilityIndicator.contentTintColor = .systemOrange
        }
    }

    @objc private func biosFileWasImported(_ notification: Notification) {
        let md5 = notification.userInfo?["MD5"] as! String
        for (index, item) in items.enumerated() {
            guard
                let group = item as? BIOSFileGroup,
                group.variants.contains(where: { ($0["MD5"] as? String)?.caseInsensitiveCompare(md5) == .orderedSame }),
                let view = tableView.view(atColumn: 0, row: index + 1, makeIfNecessary: false),
                view.identifier == .fileCell,
                let availabilityIndicator = view.viewWithTag(3) as? NSImageView
            else { continue }

            availabilityIndicator.image = NSImage(named: "bios_found")
            availabilityIndicator.contentTintColor = .systemGreen
            break
        }
    }
}

// MARK: - NSTableView DataSource

extension PrefBiosController: NSTableViewDataSource {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count + 1
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        
        guard let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        
        var importedSomething = false
        func importFile(at url: URL) {
            importedSomething = BIOSFile.checkIfBIOSFileAndImport(at: url) || importedSomething
        }
        
        for url in fileURLs {
            if !url.isDirectory {
                importFile(at: url)
            } else {
                let fm = FileManager.default
                let dirEnum = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])!
                
                for case let url as URL in dirEnum where !url.isDirectory {
                    importFile(at: url)
                }
            }
        }
        
        return importedSomething
    }
}

// MARK: - NSTableView Delegate

extension PrefBiosController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        if row == 0 {
            let groupCell = tableView.makeView(withIdentifier: .infoCell, owner: self) as? NSTableCellView
            let textField = groupCell?.textField
            
            let parStyle = NSMutableParagraphStyle()
            parStyle.alignment = .justified
            let attributes: [NSAttributedString.Key : Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: parStyle
            ]
            
            let linkAttributes: [NSAttributedString.Key : Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: parStyle,
                .link: URL.userGuideBIOSFiles
            ]
            
            let linkText = NSLocalizedString("User guide on BIOS files", comment: "Bios files introduction text, active region")
            let infoText = String(format: NSLocalizedString("In order to emulate some systems, BIOS files are needed due to increasing complexity of the hardware and software of modern gaming consoles. Please read our %@ for more information.", comment: "BIOS files preferences introduction text"), linkText)
            
            let attributedString = NSMutableAttributedString(string: infoText, attributes: attributes)
            
            let linkRange = (infoText as NSString).range(of: linkText)
            attributedString.setAttributes(linkAttributes, range: linkRange)
            
            textField?.attributedStringValue = attributedString
            
            return groupCell
        }
        
        let item = items[row - 1]
        if self.tableView(tableView, isGroupRow: row) {
            let core = item as? OECorePlugin
            let groupCell = tableView.makeView(withIdentifier: .coreCell, owner: self) as? NSTableCellView
            // CFBundleName may be an unresolved Xcode build variable like "${PRODUCT_NAME}".
            // Fall back to the system name from the core's system identifiers in that case.
            var name = core?.displayName ?? ""
            if name.hasPrefix("${") {
                name = core?.systemIdentifiers.first.flatMap { OESystemPlugin.systemPlugin(forIdentifier: $0)?.systemName } ?? core?.bundleIdentifier ?? name
            }
            groupCell?.textField?.stringValue = name
            return groupCell
        }
        else {
            guard let group = item as? BIOSFileGroup else { return nil }

            let fileCell = tableView.makeView(withIdentifier: .fileCell, owner: self) as? NSTableCellView
            let descriptionField = fileCell?.textField
            let fileNameField = fileCell?.viewWithTag(1) as? NSTextField
            let availabilityIndicator = fileCell?.viewWithTag(3) as? NSImageView

            let available = group.isAvailable
            let sizeString = ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)

            descriptionField?.stringValue = group.description
            fileNameField?.stringValue = "\(group.name) (\(sizeString))"
            fileNameField?.toolTip = nil

            availabilityIndicator?.image = NSImage(named: available ? "bios_found" : "bios_missing")
            availabilityIndicator?.contentTintColor = available ? .systemGreen : .systemOrange

            return fileCell
        }
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row == 0 {
            return 60
        } else if self.tableView(tableView, isGroupRow: row) {
            return 18
        } else {
            return 54
        }
    }
    
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        
        if row == 0 {
            return false
        }
        
        return items[row - 1] is OECorePlugin
    }
}

extension PrefBiosController: NSMenuDelegate {
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard
            tableView.clickedRow >= 1,
            !tableView(tableView, isGroupRow: tableView.clickedRow)
        else { return }
        
        if let group = items[tableView.clickedRow - 1] as? BIOSFileGroup {
            let item = NSMenuItem()
            item.title = NSLocalizedString("Delete", comment: "")
            item.action = #selector(deleteBIOSFile(_:))
            item.isEnabled = group.isAvailable
            menu.addItem(item)
        }
    }
}

// MARK: - PreferencePane

extension PrefBiosController: PreferencePane {
    
    var icon: NSImage? { NSImage(named: "bios_tab_icon") }
    
    var panelTitle: String { "System Files" }
    
    var viewSize: NSSize { view.fittingSize }
}
