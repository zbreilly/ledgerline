# Ledgerline native: project notes

## Decisions
- Architecture is **Rust core + SwiftUI front end via UniFFI** (option B, chosen Oct 26, 2026). The user plans to publish it and go multi-platform, so all business logic belongs in `core/`. Swift only does presentation.
- No WebKit or web UI anywhere.
- The SQLite schema must stay compatible with the Node app in `../ledgerline/` (same tables, same JSON settings shape, same duplicate hash). Both apps can open the same file.
- "Restore defaults" (stock taxonomy) runs only from an explicit button. Seeding happens only when the `categories` table is empty.

## Build and test
- `scripts/build-macos.sh` runs `cargo build`, then `uniffi-bindgen` (Swift output to `apple/Generated/`), then `swiftc` straight to `build.noindex/Ledgerline.app`. There is no Xcode project yet.
- `cargo test` runs the unit tests for CSV, rules, memory, transfers, hashing and month math.
- Parity with the Node app was checked on Oct 26, 2026 against a snapshot of the real database, and everything was identical:
  - 115 report checks (overview, breakdown, planning, cash flow, accounts, categories, transaction queries) for all months and all accounts.
  - An import of all three bank CSVs, compared row by row: hash, category, subcategory and transfer flag.
  - Re-running merchant memory and applying rules to all rows.
  To repeat it, run the Node server on a copy of the database (`LEDGERLINE_AUTH=off LEDGERLINE_DATA=<dir> LEDGERLINE_PORT=7499 node ../ledgerline/server/index.mjs`; `LEDGERLINE_AUTH=off` is required since Nov 12, 2026, when the Node server started requiring a signed-in session on every `/api` route, and must only be used on a copy), then diff `cargo run --release --example parity -- <copy> reports` against `PORT=7499 node scripts/parity/node_parity.mjs`.
- For UI testing, run the app against a copy of the database: `open -n --env LEDGERLINE_DB=<copy> -a build.noindex/Ledgerline.app`. Never test against `../ledgerline/data/ledgerline.db`.

## Intentional differences from the Node app
- Import header detection: preview and commit both treat row 1 as a header unless its first non-empty cell parses as a date. Node's preview used a looser check.
- AI Sort with "allow new categories" off drops suggestions that don't match an existing category. Node returned them, and applying them would create the category anyway.
- Rule editing saves `min_cents` and `max_cents`. Node's PATCH ignored them.
- Opening a CSV with the app (Dock drop or Open With) goes straight to the import preview.
- AI Sort only runs Anthropic's `claude` CLI or OpenAI's `codex` CLI (decided Nov 12, 2026). zcode, opencode and the custom command were removed; any other provider name is an error. Don't add providers back without asking.
- AI settings (provider, model, timeout) are per machine since Nov 12, 2026. The Swift app keeps them in UserDefaults and hands them to the core with `Ledger::set_ai_settings`; the core never reads or writes the `ai` object in the database's settings row (the Node app still uses it).
- The AI CLIs run with tools off, in an empty temp folder, with no shell (`core/src/ai.rs`): claude `--tools ""`, codex `--sandbox read-only` (it can still read files, but has no network or writes). Bank text in prompts goes through `prompt_text` (one line, no control characters, capped). The prompt is written to the CLI's standard input, never passed as an argument (since Nov 13, 2026): arguments can be read by every account on the computer with `ps`. Keep it that way.
- A database the app creates is owner-only (file 600, any folders it had to make 700; `db::open`, since Nov 13, 2026). An existing database or folder keeps its permissions, since it may be shared on purpose.
- CSV export prefixes `'` to text cells that start with `=`, `+`, `-`, `@`, tab or carriage return (`csv_cell` in `core/src/lib.rs`).
- Import also skips pending/posted twins: same account, amount and merchant key within 4 days, where one side is a Chase pending "POS DEBIT …" row. Node imported both copies.

## Features beyond the Node app
- **Debt** (`core/src/debts.rs`):
  - Balances can be manual or follow a linked card/loan account. Manual balances are estimated from the last entered amount, plus interest, minus the payments found by merchant key.
  - Payoff estimates, avalanche/snowball/minimum plans, and grouping by account or lender.
  - Find Debts suggestions: regular payment plans and card/loan accounts start checked; irregular debt-category payments and APR-in-notes loans start unchecked.
- **Cash Flow** (`core/src/recurring.rs`, `schedule.rs`, `cashflow.rs`):
  - Recurring income and bills, including one-time items (`once`), with detection from history.
  - A calendar with paid/missed status and a projected cash balance, plus pay periods.
- **Investments and net worth** (`core/src/investments.rs`):
  - Investment accounts are rows in `accounts` with type brokerage/retirement/hsa. Details live in `investment_details`, and dated values in `balance_history`.
  - `financial_overview` gives net worth: cash + investments − tracked debts − card/loan accounts that no debt follows.
- **Counting toward another month:** `transactions.report_month` ("YYYY-MM") makes a transaction count toward another month in every monthly report (`reports::ED`/`EDT`) and in the calendar's paycheck count. The Node app ignores this column, so its reports still use the real date.
- **Day-to-day spending in the projection** (`core/src/flex.rs`): each budget minus the scheduled bills/debt payments that land in it (inferred from each item's newest matching transaction) is spread evenly across the month. The current month only spreads what's left after spending to date. It feeds the cash projection, pay-period leftovers, and the overview's "left each month."
- **Balances from bank files:** importing a checking/savings CSV with a running-balance column sets the account's real balance from the newest row, adding any newer rows that have no balance yet (pending items). An older file never overwrites a newer balance.
- **Split transactions** (`core/src/splits.rs`): one bank charge can be split into parts with their own categories. The original row keeps its id and import hash (so re-imports stay deduplicated); extra parts get `<hash>#splitN`. All parts share `transactions.split_of` = the original's id. Merchant memory ignores split parts, and "apply rules to all" skips them.
- **New tables:** `debts`, `recurring`, `investment_details` and `balance_history`, plus the `report_month` and `split_of` columns. The Node app ignores all of them.

## Appearance engine (Nov 12, 2026)
Swift only (it is presentation), in `apple/Ledgerline/Theme*.swift`, `HSVTrianglePicker.swift` and `AppearanceView.swift`. Open it from Ledgerline › Appearance… or Settings.
- **Profiles** hold text/accent/status colors, heading and body fonts with a size scale, and four layers (window, sidebar, panels, cards) plus two button skins (standard, main action). Each layer has a fill, an outline (color, width, corner radius, glow for the neon look) and optional art.
- **System** is the default profile and draws nothing: every themed modifier falls through to the stock macOS look, so the app is unchanged until a profile is picked. Other built-ins: All White, All Black, High Contrast Dark/Light, Black/White with Neon. Editing a built-in forks it into a new unsaved profile.
- **How views opt in** (keep using these in new screens, or they won't theme):
  - Fonts: `Font.app(.caption)` instead of `.caption`.
  - Text colors: `Ink.secondary` / `Ink.tertiary` for styles, `Color.themeText`, `.themeSecondary`, `.themeAccent`, `.positive`, `.negative`, `.warning`, `.info` instead of `.primary`, `.green`, `.red`, `.orange`, `.blue`.
  - Boxes: `.surface(.panel, radius:)` or `.surface(.card, radius:)` instead of `.background(.background.secondary, in: …)`.
  - Buttons: plain `Button`s are skinned through `.themedControls()`; use `.buttonStyle(.themedProminent)` for primary actions and `.buttonStyle(.themedDefault)` after `.keyboardShortcut(.defaultAction)`. Toolbar buttons set `.buttonStyle(.automatic)` to stay system.
  - Every sheet's content needs `.themedControls()`: button styles don't carry into sheets.
- `ThemedRoot` (on each window's root) sets text color, font, tint, light/dark (from the window fill's brightness) and hides list/form backgrounds. `WindowSkinner` colors every NSWindow, including sheets, and draws the window outline in an overlay view; open/save panels, alerts and menus stay system.
- **Color picker**: hue ring around a hue/white/black triangle (`HSVTriangleWheel`), with HSB/RGB/hex fields, opacity, eyedropper and the theme's own colors. It also replaces the system color picker for account, category and investment colors.
- **Art**: PNG or SVG per layer and per button (plus optional hover and pressed button images). Fit modes: fill, fit, stretch, tile, frame (9-slice). For fill, fit and tile the image can be dragged into place in the editor; position is relative (`x`, `y` in 0…1) with a size multiplier, so it holds on panels of any size.
- **Art is never stored as received** (Nov 13, 2026; `apple/Ledgerline/ArtSanitizer.swift`). Every image is decoded once, redrawn into a new 8-bit sRGB bitmap, and written as a fresh PNG; only that PNG is stored, drawn and exported. So metadata (EXIF, text chunks, color profiles), unknown chunks, extra frames and bytes appended after the image never reach disk or a shared file. Keep it that way: don't add a path that writes or exports source image bytes, and don't load art with anything but `ThemeStore.image`.
  - PNG: size is read from the header by hand and refused over 8192 px a side or 36 MP before any decoder runs; only the PNG decoder is allowed to read it. The DPI is carried over (clamped) so tiled and framed art keeps its size.
  - SVG is accepted only from the file picker, never from a theme file. It must be self-contained: no scripts or event attributes, no `<image>`/`<foreignObject>`/animation, no `href`/`src`/`url()` that isn't `#id`, no `@import`, processing instructions or entity declarations (a bare DOCTYPE line is stripped). It is then drawn once by AppKit (no WebKit) and stored as PNG.
  - Data hidden in the pixel colors themselves survives re-encoding. It is inert (nothing reads pixels as anything but color) and is not removed.
  - Tests live outside the repo; to re-run them, build `ArtSanitizer.swift` (alone) and `Theme.swift` + `ArtSanitizer.swift` with a small `main.swift` and feed them hostile samples (payload after IEND, text/EXIF/private chunks, 50000 px header, SVGs with scripts and outside links).
- **Storage** is per Mac, not in the database: `~/Library/Application Support/Ledgerline/Themes/` (`active.json` = what's on screen, including unsaved edits; `Profiles/<id>.json`; `Assets/<sha256 prefix>.png`). Set `LEDGERLINE_THEMES=<dir>` to use another folder, and always do so when testing.
- **Export/import**: one `.ledgerlinetheme` JSON file with the art base64-embedded as PNG. Imports are untrusted: values are clamped, each image goes through `ArtSanitizer` and is stored under a name the app picks (the file's own asset names are never used as paths), images that can't be used are left out with a notice, and the profile gets a new id. Export re-runs every image through `ArtSanitizer` too.
- The Appearance window closes with Done, Esc or the red button; closing never discards edits (they stay in `active.json`). Done asks AppKit to close the hosting window (`HostWindowReader`), because `dismissWindow(id:)` did not close it in testing. The Preview column's button and switch are samples only.
- Limits: menus, alerts, open/save panels, table headers, selection highlights and the text inside pop-up controls are drawn by macOS and only follow light/dark.

## Known gaps / next features
- Notes about the owner's own accounts and data are in `CLAUDE.local.md`, which is not checked in. Keep real names, places, account numbers and amounts out of tracked files; use invented sample data in tests, comments and examples (Acme Corp, Springfield IL, Shopwell, Gasmart).
- Investment values are entered by hand; there's no brokerage import yet.
- Publishing:
  - Never make the private GitHub repo (the one this folder pushes to) public: 6 of its first 18 commits contain the owner's personal details (decided Nov 13, 2026). Do not rewrite or force-push its history.
  - **The public repo** is a separate folder, `../ledgerline-public/`, with its own history that started from one clean commit. Its local git config sets the commit identity to the project name with a non-personal address; never commit there from a folder without that config, and give commits and tags UTC dates. To publish, copy this folder's non-ignored files across, check them for personal details, and commit there.
  - **`main` on the public repo is protected** (Nov 13, 2026): every change needs a pull request and a passing `Package Mac app` check, history must stay linear, and force pushes and deletion are blocked, for admins too. Release tags (`v*`) can't be moved or deleted. Actions may only run GitHub's own actions, pinned to a commit, with a read-only token by default.
    - To land a change: push a branch, open a pull request, wait for the check, then fast-forward `main` to the pull request's head from the command line (`git push origin <branch>:main`). GitHub accepts that push because the commits belong to a pull request that passed, and it keeps the neutral commit identity.
    - Don't use the web merge button: it rewrites the commits with the merging account's name on them.
  - **Distribution builds (Nov 13, 2026):** `scripts/package-macos.sh` builds a universal (arm64 + x86_64) app for macOS 14+, ad-hoc signed, and zips it to `dist/`. `.github/workflows/build.yml` runs it on the `xcode-27` runner for every push and pull request, and publishes a GitHub release when a `v<version>` tag is pushed (the tag must match `CFBundleShortVersionString`). Release binaries come from CI, not from a developer's Mac.
    - **Release notes must say what changed** (the owner's rule, Nov 13, 2026; 0.1.0 and 0.1.1 first went out with the same install-only text). Before bumping the version, add a `## <version>` section to `CHANGELOG.md` describing the actual changes in plain words. `scripts/release-notes.sh` turns that section plus the install steps into the release text, and the build fails on any push or pull request whose version has no section.
    - To release: add the changelog section and bump `CFBundleShortVersionString`, `CFBundleVersion`, `core/Cargo.toml` and `Cargo.lock` in one pull request, land it, then push an annotated `v<version>` tag on that commit.
    - The script names rustup's `cargo` and `rustc` by full path. `rustup run stable cargo` is not enough here: cargo then runs Homebrew's `rustc` from PATH, whose standard library targets macOS 27. The script fails if the linker reports objects built for a newer macOS.
    - It remaps the home and project folders out of the binary (`--remap-path-prefix`, `-file-prefix-map`), strips symbols, and refuses to package if the home folder path is still in the app. `scripts/build-macos.sh` does none of this; don't hand out its output.
    - Locally only `aarch64-apple-darwin` is installed, so test with `LEDGERLINE_ARCHS=arm64 scripts/package-macos.sh`.
  - Still not notarized (no Developer ID; a certificate would carry the owner's legal name). Users must allow the app once in System Settings > Privacy & Security.
- Import works on one file at a time. There is no undo for single-transaction edits.

## Menu bar (Nov 13, 2026)
`apple/Ledgerline/MenuCommands.swift`. Every action has a menu item; put new ones in the menu that matches:
- **Ledgerline**: Settings… (⌘,), Appearance….
- **File**: New ▸ (Account, Category, Subcategory, Bill or Income, Debt, Investment Account), database open/create/show, Import Bank CSV (⇧⌘I), Export Transactions (⇧⌘E), appearance profile import/export.
- **Edit**: standard, plus Find Transactions… (⌘F).
- **View**: sidebar, Previous/Next/This Month (⌘[ ⌘] ⌘T), Account ▸ (scope), Appearance ▸ (profiles, Customize…), Reload (⌘R).
- **Go**: the pages (⌘1–⌘9), Uncategorized Transactions (⇧⌘U), This Month's Transactions.
- **Tools**: Categorization Rules… (⌥⌘R), Apply Rules, Apply Merchant Memory, AI Sort…, Find Bills and Income…, Find Debts…, AI Category Designer…, Set Cash Balances….
- **Help**: search only.
- "Restore Defaults" for categories is deliberately not in the menus; it stays a button on the Categories page.
- A menu item that needs a page's sheet calls `model.perform(.someCommand)` (`AppCommand`): it switches page and leaves the command in `model.pendingCommand`; the page takes it with `.onCommand(...) { }`. Cash Flow first switches to the right tab, and the tab takes the command.
- Menu items are small views (not `Commands`) so checkmarks, the account list and enabled states follow the model. Commands bring the main window forward and reopen it if it was closed (`showMain`), which is why the main `WindowGroup` has the id `main`.

## Layout notes
- The Transactions filter bar uses `ViewThatFits`: one row when it fits, otherwise the four filters above the sort/month controls (the case at the default window size). When adding a control there, put it in `filterPickers` or `monthControls` so both layouts get it.

## Learned rules (Oct 26, 2026)
- Rule match type `merchant` compares `rules::rule_key(description)` (merchant-memory key; Chase ACH "ORIG CO NAME:… IND ID:…" rows use the real payee) to the pattern.
- `Ledger::learn_rules()` / Rules sheet "Learn from My Categories" makes one priority-100 merchant rule per merchant+direction (money out `max_cents=-1`, money in `min_cents=1`) when ≥80% of its rows agree; re-running is idempotent.
- Recategorizing a transaction (editor or bulk) updates the learned rule for that merchant (`rules::follow_edit`); hand-made rules (priority < 100) and split parts are untouched.
- Dev tools: `cargo run --example learn_rules -- <db>`, `cargo run --example refill -- <db>`.
