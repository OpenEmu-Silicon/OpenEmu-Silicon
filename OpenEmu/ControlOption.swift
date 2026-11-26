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


import Foundation
import OpenEmuSystem

/// A choice a system can show in the Controls pane next to its buttons, for example "Upright / Sideways".
///
/// A system plugin declares it as a dictionary row inside its `OEControlListKey` groups (see the comment in
/// OESystemController.h). The pane draws a row of segments and saves the chosen value in `UserDefaults`.
/// Nothing here draws anything, so it can be tested on its own.
struct ControlOption: Equatable {

    static let defaultsKey = "OEControlListKeyOptionDefaultsKey"
    static let containerKey = "OEControlListKeyOptionContainerKey"
    static let choicesKey = "OEControlListKeyOptionChoicesKey"
    static let valueKey = "OEControlListKeyOptionValueKey"

    struct Choice: Equatable {
        /// Plain text from the plist. The pane looks it up in the ControlLabels strings.
        let label: String
        /// What gets saved.
        let value: String
    }

    /// Where the value is saved.
    let defaultsKey: String
    /// When set, the value is saved inside the dictionary stored under this key, with `defaultsKey` as the entry
    /// name. Game core display modes are saved this way (one dictionary per core).
    let containerKey: String?
    let choices: [Choice]

    /// Reads one plist row. Returns nil unless it names a place to save the value and has at least two choices
    /// with different values, so a typo in a plist hides the row instead of drawing a broken one.
    init?(plistRow row: [AnyHashable: Any]) {
        guard let defaultsKey = row[Self.defaultsKey] as? String, !defaultsKey.isEmpty,
              let rawChoices = row[Self.choicesKey] as? [[AnyHashable: Any]]
        else { return nil }

        var choices = [Choice]()
        for raw in rawChoices {
            guard let label = raw[OEControlListKeyLabelKey] as? String, !label.isEmpty,
                  let value = raw[Self.valueKey] as? String, !value.isEmpty,
                  !choices.contains(where: { $0.value == value })
            else { return nil }
            choices.append(Choice(label: label, value: value))
        }
        guard choices.count >= 2 else { return nil }

        self.defaultsKey = defaultsKey
        self.containerKey = (row[Self.containerKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.choices = choices
    }

    /// The saved value, or the first choice when nothing valid is saved.
    func selectedValue(in defaults: UserDefaults = .standard) -> String {
        let stored: Any?
        if let containerKey {
            stored = (defaults.dictionary(forKey: containerKey))?[defaultsKey]
        } else {
            stored = defaults.object(forKey: defaultsKey)
        }
        if let stored = stored as? String, choices.contains(where: { $0.value == stored }) {
            return stored
        }
        return choices[0].value
    }

    /// Saves a value. Values that are not one of the choices are ignored. Other entries in the container
    /// dictionary are kept.
    @discardableResult
    func select(_ value: String, in defaults: UserDefaults = .standard) -> Bool {
        guard choices.contains(where: { $0.value == value }) else { return false }
        if let containerKey {
            var dictionary = defaults.dictionary(forKey: containerKey) ?? [:]
            dictionary[defaultsKey] = value
            defaults.set(dictionary, forKey: containerKey)
        } else {
            defaults.set(value, forKey: defaultsKey)
        }
        return true
    }
}
