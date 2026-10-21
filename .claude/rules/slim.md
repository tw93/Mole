---
paths:
  - "bin/slim.sh"
  - "tests/slim.bats"
---

# mo slim

`mo slim` removes Intel slices (`x86_64`, `x86_64h`, `i386`) from universal apps on Apple Silicon. It is the one named exception to "do not rewrite third-party app bundle contents" in `AGENTS.md` (maintainer decision 2026-10-19, after the feature was judged too heavy for Mole Mac: modest savings, restored by every app update, and a deletion surface the app could not explain in its UI). Keep it narrow; a wider scope needs a new maintainer decision.

## Scope

- Only apps directly in `/Applications` and `~/Applications`, owned by the invoking user with every file inside owned by them, in a writable folder, signed with a Developer ID (`Authority=Developer ID Application`, a 10-character Team ID). App Store (`_MASReceipt`), `com.apple.*`, ad-hoc and unsigned apps, `should_protect_from_uninstall` and official-uninstaller vendors, apps set to "Open using Rosetta" (`LSArchitecturesForX86_64` in the LaunchServices plist) and symlinks are out.
- No sudo, no helper, no new privilege. Root-owned apps stay out rather than prompting.
- Running apps are listed (Stash and other menu bar apps are always running and would otherwise vanish without a reason) and refused when slimming starts and again right before the swap.
- Without a terminal, or with `--dry-run`, it only lists. Nothing is preselected; no `--yes`, no flags beyond `--dry-run` and `--debug`.

## What may be thinned

A Mach-O is thinned only when it is its bundle's main executable (`Contents/MacOS/<CFBundleExecutable>`, or `Versions/<v>/<CFBundleExecutable>` of a framework) or a `files2` entry of the nearest `_CodeSignature/CodeResources` sealed by `cdhash`. Everything sealed by plain `hash2` is left alone, and the file scan never enters `Resources` or `_CodeSignature`. Signatures are per slice, so the arm64 slice keeps its cdhash and nothing is ever re-signed.

Counterexample that set this rule: thinning every universal file outside `Resources` broke Claude's (Electron) seal, because `Electron Framework.framework/Versions/A/Libraries/libffmpeg.dylib` and `libvk_swiftshader.dylib` are sealed by hash. App Store appex and Squirrel's ShipIt behave the same.

## Replace only a verified copy

Clone the bundle with `ditto --clone` into this run's temp folder, thin the planned files, then require on the copy: every planned file is now a thin Apple Silicon Mach-O (deep strict verify alone passed a copy whose arm64 slice had been removed), `codesign --verify --deep --strict`, the same Team ID, and `spctl --assess --type execute`. The original must pass the same deep strict verify first, since a signature that is already broken proves nothing about the copy. The one failure that check forgives is `resource fork, Finder information, or similar detritus not allowed`: `com.apple.FinderInfo` and `com.apple.ResourceFork` xattrs on bundle folders sit outside the seal, and on 2026-10-21 they made Google Chrome and ProtonVPN, both notarized and accepted by Gatekeeper, report "code signature already invalid". Those two xattrs are then stripped on the copy only, with `/usr/bin/xattr -rsd` so a symlink inside the copy never carries the strip to a file outside it, and the copy must pass deep strict verify before any file is thinned, standing in for the original; the original keeps its xattrs. Any failure discards the copy and keeps the app untouched. Only then is the original moved to the Trash through `mole_delete` (identity-pinned) and the copy renamed into place; a failed rename reports that the original is in the Trash. Each slimmed app logs one `REBUILT` row.

Slimming needs no developer tools. `lipo` ships only with the Command Line Tools (over 1 GB, more than most Macs reclaim here) and `/usr/bin/lipo` opens their installer when they are missing, so `slim_fat_slices` reads `FAT_MAGIC` and `FAT_MAGIC_64` headers with `od`, and the slimmed file is the single Apple Silicon slice cut out with `tail`/`head`: on 2026-10-19 all 816 eligible universal files in the maintainer's `/Applications` came out byte-identical to `lipo -thin`, with matching Intel byte counts. A file with both `arm64` and `arm64e`, or any slice that is neither Apple Silicon nor Intel, is skipped rather than given a rebuilt fat header. `ditto --arch arm64` was tried as the built-in alternative and copies files unchanged on macOS 27. The host check reads `hw.optional.arm64`, because `uname -m` says `x86_64` inside a Rosetta shell.

## Rejected

- Ad-hoc re-signing (MacSai): drops the Team ID, so keychain items, TCC grants and launch checks break.
- Thinning everything outside `Resources`, or inside it (Pearcleaner strips Resources and keeps no backup; ScreenFlow's `Resources/screenflowrecorder` breaks the seal).
- A Mole Mac review row or result page, root-owned apps through sudo, App Store apps (restored on the next update and protected by the receipt).

Measured on the maintainer's Mac on 2026-10-19: 14 eligible apps, 1.57 GB of Intel code; a Claude copy went from 916 MB to 694 MB and NetNewsWire from 22 MB to 13 MB, both passing deep strict verify and Gatekeeper, and the slimmed NetNewsWire launched. Sparkle delta updates fail their before-hash check on a slimmed app and fall back to a full download, which brings the Intel code back.

Locked by `tests/slim.bats`: the cdhash parser, the plan excluding a hash-sealed tool, the verified swap, Gatekeeper failure keeping the original, both running-app refusals, the fat and fat64 header parser against `lipo`, a run with `lipo` and `xcode-select` made to fail, the Intel-host refusal, Finder info stripped on the copy only and never through a symlink out of it, a broken seal behind Finder info still kept, each observed red against the broken criterion.
