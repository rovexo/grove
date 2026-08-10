class Grove < Formula
  desc "Per-worktree dev sites on real public HTTPS subdomains behind one wildcard certificate"
  homepage "https://github.com/rovexo/grove"
  url "https://github.com/rovexo/grove/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 is filled in at release time: shasum -a 256 on the tarball GitHub generates for the tag.
  sha256 "0" * 64
  license "MIT"

  # System tools grove shells out to. Homebrew is the right packager precisely because it can
  # express these — a language package manager would leave them to the reader.
  depends_on "caddy"
  depends_on "lego"
  depends_on :macos

  def install
    libexec.install "lib", "templates", "docs"
    bin.install "bin/grove"
    # The binary resolves its lib/ relative to its own location, so point it at the real tree
    # rather than the symlink Homebrew puts in bin/.
    (bin/"grove").write_env_script libexec/"bin/grove", GROVE_PKG_DIR: libexec
  end

  test do
    # Runs without a project config and must say so clearly rather than crashing.
    output = shell_output("#{bin}/grove status 2>&1", 1)
    assert_match "grove.conf", output
  end
end
