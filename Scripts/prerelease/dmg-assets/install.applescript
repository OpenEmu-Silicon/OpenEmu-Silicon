-- Installer for the OpenEmu-Silicon pre-release disk image.
-- Built into Install.app by Scripts/prerelease/build-preview-dmg.sh, then signed and notarized with the rest
-- of the disk image. (It is an app and not a .command script because Apple's notarization covers apps but
-- not plain shell scripts, so Gatekeeper refuses a downloaded .command file.)

on run
	set hereFolder to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set payload to hereFolder & "/.payload"
	set appSource to payload & "/OpenEmu.app"
	set coresSource to payload & "/Preview Cores"
	set appDest to "/Applications/OpenEmu.app"
	set coresDest to (POSIX path of (path to home folder)) & "Library/Application Support/OpenEmu/Cores"

	-- OpenEmu must not be running while it is replaced.
	set isRunning to true
	try
		do shell script "pgrep -x OpenEmu"
	on error
		set isRunning to false
	end try
	if isRunning then
		display dialog "OpenEmu is open. Please quit it, then open Install again." buttons {"OK"} default button "OK" with icon caution with title "Install OpenEmu pre-release"
		return
	end if

	set answer to display dialog "This replaces /Applications/OpenEmu.app with the pre-release build and installs the Azahar (Nintendo 3DS), PCSX2 (PlayStation 2) and FBNeo (Arcade) cores." & return & return & "Your games and saves stay where they are, but please back up ~/Library/Application Support/OpenEmu first." buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with title "Install OpenEmu pre-release"
	if button returned of answer is not "Install" then return

	try
		set installScript to "set -e" & linefeed & ¬
			"rm -rf " & quoted form of appDest & linefeed & ¬
			"ditto " & quoted form of appSource & " " & quoted form of appDest & linefeed & ¬
			"xattr -cr " & quoted form of appDest & linefeed & ¬
			"chflags -R nohidden " & quoted form of appDest & linefeed & ¬
			"mkdir -p " & quoted form of coresDest & linefeed & ¬
			"for plugin in " & quoted form of coresSource & "/*.oecoreplugin; do" & linefeed & ¬
			"  name=$(basename \"$plugin\")" & linefeed & ¬
			"  rm -rf " & quoted form of coresDest & "/\"$name\"" & linefeed & ¬
			"  ditto \"$plugin\" " & quoted form of coresDest & "/\"$name\"" & linefeed & ¬
			"  xattr -cr " & quoted form of coresDest & "/\"$name\"" & linefeed & ¬
			"done"
		do shell script installScript
	on error errorMessage
		display dialog "The install did not finish:" & return & return & errorMessage buttons {"OK"} default button "OK" with icon stop with title "Install OpenEmu pre-release"
		return
	end try

	set done to display dialog "Installed. Open OpenEmu from your Applications folder." buttons {"Close", "Open OpenEmu"} default button "Open OpenEmu" with title "Install OpenEmu pre-release"
	if button returned of done is "Open OpenEmu" then
		do shell script "open " & quoted form of appDest
	end if
end run
