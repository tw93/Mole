# Open Source Compliance

Last reviewed: 2026-06-25

This is a launch checklist, not legal advice. The goal is to keep Roomy's public source, binaries, launch pages, and paid packaging aligned with the current upstream Mole license and trademark posture.

## Upstream Evidence

Authoritative upstream sources checked on 2026-06-25:

- `https://github.com/tw93/mole` presents the Mole repository as GPL-3.0 licensed.
- `https://raw.githubusercontent.com/tw93/mole/main/LICENSE` contains the GNU GPL version 3 text.
- `https://raw.githubusercontent.com/tw93/mole/main/TRADEMARK.md` says GPL-3.0 covers code, not the Mole brand, and asks forks to use their own name and icon.
- `https://mole.fit` presents Mole for Mac as a separate proprietary product.

Local conclusion: treat Roomy as a GPL-3.0-only derivative unless separate written permission from upstream says otherwise.

## Launch Requirements

- Keep `LICENSE` as the complete GPL-3.0 text.
- Keep `NOTICE` in source archives and binary distribution archives.
- Public docs must say Roomy is a modified and renamed fork of Mole.
- Public docs must not imply Roomy is endorsed by Mole or tw93.
- Public marketing must use the Roomy name and Roomy assets, not Mole names, logos, or proprietary Mole for Mac assets.
- GitHub releases must include source archives or an equivalent public source link for the exact tag.
- Binary release notes and manifests must point to the corresponding source tag, checksums, and license.
- Homebrew formulae must install from the canonical Roomy source/release URLs, not upstream Mole URLs.
- Paid offers must not restrict GPL rights for the Roomy CLI. Charging for binaries, support, signed distribution convenience, managed rollout help, or services is acceptable; withholding derivative CLI source or adding use restrictions is not.

## Native App Boundary

RoomyUI is preview-only in the current launch scope. If a native app ships later and includes, links with, embeds, or derives from GPL-covered Roomy code, plan for the native app distribution to comply with GPL-3.0 as a whole unless counsel confirms a different architecture and license boundary.

Before any paid native app launch, update:

- `LAUNCH_READINESS.md`
- `docs/macos/roomyui-release-decision.md`
- `docs/launch/go-no-go-audit.md`
- `site/`
- release workflow asset rules
- this compliance checklist

## Release Gate

Run before tagging:

```bash
scripts/check-license-compliance.sh
scripts/check-public-release.sh --tag <TAG> --full --skip-clean-machine
```

Run after install-channel validation:

```bash
scripts/check-public-release.sh --tag <TAG> --final --record <record> --evidence <archive-or-dir>
```
