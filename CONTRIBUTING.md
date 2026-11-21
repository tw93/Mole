# Contributing to Mole CLI for Linux

Thanks for helping. This branch is the Linux CLI; the macOS CLI lives on `main` and the Windows CLI lives on `windows`. Pull requests for Linux target the `linux` branch.

Issues are welcome at [tw93/Mole](https://github.com/tw93/Mole/issues) with your distribution and version in the title.

## Setup

- Bash, Go (version pinned in `go.mod`), `bats`, and `shellcheck`
- Review the safety contract in [AGENTS.md](AGENTS.md) before changing cleanup, uninstall, purge, or Trash paths

## Verification

Run these as a normal user, since Mole refuses root:

```bash
make build
go test ./...
bats tests/
./mole clean --dry-run
```

## Pull Requests

1. Branch from `linux` and keep changes focused.
2. Add or update Bats or Go tests that fail without your fix and pass with it.
3. Never delete arbitrary paths as root, never bypass `mole_remove_cache` / `mole_remove_artifact` / `internal/xdgtrash`, and keep `--dry-run` read-only.
4. Describe what changed, which distribution you tested on, and how you verified it.

By contributing you agree that your work is released under the [GPL-3.0](LICENSE) license.
