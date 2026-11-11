# Homebrew cask for hearsay. Lives in the tap repo github.com/Larry8668/homebrew-hearsay as
# Casks/hearsay.rb; this copy is the source of truth, synced on each release.
#
#   brew tap Larry8668/hearsay
#   brew trust Larry8668/hearsay          # Homebrew 7+ requires trusting third-party taps
#   brew install --cask hearsay
#
# The app is signed with a self-signed certificate (stable, so the Microphone and System Audio
# grants survive updates) but is not notarised, so Gatekeeper would refuse the quarantined
# download. The postflight below removes the quarantine attribute (Homebrew 7 dropped --no-quarantine).
cask "hearsay" do
  version "0.3.0"
  sha256 "ac17398ab2ff30de68057acd9f70ffbf593b28c5ac5de9cdd23cf48308d148b2"

  url "https://github.com/Larry8668/hearsay/releases/download/v#{version}/hearsay-#{version}.zip"
  name "hearsay"
  desc "Live, offline me/them transcripts of your calls, from the menu bar"
  homepage "https://github.com/Larry8668/hearsay"

  depends_on macos: ">= :sonoma"   # 14.2+: Core Audio process taps
  depends_on arch: :arm64

  app "hearsay.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/hearsay.app"], must_succeed: false,
        writable_paths: ["hearsay.app"], writable_base: :appdir
  end

  caveats <<~EOS
    Open hearsay, then look for the waveform in your menu bar. The first launch downloads the
    speech model (a few hundred MB, kept in ~/Library/Application Support/hearsay) and asks for
    Microphone access; macOS asks for System Audio Recording the first time you start listening.
    Transcripts are saved to ~/Documents/hearsay. After `brew upgrade`, open it once more.
  EOS

  zap trash: [
    "~/Library/Application Support/hearsay",
    "~/Library/Logs/hearsay",
    "~/Library/Preferences/dev.hearsay.app.plist",
  ]
end
