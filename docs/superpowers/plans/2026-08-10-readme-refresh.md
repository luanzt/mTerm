# README Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh mTerm's README with a Tabby-inspired presentation, the new editorial hero image, clearer user-facing features, and a directly embedded bank-transfer QR code.

**Architecture:** This is a documentation-only change. Store the supplied raster assets under `docs/images/`, reorganize `README.md` so user-facing information comes before maintainer details, and preserve all existing installation, release, and architecture accuracy.

**Tech Stack:** GitHub-flavored Markdown, HTML image/badge markup, PNG/JPEG assets.

## Global Constraints

- Replace the current overview image with the supplied 1600×1200 editorial hero.
- Publish the supplied VietQR image intentionally as `docs/images/support-qr.jpg`; do not duplicate the bank details as README text.
- Do not add GitHub Sponsors, Ko-fi, Stripe, `.github/FUNDING.yml`, or any other payment platform.
- Keep the macOS 14 minimum and the ad-hoc-signed, not-notarized installation warning accurate.
- Keep the existing eight-theme gallery and all theme image paths valid.
- Make no source-code, packaging, updater, or release-behavior changes.

---

### Task 1: Refresh README presentation and assets

**Files:**
- Create: `docs/images/mterm-hero.png`
- Create: `docs/images/support-qr.jpg`
- Delete: `docs/images/mterm-overview.png`
- Modify: `README.md`

**Interfaces:**
- Consumes: supplied hero image and VietQR JPEG from the local filesystem.
- Produces: a GitHub-renderable README whose local image references all resolve.

- [x] **Step 1: Copy the supplied assets into the repository**

Copy the hero without re-encoding and copy the QR without reducing its 1290×1135 source resolution:

```bash
cp '/Users/luan/Documents/Codex/2026-08-10/nh-n-tabby-nh-v-thi/outputs/mterm-editorial-clay-4x3.png' docs/images/mterm-hero.png
cp '/Users/luan/Downloads/IMG_8726.JPG' docs/images/support-qr.jpg
```

- [x] **Step 2: Replace the README opening**

Use the hero first, followed by centered badges for the latest release, total GitHub downloads, macOS 14+, and an anchor link to `#support-mterm`. Follow the badges with this short positioning copy:

```markdown
mTerm is a native macOS terminal built for parallel work. Run shells and coding
agents side by side, organize sessions by project, and switch focus without
stopping anything.
```

- [x] **Step 3: Put user-facing sections before maintainer documentation**

Order the README as follows:

1. Hero, badges, positioning copy, and macOS requirement.
2. `Download` with the latest-release link and first-launch Gatekeeper instructions.
3. `Highlights` covering six-pane layouts, drag-and-drop placement, project workspaces, live hidden sessions, Claude Code/Codex attention notifications, search, shortcuts, and 17 themes.
4. Existing `Themes` gallery.
5. `Using mTerm` and keyboard reference.
6. `Support mTerm`.
7. `Build from source`, packaging/release notes, and architecture.

- [x] **Step 4: Add the QR support block**

Insert this section immediately before `Build from source`:

```html
## Support mTerm

If mTerm makes your day a little easier, you can support its continued development.

<p align="center">
  <img src="docs/images/support-qr.jpg" width="420" alt="QR code to support mTerm">
</p>

<p align="center"><sub>Scan to support mTerm. Thank you ❤️</sub></p>
```

- [x] **Step 5: Remove the superseded overview asset**

After confirming `README.md` no longer references it:

```bash
git rm docs/images/mterm-overview.png
```

- [x] **Step 6: Verify the documentation change**

Run:

```bash
git diff --check
ruby -e 'readme = File.read("README.md"); paths = readme.scan(/(?:src=|!\[[^\]]*\]\()\"?([^\"\) ]+docs\/images\/[^\"\) ]+)/).flatten; missing = paths.reject { |path| File.file?(path) }; abort("Missing README images: #{missing.join(", ")}") unless missing.empty?; puts "Validated #{paths.length} README image references"'
sips -g pixelWidth -g pixelHeight docs/images/mterm-hero.png docs/images/support-qr.jpg
swift test
```

Expected results:

- `git diff --check` exits 0.
- Every local README image exists.
- Hero remains 1600×1200 and QR remains 1290×1135.
- Full Swift test suite exits 0.

- [x] **Step 7: Commit the finished refresh when requested**

```bash
git add README.md docs/images/mterm-hero.png docs/images/support-qr.jpg docs/images/mterm-overview.png
git commit -m "Refresh README presentation" -m "Co-authored-by: Codex <codex@openai.com>"
```
