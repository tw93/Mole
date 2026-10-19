---
paths:
  - "lib/clean/dev.sh"
  - "lib/manage/whitelist.sh"
  - "tests/clean_dev_caches.bats"
  - "tests/dev_extended.bats"
  - "tests/clean_developer_state.bats"
  - "tests/clean_ai_cli_caches.bats"
  - "tests/clean_corepack.bats"
  - "tests/clean_xcode_derived_data.bats"
  - "tests/clean_orphaned_runtimes.bats"
  - "tests/manage_whitelist.bats"
---

# Developer and toolchain caches (`lib/clean/dev.sh`)

General clean target policy, including the owner-command rule, is in `.claude/rules/clean.md`.

- `lib/clean/dev.sh` owns developer-tool cleanup, language/toolchain caches, AI agent caches, and Codex runtime handling. Run `MOLE_TEST_NO_AUTH=1 bats tests/clean_dev_caches.bats tests/dev_extended.bats tests/clean_developer_state.bats tests/manage_whitelist.bats`.
- Its DeviceSupport cleanup covers every platform the uninstall sweep in `lib/core/app_protection.sh` knows, with the same keep-newest rule; the two lists drifted once (`db2e462e`, `d9329649`), and `clean covers every DeviceSupport platform the Xcode uninstall sweep knows` in `tests/dev_extended.bats` now reads both.
- `clean_dev_jetbrains_toolbox` only strips whitelist patterns that start at its own apps root, so the broader JetBrains data row and the default `Application Support/JetBrains*` pattern still hide old Toolbox IDE versions; `JetBrains data row hides old Toolbox IDE versions from cleanup` in `tests/manage_whitelist.bats` pins the row case, so change that test together with the bypass if the bypass is widened.
- The Gradle candidate listing puts the small groups before the build cache, which can hold thousands of entries: whitelisted entries are settled before the roughly 10 ms `should_protect_path` probe, and an exhausted filtering budget keeps only the build cache group.
- Keep AI-tool cache cleanup conservative. Claude Code, opencode, Copilot CLI, Zed, Warp, Ghostty, and similar developer tools may have active versions, config, credentials, or session state that must not be removed accidentally.

## Recovery contracts

- uv, npm, pip and mise owner cache commands require a successful absolute-root query (or mise's explicit absolute `MISE_CACHE_DIR`). Failed, empty, relative or multiline answers skip that owner command; a signal still cancels. Never whitelist a guessed default and then let the owner mutate its separately configured root. Known npm default residuals keep their existing safe-clean guards. Locked by the four `owner cleanup requires a confirmed cache root` cases in `tests/clean_dev_caches.bats`.
- Conda validates every `pkgs_dirs` entry from one successful `conda info --json` snapshot before running its owner cleanup. An absent, empty, invalid or partially readable list skips the command; any whitelisted root or descendant protects the entire command. Locked by `conda owner cleanup protects every configured package cache root` in `tests/clean_dev_caches.bats`.

- **Classify cleanup by recovery contract, not by directory name or download cost.** Re-downloading is a real cost but not an automatic veto when the user explicitly runs `clean`: Go's module cache is owner-documented, machine-resolvable, and independently whitelistable, so it is reset through `go clean -modcache`.
- Directly consumed or mixed-state stores still stay: `registry/src`, Cargo `git`, `$DENO_DIR`, `~/.ivy2/cache`, `~/.m2/repository`, `~/.nuget/packages`, `~/.cabal/packages`, and `~/.cpan/sources`. Cargo's compressed `registry/cache` is redundant with extracted sources, while Cargo 1.88+ owns age-aware GC for sources and git dependencies.
- Downloaded model and experiment roots (`~/.cache/huggingface`, `~/.cache/torch`, `~/.cache/tensorflow`, `~/.cache/wandb`) and toolchain payloads (`~/.sbt/boot`, `~/.sbt/launchers`, `~/.stack/programs`) stay off the blanket delete path. `DENO_DIR` is review-only because the owner command removes the entire root, including origin storage and downloaded runtime payloads.
- A default whitelist row is not protection once the user saves a custom file, so fix the delete path itself and remove whitelist inventory entries for targets Mole no longer deletes. Each inventory row names a path a cleanup actually consults, and `package-manager whitelist rows protect the paths their cleaners delete` and `whitelist inventory has no row for a path no cleanup consults` in `tests/manage_whitelist.bats` run the real `clean_dev_*` cleaners for pip, Yarn, RubyGems and Podman against their rows. The Ollama default lives only in `DEFAULT_WHITELIST_PATTERNS`, and a saved line for a dropped or respelled row stays as a custom pattern (`saved lines for dropped whitelist rows survive a menu save and keep protecting`).
- Nix cleanup is `nix-store --gc` under the owner-command timeout, which removes only store paths no GC root references; `nix-collect-garbage --delete-older-than` also deletes every profile and home-manager generation past the age, the user's rollback points, so Mole never runs it. Locked by `clean_dev_nix collects only unreachable store paths under a timeout` and `clean_dev_nix dry run runs no Nix command` in `tests/clean_dev_caches.bats`.

## Xcode and simulators

- **Join simulator data on `runtimeIdentifier` from `-j` output, never on a printed runtime name.** The two listings title the same runtime differently, so a name join offers `simctl runtime delete` for a runtime its simulators still bind (story in `.claude/skills/bugs/references/shell-and-test-pitfalls.md` section 7). A reclaim recommendation additionally needs `state: Ready`, `deletable: true`, and exactly one installed image serving that identifier, because the device list cannot say which of two images its devices belong to. Locked by the `#1505` test in `tests/clean_orphaned_runtimes.bats`.
- **simctl waits for Xcode's own first-launch setup.** On an Xcode whose first-launch packages are not installed, any simctl call asks macOS to install CoreSimulator behind an administrator prompt, which a user who had skipped sudo saw appear mid-`mo clean`; users pinned to a simulator version must never have components installed by a cleanup run. `_resolve_simctl_developer_dir` accepts a developer dir only after its `xcodebuild -checkFirstLaunchStatus` returns 0 within the medium probe bound, so every simctl caller, including the booted-device guard, inherits the gate and the skip stays quiet; a signal during that check cancels the run instead of reading as unfinished setup. Locked by `simctl stays untouched while Xcode first-launch setup is unfinished` in `tests/dev_extended.bats`.
- **Every simctl read goes through `_run_simctl`.** `clean_dev_mobile` pins its probe count in `tests/dev_extended.bats`; a raw `run_with_timeout ... xcrun simctl` bypasses the stub, so added probes stay invisible to that assertion instead of being weighed by it.
- The CoreSimulator `Volumes` and `Cryptex` roots are Apple-owned and left alone, neither deleted nor listed: mount absence does not establish ownership or obsolescence. Unused runtimes are surfaced through `simctl` instead.
