# Mole agent skill

This plugin installs the official skill for the free, open-source Mole CLI (`mo`) on macOS and Windows. With it, Claude Code, Codex and DeepSeek Harness answer "what is using my disk?" from Mole's own JSON output, show every cleanup with `--dry-run` and wait for your consent before anything is removed, and leave app uninstalls and administrator steps for you to run in your own terminal.

Install it in Claude Code with `/plugin install mole --marketplace tw93/Mole`, in Codex with `codex plugin marketplace add tw93/Mole` then `codex plugin add mole@mole`, or in DeepSeek Harness with `dsh plugin --profile <name> add dsh-mole`.

The skill needs the Mole CLI on the machine: `brew install mole` on macOS, `scoop install mole` on Windows. Source, license (GPL-3.0) and other install paths are at https://github.com/tw93/Mole.

`skills/mole` here is a copy of `skills/mole` at the repository root, since Codex drops symbolic links when it installs a plugin.
