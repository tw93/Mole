# Rule compression

Read when the Not yet codified dimension flags rule volume, or before compressing or splitting `AGENTS.md`
or a `.claude/rules` file for any reason. Proven on 2026-10-17, when this guide went from 89.7 KB to 30.5 KB by moving area
sections into path rules.

## When

A file is a candidate when it is more than 20% larger than the size recorded after its last compression
in `docs/weekly-audit.md` (record the size the same day you compress). Reporting a size is not enough:
a file reported in two runs without a Phase 4 item stayed as it was. Growth is a
review trigger, not proof of redundancy or permission to remove constraints.
Compression follows the authorization for the current batch; do not ask again
when it is already included.

## Contract

The header of `AGENTS.md` is the contract: keep each rule's invariant, scope and why, plus failure
mechanism, measured numbers, counterexamples, locked test names, rejected alternatives, maintainer
decisions with their dates and every failure-recovery step. Remove narration, timelines and repeated
receipts. Per-case detail (one app, one tool, one incident) may move to the matching `.claude/skills/bugs/references/`
file with a one-line pointer; moving is not deleting. Never delete a rule because a personal global file
says the same: the repo's guides are the complete contract. Keep `paths:` frontmatter byte-identical.

## Steps

1. Save the actual working file bytes to an isolated scratch directory and record
   `wc -w` / `wc -c`, HEAD and worktree status. A `git show HEAD:<path>` snapshot
   omits uncommitted changes and cannot serve as the original when WIP exists.
2. One agent per file, each told to touch only its file and the reference file it moves detail to, and to
   compare the current file with its saved snapshot before writing. If it changed,
   reconcile those edits without overwriting them (other sessions share the tree).
3. Mechanical gates, all from the agents and rerun by the main session:
   no lock checker exists here: grep every test name the original names after "Locked by" in `tests/` and `cmd/`;
   every backticked token of the original still appears in the file or its reference destination; no
   U+2014; the size before and after.
4. Independent meaning review, mandatory: a different agent diffs the saved working-file snapshot against the
   new file and reports dropped or changed constraints, each refuted once by searching the file, its
   references, `AGENTS.md` and sibling rules. On 2026-10-17 every mechanical gate passed and this review
   still found 73 real losses across the four rule sets compressed that day, none dangerous, many medium. The recurring
   shapes, to look for first:
   - a "why" deleted where it was the only thing stopping a plausible wrong fix;
   - a list of conditions cut to its first item;
   - scope widened or narrowed;
   - the maintainer's name and date removed, so a settled decision reads as reopenable;
   - a claim the compressor invented: a rounded number, a generalisation from one incident, or a
     narrowing the code does not make (the split here wrote that the installer pins `SCRIPT_DIR=`, which
     it rewrites).
5. Restore each surviving loss by putting the original wording back, then rerun the gates.
6. Recheck HEAD, remote head and working files before integration. Reconcile
   concurrent changes against the saved snapshot under the repository sync
   workflow; never restore the working file to HEAD to make synchronization easy.
   Report merged rules, removed rules and why each removal no longer changes
   behavior; preserve every remaining constraint and its reference destination.

## Splitting a guide into path rules

- Every glob in `paths:` must match a real file: test each against `git ls-files`. A rule whose globs match
  nothing never loads.
- A rule that must apply before any file is edited (triage, PR review, release, announcements, replies) stays
  in `AGENTS.md` or gets an explicit "read X before ..." line there naming every trigger; the CLI split first
  loaded `github.md` only at reply time, after a fix already existed.
- A contract between two files (an app shape the uninstall inventory accepts must also pass Clean's scan)
  goes into the rules of both sides, and a rule follows the file that holds its code, not the feature name.
- The routing table in `AGENTS.md` names every rule file for runtimes that do not load `.claude/rules`.
- Dedupe first, then decide. When a merge-and-dedupe pass frees under about 1%, the file is long because its
  rules are dense, and the reduction is a split, not more cutting: on 2026-11-10 the Windows guide gave up 113
  of 41,451 bytes to dedupe and 14,000 to moving 27 per-command bullets verbatim into five path rules. Move
  whole bullets without rewording, so the meaning review has only loading scope to check.
- The meaning review of a split asks one question per moved rule: where does the code it constrains live, and
  does a glob match that file. That review found six gaps in the Windows split (a rule filed under the wrong
  command, `lib/core/base.ps1` and `mole.ps1` enforcing clean, uninstall and update rules, Go status files
  sharing an optimize rule). Files that say "the guide owns policy" (`CLAUDE.md`, security review, docs
  headers) need the rule folder named too.
- New rule files are shipped files where the branch installs from source: track them in `.gitignore`, and on
  `windows` list them in `Get-MoleInstallNestedFiles`, or the install inventory test fails and `mo remove`
  leaves them behind.
