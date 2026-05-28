# Release Notes

Store one curated release note file per public release tag:

```text
docs/release/notes/V<major>.<minor>.<patch>.md
```

Start from `docs/release/release-notes-template.md`, fill every section with tag-specific user-facing content, then validate it:

```bash
scripts/check-release-notes.sh --tag <TAG>
```

Do not create placeholder release notes for future tags. The release workflow uses the tag-specific file as the top of the public GitHub release body, followed by the generated release manifest.
