# Privacy

Roomy is local Mac maintenance software. Its supported release product is the
`roomy` command-line tool.

## Data Processing

Roomy runs on your Mac and inspects local filesystem metadata to preview and
perform maintenance tasks. Depending on the command, it may inspect paths,
file sizes, modification times, application bundle metadata, package receipts,
Homebrew state, system health output, and Roomy configuration files.

Roomy does not require a Roomy account, cloud cleanup engine, or telemetry
service to run supported CLI workflows.

## Network Use

Roomy uses network access only for workflows that need public software or
release metadata, such as:

- Installing or updating Roomy from GitHub release assets.
- Verifying release checksums.
- Running Homebrew commands when the user chooses Homebrew install or update
  workflows.

Routine cleanup, preview, uninstall, purge, analyze, status, report, restore,
and profile workflows do not upload local scan results to a Roomy service.

## Local Logs

Roomy can write operation logs and debug logs under `~/Library/Logs/roomy/`.
Those logs may include command names, local file paths, sizes, outcomes, and
error messages. Treat logs as local diagnostic data and review them before
sharing in public issues.

You can disable the operation journal for a run with:

```bash
ROOMY_NO_OPLOG=1 roomy <command>
```

## Sensitive Paths

Roomy is designed to skip or refuse high-risk user data, credentials, system
roots, symlink escapes, path traversal, and unsupported privilege boundaries.
Those protections are safety controls, not a backup system. Always review
`--dry-run` output before running destructive commands.

## Support Requests

Do not share secrets, tokens, private keys, personal documents, or full
unreviewed logs when asking for support. Include the Roomy version, macOS
version, install method, command used, and a redacted excerpt of relevant
output.

For security-sensitive reports, follow [SECURITY.md](SECURITY.md).
