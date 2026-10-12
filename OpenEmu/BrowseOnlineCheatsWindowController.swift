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

final class BrowseOnlineCheatsWindowController: NSWindowController, NSWindowDelegate {

    weak var gameDocument: OEGameDocument?

    /// True when this window is the one that paused emulation, so focus returning
    /// to the game only resumes a pause we caused.
    private var shouldResumeOnGameFocus = false

    private var browseViewController: BrowseOnlineCheatsViewController? {
        contentViewController as? BrowseOnlineCheatsViewController
    }

    init(document: OEGameDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = NSLocalizedString("Browse Online Cheats", comment: "Browse online cheats window title")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BrowseOnlineCheatsWindow")
        window.minSize = NSSize(width: 520, height: 380)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()

        super.init(window: window)
        self.gameDocument = document

        let viewController = BrowseOnlineCheatsViewController()
        viewController.gameDocument = document
        self.contentViewController = viewController

        window.delegate = self

        if let gameWindow = document.gameWindowController?.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(gameWindowDidBecomeMain(_:)),
                name: NSWindow.didBecomeMainNotification,
                object: gameWindow
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        pauseEmulationIfNeeded()
        browseViewController?.fetchOnlineCheats()
        // On reopen the cheat list is already loaded (so fetchOnlineCheats early-returns), but the
        // previous close flushed the ratings; re-query them for the visible rows. No-op on first open.
        browseViewController?.fetchRatingsForVisibleCheats()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        pauseEmulationIfNeeded()
        browseViewController?.refreshDynamicState()
    }

    func windowWillClose(_ notification: Notification) {
        // Ratings are cached only for the lifetime of an open window; drop them on close.
        browseViewController?.flushRatings()
    }

    func resetForCoreChange() {
        browseViewController?.resetForCoreChange()
    }

    @objc private func gameWindowDidBecomeMain(_ notification: Notification) {
        guard shouldResumeOnGameFocus else { return }
        gameDocument?.isEmulationPaused = false
        shouldResumeOnGameFocus = false
    }

    private func pauseEmulationIfNeeded() {
        guard !shouldResumeOnGameFocus else { return }
        gameDocument?.requestEmulationPauseRespectingRetroAchievementsHardcore { [weak self] paused in
            self?.shouldResumeOnGameFocus = paused
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
