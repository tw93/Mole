# Pricing Strategy

Last reviewed: 2026-06-25

## Decision

Keep the Roomy CLI free and open source under GPL-3.0. Monetize around support, trust, and distribution convenience rather than proprietary CLI feature gates.

Recommended launch offers:

| Offer | Price | Buyer | What is sold |
| --- | ---: | --- | --- |
| Free CLI | $0 | Individual technical users | Full GPL CLI source, Homebrew/script install, dry-runs, cleanup, uninstall, analyze, status, reports, schedules, restore, and community support. |
| Supporter | $19/year | Individual users who want to fund maintenance | Priority issue triage, release notes digest, supporter acknowledgement if desired, and early notification of release candidates. No CLI feature lock. |
| Team Rollout | $99/year for up to 10 Macs | Small technical teams | Email support, rollout checklist, managed profile examples, policy preset examples, signed install guidance, and release upgrade office hours. |
| Custom Support | Quote | Larger teams or regulated environments | Onboarding, compatibility review, custom runbook help, and security/compliance review support. |

Do not sell a proprietary Roomy CLI tier unless counsel approves the exact source distribution and GPL rights flow. If paid code derives from the CLI, publish corresponding source under GPL-3.0 with the release.

## Market Rationale

CleanMyMac is the broad consumer suite benchmark. MacPaw's store currently shows Annual, Monthly, and One Time options, a 4.9 rating, version 5.5.4 dated 14 May 2026, and pricing starting at $3.33/month.

DaisyDisk is the local-trust benchmark. Its FAQ says the trial does not require a credit card, the license is a one-time purchase, and disk scans use metadata rather than file contents.

Nektony is the app-uninstall and bundle benchmark. The App Cleaner & Uninstaller page currently shows $14.95/year for one Mac, $34.95 one-time for one Mac, and MacCleaner Pro bundle pricing from $39.95/year or $85.95 one-time.

Mole for Mac is the upstream-adjacent benchmark and should not be confused with Roomy. The official Mole site currently sells the native Mac app for $19 one-time, including lifetime updates for 2 Macs and a 14-day refund. Roomy should not copy the Mole brand, assets, or proprietary app positioning.

## Packaging Rules

- Core cleanup and safety features stay free.
- Paid copy sells service levels and deployment confidence, not withheld deletion capability.
- The $19 individual offer is a supporter/support plan, not "Pro-only cleanup".
- The $99 team offer is anchored on repeatable rollout work and support response, not secret code.
- If signed binaries are offered, they must not add license terms that restrict GPL redistribution or modification rights.
- Lifetime claims should be avoided for support because they create long-lived obligations. Use annual support by default.

## Site Copy Direction

Use:

- "Free GPL CLI"
- "$19/year supporter plan"
- "$99/year team rollout support"
- "same local cleanup engine"
- "paid plans fund maintenance and support"

Avoid:

- "Pro unlocks"
- "lifetime updates" for the CLI
- "exclusive cleanup categories"
- "native Mac app" until RoomyUI release gates change
- "Mole-compatible" or any wording that implies upstream endorsement

## Validation

The landing page smoke check should verify:

- the free CLI remains visible;
- pricing does not imply proprietary CLI feature locks;
- the install command uses the Roomy tap;
- the page still compares against CleanMyMac because buyers know that anchor;
- the footer links support, privacy, and license/compliance guidance.
