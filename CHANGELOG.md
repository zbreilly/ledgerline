# Changelog

What changed in each release, newest first. The notes on a GitHub release are taken from the section for its version, so add that section before tagging.

## 0.1.1

Two privacy fixes.

- **AI prompts stay private.** AI Sort and the AI Category Designer passed their prompt to the `claude` or `codex` command-line tool as an argument, which any account on the same computer could read while the tool ran. The prompt now goes to the tool on standard input.
- **New databases are owner-only.** A database the app creates can be read and written only by your account, and so can any folders it has to make for it. An existing database or folder keeps the permissions it has, since it may be shared on purpose.

## 0.1.0

First public release.

- **Import** any bank's CSV, with column detection, duplicate detection and transfer detection.
- **Categorize** with rules, merchant memory and optional AI Sort through the `claude` or `codex` command-line tool.
- **Plan** with budgets, a bills-and-income calendar, pay periods, debt payoff plans and net worth.
- **Theme engine**: colors, fonts, layers, button skins and your own art, shared as one `.ledgerlinetheme` file. Images in a shared theme are re-made as new PNGs, so a theme can't carry scripts or hidden data.
- **Private by design**: one SQLite file on your Mac, no account, no sync and no server.
