#!/usr/bin/env python3
"""Drives `bliz install` in a real pseudo-terminal and checks what lands on disk.

Why this exists: the prompts only take their interactive path when both stdin
and stdout are a TTY, so `demo/verify-player.js` (which replays recorded bytes)
and the unit tests can only ever exercise the *rendering*, never the input loop,
the raw-mode handshake, or the agent picker's decision. This harness supplies a
real PTY, sends real keystrokes, and then inspects the filesystem — which is the
only way to tell "the picker drew the right thing" apart from "the picker
installed the right thing".

Usage:
    python3 demo/verify-install.py [--bin zig-out/bin/bliz]
    python3 demo/verify-install.py -v        # dump the captured screen

Nothing outside the temp directory is touched: the harness points HOME at a
throwaway directory too, so `installedGlobally` cannot see the developer's real
~/.claude and change the pre-selection.
"""

import argparse
import errno
import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

COLS, ROWS = 100, 30

SKILL_MD = """---
name: {name}
description: A fixture skill named {name}, used by the install harness.
---

# {name}

Fixture body.
"""


class Failure(Exception):
    pass


class Session:
    """A `bliz` process attached to a real pseudo-terminal."""

    def __init__(self, argv, cwd, home):
        self.master, slave = pty.openpty()
        # A real window size, so the prompt lays out at the size the assertions
        # below assume rather than falling back to 80x24.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

        env = dict(os.environ)
        env["HOME"] = home
        env["TERM"] = "xterm-256color"
        env.pop("TERM_PROGRAM", None)
        # Keep the picker's own rendering, not the terminal's, in the capture.
        env["NO_COLOR"] = ""

        self.proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
        os.close(slave)
        self.output = bytearray()
        self.exited = False

    def read_for(self, seconds):
        """Drains the PTY for `seconds`, returning whatever arrived."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:  # the slave side closed
                    break
                raise
            if not chunk:
                break
            self.output += chunk
        return bytes(self.output)

    def send(self, data, settle=0.35):
        os.write(self.master, data.encode() if isinstance(data, str) else data)
        return self.read_for(settle)

    def wait_for(self, marker, timeout=10.0, settle=0.4):
        """Reads until `marker` decodes out of the stream, then lets it settle.

        Waiting on content rather than a fixed delay is what keeps the harness
        honest: a cold first run can take a second or two to paint, and a fixed
        sleep either flakes or wastes time on every other case.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.read_for(0.1)
            if marker in self.screen():
                self.read_for(settle)
                return True
        return False

    def wait(self, timeout=15.0):
        """Waits for exit, returning the status. Raises on a hang."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                self.exited = True
                self.read_for(0.15)
                return self.proc.returncode
            self.read_for(0.05)
        self.proc.kill()
        raise Failure("bliz did not exit — the prompt is wedged")

    def close(self):
        if not self.exited:
            self.proc.kill()
        try:
            os.close(self.master)
        except OSError:
            pass

    def clear(self):
        """Forgets everything captured so far.

        The capture is cumulative — every byte the prompt has ever written — so
        a string that was painted once stays "present" forever. Any assertion
        about what is on screen *now* has to start from an empty buffer, or it
        passes for a frame that scrolled away ten keystrokes ago.
        """
        self.output.clear()

    def screen(self):
        """The captured bytes, with escape sequences stripped for readability."""
        import re

        text = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", bytes(self.output))
        return text.decode("utf-8", "replace")

    def frame(self):
        """The most recent complete frame, escape sequences stripped.

        Every repaint is preceded by an erase-to-end-of-screen, so what follows
        the last one is what is on the terminal now. `screen()` returns the whole
        cumulative capture, which is the right thing for "did this ever say X"
        and the wrong thing for "what does it say" — a row that scrolled away
        ten keystrokes ago is still in there.
        """
        import re

        tail = bytes(self.output).rsplit(b"\x1b[J", 1)[-1]
        return re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", tail).decode("utf-8", "replace")


def make_source(root):
    """A source directory with two skills in the canonical container layout."""
    for name in ("alpha", "beta"):
        d = os.path.join(root, "skills", name)
        os.makedirs(d)
        with open(os.path.join(d, "SKILL.md"), "w") as fh:
            fh.write(SKILL_MD.format(name=name))
    return root


def has(root, *parts):
    return os.path.isdir(os.path.join(root, *parts))


def skills_in(root, *parts):
    path = os.path.join(root, *parts)
    if not os.path.isdir(path):
        return set()
    return {n for n in os.listdir(path) if os.path.isdir(os.path.join(path, n))}


def prune_tree(root):
    """Removes every agent-ish directory, so each case starts from nothing."""
    from pathlib import Path

    for entry in Path(root).iterdir():
        if entry.is_dir():
            shutil.rmtree(entry)


def project_destination_count():
    """How many project-scope rows the registry produces, read from the registry.

    The picker offers one row per destination directory, so this is the total its
    group heading reports. Deriving it beats writing a literal: the literal only
    fails the day someone adds an agent, and the assertion this replaced accepted
    *two* literals, so it went on passing for the wrong reason once the count
    moved from one to the other.
    """
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "registry.zig")
    with open(path) as fh:
        text = fh.read()
    body = text.split("pub const agents = [_]Agent{", 1)[1].split("\n};", 1)[0]
    roots = set()
    for line in body.splitlines():
        line = line.split("//", 1)[0]      # a commented-out row is not a row
        found = re.search(r'\.project = "([^"]*)"', line)
        if found and found.group(1):
            roots.add(found.group(1))
    if not roots:
        raise Failure("could not read any project directories out of src/registry.zig")
    return len(roots)


class Harness:
    def __init__(self, binary, verbose):
        self.binary = binary
        self.verbose = verbose
        self.tmp = tempfile.mkdtemp(prefix="bliz-pty-")
        self.home = os.path.join(self.tmp, "home")
        self.source = make_source(os.path.join(self.tmp, "source"))
        self.project = os.path.join(self.tmp, "project")
        os.makedirs(self.home)
        os.makedirs(self.project)
        self.passed = 0
        self.failed = []

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def start(self, *args):
        return Session([self.binary, "install", *args], self.project, self.home)

    def take_every_skill(self, s, then_destination=True):
        """Walks past the skill prompt by taking the whole source.

        The fixture source holds two skills, so a bare install now asks which
        ones first — the same order the reference asks in. Most cases below are
        about *where* a skill goes, so they take everything and get on with it;
        the skill prompt has cases of its own further down.

        The cursor opens on the "Select all" row, so one space takes the lot.
        """
        if not s.wait_for("Select skills to install"):
            raise Failure("the skill prompt never opened")
        s.send(" ")             # the cursor starts on "Select all"
        s.send("\r")
        # `-a` answers the destination question outright, so there is no second
        # prompt to wait for.
        if then_destination and not s.wait_for("Install to"):
            raise Failure("the destination prompt never opened")
        return s

    def check(self, label, cond, detail=""):
        if cond:
            self.passed += 1
            print(f"  \033[32mPASS\033[0m {label}")
        else:
            self.failed.append(label)
            print(f"  \033[31mFAIL\033[0m {label}")
            if detail:
                for line in detail.splitlines()[:40]:
                    print(f"       {line}")

    def dump(self, session):
        if self.verbose:
            print("       ---8<--- captured ---")
            for line in session.screen().splitlines():
                print(f"       {line}")
            print("       --->8---")

    # ------------------------------------------------------------------ cases

    def case_layout_honours_the_pty_size(self):
        print("\nthe prompt lays out at the size the terminal actually is")
        prune_tree(self.project)
        s = self.start(self.source)
        self.take_every_skill(s)
        s.send(" ")
        s.wait_for("Not installed")
        drawn = s.frame()
        s.close()

        # Only rows with something on them: a frame can end on a newline, and a
        # blank line is zero cells wide for reasons that have nothing to do with
        # the terminal size.
        rows = [l for l in drawn.splitlines() if l.strip()]
        widths = {len(l) for l in rows}
        self.dump(s)

        # A guard with a specific history. `term.size()` asks the kernel with
        # `TIOCGWINSZ`, whose value is *not* the same on every POSIX target; the
        # Darwin number was used on Linux, the ioctl failed, and the layout fell
        # back to 80x24 in silence. Nothing failed: the prompt just drew an
        # 80-column frame into a 100-column terminal, and the only symptom was a
        # *different* assertion failing — the list was two rows shorter, so the
        # row it looked for had fallen off the bottom. Asserting the geometry
        # directly means a wrong size says so, instead of looking like a picker
        # bug three cases later.
        self.check("the frame is exactly as wide as the terminal",
                   widths == {COLS}, f"expected all rows {COLS} wide, got {sorted(widths)}")
        # 24 is the fallback height: a frame that short means the ioctl failed
        # rather than that the prompt is being terse.
        self.check("the frame is taller than the 80x24 fallback",
                   len(rows) > 24, f"frame has {len(rows)} rows at a {ROWS}-row terminal")

    def case_prompt_appears(self):
        print("the destination prompt opens for a bare install")
        prune_tree(self.project)
        s = self.start(self.source)
        self.take_every_skill(s)
        opened = True
        self.dump(s)
        screen = s.screen()
        s.send("\x1b")  # esc
        code = s.wait()
        s.close()

        self.check("the prompt painted before any key was sent", opened, screen[:600])
        self.check("prompt header is shown", "Install to" in screen)
        self.check("the group heading names the scope", "here yet" in screen or "In this project" in screen)
        self.check("the hub destination is offered", ".agents/skills" in screen)
        self.check("escape cancels without installing", code != 0, f"exit={code}")
        self.check("cancel writes nothing", not has(self.project, ".agents"))

    def case_accept_defaults(self):
        print("\na bare ↵ installs to the pre-checked destinations")
        prune_tree(self.project)
        s = self.start(self.source)
        self.take_every_skill(s)
        s.send("\r")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        found = skills_in(self.project, ".agents", "skills")
        self.check("both skills landed in the hub", found == {"alpha", "beta"}, str(found))

    def case_pick_only_another(self):
        print("\nthe prompt can install to one chosen agent and nothing else")
        prune_tree(self.project)
        s = self.start(self.source)
        self.take_every_skill(s)

        # Filter down to Windsurf and check it.
        s.send("windsurf")
        narrowed = s.read_for(0.4).decode("utf-8", "replace")
        s.send(" ")
        # Clear the filter, then deselect the pre-checked hub row so that
        # Windsurf is the only thing left checked. Clearing the query parks the
        # cursor on the first group heading, so the hub is one row below it, past
        # the two fixed controls the frame stacks above the list.
        s.send("\x15")          # ctrl-u
        s.send("\x1b[B")        # down from the heading onto the hub row
        s.send(" ")
        s.send("\r")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("the group heading reports the filtered count",
                   f"1 of {project_destination_count()} destinations" in narrowed,
                   narrowed[-600:])
        self.check("exit code is 0", code == 0, f"exit={code}")
        windsurf = skills_in(self.project, ".windsurf", "skills")
        self.check("skills landed in .windsurf/skills", windsurf == {"alpha", "beta"}, str(windsurf))
        # The whole point of the picker: deselecting the hub has to mean the hub
        # is untouched, not merely that Windsurf also got a copy.
        self.check("the deselected hub was left alone", not has(self.project, ".agents"))

    def case_scope_switch_is_visible(self):
        print("\nthe prompt offers both scopes and repaints when switched")
        prune_tree(self.project)
        prune_tree(self.home)
        s = self.start(self.source)
        self.take_every_skill(s)
        opened = True
        first = s.screen()
        self.dump(s)

        # The opening frame has to show the choice, because the choice is the
        # whole point: the cursor starts on the scope row, so one keystroke gets
        # to the other scope without hunting for a flag.
        self.check("the prompt painted", opened, first[:700])
        self.check("the scope row is on the opening frame", "scope" in first, first[:700])
        self.check("both scopes are named", "project" in first and "global" in first, first[:700])
        self.check("the project tab uses the project wording", "here yet" in first, first[:700])

        # The scope row is where the cursor starts, so a bare space switches.
        # Each direction is asserted from an empty capture, because the two
        # scopes print the same agent names and only the paths tell them apart.
        s.clear()
        s.send(" ")
        switched = s.wait_for("Not installed")
        seen = s.screen()
        self.dump(s)
        self.check("switching repaints the headings for that scope", switched, seen[-900:])
        self.check("...and the destinations become home-relative",
                   "~/.agents/skills" in seen, seen[-900:])
        self.check("...and the project's own destination is gone",
                   "./.agents/skills" not in seen, seen[-900:])

        s.clear()
        s.send(" ")
        back = s.wait_for("./.agents/skills")
        seen_back = s.screen()
        self.check("switching back restores the project tab", back, seen_back[-900:])
        self.check("...and its own wording", "Not here yet" in seen_back, seen_back[-900:])

        s.send("\x1b")
        code = s.wait()
        s.close()
        self.check("escape cancels without writing anything",
                   code != 0 and not has(self.project, ".agents") and not has(self.home, ".agents"))

    def case_global_flag_installs_into_home(self):
        print("\n-g narrows the prompt to the global scope and writes under $HOME")
        prune_tree(self.project)
        prune_tree(self.home)
        s = self.start(self.source, "-g")
        self.take_every_skill(s)
        first = s.screen()
        self.dump(s)
        # One scope is not a choice, so there is no switch to draw — and the
        # prompt is the one it always was.
        self.check("a single scope draws no scope row", "scope" not in first, first[:700])

        s.send("qoder")
        s.read_for(0.4)
        s.send("\x1b[B")   # onto the single match
        s.send(" ")
        s.send("\r")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        qoder = skills_in(self.home, ".qoder", "skills")
        self.check("skills landed under $HOME/.qoder/skills", qoder == {"alpha", "beta"}, str(qoder))
        # The global fallback is the shared hub, and it is pre-checked, so a
        # global install keeps the same "↵ means the default" promise.
        hub = skills_in(self.home, ".agents", "skills")
        self.check("the pre-checked global hub was included", hub == {"alpha", "beta"}, str(hub))
        self.check("the project was left untouched",
                   not has(self.project, ".qoder") and not has(self.project, ".agents"))

    def case_cross_scope_install(self):
        print("\na tick made on one scope survives the switch to the other")
        prune_tree(self.project)
        prune_tree(self.home)
        s = self.start(self.source)
        self.take_every_skill(s)

        s.send(" ")             # project -> global
        s.wait_for("Not installed")
        s.send("qoder")
        s.read_for(0.4)
        s.send("\x1b[B")
        s.send(" ")

        # The summary is the only place the other tab's tick is visible, and it
        # has to be: submitting from here installs to both scopes.
        warned = s.wait_for("Qoder  ·  +1 in project")
        self.dump(s)
        s.send("\r")
        code = s.wait()
        s.close()

        self.check("the summary accounts for the tick left on the other tab",
                   warned, s.screen()[-900:])
        self.check("exit code is 0", code == 0, f"exit={code}")
        self.check("the global destination got the skills",
                   skills_in(self.home, ".qoder", "skills") == {"alpha", "beta"})
        self.check("the project default was installed as well",
                   skills_in(self.project, ".agents", "skills") == {"alpha", "beta"})
        self.check("the global destination did not leak into the project",
                   not has(self.project, ".qoder"))

    def case_search_reaches_siblings(self):
        print("\nthe filter finds an agent that shares another agent's directory")
        prune_tree(self.project)
        s = self.start(self.source)
        self.take_every_skill(s)

        # `.agents/skills` is one row labelled after the *first* agent that uses
        # it, so a user who thinks in terms of Codex would otherwise never find
        # it. The row has to be reachable by every name that reads it.
        s.send("codex")
        found = s.wait_for("Cursor +")
        screen = s.screen()
        s.send("\x1b")
        s.wait()
        s.close()

        self.check("searching a merged sibling name finds the shared row", found, screen[-800:])
        self.check("the filter reports a single match", "1 match" in s.screen(), screen[-600:])
        self.check("the shared destination is named", ".agents/skills" in s.screen())

    # ------------------------------------------------------- the skill prompt

    def case_skill_prompt_appears(self):
        print("a source holding several skills asks which ones before anything is copied")
        prune_tree(self.project)
        s = self.start(self.source)
        opened = s.wait_for("Select skills to install")
        first = s.screen()
        self.dump(s)
        s.send("\x1b")  # esc
        code = s.wait()
        s.close()

        self.check("the skill prompt painted before any key was sent", opened, first[:900])
        self.check("both skills of the source are offered",
                   "alpha" in first and "beta" in first, first[:900])
        self.check("the heading names the source, not a scope",
                   "In this source" in first, first[:900])
        self.check("the footer counts skills, not destinations",
                   "2 skills" in first, first[:900])
        # The reference opens with nothing ticked, and so does this: choosing one
        # of thirty must not mean undoing twenty-nine first.
        self.check("nothing is pre-checked", "0/2" in first, first[:900])
        self.check("the summary asks for a choice, in the right noun",
                   "pick at least one skill" in first, first[:1200])
        self.check("the destination prompt is never reached", "Install to" not in first)
        self.check("escape installs nothing", code != 0 and not has(self.project, ".agents"))

    def case_skill_prompt_picks_one(self):
        print("\none row can be picked out of a source, and only that one is copied")
        prune_tree(self.project)
        s = self.start(self.source)
        s.wait_for("Select skills to install")
        # The list is [Select all][heading][alpha][beta]. One ↓ lands on the
        # heading, where a space would take the whole group, so the first skill
        # is two down.
        s.send("\x1b[B")
        s.send("\x1b[B")
        s.send(" ")
        s.send("\r")
        s.wait_for("Install to")
        s.send("\r")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        found = skills_in(self.project, ".agents", "skills")
        self.check("only the picked skill landed", found == {"alpha"}, str(found))

    def case_skill_prompt_filters(self):
        print("\ntyping narrows the skills on offer")
        prune_tree(self.project)
        s = self.start(self.source)
        s.wait_for("Select skills to install")
        s.send("beta")
        narrowed = s.screen()
        s.send(" ")             # a filter change parks the cursor on one row
        s.send("\r")
        s.wait_for("Install to")
        s.send("\r")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("the heading reports the filtered count",
                   "1 of 2 skills" in narrowed, narrowed[-900:])
        self.check("exit code is 0", code == 0, f"exit={code}")
        found = skills_in(self.project, ".agents", "skills")
        self.check("only the match was copied", found == {"beta"}, str(found))

    def case_skill_prompt_select_all(self):
        print("\nSelect all at the skill prompt takes the whole source")
        prune_tree(self.project)
        s = self.start(self.source)
        s.wait_for("Select skills to install")
        s.send(" ")             # the cursor opens on "Select all"
        checked = s.screen()
        s.send("\r")
        s.wait_for("Install to")
        s.send("\r")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("the counter reports every skill checked", "2/2" in checked, checked[-900:])
        self.check("exit code is 0", code == 0, f"exit={code}")
        found = skills_in(self.project, ".agents", "skills")
        self.check("both skills landed", found == {"alpha", "beta"}, str(found))

    def case_skill_flag_skips_the_prompt(self):
        print("\n-s names the skill outright, so nothing is asked")
        prune_tree(self.project)
        s = self.start(self.source, "-s", "beta", "--yes")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        self.check("the skill prompt was never drawn",
                   "Select skills to install" not in s.screen())
        found = skills_in(self.project, ".agents", "skills")
        self.check("only the named skill was copied", found == {"beta"}, str(found))

    def case_skill_unknown_name_is_an_error(self):
        print("\n-s with a name that matches nothing fails rather than copying less")
        prune_tree(self.project)
        s = self.start(self.source, "-s", "nope", "--yes")
        code = s.wait()
        out = s.screen()
        self.dump(s)
        s.close()

        self.check("exit code is non-zero", code != 0, f"exit={code}")
        self.check("the offending name is reported", "no skill named nope" in out, out[-500:])
        self.check("nothing was installed", not has(self.project, ".agents"))

    def case_yes_skips_prompt(self):
        print("\n--yes skips the prompt entirely")
        prune_tree(self.project)
        s = self.start(self.source, "--yes")
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        self.check("neither prompt was drawn",
                   "Install to" not in s.screen() and "Select skills to install" not in s.screen())
        found = skills_in(self.project, ".agents", "skills")
        self.check("auto-detect still installed every skill to the hub", found == {"alpha", "beta"}, str(found))

    def case_explicit_flag_wins(self):
        print("\n-a answers where, so it bypasses the destination prompt but not the skill one")
        prune_tree(self.project)
        s = self.start(self.source, "-a", "windsurf")
        # `-a` says nothing about which skills, so the skill prompt still
        # opens — the reference needs `-y` alongside `--agent` for the same
        # reason, and says so in its own non-TTY message.
        self.take_every_skill(s, then_destination=False)
        code = s.wait()
        self.dump(s)
        s.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        self.check("the destination prompt was skipped",
                   "Install to" not in s.screen())
        windsurf = skills_in(self.project, ".windsurf", "skills")
        self.check("skills landed only in .windsurf", windsurf == {"alpha", "beta"}, str(windsurf))
        self.check("the hub was left alone", not has(self.project, ".agents"))

    def case_non_tty_does_not_prompt(self):
        print("\nwith no TTY there is no prompt and no hang")
        prune_tree(self.project)
        env = dict(os.environ)
        env["HOME"] = self.home
        proc = subprocess.run(
            [self.binary, "install", self.source],
            cwd=self.project,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.check("exit code is 0", proc.returncode == 0, f"exit={proc.returncode}")
        self.check("neither prompt was drawn",
                   "Install to" not in proc.stdout and "Select skills to install" not in proc.stdout)
        found = skills_in(self.project, ".agents", "skills")
        self.check("installed to the hub", found == {"alpha", "beta"}, str(found))

    def case_already_installed_is_additive(self):
        print("\nre-running without --force skips rather than replacing")
        prune_tree(self.project)
        first = self.start(self.source, "--yes")
        first.wait()
        first.close()
        marker = os.path.join(self.project, ".agents", "skills", "alpha", "SKILL.md")
        before = os.stat(marker).st_mtime_ns

        second = self.start(self.source, "--yes")
        code = second.wait()
        out = second.screen()
        second.close()

        self.check("exit code is 0", code == 0, f"exit={code}")
        self.check("the run reports skips", "skipped" in out, out[-400:])
        self.check("the existing copy was untouched",
                   os.stat(marker).st_mtime_ns == before)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(here, "..", "zig-out", "bin", "bliz"))
    ap.add_argument("-v", "--verbose", action="store_true", help="dump the captured screen")
    args = ap.parse_args()

    binary = os.path.abspath(args.bin)
    if not os.path.exists(binary):
        print(f"no bliz binary at {binary} — run `zig build` first", file=sys.stderr)
        return 2

    h = Harness(binary, args.verbose)
    try:
        print(f"binary  {binary}")
        print(f"tmpdir  {h.tmp}\n")
        for case in (
            h.case_layout_honours_the_pty_size,
            h.case_prompt_appears,
            h.case_accept_defaults,
            h.case_pick_only_another,
            h.case_skill_prompt_appears,
            h.case_skill_prompt_picks_one,
            h.case_skill_prompt_filters,
            h.case_skill_prompt_select_all,
            h.case_skill_flag_skips_the_prompt,
            h.case_skill_unknown_name_is_an_error,
            h.case_scope_switch_is_visible,
            h.case_global_flag_installs_into_home,
            h.case_cross_scope_install,
            h.case_search_reaches_siblings,
            h.case_yes_skips_prompt,
            h.case_explicit_flag_wins,
            h.case_non_tty_does_not_prompt,
            h.case_already_installed_is_additive,
        ):
            case()
    except Failure as exc:
        print(f"\n\033[31mharness failed:\033[0m {exc}")
        return 1
    finally:
        h.cleanup()

    total = h.passed + len(h.failed)
    if h.failed:
        print(f"\n\033[31m{len(h.failed)} of {total} checks failed\033[0m")
        for name in h.failed:
            print(f"  - {name}")
        return 1
    print(f"\n\033[32mall {total} checks passed\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
