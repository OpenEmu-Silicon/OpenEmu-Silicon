cask "openemu-silicon" do
  version "1.4.0"
  sha256 "9e3d2938edd92552f04639576b6dabde2db6978971c24d7655a1a036c88f90b7"

  url "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/download/v#{version}/OpenEmu-Silicon.dmg"
  name "OpenEmu Silicon"
  desc "Native Apple Silicon port of the OpenEmu multi-system emulator"
  homepage "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon"

  livecheck do
    url "https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :big_sur

  app "OpenEmu.app"

  zap trash: [
    "~/Library/Application Support/OpenEmu",
    "~/Library/Application Support/org.openemu.OEXPCCAgent.Agents",
    "~/Library/Caches/org.openemu.OpenEmu",
    "~/Library/HTTPStorages/org.openemu.OpenEmu",
    "~/Library/HTTPStorages/org.openemu.OpenEmu.binarycookies",
    "~/Library/Preferences/org.openemu.OpenEmu.plist",
    "~/Library/Saved Application State/org.openemu.OpenEmu.savedState",
  ]
end
