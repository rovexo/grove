# Releasing

**A release lives in two repositories, and only one of them is this one.**

`brew install rovexo/tap/grove` reads `Formula/grove.rb` from **`rovexo/homebrew-tap`**. The copy in
this repository is not what anybody installs. Tag this repo, bump the formula here, push everything,
and every user still gets the previous version — with nothing anywhere reporting a problem. The repo
looks released. GitHub shows the tag. `brew upgrade` quietly does nothing.

That has now happened twice in a row, which is what this file is for.

## The steps

```bash
# 1. version + changelog, in one commit with the work
#    bin/grove: -V string        CHANGELOG.md: a dated section
git commit -am "what changed, in the imperative"

# 2. tag the WORK commit, annotated, before the formula commit
git tag -a v0.2.9 -m "grove 0.2.9 — one line on what it is"
git push origin main && git push origin v0.2.9

# 3. the formula, from the tarball GitHub built for that tag
curl -sL https://github.com/rovexo/grove/archive/refs/tags/v0.2.9.tar.gz | shasum -a 256
$EDITOR Formula/grove.rb          # url + sha256
git commit -am "Formula: v0.2.9" && git push origin main

# 4. THE STEP THAT GETS MISSED — the tap is a separate repository
TAP=$(brew --repository)/Library/Taps/rovexo/homebrew-tap
cp Formula/grove.rb "$TAP/Formula/grove.rb"
git -C "$TAP" commit -am "grove 0.2.9" && git -C "$TAP" push

# 5. prove a user can actually get it
brew info rovexo/tap/grove        # must say: stable 0.2.9
brew fetch rovexo/tap/grove       # downloads and checks the sha256
```

Step 5 is the whole point. It is the only step that fails when step 4 was forgotten, because it asks
the question a user asks: *what do I get if I install this right now?*

## Why no GitHub Release

There has been one since v0.1.0 and it is not part of the process. Homebrew installs from the tag's
source tarball, which GitHub generates automatically. A Release adds a second thing to keep in sync
for no one's benefit.

## Tests

`tests/unpublish.sh` needs no root, no DNS and no certificate authority — it stands up its own Caddy
on `:8443` and drives the real binary against it. Run it before tagging anything that touches
publishing, unpublishing or the zone registry.
