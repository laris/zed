# Maintaining the laris/zed fork

> **Purpose of this document.** This is the long-term operating manual for the
> `laris/zed` fork of [zed-industries/zed][upstream]. It documents what we
> carry on top of upstream, how to upgrade to a new upstream version, how to
> verify the result, and how to contribute fixes back. Future maintainers
> (including future-you) should read this end-to-end before any upstream
> bump.

[upstream]: https://github.com/zed-industries/zed

---

## 0. Authoritative operating policy

This fork is maintained from **one local partial clone**:
`/Users/lqiao/dev/codes/zed-yolo`. A full clone of upstream is not needed
for routine upgrades or provider synchronization.

The legacy full clone at
`/Users/lqiao/dev/codes-repos/gh-zed-industries__zed` was removed on
2026-07-01 after its worktree, branches, tags, provider parity, and editor
references were verified. It is not a dependency of this workflow.

The normal checkpoint is the end of upstream's Friday workday. Because this
workstation uses Asia/Shanghai time, run the checkpoint on **Saturday at or
after 16:00 CST**, which safely covers Friday 23:59 in
America/Los_Angeles during daylight-saving time. The assumption that upstream
usually pauses on weekends is only a scheduling heuristic, not a guarantee.
Security fixes, urgent hotfixes, and releases published after the checkpoint
must be handled immediately or at the next checkpoint.

At each checkpoint:

1. Mirror every newly published upstream release tag since the prior
   checkpoint, not only the newest tag.
2. Select the newest non-draft `vX.Y.Z-pre` or `vX.Y.Z` GitHub Release as the
   new `enhanced` baseline. Use GitHub's `published_at` timestamp; do not rely
   on lexicographic tag sorting.
3. Snapshot upstream `main` at the checkpoint and fast-forward the fork's
   `main` to it. `enhanced` remains based on the selected release tag, not on
   the possibly newer `main` snapshot.
4. Rebase and validate the fork-only commits on the selected release tag.
5. Publish only the changed refs to GitHub and then CNB, one explicit ref at a
   time.
6. Prove exact all-head/all-tag parity between `laris/zed` and CNB
   `zed-upstream`.

Two different guarantees must not be confused:

- **Release coverage:** every upstream release tag published by the checkpoint
  exists on GitHub and CNB with the same tag-object SHA.
- **Provider parity:** every branch and tag currently present in `laris/zed`
  has the same ref-object SHA in CNB `zed-upstream`.

This policy does **not** claim that CNB continuously mirrors every live
upstream feature branch. CNB is a release-aligned union mirror and may lag
upstream between Friday checkpoints by design. Existing historical upstream
branches can remain on both providers, but routine maintenance neither fetches
nor updates those ephemeral branches.

All commands below assume:

```bash
REPO=/Users/lqiao/dev/codes/zed-yolo
SYNC_TOOLS=/Users/lqiao/.codex/skills/audit-clean-sync-repo/scripts
GH=$SYNC_TOOLS/run_github_proxy.sh
CNB=$SYNC_TOOLS/run_cnb_git_no_keychain.sh
CNB_API=$SYNC_TOOLS/run_cnb_no_proxy.sh
cd "$REPO"
```

- `$GH` is mandatory for every GitHub API, Git, SSH, Cargo/Git dependency, or
  lazy partial-clone fetch; it routes traffic through `127.0.0.1:10808`.
- `$CNB` and `$CNB_API` are mandatory for CNB and always bypass proxies.
- Never read CNB credentials from macOS Keychain. Do not use `cnb-rs` for this
  large repository while its metadata requests return HTTP 403.

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

| Remote     | URL                                             | Narrow fetch set / purpose                                      |
| ---------- | ----------------------------------------------- | --------------------------------------------------------------- |
| `upstream` | `https://github.com/zed-industries/zed.git`     | Pull-only; `main` plus explicitly selected release tags         |
| `github`   | `git@github.com:laris/zed.git`                  | Maintained public fork; normally fetch only `enhanced`           |
| `cnb`      | `https://cnb.cool/lary.me/zed-upstream.git`     | Private release-aligned union mirror; normally fetch `enhanced`  |

The clone must remain a `blob:none` partial clone. Its normal fetch refspecs
are intentionally narrow:

```text
github:   +refs/heads/enhanced:refs/remotes/github/enhanced
upstream: +refs/heads/main:refs/remotes/upstream/main
cnb:      +refs/heads/enhanced:refs/remotes/cnb/enhanced
```

Release tags are fetched by their full explicit refspec with `--no-tags`.
Never run `git fetch --all`, `git fetch --tags`, `git push --all`,
`git push --tags`, `git push --mirror`, or a blind prune in this repository.

> **Never push to `upstream`.** Upstream contributions go through
> `laris/zed` branches and a PR to `zed-industries/zed`. See §6.

#### 2.1.1 Why CNB does not show `[blob:none]`

The suffix printed by `git remote -v` is local Git configuration, not a
capability or storage property reported by the remote server. This clone was
created from GitHub with `--filter=blob:none`, and `github` and `upstream` are
configured as promisor remotes:

```text
remote.github.promisor=true
remote.github.partialclonefilter=blob:none
remote.upstream.promisor=true
remote.upstream.partialclonefilter=blob:none
```

Git therefore annotates the fetch lines for those two remotes with
`[blob:none]`. The `cnb` remote intentionally has neither
`remote.cnb.promisor` nor `remote.cnb.partialclonefilter`, so its fetch line
has no suffix. Its narrow `enhanced` fetch refspec is a separate setting.

This asymmetry is intentional:

- GitHub is the source for promised objects and lazy blob hydration, always
  through `$GH` and the required `127.0.0.1:10808` proxy.
- CNB is a normal private mirror destination, always reached through `$CNB`
  without a proxy or macOS Keychain access.
- Partial-clone filters govern fetching; they do not make pushes partial and
  do not describe whether CNB stores complete repository objects. An explicit
  push transfers only objects the destination lacks.
- Before a CNB push, §4.6 materializes the required release delta from GitHub.
  This prevents a CNB-side operation from unexpectedly triggering a lazy
  GitHub fetch under the CNB no-proxy environment.

Do not add CNB promisor/filter keys merely to make `git remote -v` look
symmetrical. Doing so provides no push-size benefit and could make an ordinary
missing-object read contact the private CNB remote unexpectedly.

Verify the intended configuration with:

```bash
git config --get-regexp \
  '^remote\.(github|upstream|cnb)\.(promisor|partialclonefilter)$'
```

The command should print the four GitHub/upstream entries above and no CNB
entry.

### 2.2 Branches we own

| Branch      | Lives on                  | Purpose                                                                 |
| ----------- | ------------------------- | ----------------------------------------------------------------------- |
| `enhanced`  | local + GitHub + CNB      | Rolling fork-only patch set rebased onto the selected Friday release tag |
| `fix/*`     | local + GitHub, temporary | Upstream PR branches based on an explicitly fetched upstream `main`      |
| `main`      | GitHub + CNB              | Fast-forward-only snapshot of upstream `main` at the Friday checkpoint   |

No local `main` branch is required. The partial clone can push
`refs/remotes/upstream/main` directly to the two providers after verifying a
fast-forward. This avoids maintaining a second checkout.

### 2.3 Archival tags

Three immutable tag classes are maintained:

- `vX.Y.Z-pre` or `vX.Y.Z`: the unchanged upstream release tag, mirrored to
  GitHub and CNB with the exact upstream tag-object SHA.
- `enhanced/vX.Y.Z-pre` or `enhanced/vX.Y.Z`: the validated enhanced build
  produced after rebasing onto that upstream release.
- `archive/enhanced/vX.Y.Z-pre-YYYYMMDD-HHMMSS`: a rollback snapshot created
  immediately before rewriting `enhanced` for the next baseline.

The timestamped rollback tag is necessary because an enhanced branch can gain
fixes after its original `enhanced/vX.Y.Z-pre` build tag was published. Never
move the original build tag to include those later fixes.

All three classes are retained on both providers. They answer which upstream
release was used, what was shipped, and what branch state existed immediately
before the next rebase. Compare tag-object SHAs, not only peeled commit SHAs.

> **Don't reuse the upstream tag name for an enhanced build.** A tag named `v1.5.0-pre-enhanced`
> (matching an old branch name) causes Git to emit "refname is ambiguous"
> warnings. Use the namespaces above.

### 2.4 Maintained comparison table

Keep this relationship table stable and obtain volatile SHAs/counts with the
commands in §2.5. Embedding the current `enhanced` SHA in this file would be
self-referential because committing the table changes that SHA.

| Endpoint | Role | Visibility | `main` policy | `enhanced` policy | Required result |
| -------- | ---- | ---------- | ------------- | ----------------- | --------------- |
| Local `/Users/lqiao/dev/codes/zed-yolo` | `blob:none` working clone | local | Cache only `upstream/main` | One checked-out local branch | Local `enhanced` equals both providers after publish |
| `zed-industries/zed` | Read-only source | Public | Live upstream | None | May lead the Friday checkpoint; selected release tags are authoritative baselines |
| `laris/zed` | Maintained fork | Public | Friday upstream snapshot | Published enhanced branch | Every advertised head/tag equals CNB |
| `lary.me/zed-upstream` | Release-aligned union mirror | Private | Equals GitHub fork | Equals GitHub fork | Every advertised head/tag equals GitHub |

The local clone intentionally has only one local branch and no complete local
tag inventory. Therefore, do **not** use a local-versus-remote `--all` or
`--tags` comparison as the mirror proof. The authoritative proof is
GitHub-remote versus CNB-remote, followed by a focused check of the locally
maintained refs.

### 2.5 Repeatable verification procedure

Run this after every fetch, rebase, publish, or provider-side change.

#### 2.5.1 Establish identity and local state

```bash
REPO=/Users/lqiao/dev/codes/zed-yolo
SYNC_TOOLS=/Users/lqiao/.codex/skills/audit-clean-sync-repo/scripts
GH=$SYNC_TOOLS/run_github_proxy.sh
CNB=$SYNC_TOOLS/run_cnb_git_no_keychain.sh
CNB_API=$SYNC_TOOLS/run_cnb_no_proxy.sh
cd "$REPO"

git status --short --branch
git remote -v
git config --get-regexp \
  '^remote\.(github|upstream|cnb)\.(promisor|partialclonefilter)$'
git config --get-all remote.github.fetch
git config --get-all remote.upstream.fetch
git config --get-all remote.cnb.fetch

$GH gh auth status
$GH gh repo view laris/zed \
  --json nameWithOwner,visibility,url,defaultBranchRef,isFork,parent
$CNB_API repositories get-by-id --repo lary.me/zed-upstream
```

Expected identities are public GitHub fork `laris/zed` with parent
`zed-industries/zed`, and active private CNB repository
`lary.me/zed-upstream`. GitHub traffic must use `$GH`; CNB must use `$CNB` or
`$CNB_API` without a proxy or macOS Keychain access.

#### 2.5.2 Enumerate and compare every provider ref

Use `gh api` as the independent GitHub listing and authenticated Git for CNB:

```bash
VERIFY_TMP=$(mktemp -d)
trap 'rm -rf "$VERIFY_TMP"' EXIT

$GH gh api --paginate \
  'repos/laris/zed/git/matching-refs/heads?per_page=100' \
  --jq '.[] | [.ref, .object.sha] | @tsv' \
  >"$VERIFY_TMP/github-heads"
$GH gh api --paginate \
  'repos/laris/zed/git/matching-refs/tags?per_page=100' \
  --jq '.[] | [.ref, .object.sha] | @tsv' \
  >"$VERIFY_TMP/github-tags"
cat "$VERIFY_TMP/github-heads" "$VERIFY_TMP/github-tags" |
  LC_ALL=C sort >"$VERIFY_TMP/github-all"

$CNB git ls-remote --heads --tags cnb >"$VERIFY_TMP/cnb-raw"
awk '$2 !~ /\^\{\}$/ {print $2 "\t" $1}' "$VERIFY_TMP/cnb-raw" |
  LC_ALL=C sort >"$VERIFY_TMP/cnb-all"

wc -l "$VERIFY_TMP/github-heads" "$VERIFY_TMP/github-tags"
diff -u "$VERIFY_TMP/github-all" "$VERIFY_TMP/cnb-all"
```

The final `diff` must be empty. GitHub's API returns annotated tag-object SHAs;
CNB's peeled `^{}` lines are excluded so the same objects are compared.

#### 2.5.3 Verify the local maintained refs

```bash
LOCAL_ENHANCED=$(git rev-parse refs/heads/enhanced)
GITHUB_ENHANCED=$(awk '$1 == "refs/heads/enhanced" {print $2}' \
  "$VERIFY_TMP/github-heads")
CNB_ENHANCED=$(awk '$1 == "refs/heads/enhanced" {print $2}' \
  "$VERIFY_TMP/cnb-all")
test "$LOCAL_ENHANCED" = "$GITHUB_ENHANCED"
test "$GITHUB_ENHANCED" = "$CNB_ENHANCED"

GITHUB_MAIN=$(awk '$1 == "refs/heads/main" {print $2}' \
  "$VERIFY_TMP/github-heads")
CNB_MAIN=$(awk '$1 == "refs/heads/main" {print $2}' \
  "$VERIFY_TMP/cnb-all")
test "$GITHUB_MAIN" = "$CNB_MAIN"

# This must be empty at the end of a completed maintenance run.
git status --porcelain=v1
```

Before publishing, a dirty worktree is allowed only when every path is
intentional and reviewed. After publishing, a non-empty status is a failed
completion check.

#### 2.5.4 Measure intentional upstream lag

```bash
OFFICIAL_MAIN=$($GH gh api repos/zed-industries/zed/commits/main --jq .sha)

$GH gh api \
  "repos/zed-industries/zed/compare/$GITHUB_MAIN...$OFFICIAL_MAIN" \
  --jq '{status, ahead_by, behind_by, total_commits}'

$GH gh api \
  "repos/laris/zed/compare/$OFFICIAL_MAIN...$GITHUB_ENHANCED" \
  --jq '{status, ahead_by, behind_by, merge_base: .merge_base_commit.sha}'
```

The fork `main` may be behind live upstream between checkpoints, but it must
remain an ancestor (`status: ahead` from upstream's perspective). Divergence
requires manual review. The enhanced branch is expected to diverge: `ahead_by`
is the maintained patch set and `behind_by` is upstream work since its selected
release baseline.

For every newly selected release tag, also run the three-provider tag-object
comparison in §4.8. Record the timestamp, timezone, counts, SHAs, lag, and test
results in §10 and `/Users/lqiao/dev/codes/REPOSITORY_SYNC_STATUS.md`.

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
| 4 | `Add CNB cross-build infrastructure`                             | `.cnb.yml`, `.cnb/*`, build scripts                                  | Linux-host cross-build via Docker. Also adds local mods to `script/bundle-mac` (runtime-shader fallback + enhanced remote-server embed). See §3.7. |
| 5 | `agent, agent_ui: Add enhanced_yolo to test fixtures`            | `agent`, `agent_ui`                                                  | Test-only fix-up for patch #1. Required for `cargo check --all-targets`.              |
| 6 | `crashes: Skip broken minidumper Server::drop on macOS quit`     | `crashes`                                                            | Workaround for [#57664][i57664]; see §3.6. **Remove this once upstream merges [PR #57951][pr57951].** |

This table lists the core product patches. CI, bundling, release, and
maintenance-document commits may also sit above the baseline. Before every
rebase, derive the complete replay set with
`git log --reverse "$PREV^{commit}..enhanced"`; never assume it is still six
commits.

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

### 3.7 Local modifications to `script/bundle-mac`

We carry three categories of edits inside patch #4 (`Add CNB cross-build
infrastructure`). They are not standalone commits — they live inside the
diff of patch #4 against upstream.

| # | Where (relative to upstream)                | What it does                                                                                                                                                                              |
| - | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A | Block after `rustup target add` (≈line 86)  | Detects whether the host has Xcode's `metal` compiler. If not (Command Line Tools only, or a Linux CNB host), exports the `gpui_platform/runtime_shaders` feature so the build does not try AOT shader compilation. |
| B | The three `cargo build` / `cargo bundle` call sites | Use the `${zed_features[@]+"${zed_features[@]}"}` idiom instead of the plain `"${zed_features[@]}"`. Required because `set -u` (which the script enables) errors on empty-array expansion under bash 3.2 — the bash that ships on the GitHub-hosted `macos-latest` runner. |
| C | New function `copy_enhanced_remote_servers` + call site | Copies pre-built `dist/zed-remote-server-linux-*.gz` (or `target/...`) into `Contents/Resources/remote_servers/` inside the bundled `.app`. Same set-u-safe array expansion as B. |

**Tracking discipline:**

- Every time you upgrade upstream, diff our script against the new
  upstream version and confirm A/B/C still apply cleanly:
  ```bash
  git diff "$NEW"..enhanced -- script/bundle-mac
  ```
  The diff should be a strict superset of the three blocks above. If
  upstream has refactored the script, you may need to relocate one or
  more blocks during the rebase.
- If upstream **adds the runtime-shader fallback** itself (block A
  becomes redundant), drop block A from our patch.
- If upstream **switches to a newer bash idiom** that doesn't need our
  set-u workaround (block B), drop the workaround.
- Block C (enhanced remote-server embedding) is fork-specific; it stays
  until we move the logic elsewhere.

---

## 4. Upstream upgrade workflow

This is the Friday release ritual. It keeps the working clone small while
making each provider update incremental and independently verifiable.

### 4.1 Pre-flight and prove the starting state

```bash
test -z "$(git status --porcelain=v1)" || {
  echo "Stop: working tree is not clean" >&2
  exit 1
}
test "$(git branch --show-current)" = enhanced || {
  echo "Stop: checkout enhanced first" >&2
  exit 1
}

# Refresh only the maintained fork branch. No tags and no other branches.
$GH git fetch --filter=blob:none --no-tags github \
  +refs/heads/enhanced:refs/remotes/github/enhanced
test "$(git rev-parse enhanced)" = \
  "$(git rev-parse refs/remotes/github/enhanced)" || {
  echo "Stop: local enhanced is not the published branch" >&2
  exit 1
}

# Record leases before changing anything.
OLD_GITHUB_MAIN=$($GH git ls-remote github refs/heads/main | awk '{print $1}')
OLD_GITHUB_ENHANCED=$($GH git ls-remote github refs/heads/enhanced | awk '{print $1}')
OLD_CNB_MAIN=$($CNB git ls-remote cnb refs/heads/main | awk '{print $1}')
OLD_CNB_ENHANCED=$($CNB git ls-remote cnb refs/heads/enhanced | awk '{print $1}')
test "$OLD_GITHUB_MAIN" = "$OLD_CNB_MAIN"
test "$OLD_GITHUB_ENHANCED" = "$OLD_CNB_ENHANCED"

# Prove complete provider parity before beginning.
TMP_REFS=$(mktemp -d)
$GH git ls-remote --heads --tags github | LC_ALL=C sort \
  >"$TMP_REFS/github"
$CNB git ls-remote --heads --tags cnb | LC_ALL=C sort \
  >"$TMP_REFS/cnb"
diff -u "$TMP_REFS/github" "$TMP_REFS/cnb"
```

If the `diff` is non-empty, stop and reconcile the existing mismatch with
explicit refspecs. Do not hide it with `--mirror`, `--all`, force, or prune.

### 4.2 Discover releases and fetch only selected refs

List releases in provider publication order:

```bash
$GH gh api --paginate 'repos/zed-industries/zed/releases?per_page=100' \
  --jq '.[] | select(.draft == false) |
        [.tag_name, .prerelease, .published_at] | @tsv'
```

Use the History table in §10 and the API output to set:

```bash
PREV=v1.9.0-pre       # baseline currently under enhanced
NEW=v1.10.0-pre       # newest release published by the checkpoint

# Include every release published since the previous checkpoint, oldest first.
# This prevents an intermediate preview/final tag from disappearing from the
# GitHub/CNB archive even though enhanced uses only the newest one.
NEW_RELEASE_TAGS=(v1.9.1-pre v1.9.2 v1.10.0-pre)
```

If there is no newly published release, leave `enhanced` unchanged and run
only the `main` snapshot, provider-parity, and ledger steps below.

Fetch upstream `main` and every new release tag explicitly:

```bash
$GH git fetch --filter=blob:none --no-tags upstream \
  +refs/heads/main:refs/remotes/upstream/main

# The initial partial clone has no tags, so fetch PREV explicitly when needed.
git show-ref --verify --quiet "refs/tags/$PREV" ||
  $GH git fetch --filter=blob:none --no-tags upstream \
    "refs/tags/$PREV:refs/tags/$PREV"

for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  $GH git fetch --filter=blob:none --no-tags upstream \
    "refs/tags/$TAG:refs/tags/$TAG"

  UPSTREAM_TAG_SHA=$($GH git ls-remote --tags upstream \
    "refs/tags/$TAG" | awk '$2 !~ /\^\{\}$/ {print $1}')
  test "$(git rev-parse "refs/tags/$TAG")" = "$UPSTREAM_TAG_SHA" || {
    echo "Stop: local tag object differs from upstream: $TAG" >&2
    exit 1
  }
done

git merge-base --is-ancestor "$PREV^{commit}" enhanced || {
  echo "Stop: PREV is not an ancestor of enhanced" >&2
  exit 1
}
git merge-base --is-ancestor "$PREV^{commit}" "$NEW^{commit}" || {
  echo "Stop: release ancestry is not linear; review manually" >&2
  exit 1
}

# Review the exact commits that will be replayed. Do not hard-code a count.
git log --reverse --format='%h %ad %s' --date=short \
  "$PREV^{commit}..enhanced"
```

### 4.3 Create a rollback ref and rebase

The immutable `enhanced/$PREV` build tag may predate later fixes on the same
baseline. Create a unique rollback tag immediately before rewriting:

```bash
ROLLBACK="archive/enhanced/$PREV-$(date +%Y%m%d-%H%M%S)"
git tag -a "$ROLLBACK" enhanced \
  -m "Rollback point before rebasing $PREV to $NEW"

# Publish the rollback ref to both providers before the rebase. The objects are
# already reachable from the current enhanced branch, so these pushes are tiny.
$GH git push github "refs/tags/$ROLLBACK:refs/tags/$ROLLBACK"
$CNB git push cnb "refs/tags/$ROLLBACK:refs/tags/$ROLLBACK"

git rebase --onto "$NEW^{commit}" "$PREV^{commit}" enhanced
```

Resolve conflicts one commit at a time:

```bash
git add -A
git rebase --continue

# Use only when upstream has made that fork patch unnecessary.
git rebase --skip

# Abort restores the branch to the rollback state.
git rebase --abort
```

#### 4.3.1 Conflict patterns we've already seen

| Patch              | File                                              | Conflict pattern                                                                                                 |
| ------------------ | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `enhanced YOLO`    | `crates/agent_servers/src/acp.rs`                 | `use gpui::{…}` import gains a new symbol upstream while we add `use settings::Settings as _;`. Merge both. |
| `enhanced YOLO`    | `crates/agent_settings/src/agent_settings.rs`     | Other authors add fields to `AgentSettings`; preserve `pub enhanced_yolo: EnhancedYoloSettings,`. |
| `test fixtures`    | `crates/agent/src/tool_permissions.rs`, `crates/agent_ui/src/agent_ui.rs` | Preserve our `enhanced_yolo` fixture fields while accepting new upstream fields. |
| `CNB infra`        | `.cnb.yml`                                        | Keep fork-owned CI and update the source baseline and release tag to `$NEW`. |

#### 4.3.2 Update version strings inside the CNB patch

After the rebase, inspect every hard-coded occurrence rather than blindly
replacing a version string:

```bash
grep -nF "$PREV" .cnb.yml MAINTAINING.md
git log --format=%H --grep='Add CNB cross-build infrastructure' -n 1 enhanced
```

Update `.cnb.yml` so its source-base comment and `RELEASE_TAG` refer to `$NEW`,
then amend the CNB infrastructure commit with an interactive rebase if those
values are intended to remain inside that commit. Review the final result:

```bash
grep -nE 'Source base:|RELEASE_TAG:' .cnb.yml
git diff "$NEW^{commit}..enhanced" -- .cnb.yml .cnb script/bundle-mac
```

### 4.4 Verify before publishing

```bash
git diff --check "$NEW^{commit}..enhanced"
git log --reverse --oneline "$NEW^{commit}..enhanced"

# Run through the GitHub proxy wrapper because Cargo may resolve Git-backed
# dependencies and the partial clone may lazily request promised blobs.
$GH cargo check --workspace --all-targets

# If the host has no Metal toolchain:
$GH cargo check --workspace --all-targets \
  --features gpui_platform/runtime_shaders

$GH script/bundle-mac -d -i aarch64-apple-darwin
open "/Applications/Zed Preview.app"
```

Smoke-test the Enhanced marker, YOLO permission behavior, editing, and clean
quit. Verify whether the minidumper workaround is still required. If any
check fails, do not publish.

Create the immutable enhanced build tag only after validation:

```bash
ENHANCED_TAG="enhanced/$NEW"
git tag -a "$ENHANCED_TAG" enhanced \
  -m "Enhanced build based on upstream $NEW"
```

Never move or reuse an existing upstream, rollback, or enhanced tag.

### 4.5 Publish incrementally to GitHub

First prove that the weekly `main` update is a fast-forward:

```bash
NEW_MAIN=$(git rev-parse refs/remotes/upstream/main)
git merge-base --is-ancestor "$OLD_GITHUB_MAIN" "$NEW_MAIN" || {
  echo "Stop: upstream main was rewritten or the recorded base is wrong" >&2
  exit 1
}
```

Push one explicit ref at a time. Upstream release tags are immutable and must
never be forced. Only `enhanced` is rewritten, protected by an exact lease:

```bash
$GH git push github \
  "$NEW_MAIN:refs/heads/main"

for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  $GH git push github "refs/tags/$TAG:refs/tags/$TAG"
done

$GH git push \
  --force-with-lease="refs/heads/enhanced:$OLD_GITHUB_ENHANCED" \
  github refs/heads/enhanced:refs/heads/enhanced

$GH git push github \
  "refs/tags/$ENHANCED_TAG:refs/tags/$ENHANCED_TAG"
```

### 4.6 Materialize only the delta needed by CNB

A `blob:none` clone may know a commit and tree without storing every blob.
CNB traffic cannot use the GitHub proxy, so all promised objects needed for
the CNB update must be materialized first under `$GH`.

The following helper enumerates only objects reachable from the new ref but
not from the old CNB ref. `git cat-file --batch-check` has been verified on
this clone to lazily fetch promised blobs:

```bash
hydrate_delta() {
  INCLUDE=$1
  EXCLUDE=$2

  git rev-list --objects --missing=print "$INCLUDE" "^$EXCLUDE" |
    awk '/^\?/ {sub(/^\?/, "", $1); print $1}' |
    $GH git cat-file --batch-check='%(objectname) %(objecttype)' \
      >/dev/null

  if git rev-list --objects --missing=print "$INCLUDE" "^$EXCLUDE" |
       grep -q '^?'; then
    echo "Stop: promised objects are still missing for $INCLUDE" >&2
    return 1
  fi
}

hydrate_delta "$NEW_MAIN" "$OLD_CNB_MAIN"
hydrate_delta refs/heads/enhanced "$OLD_CNB_ENHANCED"
for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  hydrate_delta "refs/tags/$TAG" "$OLD_CNB_MAIN"
done
```

This is the step that makes the partial-clone bridge reliable: GitHub supplies
only the missing release delta through the proxy, then CNB receives that same
small delta without ever contacting GitHub during the CNB push.

### 4.7 Publish the same explicit refs to CNB

```bash
$CNB git push cnb "$NEW_MAIN:refs/heads/main"

for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  $CNB git push cnb "refs/tags/$TAG:refs/tags/$TAG"
done

$CNB git push \
  --force-with-lease="refs/heads/enhanced:$OLD_CNB_ENHANCED" \
  cnb refs/heads/enhanced:refs/heads/enhanced

$CNB git push cnb \
  "refs/tags/$ENHANCED_TAG:refs/tags/$ENHANCED_TAG"
```

Do not combine these into one bulk push. Small independent pushes isolate
provider errors and let CNB reuse objects accepted by earlier steps.

### 4.8 Prove release coverage and full provider parity

```bash
for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  UP=$($GH git ls-remote --tags upstream "refs/tags/$TAG" |
    awk '$2 !~ /\^\{\}$/ {print $1}')
  FORK=$($GH git ls-remote --tags github "refs/tags/$TAG" |
    awk '$2 !~ /\^\{\}$/ {print $1}')
  MIRROR=$($CNB git ls-remote --tags cnb "refs/tags/$TAG" |
    awk '$2 !~ /\^\{\}$/ {print $1}')
  test "$UP" = "$FORK" && test "$FORK" = "$MIRROR" || {
    echo "Stop: release tag mismatch: $TAG" >&2
    exit 1
  }
done

$GH git ls-remote --heads --tags github | LC_ALL=C sort \
  >"$TMP_REFS/github.final"
$CNB git ls-remote --heads --tags cnb | LC_ALL=C sort \
  >"$TMP_REFS/cnb.final"
diff -u "$TMP_REFS/github.final" "$TMP_REFS/cnb.final"

$CNB_API repositories get-by-id --repo lary.me/zed-upstream
rm -rf "$TMP_REFS"
```

An empty final `diff` is the synchronization proof. Append a row to §10 with
the checkpoint time and timezone, `PREV`, `NEW`, upstream/fork/CNB SHAs, every
mirrored release tag, test results, and any dropped or modified patch.

Keep all `enhanced/*` and `archive/enhanced/*` tags. Cleanup is limited to
ordinary build outputs (`cargo clean` when appropriate), never history refs.

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

The `RELEASE_TAG` value in `.cnb.yml` must match `enhanced/<NEW>` after each
upgrade, for either a preview or final upstream baseline. See §4.3.2.

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
# Fetch only live upstream main; no local main branch is needed.
$GH git fetch --filter=blob:none --no-tags upstream \
  +refs/heads/main:refs/remotes/upstream/main

# Branch off upstream main (NOT off enhanced)
git switch -c fix/<short-description> refs/remotes/upstream/main

# Cherry-pick the relevant commit(s) from enhanced
git cherry-pick <sha>

# Verify
$GH cargo check --workspace --all-targets

# Push the explicit branch to our fork.
$GH git push -u github \
  refs/heads/fix/<short-description>:refs/heads/fix/<short-description>

# Exact provider parity includes temporary PR branches. Materialize the branch
# delta as described in §4.6, then mirror the same explicit ref to CNB.
OLD_CNB_MAIN=$($CNB git ls-remote cnb refs/heads/main | awk '{print $1}')
hydrate_delta refs/heads/fix/<short-description> "$OLD_CNB_MAIN"
$CNB git push cnb \
  refs/heads/fix/<short-description>:refs/heads/fix/<short-description>

# Open the PR with the PR template populated
$GH gh pr create --repo zed-industries/zed \
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

1. **Verify the change is in the next selected upstream release tag** before
   assuming the fork no longer needs the patch.
2. **At the next upgrade**, the rebase should detect the commit already
   exists upstream and skip it (or you `git rebase --skip` when prompted).
3. **Delete the `fix/` branch:**
   ```bash
   git branch -d fix/<short-description>
   $GH git push github :refs/heads/fix/<short-description>
   $CNB git push cnb :refs/heads/fix/<short-description>
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
$GH cargo install cargo-bundle \
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
git log --oneline --grep='Skip broken minidumper' enhanced/<PREV>
git cherry-pick <matching-patch-sha>
# or from the open PR branch:
git cherry-pick fix/crash-server-mach-port-on-macos-quit
```

---

## 8. When to revisit this guide

Re-read §1 and §3 if any of these become true:

1. **Upstream merges PR #57951** → drop patch #6 at the next upgrade and
   delete §3.6.
2. **You add another collaborator** who pulls from `laris/zed:enhanced` →
   replace the single-owner rebase workflow with merge-based maintenance and
   document the migration here.
3. **Patch set grows past ~15 commits** → consider whether some patches should
   become separate feature crates / extensions / upstream PRs.
4. **A patch becomes irrelevant** (upstream removes the code it touches) →
   drop the patch, document the removal here.
5. **macOS introduces a new bundle identifier convention** → revisit §5.3.

---

## 9. Quick reference (Friday checkpoint)

```bash
# 1. Discover every release since the last checkpoint.
$GH gh api --paginate 'repos/zed-industries/zed/releases?per_page=100' \
  --jq '.[] | select(.draft == false) |
        [.tag_name, .prerelease, .published_at] | @tsv'

# 2. Fetch only upstream main and the selected release tags.
$GH git fetch --filter=blob:none --no-tags upstream \
  +refs/heads/main:refs/remotes/upstream/main
$GH git fetch --filter=blob:none --no-tags upstream \
  refs/tags/<NEW>:refs/tags/<NEW>

# 3. Inspect, archive, rebase, and test.
git log --reverse --oneline '<PREV>^{commit}..enhanced'
git tag -a archive/enhanced/<PREV>-YYYYMMDD-HHMMSS enhanced \
  -m 'Pre-rebase rollback'
git rebase --onto '<NEW>^{commit}' '<PREV>^{commit}' enhanced
$GH cargo check --workspace --all-targets
$GH script/bundle-mac -d -i aarch64-apple-darwin
git tag -a enhanced/<NEW> enhanced -m 'Validated enhanced build'

# 4. Publish explicit refs to GitHub, hydrate only their delta (§4.6), then
# publish the same explicit refs to CNB. Use the exact leases captured in §4.1.
$GH git push github refs/remotes/upstream/main:refs/heads/main
$GH git push --force-with-lease=<lease> \
  github refs/heads/enhanced:refs/heads/enhanced
$CNB git push cnb refs/remotes/upstream/main:refs/heads/main
$CNB git push --force-with-lease=<lease> \
  cnb refs/heads/enhanced:refs/heads/enhanced

# 5. Full provider proof; output must be empty.
$GH git ls-remote --heads --tags github | LC_ALL=C sort > /tmp/zed.github.refs
$CNB git ls-remote --heads --tags cnb | LC_ALL=C sort > /tmp/zed.cnb.refs
diff -u /tmp/zed.github.refs /tmp/zed.cnb.refs
```

---

## 10. History

| Date       | From          | To             | Notes                                                                                                |
| ---------- | ------------- | -------------- | ---------------------------------------------------------------------------------------------------- |
| 2026-07-01 | `v1.9.0-pre`  | `v1.9.0-pre`   | Adopted the one-partial-clone Friday checkpoint policy, explicit-ref incremental GitHub/CNB publishing, promised-object hydration, and exact remote-to-remote parity proof. No source rebase in this documentation-only change. |
| 2026-06-27 | `v1.5.3-pre`  | `v1.9.0-pre`   | 624 upstream commits. Conflicts only in patch #1 (acp.rs imports + 2 fn sites; agent_settings.rs and settings_content/agent.rs vs upstream's new `sandbox_permissions`). Patches #2/#5/#6 auto-merged cleanly despite heavy churn (crashes.rs +89/−90, zed.rs +262/−21). PR #57951 confirmed **rejected** (CLA + maintainer prefers upstream minidumper fix), minidumper still 0.9 → **patch #6 kept**. Hit local "missing Metal Toolchain" — verified with `--features gpui_platform/runtime_shaders` (now documented in §4.4). |
| 2026-05-29 | `v1.5.0-pre`  | `v1.5.3-pre`   | 3 patch releases. Refactored CI into `build-enhanced.yml` with parallel mac + linux jobs and tag-driven GitHub Release publishing. Added §3.7 and §11. |
| 2026-05-23 | `v1.4.1-pre`  | `v1.5.0-pre`   | 135 upstream commits. One conflict in `acp.rs` imports. Added patch #6 (minidumper workaround) here. |
| 2026-05-22 | `v1.2.1-pre`  | `v1.4.1-pre`   | 333 upstream commits. Test fixtures needed `enhanced_yolo` field (patch #5 added).                   |
| (earlier)  | `v1.1.5-pre`  | `v1.2.1-pre`   | Pre-Option-B layout — branch-per-version.                                                            |
| 2026-05-28 | n/a           | n/a            | Migrated to Option B (single rolling `enhanced` branch + archival tags). Wrote this document.        |

Append a new row at every upgrade.

---

## 11. GitHub Actions release workflow

The fork ships releases via `.github/workflows/build-enhanced.yml` running
on `laris/zed`. It is **not** a copy of upstream's `release.yml` — upstream's
file is generated from `xtask::workflows::release`, uses Namespace.so
runners, code-signing certs, and ~10 secrets we don't have. We use a
purpose-built, smaller workflow on GitHub-hosted runners.

### 11.1 Triggers

| Event                         | What happens                                                            |
| ----------------------------- | ----------------------------------------------------------------------- |
| Push to `enhanced` branch     | Both build jobs run; artifacts uploaded to the workflow run only.       |
| Push of `enhanced/v*` tag     | Both build jobs run; **GitHub Release is created** with the artifacts.  |
| `workflow_dispatch` (manual)  | Same as branch push; choose `release` or `dev` profile. No release.     |

### 11.2 Jobs

| Job                                       | Runner          | Builds                                              | Approx time |
| ----------------------------------------- | --------------- | --------------------------------------------------- | ----------- |
| `bundle_mac_aarch64`                      | `macos-latest`  | `Zed-Preview.app`, `Zed-aarch64.dmg`, `zed-remote-server-macos-aarch64.gz` | 30–120 min (cache-dependent) |
| `bundle_linux_remote_server_x86_64`       | `ubuntu-latest` | `zed-remote-server-linux-x86_64.gz` (musl, static)  | 5–15 min    |
| `publish_release`                         | `ubuntu-latest` | GitHub Release (tag push only)                      | 1–2 min     |

### 11.3 Release artifacts

When an `enhanced/v*` tag is pushed, `publish_release` creates the matching
GitHub Release under `https://github.com/laris/zed/releases/tag/<tag>` with:

- `Zed-Preview-aarch64.tar.gz` + `.sha256` — the macOS `.app`, tarred (preserves
  ad-hoc signature, resource forks, symlinks).
- `Zed-aarch64.dmg` — the same `.app` distributed as a DMG.
- `zed-remote-server-macos-aarch64.gz` — gzipped binary for use as remote
  server on a macOS aarch64 host.
- `zed-remote-server-linux-x86_64.gz` + `.sha256` — gzipped statically-linked
  musl binary, runs on any glibc or musl Linux x86_64 host.

An `enhanced/vX.Y.Z-pre` build and its `-pre.N` re-spins are marked
**prerelease**. An `enhanced/vX.Y.Z` build based on an upstream final release
is not. Keep this conditional behavior aligned with upstream's release
classification.

Release notes are **auto-generated** from commit history between the previous
and current tag via `gh release create --generate-notes`.

### 11.4 Failure policy

`publish_release` **fails loudly** if a release with the same tag already
exists. Tags should be treated as immutable.

If the build fails after the immutable tag has been pushed:

1. Inspect the failure in the workflow run.
2. Fix the source code or the workflow.
3. Do **not** delete or move the published tag. Create a new validated re-spin
   tag and mirror it to both providers:
   ```bash
   git tag -a enhanced/vX.Y.Z-pre.2 enhanced -m 'Validated re-spin 2'
   $GH git push github \
     refs/tags/enhanced/vX.Y.Z-pre.2:refs/tags/enhanced/vX.Y.Z-pre.2
   $CNB git push cnb \
     refs/tags/enhanced/vX.Y.Z-pre.2:refs/tags/enhanced/vX.Y.Z-pre.2
   ```
4. Re-run the provider parity proof from §4.8.

### 11.5 Reusing upstream scripts

The workflow calls upstream-derived shell scripts that we have customized.
Each rebase, diff them against the new upstream to confirm our local mods
still apply:

```bash
git diff "$NEW"..enhanced -- script/bundle-mac
```

See §3.7 for what blocks live in `script/bundle-mac`. If upstream renames or
reorganizes a script, the rebase will likely conflict; resolve the conflict
to preserve the three blocks.

### 11.6 Secrets we don't (yet) have

Adding any of the following enables features currently disabled in CI:

| Secret                            | Enables                                              |
| --------------------------------- | ---------------------------------------------------- |
| `MACOS_CERTIFICATE` + password    | Developer-ID code signing (replaces ad-hoc)          |
| `APPLE_NOTARIZATION_KEY` + id + issuer | Apple notarization (no Gatekeeper warning)      |
| `SENTRY_AUTH_TOKEN`               | Upload debug symbols + minidumps to Sentry           |
| `ZED_CLIENT_CHECKSUM_SEED`        | Match upstream's binary self-update integrity hash   |

`script/bundle-mac` picks these up automatically when present (no workflow
changes needed). Store them as repository secrets in `laris/zed` settings.

### 11.7 Build minutes

`laris/zed` is public → GitHub-hosted macOS minutes are free and unlimited.
The 2h cold mac build doesn't cost anything. Linux jobs use ubuntu-latest
which is also free for public repos.
