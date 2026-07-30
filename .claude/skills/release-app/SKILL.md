---
name: release-app
description: Use when publishing a new mTerm release — cutting a version, building the .app/.dmg, and creating the GitHub release. Triggers on "release", "ship a version", "cut a release", "tag a new version", or /release-app.
---

# release-app

Cut a new mTerm release: build the distributable, generate its signed Sparkle
feed, tag it, and publish a GitHub Release with the `.dmg` attached. Wraps
`scripts/package.sh`, `scripts/generate-appcast.sh`, and `gh`.

## Preflight (verify before doing anything)

1. `git status` — working tree must be **clean**. If not, commit/stash first;
   `--generate-notes` and the tag must point at a real, pushed commit.
2. `git rev-parse --abbrev-ref HEAD` — should be `main`. Warn if not.
3. `git push` any unpushed commits on the branch first.
4. `gh auth status` — must be logged in.
5. Sparkle's `mterm-ed25519` EdDSA private key must be available in the macOS
   Keychain. Verify
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mterm-ed25519 -p`
   prints `LzG6J9ahpYdZHqj/wzaotCscwjxGcVnN6zfv10dqqsU=`.

## Choose the version

- Ask the user for the version if they didn't give one. Format is semver
  (`MAJOR.MINOR.PATCH`), tag is `v<version>` (e.g. `0.2.0` → tag `v0.2.0`).
- Show the latest existing tag for context: `git tag --sort=-v:refname | head -1`.
- Refuse to reuse an existing tag: `git tag -l v<version>` and
  `gh release view v<version>` must both be empty.

## Publish

Run in order — **build and generate the signed appcast first**, so a failed
build or missing signing key never leaves a dangling tag:

```bash
./scripts/package.sh <version>          # → build/mTerm-<version>.dmg
./scripts/generate-appcast.sh <version> # → build/appcast.xml
git tag v<version>
git push origin v<version>
gh release create v<version> build/mTerm-<version>.dmg --generate-notes
```

After the release asset exists, publish the prepared feed:

```bash
cp build/appcast.xml appcast.xml
git add appcast.xml
git commit -m "Update appcast for v<version>"
git push origin main
```

When Codex creates the appcast commit, include the required
`Co-authored-by: Codex <codex@openai.com>` trailer. Then verify the release URL,
asset, and that the raw `main/appcast.xml` enclosure points to the new asset.

## Rules

- **Confirm with the user before `gh release create`** — a GitHub release is
  public and outward-facing. State the version and that it will be published.
- The app is **ad-hoc code-signed / not notarized**. The DMG has a Sparkle EdDSA
  signature in the appcast, but that is not Apple notarization. Don't claim
  otherwise. First manual install needs right-click ▸ Open.
- If the build fails, stop — do **not** create the tag or the release.
- If appcast generation or signature verification fails, stop — do **not**
  create the tag or the release.
- If the user only wants source (no binary), skip `package.sh` and drop the
  `.dmg` arg from `gh release create`; do not update the appcast.

## Rollback (if published by mistake)

```bash
gh release delete v<version> --yes
git push origin :refs/tags/v<version>   # delete remote tag
git tag -d v<version>                   # delete local tag
```
