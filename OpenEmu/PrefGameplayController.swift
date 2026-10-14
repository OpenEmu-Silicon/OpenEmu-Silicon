// Copyright (c) 2020, OpenEmu Team
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

final class PrefGameplayController: NSViewController {
    
    @IBOutlet var globalDefaultShaderSelection: NSPopUpButton!
    
    private var token: NSObjectProtocol?
    
    // Injected slider controls (nil until viewDidAppear)
    private var saturationSlider: NSSlider?
    private var saturationLabel:  NSTextField?
    private var gammaSlider:      NSSlider?
    private var gammaLabel:       NSTextField?
    private var settingsGridView: NSGridView?

    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()

        loadShaderMenu()
        addSliders()
        addCheatSettings()

        token = NotificationCenter.default.addObserver(forName: .shaderModelCustomShadersDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }

            self.loadShaderMenu()
        }
    }
    
    deinit {
        if let token = token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
    
    // MARK: - Slider injection

    private func addSliders() {
        let sat = OEGameDocument.clampedSaturation((UserDefaults.standard.object(forKey: OEGameSaturationKey) as? Float) ?? 1.0)
        let gam = OEGameDocument.clampedGamma((UserDefaults.standard.object(forKey: OEGameGammaKey) as? Float) ?? 1.0)

        // The XIB has one NSGridView (2 columns) as the only direct subview.
        // Walk up from the shader popup to find it, then insert two new rows
        // at index 0 (above Shader). NSGridView handles all layout automatically.
        var ancestor: NSView? = globalDefaultShaderSelection
        while let parent = ancestor?.superview, parent !== view { ancestor = parent }
        guard let gridView = ancestor as? NSGridView else { return }
        settingsGridView = gridView

        // ── Build Saturation row ──────────────────────────────────────────
        let satLabel = NSTextField(labelWithString: "Saturation:")
        satLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let satSlider = NSSlider(value: Double(sat), minValue: 0.5, maxValue: 3.0,
                                 target: self, action: #selector(saturationChanged(_:)))
        satSlider.isContinuous = true
        satSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let satPct = NSTextField(labelWithString: String(format: "%.0f%%", sat * 100))
        satPct.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        satPct.setContentHuggingPriority(.required, for: .horizontal)

        let satRow = NSStackView(views: [satSlider, satPct])
        satRow.orientation = .horizontal
        satRow.spacing = 8
        satRow.distribution = .fill

        // ── Build Gamma row ───────────────────────────────────────────────
        let gamLabel = NSTextField(labelWithString: "Gamma:")
        gamLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let gamSlider = NSSlider(value: Double(gam), minValue: 0.5, maxValue: 2.0,
                                 target: self, action: #selector(gammaChanged(_:)))
        gamSlider.isContinuous = true
        gamSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let gamPct = NSTextField(labelWithString: String(format: "%.0f%%", gam * 100))
        gamPct.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        gamPct.setContentHuggingPriority(.required, for: .horizontal)

        let gamRow = NSStackView(views: [gamSlider, gamPct])
        gamRow.orientation = .horizontal
        gamRow.spacing = 8
        gamRow.distribution = .fill

        // ── Insert rows above Shader ──────────────────────────────────────
        // Insert Gamma at 0 first, then Saturation at 0 → Saturation ends up on top.
        gridView.insertRow(at: 0, with: [gamLabel, gamRow])
        gridView.insertRow(at: 0, with: [satLabel, satRow])

        // Center the grid horizontally within the (potentially wider) window.
        // Deactivate the XIB's fixed leading=30 and soft trailing>=30 constraints,
        // then pin the grid to the center with minimum side margins.
        for c in view.constraints where (c.firstItem as? NSView) === gridView
                                     && c.firstAttribute == .leading {
            c.isActive = false
        }
        for c in view.constraints where c.secondItem as? NSView === gridView
                                     && c.secondAttribute == .trailing {
            c.isActive = false
        }
        NSLayoutConstraint.activate([
            gridView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            gridView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30)
        ])

        saturationSlider = satSlider
        saturationLabel  = satPct
        gammaSlider      = gamSlider
        gammaLabel       = gamPct
    }

    // MARK: - Cheat settings

    private let cheatWorksCheckbox = NSButton(checkboxWithTitle: "Community cheat ratings (CheatWorks)", target: nil, action: nil)

    private static let cheatWorksPrivacyURL = URL(string: "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/blob/main/docs/privacy-policy.md#cheatworks-community-cheat-ratings")!

    /// Adds a "Cheats" row below the existing settings, with the CheatWorks on/off switch.
    private func addCheatSettings() {
        guard let gridView = settingsGridView else { return }

        cheatWorksCheckbox.target = self
        cheatWorksCheckbox.action = #selector(toggleCheatWorks(_:))
        cheatWorksCheckbox.state = CheatWorksConfig.isEnabled ? .on : .off

        let note = NSTextField(wrappingLabelWithString: "Show and share cheat ratings. When off, OpenEmu never contacts CheatWorks.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300

        let privacyButton = NSButton(title: "What is shared?", target: self, action: #selector(openCheatWorksPrivacyDetails(_:)))
        privacyButton.bezelStyle = .inline
        privacyButton.controlSize = .small

        let stack = NSStackView(views: [cheatWorksCheckbox, note, privacyButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let label = NSTextField(labelWithString: "Cheats:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let row = gridView.addRow(with: [label, stack])
        // The pane's bottom margin is a weak constraint, so the last row supplies its own spacing.
        row.bottomPadding = 20
        row.cell(at: 0).yPlacement = .top
    }

    @objc private func toggleCheatWorks(_ sender: NSButton) {
        let enabled = sender.state == .on
        CheatWorksConfig.isEnabled = enabled

        // Turning it back on: share any ratings given while it was off.
        if enabled {
            Task.detached(priority: .utility) {
                await CheatFeedbackService.shared.syncToCheatWorks()
            }
        }
    }

    @objc private func openCheatWorksPrivacyDetails(_ sender: Any?) {
        NSWorkspace.shared.open(Self.cheatWorksPrivacyURL)
    }

    // MARK: - Slider actions

    @objc private func saturationChanged(_ sender: NSSlider) {
        let v = OEGameDocument.clampedSaturation(sender.floatValue)
        saturationLabel?.stringValue = String(format: "%.0f%%", v * 100)
        UserDefaults.standard.set(v, forKey: OEGameSaturationKey)
        
        NSDocumentController.shared.documents.forEach {
            ($0 as? OEGameDocument)?.setSaturation(v, asDefault: false)
        }
    }

    @objc private func gammaChanged(_ sender: NSSlider) {
        let v = OEGameDocument.clampedGamma(sender.floatValue)
        gammaLabel?.stringValue = String(format: "%.0f%%", v * 100)
        UserDefaults.standard.set(v, forKey: OEGameGammaKey)
        
        NSDocumentController.shared.documents.forEach {
            ($0 as? OEGameDocument)?.setGamma(v, asDefault: false)
        }
    }
    
    private func loadShaderMenu() {
        
        let globalShaderMenu = NSMenu()
        
        let systemShaders = OEShaderStore.shared.sortedSystemShaderNames
        systemShaders.forEach { shaderName in
            globalShaderMenu.addItem(withTitle: shaderName, action: nil, keyEquivalent: "")
        }
        
        let customShaders = OEShaderStore.shared.sortedCustomShaderNames
        if !customShaders.isEmpty {
            globalShaderMenu.addItem(.separator())
            
            customShaders.forEach { shaderName in
                globalShaderMenu.addItem(withTitle: shaderName, action: nil, keyEquivalent: "")
            }
        }
        
        globalDefaultShaderSelection.menu = globalShaderMenu
        
        let selectedShaderName = OEShaderStore.shared.defaultShaderName
        
        if globalDefaultShaderSelection.item(withTitle: selectedShaderName) != nil {
            globalDefaultShaderSelection.selectItem(withTitle: selectedShaderName)
        } else {
            globalDefaultShaderSelection.selectItem(at: 0)
        }
    }
    
    @IBAction func changeGlobalDefaultShader(_ sender: Any?) {
        guard let context = OELibraryDatabase.default?.mainThreadContext else { return }
        
        guard let shaderName = globalDefaultShaderSelection.selectedItem?.title else { return }
        
        let allSystemIdentifiers = OEDBSystem.allSystemIdentifiers(in: context)
        allSystemIdentifiers.forEach(OESystemShaderStore.shared.resetShader(forSystem:))
        OEShaderStore.shared.defaultShaderName = shaderName
    }
}

// MARK: - PreferencePane

extension PrefGameplayController: PreferencePane {
    
    var icon: NSImage? { NSImage(named: "gameplay_tab_icon") }
    
    var panelTitle: String { "Gameplay" }
    
    var viewSize: NSSize { view.fittingSize }
}
