# Homebrew cask. Install from this file with `brew install --cask packaging/narrate.rb`, or copy it
# into a tap. scripts/release.sh prints the sha256 of the zip it builds.
cask "narrate" do
  version "0.5.0"
  sha256 "SHA256"

  url "https://github.com/djui/narrate/releases/download/v#{version}/Narrate-#{version}.zip"
  name "Narrate"
  desc "Turn DRM-free EPUBs into chaptered M4B audiobooks, offline"
  homepage "https://djui.github.io/narrate/"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"
  depends_on formula: "ffmpeg"

  app "Narrate.app"

  zap trash: [
    "~/Library/Caches/narrate",
    "~/Library/Application Support/narrate",
  ]
end
