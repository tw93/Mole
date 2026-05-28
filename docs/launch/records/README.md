# Clean-Machine Drill Records

Store one completed record per public release tag in this directory:

```text
docs/launch/records/V<major>.<minor>.<patch>.md
```

Create records from `docs/launch/clean-machine-cli-drill-record-template.md` or by running `scripts/run-clean-machine-cli-drill.sh` on a fresh macOS environment. The release workflow may also upload the generated record as `clean-machine-drill-<TAG>.md`. Do not add placeholder records for tags that have not completed the drill; `scripts/check-clean-machine-drill-record.sh --tag <TAG> --record <record>` must pass before a public release tag is promoted to stable/latest.
