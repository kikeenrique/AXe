class Axe < Formula
  desc "<normalized>"
  homepage "https://github.com/cameroncooke/AXe"
  license "MIT"
  version "<normalized>"
  depends_on arch: :arm64
  depends_on macos: :sequoia

  url "<normalized>"
  sha256 "<normalized>"

  def install
    libexec.install "axe", "AXe_AXe.bundle", "Resources"
    bin.write_exec_script libexec/"axe"
  end

  # Only axe is re-signed. Resources/SimulatorFrameworkBridge-iOS runs inside the
  # simulator and keeps the signature it was built with.
  def post_install
    system "codesign", "--force", "--sign", "-", "--timestamp=none", libexec/"axe"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/axe --version")
  end
end
