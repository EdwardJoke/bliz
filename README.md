# bliz

A skill manager for the open agent-skills ecosystem, written in Zig.

It scans the skill directories that coding agents actually read, installs skills
from a repository or a local directory, and lets you browse skills *and* choose
destinations and scope in animated terminal prompts. The prompts are a
from-scratch TUI — raw-mode input, 256-colour output, spring-driven animation —
built to the same standard as the reference `npx skills` interface, with the
repaint protocol verified frame by frame.

```
bliz  skill manager for the open agent-skills ecosystem

  find [query]          browse and select skills in an animated prompt
  list [-g|-p]          list installed skills, grouped by root
  inspect <name>        show one skill's metadata and description
  install <source>      add skills; picks destinations in a prompt
  init [name]           scaffold a new SKILL.md (-a <agent>, -g)
  remove [names...]     delete skills, with --yes to confirm
  stats                 skills per root, as a bar chart
  agents                supported agents and their directories
  record --out f.json   capture prompt frames for the web player
  record --html p.html  bake frames into a self-contained player

  flags:  -g/--global  -p/--project  -a/--agent <key>  --json  --root <dir>
          install:  --skill <name>  -l/--list  --all  --force  --dry-run  --ref <ref>
                    -g/-p narrow the prompt to one scope; --yes skips it
```

## Install

On Linux and macOS — one line, no toolchain:

```sh
curl -fsSL https://raw.githubusercontent.com/EdwardJoke/bliz/master/install.sh | sh
```

Once a release exists,
`https://github.com/EdwardJoke/bliz/releases/latest/download/install.sh` is the
same script attached to that release, listed in `SHA256SUMS` beside the
tarballs — prefer it if you would rather pin the installer to the version it
installs than take whatever `master` currently holds.

That resolves the latest release, downloads the tarball for your platform,
verifies it against the published `SHA256SUMS`, checks that the binary actually
runs and reports the version its package is named after, and only then installs
it to `~/.local/bin`. The file is written beside the destination and renamed
into place, so an interrupted install cannot leave a half-written binary on
`PATH`. If `~/.local/bin` is not on your `PATH` it says so and prints the line to
add, rather than editing your shell's startup files behind your back.

```sh
sh install.sh --dry-run                    # show the resolved plan, write nothing
sh install.sh --version 0.4.1              # a specific release
sh install.sh --bin-dir /usr/local/bin     # somewhere else
```

| flag | |
| --- | --- |
| `--version <v>` | install a specific release instead of the latest |
| `--bin-dir <dir>` | destination directory (default `~/.local/bin`) |
| `--repo <owner/repo>` | install from a fork |
| `--target <triple>` | fetch a release target explicitly, e.g. for another machine |
| `--dry-run` | print what would happen, then stop |

`BLIZ_VERSION`, `BLIZ_BIN_DIR`, `BLIZ_REPO`, `BLIZ_TARGET` and `BLIZ_BASE_URL`
do the same from the environment. `BLIZ_BASE_URL` points at a flat mirror of the
release assets — it is what the harness below uses — and requires an explicit
version, because a mirror has no "latest" to resolve against.

To compile it yourself instead, see [Build](#build).

### Platform support

| platform | status | artifact |
| --- | --- | --- |
| Linux x86_64 | supported | `bliz-<v>-x86_64-linux-musl.tar.gz` |
| Linux aarch64 | supported | `bliz-<v>-aarch64-linux-musl.tar.gz` |
| Linux x86_64, glibc | supported | `bliz-<v>-x86_64-linux-gnu.tar.gz` |
| Linux aarch64, glibc | supported | `bliz-<v>-aarch64-linux-gnu.tar.gz` |
| macOS Apple silicon | supported | `bliz-<v>-aarch64-macos.tar.gz` |
| macOS Intel | supported | `bliz-<v>-x86_64-macos.tar.gz` |
| **Windows** | **not supported yet** | — |

Linux gets the musl build because it is **statically linked** — `file` reports
`statically linked` — so one binary runs on any distribution regardless of its
glibc version. The `-gnu` builds exist for anyone who wants a dynamic one;
`--target x86_64-linux-gnu` selects it.

**Windows is not supported yet.** This is a missing platform backend, not a
missing build flag: `bliz` drives raw mode through `std.posix` — termios, `poll`,
`ioctl` — and on Windows that layer is a stub, so building for it fails with

```
error: root source file struct 'os.windows.ws2_32' has no member named 'pollfd'
```

plus six errors in `src/term.zig`. Supporting Windows means writing a console
backend (`SetConsoleMode` / `ReadConsoleInput`) and an event loop to go with it
first. `install.sh` recognises Git Bash, MSYS2 and Cygwin and refuses with that
explanation rather than downloading something that cannot run.

The script is POSIX `sh`, not bash, because a `curl | sh` installer has no way to
know what `/bin/sh` is on the target — and the harness runs it under `dash`,
`bash`, `ksh` and `zsh` to prove that rather than claim it.

## Build

The one-line [installer](#install) is the short path on both supported platforms.
`bliz` targets Linux and macOS only — **Windows is not supported yet**; see
[Platform support](#platform-support) for the reason. What follows is how to
build it from source instead.

<details>
<summary><b>Build from scratch</b> — requires Zig 0.16.0</summary>

```sh
zig build            # → zig-out/bin/bliz
zig build run -- list
zig build test       # unit tests for every module
zig build verify     # frame-invariant check, both prompts, against the fixture

# cross-compile exactly the way the release does
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

`zig build test` and `zig build verify` are the two gates a patch is expected to
pass. `verify` re-records both prompts against `demo/workspace` and exits
non-zero if any painted row is not exactly the width of the frame — which is why
that fixture is committed rather than generated.

</details>

## Commands

**`find [query]`** — the centrepiece. Opens the animated multi-select prompt.
`query` pre-fills the filter. Keys:

| key | action |
| --- | --- |
| `↑` `↓` | move |
| `space` | toggle selection |
| `←` `→` | collapse / expand the group under the cursor |
| `tab` | jump to the next group |
| `↵` | confirm |
| `esc` | cancel |
| typing | filters live, case-insensitively, over name + description + path |

When stdout is not a TTY it degrades to a plain line-based fallback rather than
emitting escape sequences into a pipe.

**`list [-g\|-p] [--json]`** — every installed skill grouped by root, with
descriptions and marker badges (`no frontmatter`, `[references, scripts]`).
`--json` emits a JSON array of `{name, description, path, scope, root, files,
license, hasFrontmatter}` objects.

**`inspect <name>`** — one skill's frontmatter, description, path, age and
bundled extras.

**`install <source>`** (alias `add`) — brings skills in from a repository or a
local directory. The source is either a path or a git repository:

```sh
bliz install vercel-labs/agent-skills              # github shorthand
bliz install https://github.com/owner/repo         # full URL
bliz install https://github.com/owner/repo/tree/main/skills/web-design-guidelines
bliz install git@github.com:acme/private-skills.git # ssh, uses your git auth
bliz install ./my-local-skills                     # a local directory
```

| flag | meaning |
| --- | --- |
| `-l, --list` | show what the source offers, install nothing |
| `-s, --skill <name>` | only these skills; repeatable, `'*'` for all |
| `-a, --agent <key>` | target agents; repeatable, `'*'` for all |
| `-g, --global` | global scope only — `~/<agent>/skills`, and the prompt offers no other scope |
| `-p, --project` | project scope only — `./<agent>/skills`. The default, and now actually read |
| `--all` | every skill to every agent |
| `--force` | replace skills that are already installed |
| `--dry-run` | print the plan and change nothing |
| `--yes` | skip both prompts: every skill, to the auto-detected destinations |
| `--ref <ref>` | branch, tag or commit to check out |
| `--json` | machine-readable result, one object per (skill, destination) |

### Choosing which skills

A repository that holds one skill installs it and says nothing. A repository
that holds thirty — which is the normal shape of a skill collection — asks
which ones, because "install everything it can find" is not an answer anyone
chose. The question comes *before* the destination one: "what" reads before
"where", and an answer about destinations would be thrown away by a cancel.
Both captures below are real 80×24 frames:

```
◆  Select skills to install                                         agent-skills
│                                                                               
│  ⌕ type to filter▏                                                   6 matches
│  ↑↓ move   space select   tab next   ↵ install   esc cancel                   
│                                                                               
│ ❯    ○ Select all                                                          0/6
│  ─────────────────────────────────────────────────────────────────────────────
│   ▾  ○ In this source  6 skills                                               
│   ├─ ○ api-contract-tests                            skills/api-contract-tests
│   ├─ ○ code-review                                          skills/code-review
│   ├─ ○ css-architecture                                skills/css-architecture
│   ├─ ○ find-skills                                          skills/find-skills
│   ├─ ○ release-notes                                      skills/release-notes
│   └─ ○ typescript-strict                              skills/typescript-strict
│                                                                               
│                                                                               
│                                                                               
│  Select all                                                                   
│  Toggles every skill the filter currently matches.                            
│                                                                               
│                                                                               
│  Selection  none — pick at least one skill                                    
└                                                                       6 skills
```

**Nothing is pre-checked, and that is the point** — the same choice the
reference makes. A list that opens fully ticked turns "install this one" into
"undo twenty-nine", and the honest default for a thirty-skill collection is
that you have not chosen yet. Submitting with nothing ticked nudges instead of
proceeding, so an empty selection is not reachable. `Select all` is the one
keystroke back the other way, and the filter composes with it:

```
◆  Select skills to install                                         agent-skills
│                                                                               
│  ⌕ re▏                                                               3 matches
│  ↑↓ move   space select   tab next   ↵ install   esc cancel                   
│                                                                               
│      ● Select all                                                          3/6
│  ─────────────────────────────────────────────────────────────────────────────
│ ❯ ▾  ◑ In this source  3 of 6 skills                                       3/6
│   ├─ ● code-review                                          skills/code-review
│   ├─ ● css-architecture                                skills/css-architecture
│   └─ ● release-notes                                      skills/release-notes
│                                                                               
│                                                                               
│                                                                               
│                                                                               
│                                                                               
│                                                                               
│  Skill  group                                                                 
│  6 skills · 3 selected — space toggles a row, Select all takes every skill    
│  the filter matches.                                                          
│                                                                               
│  Selection  code-review, css-architecture, release-notes                      
└                                                                       6 skills
```

Naming a skill skips the question entirely, which is what makes the thing
scriptable:

```sh
bliz install owner/repo --skill code-review        # just that one
bliz install owner/repo -s code-review -s release-notes
bliz install owner/repo --skill '*'                # everything, silently
bliz install owner/repo --yes                      # every skill, auto-detected destinations
```

A name that matches nothing is an error rather than a shorter list, so a typo
cannot quietly install less than was asked for. `-l/--list` prints the
inventory and, on a terminal, names the flag that narrows it.

`--all` and `-s '*'` both mean every skill, and `--yes` is the blanket "stop
asking": with no terminal, or with `--yes`, or with `--json`, every skill is
installed and the report names them. `-a` is *not* a blanket — it answers
"where", not "what", so the skill prompt still opens. (The reference draws the
same line: its non-TTY message asks for `--agent` *and* `-y`.)

### Choosing where it goes

On a terminal, an install with no `-a` opens a destination prompt instead of
guessing. Both frames below are real captures at 80×24 — every row is exactly as
wide as the frame, which is the invariant the rest of this section relies on:

```
◆  Install to                                                   project + global
│
│  ⌕ type to filter▏                                                  58 matches
│  ↑↓ move   space select   ←→ group/scope   tab next   ↵ install   esc cancel
│
│ ❯    scope  ● project   ○ global               /private/tmp/bliz-demo/home/app
│      ◑ Select all                                                         6/58
│  ─────────────────────────────────────────────────────────────────────────────
│   ▾  ● In this project  6 destinations                                     6/6
│   ├─ ● Claude Code                                            ./.claude/skills
│   ├─ ● CodeBuddy                                           ./.codebuddy/skills
│   ├─ ● WorkBuddy                                           ./.workbuddy/skills
│   ├─ ● Cursor +20                                             ./.agents/skills
│   ├─ ● OpenClaw                                                       ./skills
│   └─ ● Windsurf                                             ./.windsurf/skills
│   ▾  ○ Not here yet  52 destinations
│   ├─ ○ OpenCode new                                         ./.opencode/skills
│  Scope
│  showing project — space switches to global. Project installs into this
│  checkout; global installs under your home, shared by every project.
│
│  Selection  Claude Code, CodeBuddy, WorkBuddy +3 more
└                                                                58 destinations
```

The cursor starts on that `scope` row, so one keystroke reaches the other half
of the machine:

```
◆  Install to                                                   project + global
│
│  ⌕ type to filter                                                   70 matches
│  ↑↓ move   space select   ←→ group/scope   tab next   ↵ install   esc cancel
│
│ ❯    scope  ○ project   ● global                                             ~
│      ○ Select all                                                         0/70
│  ─────────────────────────────────────────────────────────────────────────────
│   ▾  ○ Installed  1 destination
│   └─ ○ Claude Code                                            ~/.claude/skills
│   ▾  ○ Not installed  69 destinations
│   ├─ ○ CodeBuddy new                                       ~/.codebuddy/skills
│   ├─ ○ WorkBuddy new                                       ~/.workbuddy/skills
│   ├─ ○ Cursor new                                             ~/.cursor/skills
│   ├─ ○ Codex new                                               ~/.codex/skills
│   ├─ ○ Gemini CLI new                                         ~/.gemini/skills
│   ├─ ○ GitHub Copilot new                                    ~/.copilot/skills
│  Scope
│  showing global — space switches to project. Project installs into this
│  checkout; global installs under your home, shared by every project.
│
│  Selection  6 in project
└                                                                70 destinations
```

Four things make it a prompt rather than a form:

- **It opens pre-checked with the exact set a bare `bliz install` would have
  used**, so `↵` on the first frame is the old behaviour. The prompt adds
  control, not a mandatory decision.
- **Both scopes are on the table; the one your flags named is the one it opens
  on.** Project and global are two halves of one list, and the `scope` row
  filters between them the way typing filters over names — which also means the
  two tabs keep their own ticks, so you can take a project destination and a
  global one in a single confirmed answer. Only the scope the install would have
  used on its own is pre-checked, so the other tab opens empty and `↵` still
  means what it always meant. The summary line is the one place the other tab's
  tick is visible (`+6 in project` above), because submitting from here installs
  to both.
- **One row per destination directory, not per agent.** The registry's 21 hub
  agents collapse to a single `.agents/skills` row labelled `Cursor +20`, which
  is what the install actually does. The row is still *found* by any of those
  names — typing `codex` matches it — because the filter searches every agent
  that reads the directory, not just the label. Scope is part of that key, so
  `./.agents/skills` and `~/.agents/skills` stay two rows: they are two
  directories.
- **The two groups are the two consequences**, and they are worded for the scope
  on screen. `In this project` / `Not here yet` on the project tab, `Installed` /
  `Not installed` on the global one: the first means the skill lands somewhere
  already in place, the second that a new directory is created, which is the only
  thing this command does that is not trivially reversible. Those rows carry a
  `new` badge, and the footer counts how many of the checked destinations will be
  created.

It is skipped — falling back to auto-detection — when `-a` names an agent, when
stdin or stdout is not a terminal, or with `--json` / `--yes`. `--list` and
`--dry-run` are unaffected and never write anything. `-g` or `-p` narrows it to a
single scope instead of skipping it, and the prompt then has no scope row to
draw — one option is not a choice.

The keys are the same as `find`'s — `↑`/`↓` to move, `space` to toggle, `←`/`→`
to collapse a group, `tab` to jump to the next one, `↵` to install, `esc` to
cancel — with four picker-specific touches: `space` on a *group* heading toggles
that whole group, `space` or `←`/`→` on the *scope* row switches scope, the
detail pane shows the destination path and every agent that reads it (or, on the
scope row, what the difference between the two scopes is), and `esc` is a real
cancel that writes nothing rather than a silent fallback to the defaults.

Typing a query parks the cursor on the first row of the list rather than on a
control, so "narrow, then `space`" acts on what you narrowed to; the two controls
stay one `↑` away.

**With no `-a` and no prompt** (a pipe, CI, `--yes`) it installs to the agents
whose skills directory already exists in the current scope, so a bare
`bliz install` cannot litter directories for agents you do not have. Agents that
share a directory are merged into a single copy — the registry's 81 agents
collapse to 58 distinct project directories, 21 of them on the shared
`.agents/skills`. Nothing is ever overwritten unless `--force` is passed, which
makes installs additive and safe to re-run in CI; a failed copy exits non-zero.

**When a scope has no agent directory at all**, it falls back instead of
refusing: the universal `.agents/skills` hub is created (read by every hub
agent), plus Claude Code's directory when Claude Code looks installed — that is,
when `$CLAUDE_CONFIG_DIR` or `~/.claude` exists. This mirrors the reference,
which always writes the universal hub and creates Claude Code's project
directory, but it deliberately does *not* invent directories for the other
fifty-odd agents. In the prompt those fallback targets are simply the rows that
open pre-checked; a project that already has its own agent directory is
completely unaffected by this path.

Remote sources are fetched with a shallow `git clone`, which is what makes refs,
tags, commits, SSH URLs and private repositories work without any bespoke
auth code — the credential helper you already have is used.

Three deliberate differences from the reference tool:

- **Copy, not symlink.** The reference keeps a canonical copy and symlinks each
  agent to it. `bliz` copies into each destination. Symlinks pointing into a
  deleted temp clone would dangle, and a canonical store is a bigger design
  commitment than this build needs. `--copy` is therefore accepted and is
  already the behaviour.
- **The destination prompt is skippable, not mandatory.** The reference prompts
  for agents and skills on every install. `bliz` prompts too — but the answer it
  opens with is the one it would have computed anyway, and
  `--yes` / `--json` / a non-TTY pipe take that answer and carry on, so nothing
  that used to be scriptable stopped being scriptable. `-a` and `-s` still mean
  exactly what they meant. The prompt also asks the scope question: project and
  global are two halves of one list with a switch between them, rather than
  something you had to have settled with a flag before the prompt opened.
- **The skills are not offered as a second prompt.** `bliz` installs everything
  found unless `-s` narrows it; `--list` covers inspection, and `find` is the
  interactive skill picker. A second unanswered prompt after the first would
  make the common case slower, not safer.

Discovery looks in the well-known container directories first (`skills/`,
`skills/.curated/`, `.claude/skills/`, `.agents/skills/`, … — the registry's
paths plus the reference's), walking up to three levels so flat
(`skills/<name>`) and catalog (`skills/<category>/<name>`) layouts both work. A
directory containing a `SKILL.md` shadows everything below it, so a skill's own
`references/` are never mistaken for skills. If that finds nothing, it falls
back to a bounded walk of the whole tree.

**`init [name]`** — scaffolds a `SKILL.md`, with `-a <agent>` to pick the target
directory and `-g` for the global scope.

**`remove [names...]`** — deletes skills. Interactive confirmation unless
`--yes` is passed.

**`stats`** — skills per root as a bar chart.

**`agents`** — the full registry: 81 supported agents, from Claude Code, Cursor
and Codex to CodeWhale, each with its project
directory, its global directory (with `${VAR:-fallback}` shell templates shown
verbatim), and a `●` marking the ones present on this machine.

## Architecture

Each module has one job. The dependency order runs top to bottom:

| module | lines | responsibility |
| --- | --- | --- |
| `term.zig` | 296 | raw mode, signal guards, size ioctl, buffered output, escape constants |
| `width.zig` | 488 | display-width maths — CJK/emoji cells, ANSI-aware measure, truncate, wrap |
| `buf.zig` | 137 | growable byte sink and small text helpers |
| `style.zig` | 84 | the 256-colour palette and colour mixing |
| `anim.zig` | 190 | critically-damped springs, tweens, stagger, shimmer, counters |
| `paint.zig` | 225 | the frame contract: `emitRow`, `erasePrevious`, `flush`, `checkFrame` |
| `registry.zig` | 336 | the agent registry, directory templates, install-marker detection |
| `frontmatter.zig` | 229 | YAML frontmatter parsing |
| `discover.zig` | 420 | root discovery and skill scanning |
| `install.zig` | 629 | source parsing, `git` fetching, skill discovery in a source, tree copy |
| `tui.zig` | 1569 | the skill multiselect: scan, filter, groups, animation, rendering |
| `pick.zig` | 2481 | the multi-select picker: candidates, merge, scope tabs, filter, animation, rendering |
| `script.zig` | 102 | the `record` keystroke-script mini-language |
| `record.zig` | 323 | deterministic frame capture for the web player |
| `main.zig` | 1931 | CLI dispatch and command implementations |

### The rendering contract

`Prompt.render()` is *pure*: it maps state to bytes and touches nothing else.
Every animation reads `prompt.now`, a clock the driver owns rather than the
system. That is what makes the recorded replay frame-identical to a live
session of the same size — and it is why the demo can be trusted.

There are two prompts, and they share `paint.zig` rather than each keeping a
copy of the protocol. That is deliberate: the rules below are subtle enough that
a second, independently written version would be a bug waiting to happen, and
the one really nasty failure mode (the walk-up distance) produces a prompt that
slides off the screen one row per frame rather than anything obviously broken.

Two invariants make the repaint work:

1. **One logical line is exactly `cols` cells.** Every emitted row is
   truncated *and* padded to the terminal width, so a line can never soft-wrap
   into two physical rows. `paint.emitRow` is the only place a row is finished.
2. **The cursor walks up by the height of the frame currently on screen** —
   not the new one's. `\x1b[{n}A\x1b[J` then the new frame. The height is
   captured from the frame that was actually written, which anchors the layout
   at its top. Using the new frame's height instead moves the top down whenever
   the layout shrinks, stranding stale rows above it and producing a redraw
   loop that drifts downward one row per frame, forever. `paint.erasePrevious`
   takes the on-screen height and nothing else, so the rule cannot be got wrong
   at the call site.

`paint.checkFrame()` asserts both, and `record --verify` turns them into an
exit code, so `zig build verify` fails the build rather than shipping a prompt
that slides off the screen. Both prompts are gated: the skill multiselect from
its own recording, the picker from `record --pick`.

Two further rules the drivers follow, both learned the hard way:

- **Never park in `poll()` while a frame is dirty.** The picker has no loading
  phase, so on its first iteration nothing is animating — and a driver that
  blocked whenever `!wantsAnimation()` left the prompt invisible until the user
  happened to press a key.
- **Re-arm the entrance timings against the real clock.** `init()` runs before
  the driver's clock exists, so a prompt that derived its stagger from
  `now == 0` appears fully formed in a live session while the recording (whose
  virtual clock really does start at zero) still animates.

### Why the width maths is the risky part

Cell counts are not byte counts and not codepoint counts. `width.zig` implements
East-Asian-Wide and emoji ranges, zero-width combining marks, and a real ANSI
parser (CSI + OSC) so escape sequences measure as zero width. A styled prefix
can never be sliced in half.

Self-consistency is the trap: `checkFrame` measures rows with the same `width()`
that built them, so a measurement that is wrong in the same way on both sides
passes silently. Concretely, `❤️` (`U+2764 U+FE0F`) is *two* cells in a
terminal — VS16 requests emoji presentation, widening a one-cell base — but a
naive table counts the base as one and VS16 as zero. Any description containing
an emoji like that would have shifted every row beneath it. The unit tests pin
this down along with the wrap and pad behaviour.

## The player

`record` can bake a recording into a single self-contained HTML page:

```sh
cd demo/workspace
../../zig-out/bin/bliz record --verify --html ../player.html
HOME=../home ../../zig-out/bin/bliz record --pick --verify --html ../player-install.html
```

The second is the destination picker. `record --pick` builds its rows from the
same registry sweep `bliz install` uses, with the same `addDefaultTargets`
pre-selection, so the recording shows the prompt a real install opens — not a
prompt wired to a fixture.

Its global tab resolves against `$HOME`, which is why that one run pins `HOME` to
`demo/home`: without it the demo would list whatever agent directories the
machine that recorded it happens to have, and the tab would be empty on a clean
one. `build.zig` sets the same variable for the `verify` step.

This drives the prompt on a virtual clock, captures the exact bytes `flush()`
would have written for each repaint, gzips and base64s the result, and splices
it into `demo/player.template.html`. The output opens from `file://` with no
server and no network access.

The page carries a self-contained terminal emulator (cell grid, escape parser,
SGR handling bold / dim / inverse and 256-colour) plus playback controls:
play/pause, a scrubber, 0.5×/1×/2× speed, zoom, keyboard navigation, and a
script sidebar that highlights the current step.

### Verifying the player without a browser

`demo/verify-player.js` extracts the *real* emulator source out of the generated
page, replays the recording in Node, prints the resulting grid, and asserts the
structure:

```sh
node demo/verify-player.js demo/player.html
node demo/verify-player.js demo/player-install.html
```

```
  widest row across the whole recording: 104 cells (cols=104)

334 frames, 34 steps, PASS     # player.html
226 frames, 23 steps, PASS     # player-install.html
```

It checks that frame 0 does no cursor-up, that every later frame's cursor-up
equals the height the screen actually holds, and that no row exceeds `cols` —
the same invariants the Zig side asserts, but verified against the consumer of
the byte stream rather than the producer. The content assertions are keyed on
the recording's own title, so each demo is checked against what *it* is meant to
show; a recording with no expectations registered fails rather than passing on
structure alone.

### Verifying the prompts with a real terminal

The recorded replay proves the rendering. It cannot prove the input loop, the
raw-mode handshake, or that the row you picked is the directory that got
written — because a recording never takes the interactive path at all. So the
install prompt gets driven for real, under a PTY:

```sh
python3 demo/verify-install.py          # 72 checks
python3 demo/verify-install.py -v       # dump the captured screen
```

It builds a throwaway project and a source holding two skills, points `HOME` at
a temp directory so detection cannot see the developer's own config, and then
sends real keystrokes: pick one skill out of the source, filter the skills and
take the match, accept the destination defaults, filter and select a different
agent, cancel with `esc` at either prompt, switch scope and install globally,
take a destination on each scope and install to both, `-g`, `-a`, `-s`, and a
non-TTY pipe.

Each case is judged by what landed on disk, including that a deselected
destination was left *untouched* — the assertion that catches "it installed to
the right place" being mistaken for "and nowhere else". The scope cases are the
sharpest form of that: a global install has to leave `$HOME/.qoder/skills`
populated *and* the project empty, and a cross-scope one has to write both,
because a scope filter that only changed what was drawn would pass every
purported check of the screen and every filesystem check of a single scope.
This is also the harness that caught the picker never painting its first frame.

Its first case asserts the frame's *shape* — every row exactly as wide as the
terminal, and taller than the 80x24 default. That is a regression guard with a
history: `term.size()` asks the kernel with `TIOCGWINSZ`, whose value is not the
same number on every POSIX target, and the Darwin value was used on Linux. The
ioctl failed, the layout silently fell back to 80x24, and the first symptom was a
*different* assertion failing three cases later — the destination list was nine
rows instead of fourteen, so the row it looked for had fallen off the bottom.
A wrong size now says so, on the first case.

### Verifying the installer

`install.sh` is the only file here that downloads an executable and puts it on
`PATH`, which makes it the only one whose failure mode is *"it worked, and
installed the wrong thing"*. `demo/verify-install-sh.sh` packages a release
fixture the way the workflow does, serves it over a local HTTP server, and drives
the real script against it:

```sh
bash demo/verify-install-sh.sh     # 83 checks
```

Every refusal is asserted three times over: the exit status, the message, **and**
that the destination directory was never created. `checksum mismatch` printed by
a script that installed the file anyway reads like success in a log, and that is
the failure this exists to catch. The fixture deliberately contains a tarball
named `9.9.9` whose binary reports `0.4.1` — the same drift `release-check.sh`
guards at build time, caught here at the far end — and one whose bytes were
corrupted after it was hashed.

Platform detection is tested by shimming `uname`, not by reading the `case`
statement: Windows is refused even when the architecture matches, which is the
branch a naive check runs past. The whole install path is then run under `dash`,
`bash`, `ksh` and `zsh`, because that is exactly what a `curl | sh` installer
cannot assume. One case is live — it resolves the latest tag of a repository
that certainly has releases, to exercise the redirect-following path against
GitHub rather than a stub of it — and skips itself when offline.

## Releases

Tag a version and it is built, verified and published:

```sh
git tag v0.4.1 && git push origin v0.4.1
```

[`CHANGELOG.md`](CHANGELOG.md) records what changed in each release, in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

`.github/workflows/release.yml` is the only workflow in the repository — there is
deliberately no build-on-push CI — so that `verify` job is the only thing standing
between a broken commit and a published binary. It runs every layer above — the
unit tests, the frame invariant, the recorded replay, the PTY harness and the
installer harness — before the build matrix is allowed to start.

Zig is installed by [`vercel-labs/setup-zig`](https://github.com/vercel-labs/setup-zig),
which installs one exact release and verifies the download against Zig's minisign
public key plus the SHA-256 from the official download index.

### The version is written down in three places

`scripts/release-check.sh` fails the run unless all of them match the tag:

| where | what |
| --- | --- |
| `src/main.zig` | `const version` — what `bliz version` prints |
| `build.zig.zon` | `.version` |
| `.github/workflows/release.yml` | `ZIG_VERSION`, which must equal `.minimum_zig_version` |

A release stamps a version into a *filename* while the binary inside reports its
own, so a disagreement publishes a tarball whose name contradicts its contents
and nothing fails. Those labels had already drifted a release apart once here
before the check existed. The third row is checked because `setup-zig` takes an
explicit version and cannot read `build.zig.zon` itself.

### Artifacts

Six targets, each built on a runner of its own OS so only same-architecture
cross-compiles are involved:

```
bliz-0.4.1-x86_64-linux-musl.tar.gz    bliz-0.4.1-aarch64-macos.tar.gz
bliz-0.4.1-aarch64-linux-musl.tar.gz   bliz-0.4.1-x86_64-macos.tar.gz
bliz-0.4.1-x86_64-linux-gnu.tar.gz
bliz-0.4.1-aarch64-linux-gnu.tar.gz
install.sh
SHA256SUMS
```

Each tarball holds the binary and this README. `install.sh` is attached
alongside them — it is not one of the six platform artifacts, because it is
plain `sh` and identical everywhere, and six copies would only invite them to
drift — and it is covered by `SHA256SUMS` too: it is downloaded and executed, so
it is the most important file here to be able to verify.

**There is no Windows build, and that is a limitation rather than an omission.**
See [Platform support](#platform-support) for the full explanation.

Three details in the workflow are load-bearing rather than tidy:

- **`chmod +x` after downloading the artifact.** Artifact upload does not
  preserve file permissions — everything comes back as `644` — so without it every
  tarball would contain a binary nobody can run.
- **Every native row runs its own output**, and the `x86_64-linux-musl` row
  additionally drives `demo/verify-install.py` against the *shipped* binary in a
  real PTY. A cross-compile that links is not yet a binary that runs, and the
  strongest statement available about a release is that the published file
  installed a skill somewhere and nowhere else.
- **`demo/home/.claude/skills/.gitkeep`.** Git cannot track an empty directory, so
  without it a fresh clone has no `demo/home/.claude`, the picker finds no global
  destination, and the recording changes — while `zig build verify` still passes,
  because a missing row is still exactly `cols` cells wide.

Re-running a failed release job is safe: an existing release has its assets
replaced instead of failing the run. Release notes are generated from the commits
since the previous tag, which is why the checkout uses `fetch-depth: 0`.

## Layout

```
build.zig               build, test and verify steps
src/                    the implementation
install.sh              the released POSIX installer (sh, not bash)
scripts/release-check.sh        the version-label gate the release runs
.github/workflows/release.yml   the release pipeline (the only workflow)
demo/workspace/         18-skill fixture across 6 project roots
demo/home/              a pinned $HOME for the picker recording's global tab
demo/player.template.html      the self-contained player page
demo/player.html               a baked recording of `bliz find` (generated)
demo/player-install.html       a baked recording of the picker (generated)
demo/verify-player.js          headless emulator harness
demo/verify-install.py         PTY harness for the interactive install path
demo/verify-install-sh.sh      harness for install.sh
```

The fixture deliberately covers the awkward cases: a skill with **no
frontmatter block**, one with `references/`, and six different agent root
conventions (`.claude/skills`, `.agents/skills`, `.codebuddy/skills`,
`.windsurf/skills`, `.workbuddy/skills`, `skills/`).
