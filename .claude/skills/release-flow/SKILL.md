---
name: release-flow
description: "Mole CLI release runbook for distribution channels, pre-flight checks, capital-V tags, artifacts, and curated-note handoff. Use when assessing or executing a Mole release. Not for release-note copy alone or ordinary code review."
---

# Mole CLI Release Flow

Tag-driven flow. The `release.yml` workflow watches `'V*'` tag pushes (capital `V`), builds amd64 and arm64 binaries on macOS, generates `SHA256SUMS`, attaches build provenance, creates the GitHub Release without notes, then opens a Homebrew core PR.

## Distribution channels

| Channel | What ships | Trigger | Automation |
|---|---|---|---|
| Nightly (`mo update --nightly`) | `main` HEAD via `install.sh` | Any commit pushed to `main` | Automatic; no tag or release involved |
| GitHub stable release | amd64/arm64 binaries + `SHA256SUMS` | Push a capital-`V` tag | `release.yml` builds and creates the release; curated notes are a manual follow-up |
| Homebrew core | Version-bump PR to `Homebrew/homebrew-core` | Same `V*` tag workflow | Automatic PR; merge timing is upstream's |
| Nix flake | Source-built macOS package from the selected Git ref | `main` follows development; a release tag pins that release | Nix manages install, upgrade and removal; no separate registry publish |

At the start of any release-flavored task, restate which channels this run will touch and which it will not, and confirm with the maintainer before acting. Channel scope is specified by the maintainer, never inferred.

## Pre-flight checklist

Resolve the latest published stable tag from GitHub before choosing the version or review range. Reconcile handoff claims against the current branch, worktree, and remote SHA; an earlier report of uncommitted work may describe commits that have already landed. Review all changes since that stable tag, not just the final fix batch.

1. `grep '^VERSION=' mole` matches the new version.
2. `SECURITY_AUDIT.md` opening line reflects the new version and date, and its CI coverage list matches the matrix in `.github/workflows/test.yml`.
3. `git status -s` is empty or only contains intentionally staged release work.
4. `git log origin/main..HEAD --oneline` shows only commits you intend to ship.
5. `./scripts/check.sh --format` and `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 MOLE_TEST_JOBS=2 BATS_FORMATTER=tap ./scripts/test.sh` both exit 0.
6. `go test ./...` and `make build` both pass.
7. `scripts/e2e_macos.py` exits 0 on a real Mac at the candidate commit. It installs IINA from its verified GitHub DMG, launches it, uninstalls it with every personal-data row selected through a real terminal, lists the DMG in `mo installer --dry-run`, deletes it from `mo analyze ~/Downloads`, and runs every other command read-only, so it changes only what it installed and never asks for a password. It refuses to start when the Mac already has IINA or any of its data. A failed run lists what it left behind; move those to the Trash before rerunning. Transcripts and `report.json` land in `~/Library/Logs/mole-e2e/<run>/`.

Use the Go version declared in `go.mod` for local release builds, matching `actions/setup-go` in CI, then run `scripts/check_release_minos.sh` on both architectures. A newer local Go can raise the minimum macOS version even with `CGO_ENABLED=0`; during V1.54.0 verification, Go 1.27 produced macOS 13 binaries while the declared Go 1.25 toolchain preserved macOS 12. Rebuild with the declared toolchain instead of relaxing the minimum-OS gate. Check the `make release-amd64 release-arm64` outputs, not `make build`: the local build links `status` with cgo against the host SDK, so its `status-go` reports the host macOS as its minimum and says nothing about the release binaries.

Capture the test runner's exit status and structured summary, with skipped tests reported separately. After pushing the candidate commit, wait for its required Check, Validation, CodeQL, and Nix workflows to finish successfully before tagging that exact SHA. Nix must verify both Darwin architectures and the installed/profile lifecycle. A cancelled run or a green check on another commit is not release evidence.

## Tag and publish

```bash
git push origin main
git tag V<version>          # capital V; release workflow ignores lowercase v
git push origin V<version>
```

Wait for the workflow to finish. The workflow creates the release with assets but `generate_release_notes: false`, so notes must be added in a follow-up step.

After the workflow finishes, verify the release assets before announcing anything: `gh release view V<version> --json assets --jq '.assets[].name'` must list all four `analyze-`/`status-darwin-{amd64,arm64}` binaries, both `binaries-darwin-*.tar.gz` Homebrew tarballs, AND `SHA256SUMS`. Install verification is fail-closed, so a release without a readable `SHA256SUMS` asset makes every install and `mo update` abort by design; a missing checksums file is a release blocker, not a cosmetic gap.

Download all seven assets. Verify the six payload checksums, attestations for all seven tied to the release tag, exact source commit, and `.github/workflows/release.yml`, and each archive's two expected binary members against the raw binary assets. Check Mach-O architecture and minimum macOS version on the downloaded binaries, then run the native architecture's Analyze and Status smoke probes. Successful local builds do not prove the public package contains those bytes.

Then run a **script self-update smoke** before publishing notes or announcing: install the previous stable release through the script channel, run `mo update`, and confirm `mo --version` prints the candidate version. Script-installed clients execute the new tag's `install.sh`, so this is the only gate that exercises their real upgrade path; the pre-flight suite cannot cover it before the release exists. Homebrew is a separate downstream gate: verify it only after the core formula has updated, and never treat a script-channel smoke as proof that Homebrew is ready. If the script smoke fails, pull the release (see the pulling-and-re-releasing pitfall) before anyone is told to update.

Use a fresh archive of the previous tag so ignored local `bin/*` builds cannot contaminate the old installation. Place the isolated prefix and config under a physical user-owned directory; `/tmp` or `/var` aliases and writable ancestors can correctly fail installer path checks. Isolate HOME, config/cache paths, and PATH, block host `brew` and `sudo`, and set `MOLE_TEST_NO_AUTH=1`. Verify `config/install_channel` retains `CHANNEL=stable`, `config/bin/{analyze,status}-go` match the verified release assets, changed installed shell sources match the tag, and a second update reports the current version. Keep the user's existing installation unchanged.

## Apply curated release notes

The curated-notes flow (bilingual format, `gh release edit` instead of `create`, thanks block, and the six-reaction set) is owned by `.claude/skills/release-notes/SKILL.md`. `.agents/skills/release-notes` is a symlink to that canonical directory for Codex discovery, and its Codex-only invocation policy lives in `agents/openai.yaml`; do not replace the symlink with a copied mirror. Follow that skill; do not duplicate its format details here. Version, codename, and emoji go only in the release title; the body h1 is just `Mole`.

After applying notes and the standard reactions through that skill, read back the published title, full body, and all six reactions. Report GitHub Stable and Homebrew availability separately; a successfully opened core PR still needs upstream tests and merge.

- Issues whose reporter already verified the fix on nightly get no "now in stable" follow-up after the release, and none is proposed.

## Release-notes craft

Format rules (impact ordering, command existence checks, icon semantics, no em dash, no inline PR refs) live in `.claude/skills/release-notes/SKILL.md` under "Format rules". Keep that skill as the single source of truth for notes formatting.

## Release-only pitfalls

- **Tag prefix is case-sensitive**: `release.yml` filters on `'V*'`. A lowercase `v1.38.0` tag will not trigger the workflow.
- **Old clients fetch `install.sh` from the release tag, not from main**: a self-updating Mole downloads `raw.githubusercontent.com/tw93/mole/V<tag>/install.sh`, and tag content is immutable. An installer/updater bug therefore reaches existing stable users only through a new tag; fixing main changes Nightly but does not repair an already published stable updater.
- **Never rewrite history an already published tag can reach**: the rule and the pre-rewrite tag audit are in `AGENTS.md` (Release). The incident behind it: on 2026-09-17, four days after V1.54.0 shipped, a `git filter-branch --msg-filter` run stripped a `Co-authored-by: Cursor` trailer from a commit dated 2026-05-06 that had 956 descendants. `--tag-name-filter cat` carried the tags onto the rebuilt commits, the release commit was rebuilt, and `brew upgrade mole` has failed the source checksum for every Intel user since, because Homebrew dropped Intel bottles so they all build from source (#1591). The enumeration was run afterwards: 25 published tags were reachable from that rewrite, so 25 source-tarball checksums moved, not one. Only V1.54.0 broke anything, because homebrew-core pins the checksum of the formula's current version alone, and `install.sh` anchors on the release assets' `SHA256SUMS` rather than on the tag archive it downloads. Any external consumer pinning an older tag's tarball is outside what can be checked from here. Recovery on a live release is a one-line `sha256` PR to `Homebrew/homebrew-core` with the current tarball's hash, and it takes two things that are easy to miss. The PR body must carry Homebrew's own template or a bot closes it within seconds as AI-written, editing it in reopens the same PR and opening a second one is explicitly refused. And a moved checksum is read as a possible supply-chain compromise, so a maintainer will hold the merge until the upstream author confirms in that thread that the change was benign; answer with the two commits' identical tree and the archive's pax header, which they can verify without trusting you, not with a promise. Check for an existing PR before opening one: the community usually files it first. Bottles are unaffected because BrewTestBot built them from the original download.
- **Pulling and re-releasing a version**: `gh release delete V<old> --cleanup-tag` removes the release and remote tag. Delete the local tag, close the superseded Homebrew core PR with a one-line supersede comment before pushing the replacement tag (`release.yml` refuses to overwrite an existing `mole-<version>` fork branch and reuses, rather than recreates, an open PR for the same head), then bump `VERSION` and `SECURITY_AUDIT.md`, commit `release: V<new>`, tag, and run the normal publish flow. The Homebrew core PR regenerates on the new tag.

When release work touches Shell code or tests, read `.claude/skills/bugs/references/shell-and-test-pitfalls.md` for Bash 3.2 arrays, heredoc input, mock bypasses, and CI-runner quirks.
