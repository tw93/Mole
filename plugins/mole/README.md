# Mole agent skill

Clean your computer with AI: clear tens of GB of junk, uninstall apps, remove leftovers and tune up your system.

Ask "what is using my disk?" or "clean up my computer", and your agent finds the junk on your system, lists all of it, and cleans only after you agree.

If Mole is not installed yet, your agent asks first and installs it once you agree.

If you prefer an app, use the official [Mole](https://mole.fit/) app.

Install it in Claude Code with `/plugin install mole --marketplace tw93/Mole`, in Codex with `codex plugin marketplace add tw93/Mole` then `codex plugin add mole@mole`, or in DeepSeek Harness with `dsh plugin --profile <name> add dsh-mole`.

Official open-source repository: https://github.com/tw93/Mole

`skills/mole` here is a copy of `skills/mole` at the repository root, since Codex drops symbolic links when it installs a plugin.
