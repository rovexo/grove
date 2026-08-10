class Grove < Formula
  desc "Per-worktree dev sites on real public HTTPS subdomains behind one wildcard certificate"
  homepage "https://github.com/rovexo/grove"
  # rovexo/grove is a PRIVATE repository, so this cannot be the plain
  # github.com/.../archive/refs/tags/... URL: Homebrew does not send credentials to it and the
  # download 404s. The API tarball endpoint does accept a token, and current Homebrew has dropped the
  # GitHubPrivateRepository download strategies that used to handle this, so the header goes here.
  #
  # That means `brew install` needs HOMEBREW_GITHUB_API_TOKEN set to a token that can read the repo:
  #   export HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)"
  # Making the repository public would remove this whole paragraph and the header with it.
  #
  # The hash is of what THIS url serves. The API tarball and the archive tarball are different bytes
  # for the same tag (0e116bd… against 0ef18904…), so the two are not interchangeable.
  url "https://api.github.com/repos/rovexo/grove/tarball/v0.2.1",
      headers: ["Authorization: Bearer #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "")}",
                "Accept: application/vnd.github+json"]
  sha256 "663ae4a386dbce63a75dc8829f98564de49b296eb725e39c5ef652e808b07ed2"
  version "0.2.1"
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
