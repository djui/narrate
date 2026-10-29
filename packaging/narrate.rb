# Homebrew cask. Install from this file with `brew install --cask packaging/narrate.rb`, or copy it
# into a tap. scripts/release.sh prints the sha256 of the zip it builds.
cask "narrate" do
  version "0.6.0"
  sha256 "66314762c899091cd52305278f46b811d58a90be968372276952eae1bf170d55"

  url "https://github.com/djui/narrate/releases/download/v#{version}/Narrate-#{version}.zip"
  name "Narrate"
  desc "Turn DRM-free EPUBs into chaptered M4B audiobooks, offline"
  homepage "https://djui.github.io/narrate/"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Narrate.app"

  zap trash: [
    "~/Library/Caches/narrate",
    "~/Library/Application Support/narrate",
  ]
end
