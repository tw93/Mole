# Launch Strategy

Last reviewed: 2026-06-25

## Launch Thesis

Roomy should launch as a transparent, GPL-3.0, CLI-first Mac maintenance toolkit for technical Mac users and small teams. The launch should compete on trust and repeatability rather than broad consumer-suite polish.

The product promise is:

> Clean your Mac. See every change.

That promise must stay true in product behavior, docs, pricing, and distribution:

- dry-run previews before destructive work;
- local execution and no account gate for supported CLI workflows;
- protected-path, symlink, traversal, sudo-boundary, restore, and logging gates;
- GPL-3.0 source availability with upstream Mole attribution;
- paid offers based on support and rollout confidence, not hidden cleanup capability.

## Audience

Primary:

- Mac developers and technical operators with Xcode, package-manager, browser, build, simulator, and installer clutter.
- Users who distrust opaque cleaner suites but still want guided cleanup.
- Small teams that need repeatable Mac maintenance with logs and predictable commands.

Secondary:

- Power users who already use AppCleaner, DaisyDisk, Homebrew, or shell scripts and want one auditable workflow.

Do not target broad nontechnical consumer buyers until a production native app exists and RoomyUI release gates are complete.

## Positioning

Roomy is not CleanMyMac, DaisyDisk, AppCleaner, or Mole for Mac. It is narrower and more inspectable:

- Compared with CleanMyMac: less suite breadth, more transparency and automation.
- Compared with DaisyDisk: less visual-first, broader cleanup and repeatable maintenance.
- Compared with AppCleaner/Nektony: broader than uninstall, with developer cleanup and scheduled/reportable workflows.
- Compared with Mole for Mac: Roomy is a renamed GPL CLI fork with its own namespace and support path; it must not imply upstream endorsement.

## Pricing

Follow `docs/marketing/pricing-strategy.md`:

- Free CLI: full GPL CLI.
- Supporter: $19/year for maintenance funding, priority triage, release notes digest, and release candidate notification.
- Team Rollout: $99/year for up to 10 Macs with rollout checklist, managed profile examples, policy preset examples, signed install guidance, and release upgrade support.
- Custom Support: quote-based onboarding, compatibility review, or security/compliance review help.

Do not sell proprietary CLI feature gates. The paid product is support, confidence, and deployment help.

## Launch Sequence

1. Namespace lock: public repository and Homebrew tap use `jake-seo-cl/roomy` and `jake-seo-cl/homebrew-tap`.
2. Source lock: `LICENSE`, `NOTICE`, README, release notes, release manifest, and site all agree on GPL-3.0 and upstream attribution.
3. Scope lock: production launch remains CLI-only; RoomyUI remains preview-only.
4. Candidate lock: final release notes exist under `docs/release/notes/<TAG>.md`.
5. Distribution prereq gate: `scripts/check-distribution-prereqs.sh --check-secrets` passes.
6. Source gate: `scripts/check-public-release.sh --tag <TAG> --full --skip-clean-machine` passes.
7. Tag and release workflow: push `V<major>.<minor>.<patch>` and let GitHub Actions build assets, checksums, manifest, release body, and attestations.
8. Install-channel staging: release becomes a prerelease only after assets/checksums/attestations exist.
9. Formula and install validation: personal tap update, optional Homebrew core update, and clean-machine drill run.
10. Final gate: `scripts/check-public-release.sh --tag <TAG> --final --record <record> --evidence <archive-or-dir>` passes.
11. Stable/latest promotion: only after the workflow validates uploaded assets and clean-machine evidence.

## Launch Channels

Owned:

- GitHub README and release page.
- Static site under `site/`.
- GitHub Discussions/issues for community support.
- Release notes and clean-machine evidence.

Distribution:

- GitHub tagged releases.
- Install script from the canonical Roomy repo.
- Personal Homebrew tap.
- Homebrew core only after formula PR succeeds and install-channel validation remains green.

Community:

- Developer communities, open-source launch posts, and Mac power-user channels should lead with dry-run proof and GPL source availability.
- Avoid using upstream Mole testimonials, logos, or community channels as Roomy proof.

## Launch Assets

Required for a stable/latest launch:

- `README.md` with install, support, privacy, license, and upstream attribution.
- `site/index.html` and `site/pricing.html` passing `npm run site:check`.
- `docs/release/notes/<TAG>.md` passing `scripts/check-release-notes.sh --tag <TAG>`.
- GitHub release assets, `SHA256SUMS`, `RELEASE_MANIFEST.md`, `RELEASE_BODY.md`, and attestations.
- `clean-machine-drill-<TAG>.md` and `clean-machine-drill-<TAG>-evidence.tar.gz`.
- Homebrew tap formula pointing to the canonical Roomy tag and matching checksums.

## Success Metrics

First 30 days:

- Successful Homebrew tap installs and script installs without checksum failures.
- No confirmed destructive cleanup boundary regressions.
- No public confusion that Roomy is official Mole or Mole for Mac.
- GitHub issues with enough environment/install context to reproduce.
- At least one complete clean-machine drill record for the promoted tag.

Signals to watch:

- `roomy clean --dry-run` and `roomy uninstall --dry-run` confusion points.
- Install failures caused by repository rename, tap setup, or tag URLs.
- Requests for native app support; route these to RoomyUI preview-only docs until the release decision changes.
- Pricing pushback that indicates the support model is unclear.

## No-Go Summary

Do not launch stable/latest if:

- the public repo is still `jake-seo-cl/Mole`;
- the Homebrew tap does not exist or points to upstream Mole URLs;
- any public doc claims MIT licensing;
- paid copy implies proprietary CLI feature locks;
- RoomyUI is marketed as production-ready;
- release assets do not include GPL license, `NOTICE`, manifest, checksums, and corresponding source link;
- clean-machine drill evidence is missing, failed, or unverifiable.
