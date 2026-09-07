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
6. A stable code-signing identity must exist so macOS keeps previously granted
   permissions across updates: `security find-identity -v -p codesigning` must
   list `mTerm Self-Signed` (or your `MTERM_SIGN_IDENTITY`). If missing, run
   `scripts/create-signing-cert.sh` once. Without it, `package.sh` falls back to
   ad-hoc signing and every update re-prompts for Accessibility/Full Disk/folder
   permissions.

## Choose the version

- **Auto-increment PATCH version** from the latest tag. Extract the latest tag
  (e.g., `v1.1.32`), parse it, increment PATCH by 1 (e.g., `v1.1.33`), and
  proceed without asking the user.
- Example: `v1.1.32` → increment to `v1.1.33`
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

- **No user confirmation needed** — automatically proceed with all steps once
  preflight checks pass and version is auto-incremented. Release is fully
  automated from preflight through appcast commit.
- The app is signed with a stable self-signed identity (`mTerm Self-Signed`) but
  **not notarized**. The DMG has a Sparkle EdDSA signature in the appcast, but
  that is not Apple notarization. Don't claim otherwise. First manual install
  needs right-click ▸ Open. If no signing identity is present, the build falls
  back to ad-hoc and macOS re-prompts for permissions after every update.
- If the build fails, stop — do **not** create the tag or the release.
- If appcast generation or signature verification fails, stop — do **not**
  create the tag or the release.
- **Retry on transient failures** — if a step fails, check if it's transient
  (network timeout, temporary lock), retry up to 2 times before giving up.
- If the user only wants source (no binary), skip `package.sh` and drop the
  `.dmg` arg from `gh release create`; do not update the appcast.

## Rollback (if published by mistake)

```bash
gh release delete v<version> --yes
git push origin :refs/tags/v<version>   # delete remote tag
git tag -d v<version>                   # delete local tag
```
