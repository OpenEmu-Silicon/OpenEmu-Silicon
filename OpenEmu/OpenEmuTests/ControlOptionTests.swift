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


import XCTest
import OpenEmuSystem
@testable import OpenEmu

/// The Controls pane choice that a system plist can declare. These tests cover reading the plist row and saving the
/// value; the drawing is checked in the app. Every test uses its own throwaway defaults.
final class ControlOptionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ControlOptionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func choice(_ label: String, _ value: String) -> [String: String] {
        [OEControlListKeyLabelKey: label, ControlOption.valueKey: value]
    }

    private func row(key: String? = "orientation", container: String? = nil,
                     choices: [[String: String]]? = nil) -> [AnyHashable: Any] {
        var row = [AnyHashable: Any]()
        if let key { row[ControlOption.defaultsKey] = key }
        if let container { row[ControlOption.containerKey] = container }
        row[ControlOption.choicesKey] = choices ?? [choice("Upright", "upright"), choice("Sideways", "sideways")]
        return row
    }

    func testReadsAValidRow() throws {
        let option = try XCTUnwrap(ControlOption(plistRow: row()))
        XCTAssertEqual(option.defaultsKey, "orientation")
        XCTAssertNil(option.containerKey)
        XCTAssertEqual(option.choices, [.init(label: "Upright", value: "upright"),
                                        .init(label: "Sideways", value: "sideways")])
    }

    func testRejectsRowsThatCouldNotBeDrawnOrSaved() {
        XCTAssertNil(ControlOption(plistRow: row(key: nil)), "no place to save")
        XCTAssertNil(ControlOption(plistRow: row(key: "")), "empty key")
        XCTAssertNil(ControlOption(plistRow: row(choices: [choice("Only", "only")])), "one choice is not a choice")
        XCTAssertNil(ControlOption(plistRow: row(choices: [choice("A", "x"), choice("B", "x")])), "same value twice")
        XCTAssertNil(ControlOption(plistRow: row(choices: [choice("A", "a"), choice("", "b")])), "empty label")
        XCTAssertNil(ControlOption(plistRow: [OEControlListKeyNameKey: "OEButtonUp", OEControlListKeyLabelKey: "Up"]),
                     "an ordinary button row is not an option")
    }

    func testOptionalLabelIsKept() throws {
        var withLabel = row()
        withLabel[ControlOption.labelKey] = "Orientation"
        XCTAssertEqual(ControlOption(plistRow: withLabel)?.label, "Orientation")
        XCTAssertNil(ControlOption(plistRow: row())?.label)
    }

    func testFirstChoiceIsTheDefault() throws {
        let option = try XCTUnwrap(ControlOption(plistRow: row()))
        XCTAssertEqual(option.selectedValue(in: defaults), "upright")
    }

    func testSavesAndReadsBack() throws {
        let option = try XCTUnwrap(ControlOption(plistRow: row()))
        XCTAssertTrue(option.select("sideways", in: defaults))
        XCTAssertEqual(option.selectedValue(in: defaults), "sideways")
        XCTAssertEqual(defaults.string(forKey: "orientation"), "sideways")
    }

    func testIgnoresValuesThatAreNotChoices() throws {
        let option = try XCTUnwrap(ControlOption(plistRow: row()))
        XCTAssertFalse(option.select("upside-down", in: defaults))
        XCTAssertNil(defaults.object(forKey: "orientation"))

        defaults.set("upside-down", forKey: "orientation")   // stale or hand-edited value
        XCTAssertEqual(option.selectedValue(in: defaults), "upright")
    }

    func testSavesInsideAContainerDictionaryAndKeepsOtherEntries() throws {
        let option = try XCTUnwrap(ControlOption(plistRow: row(container: "core.display")))
        defaults.set(["dolphin.resolution": "3x"], forKey: "core.display")

        XCTAssertEqual(option.selectedValue(in: defaults), "upright")
        XCTAssertTrue(option.select("sideways", in: defaults))

        let saved = defaults.dictionary(forKey: "core.display")
        XCTAssertEqual(saved?["orientation"] as? String, "sideways")
        XCTAssertEqual(saved?["dolphin.resolution"] as? String, "3x")
        XCTAssertEqual(option.selectedValue(in: defaults), "sideways")
        XCTAssertNil(defaults.object(forKey: "orientation"), "must not also write a top-level key")
    }

    /// The pane reloads the controller picture when this fires, and only accepts it from a view inside its setup
    /// view. (It once listened for the setup view itself, so the picture never changed.)
    func testPickingAChoicePostsFromInsideTheSetupView() throws {
        let setupView = ControlsButtonSetupView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let group: [AnyHashable] = ["Orientation", NSDictionary(dictionary: row(key: "controlOptionTest.\(suiteName!)"))]
        setupView.setup(withControlList: ["Gameplay Buttons", NSArray(object: group)])
        let optionView = try XCTUnwrap(setupView.subviews.compactMap { $0 as? ControlsOptionView }.first)
        let saved = optionView.option
        defer { UserDefaults.standard.removeObject(forKey: saved.defaultsKey) }

        var sender: NSView?
        let token = NotificationCenter.default.addObserver(forName: ControlOption.didChangeNotification, object: nil, queue: nil) {
            sender = $0.object as? NSView
        }
        defer { NotificationCenter.default.removeObserver(token) }

        optionView.selectedSegment = 1
        optionView.performClick(nil)

        XCTAssertEqual(sender?.isDescendant(of: setupView), true)
        XCTAssertEqual(saved.selectedValue(), "sideways")
    }
}
