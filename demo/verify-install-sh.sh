#!/usr/bin/env bash
#
# Harness for install.sh.
#
# install.sh is the only file in this repository that downloads an executable
# from the network and puts it on the user's PATH, which makes it the highest
# -consequence script here and the one least able to be checked by reading it.
# So this drives the real script, unmodified, against a real HTTP server
# serving a real release tree, and asserts on three separate things:
#
#   * the process exit status
#   * what it printed
#   * what it left on the filesystem afterwards
#
# The last one is the point. "checksum mismatch" printed by a script that
# installed the file anyway reads like success in a log and is the exact failure
# this is here to catch, so every refusal case also asserts that the destination
# directory was never even created.
#
# Nothing here reaches the network except the one case explicitly marked as a
# live check, which skips itself when offline.
#
# Usage:
#   bash demo/verify-install-sh.sh
#   PYTHON=/usr/bin/python3 bash demo/verify-install-sh.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
VERSION="0.4.1"

PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for c in "$HOME/.workbuddy/binaries/python/versions/3.13.12/bin/python3" python3 python; do
        if command -v "$c" >/dev/null 2>&1; then PYTHON="$c"; break; fi
    done
fi

checks=0
failures=0
OUT=""
STATUS=0

# --- assertions -------------------------------------------------------------

expect_status() { # want label
    checks=$((checks + 1))
    if [ "$STATUS" = "$1" ]; then
        printf '  ok    %s\n' "$2"
    else
        printf '  FAIL  %s — exit status %s, wanted %s\n' "$2" "$STATUS" "$1"
        printf '%s\n' "$OUT" | sed 's/^/        | /'
        failures=$((failures + 1))
    fi
}

expect_in() { # needle label
    checks=$((checks + 1))
    case "$OUT" in
        *"$1"*) printf '  ok    %s\n' "$2" ;;
        *)
            printf '  FAIL  %s — output did not contain: %s\n' "$2" "$1"
            printf '%s\n' "$OUT" | sed 's/^/        | /'
            failures=$((failures + 1))
            ;;
    esac
}

expect_not_in() { # needle label
    checks=$((checks + 1))
    case "$OUT" in
        *"$1"*)
            printf '  FAIL  %s — output unexpectedly contained: %s\n' "$2" "$1"
            printf '%s\n' "$OUT" | sed 's/^/        | /'
            failures=$((failures + 1))
            ;;
        *) printf '  ok    %s\n' "$2" ;;
    esac
}

expect_true() { # label cmd...
    local label="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf '  ok    %s\n' "$label"
    else
        printf '  FAIL  %s\n' "$label"
        failures=$((failures + 1))
    fi
}

expect_false() { # label cmd...
    local label="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf '  FAIL  %s\n' "$label"
        failures=$((failures + 1))
    else
        printf '  ok    %s\n' "$label"
    fi
}

expect_no_match() { # label dir pattern
    local found
    checks=$((checks + 1))
    found="$(find "$2" -maxdepth 1 -name "$3" 2>/dev/null | head -1)"
    if [ -z "$found" ]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s — found %s\n' "$1" "$found"
        failures=$((failures + 1))
    fi
}

section() { printf '\n%s\n' "$1"; }

run() { # cmd...
    OUT="$("$@" 2>&1)"
    STATUS=$?
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

# --- preconditions ----------------------------------------------------------

if [ ! -x "$INSTALLER" ]; then
    echo "error: $INSTALLER is missing or not executable" >&2
    exit 1
fi
if [ -z "$PYTHON" ]; then
    echo "error: no python3 found (needed to serve the fixture over HTTP); set PYTHON=" >&2
    exit 1
fi

BIN="$ROOT/zig-out/bin/bliz"
if [ ! -x "$BIN" ]; then
    echo "== zig-out/bin/bliz is missing; building it first"
    (cd "$ROOT" && zig build) || { echo "error: zig build failed" >&2; exit 1; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bliz-installsh.XXXXXX")"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null
        # Without the wait, bash reports the killed job ("Terminated: 15") on
        # the way out, which reads like a failure in CI logs.
        wait "$SERVER_PID" 2>/dev/null
    fi
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

# The fixture has to be built for *this* host's target, because that is the only
# one whose smoke test can genuinely run here. Getting this wrong makes every
# download miss, which looks like an installer bug and is not one.
HOST_S="$(uname -s)"
HOST_M="$(uname -m)"
HOST_SUFFIX=macos
[ "$HOST_S" = "Linux" ] && HOST_SUFFIX=linux-musl
HOST_TARGET="$HOST_M-$HOST_SUFFIX"
[ "$HOST_M" = "arm64" ] && HOST_TARGET="aarch64-$HOST_SUFFIX"

# A target this host cannot execute, whatever this host happens to be.
FOREIGN_TARGET="x86_64-linux-musl"
[ "$FOREIGN_TARGET" = "$HOST_TARGET" ] && FOREIGN_TARGET="aarch64-linux-musl"

echo "install.sh harness — host $HOST_S/$HOST_M (target $HOST_TARGET)"

# ===========================================================================
# Fixture: a release tree shaped exactly like the one the workflow publishes.
# ===========================================================================

FIX="$WORK/www"
mkdir -p "$FIX/release/nosums"

# Mirrors the workflow's Package step: a directory named bliz-<version>-<target>
# holding the binary plus the README, tarred from the parent.
package() { # binary version target
    local name="bliz-$2-$3"
    local stage="$WORK/stage/$name"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp "$1" "$stage/bliz"
    chmod +x "$stage/bliz"
    cp "$ROOT/README.md" "$stage/"
    tar -C "$WORK/stage" -czf "$FIX/release/$name.tar.gz" "$name"
}

package "$BIN" "$VERSION" "$HOST_TARGET"   # the good one
package "$BIN" "9.9.9" "$HOST_TARGET"      # name says 9.9.9, binary says 0.4.1
package "$BIN" "0.5.0" "$HOST_TARGET"      # hashed, then corrupted

# A foreign target. Deliberately not a real ELF: the case below asserts the
# smoke test is *skipped* for a target this host cannot run, so a stub that
# could never execute is a stricter fixture than a real cross-compiled binary.
STUB="$WORK/stub/bliz"
mkdir -p "$WORK/stub"
printf '#!/bin/sh\necho "this must never be executed"\n' > "$STUB"
chmod +x "$STUB"
package "$STUB" "0.6.0" "$FOREIGN_TARGET"

# Exactly what the workflow's Checksums step runs: bare filenames, generated
# from inside the directory. The installer also tolerates "./name" and "*name".
( cd "$FIX/release" && sha256 *.tar.gz > SHA256SUMS )
cp "$FIX/release/bliz-$VERSION-$HOST_TARGET.tar.gz" "$FIX/release/nosums/"

# Corrupt 0.5.0 *after* it was hashed, so the published checksum no longer
# describes the published bytes.
printf 'corrupted\n' >> "$FIX/release/bliz-0.5.0-$HOST_TARGET.tar.gz"

cat > "$WORK/serve.py" <<'PY'
import http.server, socketserver, sys, os
os.chdir(sys.argv[1])
srv = socketserver.TCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
with open(sys.argv[2], "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY

"$PYTHON" "$WORK/serve.py" "$FIX" "$WORK/port" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do [ -s "$WORK/port" ] && break; sleep 0.1; done
if [ ! -s "$WORK/port" ]; then
    echo "error: the fixture HTTP server did not start" >&2
    exit 1
fi
BASE="http://127.0.0.1:$(cat "$WORK/port")/release"

# A shimmed `uname` is how the platform matrix gets tested for real rather than
# by reading the case statement: the script asks the system, and this changes
# the system's answer.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat > "$SHIM/uname" <<'SH'
#!/bin/sh
case "$1" in
    -m) printf '%s\n' "${FAKE_M:-arm64}" ;;
    *)  printf '%s\n' "${FAKE_S:-Darwin}" ;;
esac
SH
chmod +x "$SHIM/uname"

echo "fixture: $BASE"

# ===========================================================================
section "Usage and argument handling"
# ===========================================================================

run sh "$INSTALLER" --help
expect_status 0 "--help exits 0"
expect_in "Install bliz (Linux and macOS)" "--help describes the supported platforms"
expect_in "Windows is not supported" "--help states the Windows limitation"

run sh "$INSTALLER" --nonsense
expect_status 2 "an unknown option is a usage error, not a silent no-op"
expect_in "unknown option: --nonsense" "the unknown option is named"

run sh "$INSTALLER" --version
expect_status 2 "--version with no value is a usage error"

run sh "$INSTALLER" extra-argument
expect_status 2 "a stray positional argument is a usage error"

# ===========================================================================
section "Platforms that are refused"
# ===========================================================================

for fake in "MINGW64_NT-10.0-19045" "MSYS_NT-10.0" "CYGWIN_NT-10.0"; do
    run env PATH="$SHIM:$PATH" FAKE_S="$fake" FAKE_M=x86_64 sh "$INSTALLER" --version 0.4.1 --dry-run
    expect_status 1 "$fake is refused"
    expect_in "Windows is not supported" "$fake says why"
done
# The refusal must survive a *matching* architecture: the usual reason a Windows
# check gets skipped is that the arch branch runs first and looks fine.
run env PATH="$SHIM:$PATH" FAKE_S=MINGW64_NT-10.0 FAKE_M=arm64 sh "$INSTALLER" --version 0.4.1 --dry-run
expect_status 1 "Git Bash on arm64 is still refused"
expect_in "termios, poll and ioctl" "the refusal names the actual reason"

run env PATH="$SHIM:$PATH" FAKE_S=Linux FAKE_M=i686 sh "$INSTALLER" --version 0.4.1 --dry-run
expect_status 1 "32-bit x86 is refused"
expect_in "32-bit x86 is not supported" "and says which architectures exist"

run env PATH="$SHIM:$PATH" FAKE_S=Linux FAKE_M=riscv64 sh "$INSTALLER" --version 0.4.1 --dry-run
expect_status 1 "an unknown architecture is refused"
expect_in "unsupported architecture: riscv64" "and names it"

run env PATH="$SHIM:$PATH" FAKE_S=FreeBSD FAKE_M=x86_64 sh "$INSTALLER" --version 0.4.1 --dry-run
expect_status 1 "an unsupported OS is refused"
expect_in "unsupported operating system: FreeBSD" "and names it"

# ===========================================================================
section "Target selection (offline, --dry-run)"
# ===========================================================================

dry() { # uname_s uname_m extra...
    local s="$1" m="$2"; shift 2
    run env PATH="$SHIM:$PATH" FAKE_S="$s" FAKE_M="$m" sh "$INSTALLER" "$@"
}

dry Linux x86_64 --version 0.4.1 --dry-run
expect_status 0 "Linux/x86_64 plans an install"
expect_in "x86_64-linux-musl" "Linux/x86_64 selects the static musl build"
expect_in "->  x86_64-linux-musl" "the plan shows the target it resolved"

dry Linux aarch64 --version 0.4.1 --dry-run
expect_in "aarch64-linux-musl" "Linux/aarch64 selects aarch64-linux-musl"

dry Linux amd64 --version 0.4.1 --dry-run
expect_in "x86_64-linux-musl" "Linux/amd64 is understood as x86_64"

dry Darwin x86_64 --version 0.4.1 --dry-run
expect_in "x86_64-macos" "macOS/x86_64 selects x86_64-macos"

dry Darwin arm64 --version 0.4.1 --dry-run
expect_in "aarch64-macos" "macOS/arm64 selects aarch64-macos"
expect_not_in "would be skipped" "the host's own target is not marked unrunnable"

dry Darwin arm64 --version 0.4.1 --dry-run --target "$FOREIGN_TARGET"
expect_in "$FOREIGN_TARGET" "--target overrides detection"
expect_in "would be skipped" "a foreign target says the smoke test will be skipped"

DRYDIR="$WORK/dry"
run sh "$INSTALLER" --version 0.4.1 --bin-dir "$DRYDIR" --dry-run
expect_status 0 "a dry run succeeds"
expect_false "--dry-run created the destination directory" test -e "$DRYDIR"

run sh "$INSTALLER" --version 0.4.1 --dry-run --bin-dir '~/bliz-dry'
expect_in "$HOME/bliz-dry/" "a quoted tilde in --bin-dir is expanded"

run sh "$INSTALLER" --version 0.4.1 --dry-run --repo example/fork
expect_in "github.com/example/fork/releases/download/v0.4.1/" "--repo redirects the download URL"

run sh "$INSTALLER" --version v0.4.1 --dry-run
expect_in "(tag v0.4.1)" "a leading v in --version is accepted"

run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --dry-run
expect_status 1 "BLIZ_BASE_URL without a version is refused"
expect_in "must be explicit" "and explains why a mirror needs --version"

run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version 0.4.1 --dry-run --bin-dir "$WORK/dry2"
expect_in "$BASE/bliz-0.4.1-$HOST_TARGET.tar.gz" "a mirror base URL is used verbatim"

# ===========================================================================
section "Installing (real download, real checksum, real binary)"
# ===========================================================================

T="$WORK/t1"
run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version "$VERSION" --bin-dir "$T"
expect_status 0 "a full install from the fixture succeeds"
expect_in "checksum      ok" "the checksum was verified"
expect_in "smoke test    ok" "the downloaded binary was executed before it was installed"
expect_in "installed $T/bliz" "the destination is reported"
expect_true "the binary is installed" test -x "$T/bliz"
expect_no_match "the atomic-rename staging file was cleaned up" "$T" '.bliz.new.*'

checks=$((checks + 1))
if [ "$("$T/bliz" version 2>/dev/null)" = "$VERSION" ]; then
    printf '  ok    the installed binary runs and reports %s\n' "$VERSION"
else
    printf '  FAIL  the installed binary does not report %s\n' "$VERSION"
    failures=$((failures + 1))
fi

# Byte identity is a stronger claim than "it runs": it rules out a partially
# written file that happens to still execute.
want_sum="$(sha256 "$BIN" | awk '{print $1}')"
got_sum="$(sha256 "$T/bliz" | awk '{print $1}')"
checks=$((checks + 1))
if [ "$want_sum" = "$got_sum" ]; then
    printf '  ok    the installed binary is byte-identical to the tarball\n'
else
    printf '  FAIL  byte mismatch: %s vs %s\n' "$want_sum" "$got_sum"
    failures=$((failures + 1))
fi

run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version "$VERSION" --bin-dir "$T"
expect_status 0 "re-installing over an existing binary succeeds"
expect_in "replaced $T/bliz" "and reports that it replaced, not installed"

# The real point of /bin/sh being dash on Debian and Ubuntu: the installer must
# behave identically under every shell a user might pipe it into.
for shell in sh bash dash ksh zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    ST="$WORK/shell-$shell"
    run env BLIZ_BASE_URL="$BASE" "$shell" "$INSTALLER" --version "$VERSION" --bin-dir "$ST"
    expect_status 0 "runs under $shell"
    expect_true "$shell produced a runnable binary" test -x "$ST/bliz"
done

# The PATH warning is the difference between "installed" and "usable".
run env BLIZ_BASE_URL="$BASE" PATH="/usr/bin:/bin" sh "$INSTALLER" --version "$VERSION" --bin-dir "$WORK/notonpath"
expect_status 0 "installing outside PATH still succeeds"
expect_in "is not on your PATH" "but warns that the command will not be found"
expect_in "export PATH=" "and prints the exact line to add"

# ===========================================================================
section "Refusals (each also proves nothing was written)"
# ===========================================================================

# 0.5.0's bytes no longer match its published checksum.
run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version 0.5.0 --bin-dir "$WORK/t-corrupt"
expect_status 1 "a corrupted download is refused"
expect_in "checksum mismatch" "and the mismatch is named"
expect_in "Nothing was installed" "and it says nothing was installed"
expect_false "the destination directory was never created" test -e "$WORK/t-corrupt"

# SHA256SUMS absent from the mirror entirely.
run env BLIZ_BASE_URL="$BASE/nosums" sh "$INSTALLER" --version "$VERSION" --bin-dir "$WORK/t-nosums"
expect_status 1 "a release with no SHA256SUMS is refused"
expect_in "refusing to install an unverified binary" "and it fails closed rather than skipping the check"
expect_false "nothing was written when the checksums were missing" test -e "$WORK/t-nosums"

# SHA256SUMS present but silent about this asset.
run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version 0.7.0 --bin-dir "$WORK/t-unlisted"
expect_status 1 "an asset missing from SHA256SUMS is refused"
expect_in "is not listed in SHA256SUMS" "and the missing entry is named"
expect_false "nothing was written for the unlisted asset" test -e "$WORK/t-unlisted"

# The tarball is named 9.9.9 but contains the 0.4.1 binary — the same class of
# drift scripts/release-check.sh guards in CI, caught here at the far end.
run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version 9.9.9 --bin-dir "$WORK/t-drift"
expect_status 1 "a package whose name contradicts its binary is refused"
expect_in "internally inconsistent" "and the contradiction is described"
expect_in "reports version $VERSION" "naming what the binary actually claims"
expect_false "the mismatched package was not installed" test -e "$WORK/t-drift"

# A foreign target skips the smoke test instead of failing, so the stub can be
# installed — and must never have been executed.
run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version 0.6.0 --target "$FOREIGN_TARGET" --bin-dir "$WORK/t-foreign"
expect_status 0 "a foreign target installs without the smoke test"
expect_in "smoke test    skipped" "and says the smoke test was skipped"
expect_not_in "must never be executed" "the foreign binary was not run"
expect_true "the foreign binary was installed" test -e "$WORK/t-foreign/bliz"

RO="$WORK/readonly"
mkdir -p "$RO"
chmod 500 "$RO"
run env BLIZ_BASE_URL="$BASE" sh "$INSTALLER" --version "$VERSION" --bin-dir "$RO"
expect_status 1 "an unwritable destination is refused"
expect_in "is not writable" "and says so"
chmod 700 "$RO"

# ===========================================================================
section "Latest-release resolution (live network, skipped when offline)"
# ===========================================================================

if command -v curl >/dev/null 2>&1; then
    # A repository that demonstrably has releases, so this exercises the
    # redirect-following path against GitHub rather than a stub of it.
    run sh "$INSTALLER" --repo vercel-labs/setup-zig --dry-run --bin-dir "$WORK/t-live"
    if [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -qE '\(tag v[0-9]'; then
        checks=$((checks + 1))
        printf '  ok    an unpinned run resolves the latest tag (%s)\n' "$(printf '%s' "$OUT" | sed -n 's/.*(tag \([^)]*\)).*/\1/p')"
    elif [ "$STATUS" -eq 0 ]; then
        checks=$((checks + 1))
        printf '  FAIL  an unpinned run resolved no tag\n'
        printf '%s\n' "$OUT" | sed 's/^/        | /'
        failures=$((failures + 1))
    else
        printf '  skip  live check (offline or GitHub unreachable)\n'
    fi
else
    printf '  skip  live check (no curl)\n'
fi

# ===========================================================================

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '%s checks, all passed\n' "$checks"
    exit 0
fi
printf '%s checks, %s FAILED\n' "$checks" "$failures"
exit 1
