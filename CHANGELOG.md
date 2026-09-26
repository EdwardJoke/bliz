# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are dated by release day. The repository's git history begins at `0.4.0`,
so earlier entries come from the project's own logs and have no diff links;
per-version links will be added as releases are tagged.

## [Unreleased]

## [0.4.1] - 2026-09-26

### Added

- **CodeWhale support.** `bliz` installs into `.codewhale/skills` in a project and
  `~/.codewhale/skills` globally — the two directories CodeWhale's own
  `docs/SKILLS.md` marks writable. Its pre-rename `~/.deepseek/skills` is a *read*
  fallback for installations that upgraded in place, so it is not mapped as a
  second destination: one write to the current path is read by both.
- **Choosing which skills to install.** A source holding more than one skill now
  asks which ones, and asks *before* the destination prompt — "what" reads before
  "where", and an answer about destinations would be thrown away by a cancel.
  Nothing is pre-checked, which is the choice the reference makes too: a fully
  ticked list turns "install this one" into "undo twenty-nine". `Select all` takes
  every skill the filter matches, the filter narrows the list, and a name that
  matches nothing stays an error rather than a shorter list. `-s/--skill` and
  `--all` answer the question without asking it; `--yes`, `--json` and a run with
  no terminal install every skill, as they always did. `-a` is not a blanket — it
  answers "where", not "what" — so the skill prompt still opens, which is the line
  the reference draws when its non-TTY message asks for `--agent` *and* `-y`.
- `-l/--list` names `--skill` on a terminal, since a source holding several skills
  is exactly the case where the next question is "which ones, and how do I say so".

### Fixed

- The picker's detail pane was cached on the cursor position alone, and a space
  toggles rows *without* moving the cursor — so the count under a group heading
  went stale the instant anything was ticked, leaving a frame that read
  `6 skills · 0 selected` directly above a heading reading `3/6` and a summary
  naming all three. The selection count now joins the cache key, but only while
  the cursor is on a group heading, so an ordinary row's detail is not rebuilt —
  and re-faded — on every keystroke.
- The destination picker's count assertion accepted either `1 of 58 destinations`
  or `1 of 57 destinations`. The real answer is 57, so the second alternative was
  dead code that would have passed for the wrong reason the moment the registry
  grew — it is now derived from `src/registry.zig`.

## [0.4.0] - 2026-09-25

### Added

- **Scope selection in the install prompt.** A scope row above the destination
  list: `tab` or `space` switches between project and global, and the whole view
  re-filters with it — group headings, footer counts, the `Select all` counter and
  the confirm summary all describe the scope on screen.
- `-p` / `--project`, which now narrows the install prompt to the project scope.
  It was advertised in `--help` and read by nothing.
- A release pipeline (`.github/workflows/release.yml`): on a `v*` tag it verifies
  every layer, cross-compiles six targets across Linux and macOS, packages the
  tarballs, and publishes them with `gh release create`.
- `install.sh` — a POSIX `sh` installer that resolves the latest release, verifies
  the download against the published `SHA256SUMS`, smoke-tests the binary, then
  installs it. Attached to each release, and covered by the same checksums.
- `scripts/release-check.sh`, which fails a release unless the tag,
  `src/main.zig`, `build.zig.zon` and `ZIG_VERSION` all agree.
- `demo/verify-install-sh.sh` — 83 checks over the installer, every refusal
  asserted on the exit status, the message and the filesystem.
- `demo/home/`, a pinned `$HOME` fixture for the picker recording's global tab.

### Changed

- `-g` / `-p` **narrow** the install prompt to one scope instead of skipping it;
  with a single scope offered, no scope row is drawn at all.
- Only the primary scope arrives pre-checked, so `↵` on the first frame still
  means exactly what a bare `bliz install` always did. Ticks made on the other
  tab are kept and installed in the same pass — the summary line reports them
  (`Selection  CodeBuddy  ·  +6 in project`).
- The picker's recording is now machine-independent: `build.zig` pins `HOME`,
  because the global tab resolves against it.
- On Linux the installer prefers the **statically linked** musl build, so one
  binary runs on any distribution regardless of its glibc version.
- **Windows is documented as unsupported.** Raw mode needs `std.posix` termios,
  `poll` and `ioctl`, and that layer is a stub on Windows, so the build fails
  rather than degrading. The README says so, the release matrix carries no
  Windows rows, and `install.sh` refuses Git Bash, MSYS2 and Cygwin by name.

### Fixed

- **Two rows painted the cursor at once** once the scope row was added above
  `Select all`; both controls decided focus from `cursor == 0`. Each fixed row now
  has an explicit index.
- The detail pane's scope text reflowed into a run-on sentence, because
  `wrapLines` collapses newlines and re-wraps as a single paragraph.
- Typing in the picker parked the cursor on a heading rather than on the first
  matching row, so the next keystroke acted on the wrong thing.
- `build.zig.zon` had drifted a release behind `src/main.zig`.
- **The prompts laid out at 80x24 on Linux, whatever the terminal actually was.**
  `term.size()` asks the kernel with `TIOCGWINSZ`, which is *not* the same number
  on every POSIX target: Darwin and the BSDs pack it as
  `_IOR('t', 104, struct winsize)` (`0x40087468`), while Linux and the other
  `asm-generic` targets number it flatly (`0x5413`). Darwin's value was used on
  every target, so on Linux the ioctl failed and the layout fell back to the
  80x24 default in silence — a 100x30 prompt drew an 80-column, 23-row frame.
  Nothing reported an error and nothing exited non-zero: the destination list was
  nine rows instead of fourteen, which put the `.agents` hub row out of view and
  surfaced as an unrelated picker assertion failing in CI. This is the fix that
  the `v0.4.0` tag was moved onto, so it is part of that release rather than
  pending.

## [0.3.0] - 2026-09-25

### Added

- **The install destination picker** (`src/pick.zig`). `bliz install` now asks
  which agents to install to: two groups split on whether the destination already
  exists, agents that share a directory merged into a single row (`Cursor +20`),
  and the same live search, spring scroll and staggered entrance as `find`.
- `src/paint.zig` — the frame protocol extracted from `tui.zig`, so both prompts
  share one implementation of the repaint rule instead of each holding a copy of
  it. `erasePrevious` now takes *only* the on-screen height, so a call site cannot
  pass the wrong one.
- `--yes` / `-y` to accept the pre-checked destinations without the prompt.
- `demo/verify-install.py` — a PTY harness that drives the real prompt and asserts
  on the filesystem as well as the screen.
- `record --pick`, so the picker can be recorded into the web player.

### Changed

- The picker's pre-selection is exactly what a bare install would have done, so
  `↵` on the first frame is unchanged behaviour.
- `demo/verify-player.js` is keyed on a recording's title, and an unregistered
  title now counts as a failure — previously a new demo could pass on structure
  alone while displaying nothing.

### Fixed

- **`esc` in `bliz find` and `bliz remove` hung the prompt forever.** `cancel()`
  never set `outcome`, so the driver kept waiting with the cursor hidden and
  swallowed every subsequent key, including a second Ctrl-C.
- The picker never painted its first frame: the driver blocked reading input
  whenever nothing was animating, and the picker has no loading phase.
- The entrance stagger never played in a live session — `init` derived it from a
  clock that did not exist yet, so it was already over by the first frame.
- Merged destinations were reported as `Cursor +20 +20`.

## [0.2.1] - 2026-09-24

### Added

- `registry.universal_hub`, `createsProjectDirByDefault` and `installedGlobally`,
  which detects an agent from its **home** marker rather than from a project
  directory.

### Fixed

- **`bliz install` dead-ended with `no agent found in this project`** in any
  project that had no agent directory yet, including a fresh checkout — while the
  reference tool succeeded in the same place. It now falls back to the universal
  hub (`.agents/skills`) plus Claude Code when its config directory exists, which
  is what the reference does. Existing directories still take the normal path, and
  no project gets littered with all 57 agent directories.

## [0.2.0] - 2026-09-24

### Added

- **`bliz install`** (alias `add`) — install a skill from `owner/repo`, a GitHub
  URL, a `/tree/<ref>/<path>` URL, any git URL or a local directory.
- `--skill`/`-s` to narrow by name, `--list`/`-l` to inventory a source, `--all`,
  `--force`, `--dry-run`, `--ref` and `--json`.
- Fetching via a shallow `git clone`, so refs, tags, commit SHAs, SSH URLs,
  private repositories and the user's own credential helper all work with no
  authentication code.
- Container-first discovery to depth 3, with a bounded whole-tree walk behind it.
  A directory holding a `SKILL.md` shadows its children, so `references/` is
  never mistaken for a skill.

### Changed

- Installs are **additive by default**: an existing skill is skipped rather than
  overwritten. `--force` deletes the destination before copying, so stale files
  cannot survive an update.
- Agents that share a skills directory are merged into one copy, labelled after
  merging (`Cursor +2`).
- Skills are **copied, not symlinked**. A symlink into a temporary clone would
  dangle once that clone is removed, and the reference's canonical store is a
  larger commitment than this build needs.

### Fixed

- `--all` was advertised in `bliz help` but never implemented — it parsed as an
  unknown flag and was silently ignored.
- `--list --json` silently ignored `--json`.
- `build.zig.zon`'s `.paths` was missing `demo`, so a packaged checkout had a
  broken `zig build verify` (which scans the fixture) and no
  `demo/player.template.html` for `record --html`.

## [0.1.0] - 2026-09-22

First release.

### Added

- `find` — the animated multi-select prompt: raw-mode input, 256-colour output,
  spring-driven motion, live case-insensitive filtering over name, description
  and path.
- `list`, `inspect`, `init`, `remove`, `stats` (a bar chart per root) and
  `agents`, an 80-agent registry of the directories coding agents actually read.
- `record`, which captures a prompt's frames against an injected clock and bakes
  them into a self-contained HTML player that opens from `file://`.
- A display-width table that measures cells correctly, including variation
  selectors and combining enclosures.
- `demo/player.html` and an 18-skill fixture spanning six agent root conventions,
  deliberately including a skill with no frontmatter and one with `references/`.
- Three verification layers: unit tests, a frame-invariant check that fails the
  build on any row that is not exactly the terminal width, and a headless
  emulator that replays a recording in place of a browser.

### Changed

- Renamed from the working title `zskills` to `bliz`, and moved to the repository
  root. Renaming the package invalidated `build.zig.zon`'s fingerprint, which
  derives from `.name`.
