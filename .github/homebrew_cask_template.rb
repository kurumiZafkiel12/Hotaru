cask "hotaru" do
  version "VERSION"

  on_macos do
    arch arm: "arm64", intel: "amd64"

    sha256 arm:   "ARM_SHA256",
           intel: "AMD_SHA256"

    url "https://github.com/kurumiZafkiel12/Hotaru/releases/download/v#{version}/Hotaru-#{version}-macos-#{arch}.dmg"
  end

  name "Hotaru"
  desc "Multi-platform proxy client based on ClashMeta"
  homepage "https://github.com/kurumiZafkiel12/Hotaru"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on :macos

  app "Hotaru.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-rd", "com.apple.quarantine", "{{appdir}}/Hotaru.app"],
        writable_paths: ["Hotaru.app"],
        writable_base:  :appdir
  end

  uninstall quit: "dev.hotaru.hotaru"

  zap trash: [
    "~/Library/Application Support/dev.hotaru.hotaru",
    "~/Library/Caches/dev.hotaru.hotaru",
    "~/Library/Preferences/dev.hotaru.hotaru.plist",
    "~/Library/Saved Application State/dev.hotaru.hotaru.savedState",
  ]
end
