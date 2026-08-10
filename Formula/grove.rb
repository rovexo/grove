class Grove < Formula
  desc "Per-worktree dev sites on real public HTTPS subdomains behind one wildcard certificate"
  homepage "https://github.com/rovexo/grove"
  url "https://github.com/rovexo/grove/archive/refs/tags/v0.2.3.tar.gz"
  sha256 "3c613b88785ee812c530a0f69aa1145590ac52ec7df61d980adc59c7027122c1"
  license "MIT"

  # System tools grove shells out to. Homebrew is the right packager precisely because it can
  # express these — a language package manager would leave them to the reader.
  depends_on "caddy"
  depends_on "lego"
  depends_on :macos

  def install
    # bin/ and lib/ are internals — libexec keeps them off PATH while the wrapper below points at
    # them. templates/ and docs/ are for humans, so they go where `brew --prefix grove` finds them:
    # the config hint tells people to copy from exactly that path, and it has to be true.
    libexec.install "bin", "lib", "profiles"
    prefix.install "templates", "docs"
    # grove resolves lib/ from GROVE_PKG_DIR, so it works through Homebrew's symlink.
    (bin/"grove").write_env_script libexec/"bin/grove", GROVE_PKG_DIR: libexec
  end

  test do
    # Runs without a project config and must say so clearly rather than crashing.
    output = shell_output("#{bin}/grove status 2>&1", 1)
    assert_match "grove.conf", output
  end
end
