# Maintaining the laris/zed fork

> **Purpose of this document.** This is the long-term operating manual for the
> `laris/zed` fork of [zed-industries/zed][upstream]. It documents what we
> carry on top of upstream, how to upgrade to a new upstream version, how to
> verify the result, and how to contribute fixes back. Future maintainers
> (including future-you) should read this end-to-end before any upstream
> bump.

[upstream]: https://github.com/zed-industries/zed

---

## 1. Why this fork exists

We maintain a small, focused patch set on top of upstream Zed to:

- **Run an "enhanced YOLO" agent mode** — auto-approve ACP permission requests
  and inject `ZED_YOLO*` env vars so agent-spawned processes inherit
  high-permission defaults. Configured via `settings.json`.
- **Carry a visible build marker** — "Enhanced" suffix in the About-dialog
  title, so we can tell our build apart from the official Preview.
- **Carry a project-manager settings scaffold** — placeholder schema for
  future workspace/agent management UI.
- **Carry CNB cross-build infrastructure** — Linux → macOS compile path for
  CI under cnb.cool. (Linux-host cross-build via `cargo-zigbuild`; macOS host
  uses the upstream `script/bundle-mac` unchanged.)
- **Carry a macOS crash-on-quit workaround** — see §3.6 and upstream
  [#57664][i57664]/[#57950][i57950]/[PR #57951][pr57951].

The fork is **personal**. It's not collaboratively maintained. The patch set
exists because upstream either won't accept these changes (YOLO defaults are
intentionally conservative upstream) or hasn't accepted them yet (the
crash-on-quit fix is pending PR).

[i57664]: https://github.com/zed-industries/zed/issues/57664
[i57950]: https://github.com/zed-industries/zed/issues/57950
[pr57951]: https://github.com/zed-industries/zed/pull/57951

---

## 2. Repository layout

### 2.1 Remotes

| Remote          | URL                                                  | Purpose                          |
| --------------- | ---------------------------------------------------- | -------------------------------- |
| `origin`        | `https://github.com/zed-industries/zed`              | **Upstream.** Pull-only.         |
| `laris`         | `git@github.com:laris/zed.git`                       | Our fork. Push our work here.    |
| `cnb`           | `https://cnb.cool/lary.me/zed-yolo.git`              | CNB mirror for CI.               |
| `cnb-upstream`  | `https://cnb.cool/lary.me/zed-upstream.git`          | CNB mirror of upstream for CI.   |

> **Never push to `origin`.** Upstream contributions go through `laris/zed`
> branches → PR to `zed-industries/zed`. See §6.

### 2.2 Branches we own

| Branch                                  | Lives on        | Purpose                                                      |
| --------------------------------------- | --------------- | ------------------------------------------------------------ |
| `enhanced`                              | local + `laris` | **The fork.** Rolling branch with our N patches on top of the latest upstream pre-release we've upgraded to. This is the branch you build and run from. |
| `fix/*` (e.g. `fix/crash-server-…`)     | local + `laris` | Single-patch source branches for upstream PRs. Branched off upstream `main`, contain one commit each. Delete after the PR merges. |
| `main`                                  | local + `laris` | Mirrors upstream `main`. Don't commit here; rebase if needed: `git fetch origin && git reset --hard origin/main`. |

### 2.3 Archival tags

After each upstream upgrade, we **tag the pre-rebase state** of `enhanced` for
historical reference. Format: `enhanced/v<upstream-version>-pre`. Examples:

- `enhanced/v1.5.0-pre` — our patch set sitting on top of upstream `v1.5.0-pre`
- `enhanced/v1.6.0-pre` — our patch set sitting on top of upstream `v1.6.0-pre`
- etc.

These tags are immutable and never deleted. They are how we answer "what did
the 1.5 line look like?" after we've rebased to 1.6+.

> **Don't reuse the upstream tag name.** A tag named `v1.5.0-pre-enhanced`
> (matching an old branch name) causes Git to emit "refname is ambiguous"
> warnings. Stick to the `enhanced/v<version>-pre` prefix.

---

## 3. The patch set

These are the commits that sit on top of upstream on the `enhanced` branch.
Patch order matters because some patches reference fields/types introduced by
earlier ones. The chronological order is:

| # | Subject                                                          | Crates touched                                                       | Notes                                                                                 |
| - | ---------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 1 | `Add config-backed enhanced YOLO runtime`                        | `agent_servers`, `agent_settings`, `auto_update`, `settings_content` | Adds `EnhancedYoloSettings` to `AgentSettings`; opt-out via `agent.enhanced_yolo`.    |
| 2 | `Show enhanced marker in About title`                            | `zed`                                                                | Reads `ZED_ENHANCED` / `ZED_ENHANCED_LABEL` env vars (build-time or runtime).         |
| 3 | `Add enhanced project manager settings scaffold`                 | `settings`, `settings_content`, `workspace`                          | Placeholder schema only — no UI yet.                                                  |
| 4 | `Add CNB cross-build infrastructure`                             | `.cnb.yml`, `.cnb/*`, build scripts                                  | Linux-host cross-build via Docker. Touches macOS build files only via runtime-shader fallback (no `metal` compiler on Linux). |
| 5 | `agent, agent_ui: Add enhanced_yolo to test fixtures`            | `agent`, `agent_ui`                                                  | Test-only fix-up for patch #1. Required for `cargo check --all-targets`.              |
| 6 | `crashes: Skip broken minidumper Server::drop on macOS quit`     | `crashes`                                                            | Workaround for [#57664][i57664]; see §3.6. **Remove this once upstream merges [PR #57951][pr57951].** |

### 3.6 The minidumper workaround (patch #6)

`minidumper 0.9`'s `Server::drop` calls `mach_port_deallocate` on a
kernel-guarded Mach port, which raises `EXC_GUARD/INVALID_RIGHT` and SIGKILLs
the crash-handler subprocess on every quit. Symptom: "Zed quit unexpectedly"
dialog despite a clean quit.

The patch leaks the `Server` via `std::mem::forget` on macOS only. The
subprocess exits immediately after, so the kernel reclaims the port — no real
leak in practice.

**Removal criteria:** delete this commit during the next upstream upgrade if:

- PR #57951 (or any equivalent fix) has been merged upstream, **or**
- `minidumper` has been bumped to a version that no longer calls
  `mach_port_deallocate` from `Drop`. (Verify with
  `grep -nC2 'mach_port_deallocate' $(cargo metadata --format-version=1 | jq -r '.packages[] | select(.name == "minidumper") | .manifest_path | sub("Cargo.toml$"; "src")')/ipc/*.rs`.)

---

## 4. Upstream upgrade workflow

This is the core ritual. Run through it any time upstream ships a new
`vX.Y.Z-pre` you want to track. Estimated time end-to-end: 30–90 minutes
depending on conflict size.

### 4.1 Pre-flight

```bash
# Confirm a clean working tree
git status
# Should print: "nothing to commit, working tree clean"

# Sync remotes
git fetch origin --tags
git fetch laris

# Identify the upstream tags involved
PREV=v1.5.0-pre      # what enhanced currently sits on
NEW=v1.6.0-pre       # what you're upgrading to
echo "Upgrading $PREV -> $NEW"

# Sanity-check that PREV is actually the base
git merge-base --is-ancestor "$PREV" enhanced && echo "OK" || echo "PREV is wrong"
```

If `PREV is wrong`, figure out the actual base before continuing. A useful
diagnostic:

```bash
# Show what enhanced sits on top of (first parent of the oldest patch commit)
git log --first-parent --format="%h %s" enhanced ^"$PREV"
# Should print exactly the patch set (currently 6 commits). If it prints
# upstream commits too, PREV is wrong.
```

### 4.2 Archive the current state

```bash
# Snapshot the pre-rebase enhanced branch as a permanent tag
git tag "enhanced/$PREV" enhanced
git push laris "enhanced/$PREV"
```

This is your rollback anchor. Never delete it.

### 4.3 Rebase

```bash
# Move our patches onto the new upstream tag
git checkout enhanced
git rebase --onto "$NEW" "$PREV" enhanced
```

Expect conflicts. Resolve them one commit at a time. After each:

```bash
# After staging the resolution
git add -A
git rebase --continue

# If you discover the patch is no longer needed (e.g., upstream merged it):
git rebase --skip
```

If you get hopelessly stuck:

```bash
git rebase --abort     # back to pre-rebase state — safe
```

#### 4.3.1 Conflict patterns we've already seen

| Patch              | File                                              | Conflict pattern                                                                                                 |
| ------------------ | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `enhanced YOLO`    | `crates/agent_servers/src/acp.rs`                 | `use gpui::{…}` import gains a new symbol upstream while we add `use settings::Settings as _;`. Merge both. |
| `enhanced YOLO`    | `crates/agent_settings/src/agent_settings.rs`     | Other authors add fields to `AgentSettings`; our `pub enhanced_yolo: EnhancedYoloSettings,` line lands among them.|
| `test fixtures`    | `crates/agent/src/tool_permissions.rs`, `crates/agent_ui/src/agent_ui.rs` | Upstream adds new fields to `AgentSettings` and updates fixtures — make sure our `enhanced_yolo: …` block survives. |
| `CNB infra`        | `.cnb.yml`                                        | Pure file we own; conflict is unlikely. **Bump the comment and `RELEASE_TAG` to `$NEW` here.** See §4.3.2.       |

#### 4.3.2 Update version strings inside the CNB patch

The CNB infra patch hardcodes the upstream version in two places. When you
finish the rebase, the `Add CNB cross-build infrastructure` commit must end up
with these two lines updated:

```yaml
# .cnb.yml
# Source base: zed-industries/zed v1.6.0-pre (preview).   # ← was v1.5.0-pre
...
        RELEASE_TAG: zed-yolo-v1.6.0-pre-enhanced          # ← was v1.5.0-pre-enhanced
```

If the rebase conflict-resolution UI for this commit didn't include those
lines, fix them after `git rebase --continue` finishes the rebase:

```bash
# Find the CNB infra commit
CNB_SHA=$(git log --format=%H --grep='Add CNB cross-build infrastructure' -n 1 enhanced)
git rebase -i "$CNB_SHA^"
# Mark $CNB_SHA as 'edit', save and exit. Then:
sed -i '' "s/v1\\.5\\.0-pre/v1.6.0-pre/g" .cnb.yml
git add .cnb.yml
git commit --amend --no-edit
git rebase --continue
```

(Adjust the `sed` source/target to your actual `$PREV` and `$NEW`.)

### 4.4 Verify (mandatory before pushing)

```bash
# 1. Compile everything, including test targets
set -o pipefail
cargo check --workspace --all-targets

# 2. Dev build (faster than release — fine for smoke test)
script/bundle-mac -d -i aarch64-apple-darwin
# This installs to /Applications/Zed Preview.app
# The script exits non-zero at the very end on dev builds due to a
# trailing `gzip target/$triple/release/remote_server` that doesn't exist
# in debug mode. The install before that step succeeds. Ignore the exit
# code; check /Applications/Zed Preview.app exists and was just touched.

# 3. Quick sanity-launch
open "/Applications/Zed Preview.app"
# - Confirm the title bar / About dialog shows "Enhanced".
# - Open a project, type, quit (⌘Q).
# - Confirm no "Zed quit unexpectedly" dialog (validates patch #6).
# - Confirm an agent task auto-approves a tool call (validates patch #1).
```

If any of those fail, **do not push.** Debug, fix, then retry.

### 4.5 Publish

```bash
# Force-push the rebased branch (safe because we have the archive tag)
git push --force-with-lease laris enhanced
```

`--force-with-lease` refuses to overwrite if someone else pushed to `enhanced`
since your last fetch — protects against accidents if you ever add
collaborators.

### 4.6 Clean up the previous archive (optional)

We keep all `enhanced/v*` tags forever. There's no cleanup here. Just confirm
the new tag is reachable:

```bash
git tag --list 'enhanced/v*' --sort=-version:refname | head
```

---

## 5. Build & install

### 5.1 macOS host (typical local build)

```bash
# Debug build — faster, larger binary, fine for daily use
script/bundle-mac -d -i aarch64-apple-darwin
# → installs to /Applications/Zed Preview.app

# Release build — slow, optimized
script/bundle-mac aarch64-apple-darwin
# → .app at target/aarch64-apple-darwin/release/dmg/Zed Preview.app
# Then manually:
rm -rf ~/Applications/Zed\ Preview.app
cp -R "target/aarch64-apple-darwin/release/dmg/Zed Preview.app" ~/Applications/
```

Known script quirks (do not "fix" without understanding):

- `script/bundle-mac -d -i` exits non-zero because of a trailing `gzip` on
  `release/remote_server` even in debug mode. The install completes before
  this step.
- `script/bundle-mac` (release) exits non-zero unless `dmg-license` is
  globally installed via npm. The `.app` and `.dmg` are produced before this
  step.

### 5.2 Linux-host cross-build (CNB)

Driven by `.cnb.yml` + `.cnb/Dockerfile.zed-macos`. Triggered automatically
when the `RELEASE_TAG` env var matches a pushed tag. The pipeline produces
unsigned macOS Mach-O binaries; signing/notarization happens later locally or
in a rcodesign stage.

The `RELEASE_TAG` value in `.cnb.yml` must match `enhanced/v<NEW>-pre` after
each upgrade. See §4.3.2.

### 5.3 Parallel installs

| Path                              | Purpose                                                  |
| --------------------------------- | -------------------------------------------------------- |
| `~/Applications/Zed Preview.app`  | "Stable" install — replace only after the new build has been smoke-tested. |
| `/Applications/Zed Preview.app`   | "Test target" — overwrite freely while iterating.        |

Both share the bundle identifier `dev.zed.Zed-Preview`, so macOS may
arbitrate `zed://` URL handling. For predictable URL routing, use Finder →
right-click → Get Info → "Open with" → choose the preferred app → "Change All".

---

## 6. Contributing fixes back to upstream

When we find a fix that's useful beyond our fork (e.g., the minidumper
workaround), we open a PR to `zed-industries/zed`. **Never PR our YOLO/scaffold
patches** — they're intentional fork-only changes upstream won't accept.

### 6.1 Workflow

```bash
# Make sure local main mirrors upstream
git fetch origin --tags
git checkout main
git reset --hard origin/main

# Branch off upstream main (NOT off enhanced)
git checkout -b fix/<short-description> origin/main

# Cherry-pick the relevant commit(s) from enhanced
git cherry-pick <sha>

# Verify
cargo check --workspace --all-targets

# Push to our fork
git push -u laris fix/<short-description>

# Open the PR with the PR template populated
gh pr create --repo zed-industries/zed \
  --base main \
  --head laris:fix/<short-description> \
  --title "<crate>: <imperative-summary>" \
  --body "$(cat <<'EOF'
## Summary
<why this exists>

Closes #<analysis-issue>
Fixes #<bug-issue-if-applicable>

Self-Review Checklist:

- [x] I've reviewed my own diff for quality, security, and reliability
- [x] Unsafe blocks (if any) have justifying comments
- [x] The content is consistent with the UI/UX checklist
- [x] Tests cover the new/changed behavior
- [x] Performance impact has been considered and is acceptable

Release Notes:

- Fixed/Added/Improved …
EOF
)"
```

### 6.2 PR hygiene rules (from upstream CLAUDE.md)

- **PR title:** clear, imperative, correctly capitalized. No conventional-commit
  prefixes (`fix:`, `feat:`). No trailing punctuation. Optionally prefix with a
  crate name when one crate is the clear scope (`crashes: Skip broken …`).
- **Release Notes:** mandatory final section. Single bullet:
  `- Fixed/Added/Improved …` for user-facing changes, or `- N/A` for
  docs-only/non-user-facing.

### 6.3 Closing the loop after merge

When upstream merges your PR:

1. **Verify the change is in the next `vX.Y.Z-pre` tag** before assuming the
   fork no longer needs the patch.
2. **At the next upgrade**, the rebase should detect the commit already
   exists upstream and skip it (or you `git rebase --skip` when prompted).
3. **Delete the `fix/` branch:**
   ```bash
   git branch -d fix/<short-description>
   git push laris --delete fix/<short-description>
   ```
4. **Update §3 of this doc** — remove the row for the now-upstream patch.

---

## 7. Troubleshooting

### 7.1 "refname is ambiguous"

You have a branch and a tag with the same name (e.g., from older versioned
branches). Disambiguate explicitly:

```bash
git log refs/heads/<name>    # branch
git log refs/tags/<name>     # tag
```

Long-term fix: don't create overlapping names. Our convention (§2.3) avoids
this.

### 7.2 Rebase conflict in a file you don't recognize

```bash
# Look at what the patch was supposed to do
git log -p <patch-sha> -- <file>

# Look at what upstream did
git log v<PREV> v<NEW> -- <file>

# Read the conflicting hunks in context
git diff
```

If you can't make sense of the conflict in 10 minutes, `git rebase --abort`
and ask before retrying.

### 7.3 `cargo check --all-targets` fails after rebase but `cargo check` passes

This usually means a test fixture is missing a new field added by one of our
patches (the symptom that produced patch #5). Look at the error — it'll name
the struct and missing field — and update the corresponding fixture in the
patch that introduced the field.

### 7.4 Build hangs on `cargo install cargo-bundle …`

`script/bundle-mac` tries to install a forked `cargo-bundle`. If your
network blocks GitHub clones or the install hangs, run it manually first:

```bash
cargo install cargo-bundle \
  --git https://github.com/zed-industries/cargo-bundle.git \
  --branch zed-deploy
```

Then re-run `script/bundle-mac`.

### 7.5 "Zed quit unexpectedly" comes back

Means patch #6 isn't in the build (or the rebase dropped it). Verify:

```bash
git log --grep='Skip broken minidumper' enhanced
```

Should print exactly one commit. If zero, cherry-pick it back from the
archive tag:

```bash
git cherry-pick enhanced/v<PREV>-pre^{commit}~0
# or from the open PR branch:
git cherry-pick fix/crash-server-mach-port-on-macos-quit
```

---

## 8. When to revisit this guide

Re-read §1 and §3 if any of these become true:

1. **Upstream merges PR #57951** → drop patch #6 at the next upgrade and
   delete §3.6.
2. **You add another collaborator** who pulls from `laris/zed:enhanced` → switch
   from rebase (Option B) to merge-based maintenance (Option C). Document the
   migration in this file.
3. **Patch set grows past ~15 commits** → consider whether some patches should
   become separate feature crates / extensions / upstream PRs.
4. **A patch becomes irrelevant** (upstream removes the code it touches) →
   drop the patch, document the removal here.
5. **macOS introduces a new bundle identifier convention** → revisit §5.3.

---

## 9. Quick reference (the 5 commands you'll actually use)

```bash
# 1. See what's in the patch set
git log --oneline v<PREV>-pre..enhanced

# 2. Upgrade to a new upstream pre-release
git fetch origin --tags
git tag "enhanced/v<PREV>-pre" enhanced
git push laris "enhanced/v<PREV>-pre"
git rebase --onto v<NEW>-pre v<PREV>-pre enhanced
cargo check --workspace --all-targets
script/bundle-mac -d -i aarch64-apple-darwin
git push --force-with-lease laris enhanced

# 3. Open an upstream PR
git checkout -b fix/<name> origin/main
git cherry-pick <sha-from-enhanced>
git push -u laris fix/<name>
gh pr create --repo zed-industries/zed --base main --head laris:fix/<name>

# 4. Roll back to the previous version
git checkout enhanced
git reset --hard enhanced/v<PREV>-pre
git push --force-with-lease laris enhanced

# 5. Diff our patches against upstream
git diff v<NEW>-pre..enhanced
```

---

## 10. History

| Date       | From          | To             | Notes                                                                                                |
| ---------- | ------------- | -------------- | ---------------------------------------------------------------------------------------------------- |
| 2026-05-23 | `v1.4.1-pre`  | `v1.5.0-pre`   | 135 upstream commits. One conflict in `acp.rs` imports. Added patch #6 (minidumper workaround) here. |
| 2026-05-22 | `v1.2.1-pre`  | `v1.4.1-pre`   | 333 upstream commits. Test fixtures needed `enhanced_yolo` field (patch #5 added).                   |
| (earlier)  | `v1.1.5-pre`  | `v1.2.1-pre`   | Pre-Option-B layout — branch-per-version.                                                            |
| 2026-05-28 | n/a           | n/a            | Migrated to Option B (single rolling `enhanced` branch + archival tags). Wrote this document.        |

Append a new row at every upgrade.
