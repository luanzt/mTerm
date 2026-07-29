---
name: release-app
description: Use when publishing a new mTerm release — cutting a version, building the .app/.dmg, and creating the GitHub release. Triggers on "release", "ship a version", "cut a release", "tag a new version", or /release-app.
---

# release-app

Cut a new mTerm release: build the distributable, tag it, and publish a GitHub
Release with the `.dmg` attached. Wraps `scripts/package.sh` + `gh`.

## Preflight (verify before doing anything)

1. `git status` — working tree must be **clean**. If not, commit/stash first;
   `--generate-notes` and the tag must point at a real, pushed commit.
2. `git rev-parse --abbrev-ref HEAD` — should be `main`. Warn if not.
3. `git push` any unpushed commits on the branch first.
4. `gh auth status` — must be logged in.

## Choose the version

- Ask the user for the version if they didn't give one. Format is semver
  (`MAJOR.MINOR.PATCH`), tag is `v<version>` (e.g. `0.2.0` → tag `v0.2.0`).
- Show the latest existing tag for context: `git tag --sort=-v:refname | head -1`.
- Refuse to reuse an existing tag: `git tag -l v<version>` and
  `gh release view v<version>` must both be empty.

## Publish

Run in order — **build first**, so a failed build never leaves a dangling tag:

```bash
./scripts/package.sh <version>          # → build/mTerm-<version>.dmg
git tag v<version>
git push origin v<version>
gh release create v<version> build/mTerm-<version>.dmg --generate-notes
```

Then report the release URL (`gh release view v<version> --web` opens it).

## Rules

- **Confirm with the user before `gh release create`** — a GitHub release is
  public and outward-facing. State the version and that it will be published.
- The `.dmg` is **unsigned / not notarized**. Don't claim otherwise. First-open
  needs right-click ▸ Open. (Add notarization to `package.sh` before promising a
  clean install.)
- If the build fails, stop — do **not** create the tag or the release.
- If the user only wants source (no binary), skip `package.sh` and drop the
  `.dmg` arg from `gh release create`.

## Rollback (if published by mistake)

```bash
gh release delete v<version> --yes
git push origin :refs/tags/v<version>   # delete remote tag
git tag -d v<version>                   # delete local tag
```
