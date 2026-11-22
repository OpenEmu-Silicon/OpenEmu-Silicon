/*
 Copyright (c) 2015, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Cocoa

extension Notification.Name {
    // Pre-change notification: split-view geometry must be updated before
    // NSToolbar re-tiles the unified titlebar for the new visibility.
    static let oeLibraryToolbarVisibilityWillChange = Notification.Name("OELibraryToolbarVisibilityWillChange")
    static let oeLibraryToolbarVisibilityDidChange = Notification.Name("OELibraryToolbarVisibilityDidChange")
}

@objc(OELibraryToolbar)
@objcMembers
final class LibraryToolbar: NSToolbar {

    private static let showToolbarKey = "OEShowLibraryToolbar"

    // LibraryController still configures the toolbar for customization.
    // Suppress that setup while the toolbar is hidden, without disabling
    // customization permanently when the user shows the toolbar again.
    override var allowsUserCustomization: Bool {
        get { super.allowsUserCustomization }
        set { super.allowsUserCustomization = newValue && shouldBeVisible }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        // Apply saved visibility when the Library toolbar is created.
        // A missing key preserves OpenEmu's existing default: visible.
        applyDisplayOption()

        NotificationCenter.default.addObserver(self,
            selector: #selector(displayOptionDidChange(_:)),
            name: .oeLibraryToolbarVisibilityDidChange,
            object: nil)

        // NSToolbar's autosaved configuration can be re-applied when a window
        // installs/reinstalls it (for example after returning from gameplay).
        // Reconcile only our own window, and only when visibility differs.
        NotificationCenter.default.addObserver(self,
            selector: #selector(libraryWindowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var shouldBeVisible: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.showToolbarKey) == nil || defaults.bool(forKey: Self.showToolbarKey)
    }

    private func applyDisplayOption() {
        let desired = shouldBeVisible
        if isVisible != desired {
            // Retain the established visibility notification and v6 titlebar
            // geometry; these are intentionally unchanged by this fix.
            NotificationCenter.default.post(name: .oeLibraryToolbarVisibilityWillChange,
                                            object: self)
            isVisible = desired
        }

        // The attached but hidden NSToolbar still owns the titlebar's
        // contextual menu. Disable both item customization and, on modern
        // AppKit, display-mode customization to leave no toolbar menu in
        // the empty titlebar. Restore both when the toolbar is shown.
        super.allowsUserCustomization = desired
        if #available(macOS 15.0, *) {
            allowsDisplayModeCustomization = desired
        }
    }

    @objc private func displayOptionDidChange(_ notification: Notification) {
        applyDisplayOption()
    }

    @objc private func libraryWindowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.toolbar === self else { return }
        applyDisplayOption()
    }

    private var del: LibraryToolbarDelegate {
        delegate as! LibraryToolbarDelegate
    }
    
    var categorySelector: NSSegmentedControl {
        del.categoryToolbarItem.view as! NSSegmentedControl
    }
    var viewModeSelector: NSSegmentedControl {
        del.viewModeToolbarItem.view as! NSSegmentedControl
    }
    var addButton: NSSegmentedControl {
        del.addToolbarItem.view as! NSSegmentedControl
    }
    var gridSizeSlider: NSSlider {
        (del.gridSizeToolbarItem.view as! GridSizeSlider).slider
    }
    var decreaseGridSizeButton: NSButton {
        (del.gridSizeToolbarItem.view as! GridSizeSlider).minButton
    }
    var increaseGridSizeButton: NSButton {
        (del.gridSizeToolbarItem.view as! GridSizeSlider).maxButton
    }
    var searchField: NSSearchField {
        del.searchField
    }
    
    @objc func _allowsSizeMode(_ mode: NSToolbar.SizeMode) -> Bool {
        return mode != .small
    }
}
