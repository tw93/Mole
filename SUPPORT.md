# Support

Roomy support covers the current `roomy` command-line release for macOS.
RoomyUI is preview-only unless the release notes for a future version say
otherwise.

## Before Opening A Support Request

Run the safest preview first:

```bash
roomy <command> --dry-run
roomy --version
```

For cleanup, uninstall, purge, installer cleanup, remove, and other destructive
workflows, include whether the issue happened in preview mode or during an
executing run.

## Where To Ask

- Bugs and reproducible product issues: open a GitHub issue.
- Small fixes and documentation improvements: open a pull request.
- Security-sensitive reports: use [SECURITY.md](SECURITY.md), not a public
  issue.
- Commercial, team, or support inquiries: email `hitw93@gmail.com`.

## Include This Context

- Roomy version: `roomy --version`
- Install method: Homebrew tap, Homebrew core, install script, or source
  checkout
- macOS version and CPU architecture
- Command and flags used
- Whether `--dry-run` was used
- Relevant output or logs, redacted for private paths and secrets

## Supported Versions

Support and security fixes target the latest published release and the current
`main` branch. Older releases may not receive fixes.

## Safety Expectations

Roomy intentionally refuses some cleanup requests when paths, permissions, or
local system state are ambiguous. A refusal, protected-path skip, or dry-run
warning is often expected behavior. Do not bypass those controls without first
understanding the reported risk.
