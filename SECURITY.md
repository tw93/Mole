# Security Policy

Roomy is a local system maintenance tool. It includes high-risk operations such as cleanup, uninstall, optimization, and artifact removal. We treat safety boundaries, deletion logic, and release integrity as security-sensitive areas.

## Reporting a Vulnerability

Please report suspected security issues privately.

- Use GitHub private vulnerability reporting for `jake-seo-cl/roomy` once it is
  enabled.
- If private vulnerability reporting is not enabled, use the private maintainer
  contact published on the Roomy repository profile.

Do not open a public GitHub issue for an unpatched vulnerability.

Do not send Roomy fork reports to upstream Mole maintainers unless you have
confirmed the issue also affects upstream Mole.

Include as much of the following as possible:

- Roomy version and install method
- macOS version
- Exact command or workflow involved
- Reproduction steps or proof of concept
- Whether the issue involves deletion boundaries, symlinks, sudo, path validation, or release/install integrity

## Response Expectations

- We aim to acknowledge new reports within 7 calendar days.
- We aim to provide a status update within 30 days if a fix or mitigation is not yet available.
- We will coordinate disclosure after a fix, mitigation, or clear user guidance is ready.

Response times are best-effort for a maintainer-led open source project, but security reports are prioritized over normal bug reports.

## Supported Versions

Security fixes are only guaranteed for:

- The latest published release
- The current `main` branch

Older releases may not receive security fixes. Users running high-risk commands should stay current.

## What We Consider a Security Issue

Examples of security-relevant issues include:

- Path validation bypasses
- Deletion outside intended cleanup boundaries
- Unsafe handling of symlinks or path traversal
- Unexpected privilege escalation or unsafe sudo behavior
- Sensitive data removal that bypasses documented protections
- Release, installation, update, or checksum integrity issues
- Vulnerabilities in logic that can cause unintended destructive behavior

## What Usually Does Not Qualify

The following are usually normal bugs, feature requests, or documentation issues rather than security issues:

- Cleanup misses that leave recoverable junk behind
- False negatives where Roomy refuses to clean something
- Cosmetic UI problems
- Requests for broader or more aggressive cleanup behavior
- Compatibility issues without a plausible security impact

If you are unsure whether something is security-relevant, report it privately first.

## Security-Focused Areas in Roomy

The project pays particular attention to:

- Destructive command boundaries
- Path validation and protected-directory rules
- Sudo and privilege boundaries
- Symlink and path traversal handling
- Sensitive data exclusions
- Packaging, release artifacts, checksums, and update/install flows

For the current technical design and known limitations, see [SECURITY_AUDIT.md](SECURITY_AUDIT.md).
