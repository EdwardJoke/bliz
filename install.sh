#!/bin/sh
#
# bliz installer for POSIX systems — Linux and macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/EdwardJoke/bliz/master/install.sh | sh
#
# Written for plain `sh`, not bash: it runs under dash, ash/busybox, ksh, bash
# and zsh alike, because a one-line `curl | sh` installer has no way to know
# what /bin/sh is on the target. That rules out `local`, `[[ ]]`, arrays and
# `pipefail` — and it means no critical result may be read from the exit status
# of a pipeline, so every download lands in a file whose status is checked
# directly.
#
# Why Linux gets the musl artifact: `bliz-<version>-x86_64-linux-musl.tar.gz` is
# statically linked (the release's own `file` output says so), so one binary runs
# on every distribution regardless of its glibc version. That is the whole reason
# this can be a single download instead of a package per distro.
#
# Windows is not supported and this script says so instead of installing
# something that cannot run: bliz drives raw mode through std.posix (termios,
# poll, ioctl) and on Windows that layer is a stub, so no Windows artifact is
# even built. See the Releases section of the README.
#
# Nothing here trusts the network. The tarball is checked against the
# SHA256SUMS published in the same release, and a mismatch aborts before
# anything is written. If SHA256SUMS is missing the script fails closed —
# a skipped check is worse than a failed install.

set -eu

REPO="${BLIZ_REPO:-EdwardJoke/bliz}"
WANT_VERSION="${BLIZ_VERSION:-}"
BIN_DIR="${BLIZ_BIN_DIR:-}"
TARGET_OVERRIDE="${BLIZ_TARGET:-}"
BASE_URL="${BLIZ_BASE_URL:-}"
DRY_RUN=0

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# A malformed command line exits 2, like every other well-behaved CLI here, so
# a wrapper script can tell "you called it wrong" apart from "it ran and failed".
die_usage() { printf 'error: %s\n\n' "$*" >&2; usage >&2; exit 2; }

usage() {
    cat <<'EOF'
Install bliz (Linux and macOS).

Usage:
  install.sh [options]

Options:
  --version <v>     Install a specific release, e.g. --version 0.4.1 or v0.4.1.
                    Default: the latest published release.
  --bin-dir <dir>   Where to put the binary. Default: ~/.local/bin
  --repo <o/r>      Install from a fork, e.g. --repo someone/bliz.
  --target <t>      Override platform detection with a release target triple,
                    e.g. x86_64-linux-musl. Only useful to fetch a binary for
                    another machine; the smoke test is skipped when the target
                    differs from this host.
  --dry-run         Print what would happen, then stop. Writes nothing.
  -h, --help        Show this message.

Environment: BLIZ_VERSION, BLIZ_BIN_DIR, BLIZ_REPO, BLIZ_TARGET, BLIZ_BASE_URL.
BLIZ_BASE_URL points at a flat mirror of the release assets and requires an
explicit --version, since a mirror has no "latest" to resolve against.

Windows is not supported. See the Releases section of the README.

Exit status: 0 installed, 1 failed, 2 usage error.
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || die_usage "--version needs a value"; WANT_VERSION="$2"; shift 2 ;;
        --bin-dir) [ $# -ge 2 ] || die_usage "--bin-dir needs a value"; BIN_DIR="$2"; shift 2 ;;
        --repo)    [ $# -ge 2 ] || die_usage "--repo needs a value";    REPO="$2";    shift 2 ;;
        --target)  [ $# -ge 2 ] || die_usage "--target needs a value";  TARGET_OVERRIDE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die_usage "unknown option: $1" ;;
        *)  die_usage "unexpected argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

kernel="$(uname -s)"
machine="$(uname -m)"

case "$kernel" in
    Linux*)  os=linux ;;
    Darwin*) os=macos ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT|UWIN*)
        # Git Bash, MSYS2 and Cygwin all land here. None of them can run the
        # binary, because on Windows there is no binary to run.
        die "Windows is not supported. bliz is POSIX-only (Linux and macOS): its terminal handling needs termios, poll and ioctl, which Windows does not provide. See the Releases section of the README."
        ;;
    *) die "unsupported operating system: $kernel (bliz supports Linux and macOS)" ;;
esac

case "$machine" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    i386|i486|i586|i686|x86) die "32-bit x86 is not supported; releases are published for x86_64 and aarch64 only" ;;
    armv7l|armv6l|arm) die "32-bit ARM is not supported; releases are published for x86_64 and aarch64 only" ;;
    *) die "unsupported architecture: $machine (releases are published for x86_64 and aarch64)" ;;
esac

if [ -n "$TARGET_OVERRIDE" ]; then
    target="$TARGET_OVERRIDE"
elif [ "$os" = linux ]; then
    # musl, not gnu: the musl artifact is static, so it does not care which
    # glibc the host has. Pass --target x86_64-linux-gnu for the dynamic build.
    target="${arch}-linux-musl"
else
    target="${arch}-macos"
fi

# Can this host execute the artifact it is about to fetch? Both the
# architecture and the OS must match the ones `uname` reported. A foreign triple
# is still a legitimate thing to fetch — preparing a binary for another machine
# — so in that case the smoke test is skipped rather than failed.
target_arch="${target%%-*}"
case "${target#*-}" in
    linux*) target_os=linux ;;
    macos*) target_os=macos ;;
    *)      target_os=unknown ;;
esac
smoke_ok=0
if [ "$target_arch" = "$arch" ] && [ "$target_os" = "$os" ]; then
    smoke_ok=1
fi

# ---------------------------------------------------------------------------
# Version resolution
# ---------------------------------------------------------------------------

github_base="https://github.com/${REPO}"

if [ -n "$BASE_URL" ] && [ -z "$WANT_VERSION" ]; then
    die "BLIZ_BASE_URL is set, so the version must be explicit — pass --version <v>. A flat asset mirror has no \"latest\" to resolve against."
fi

if [ -n "$WANT_VERSION" ]; then
    case "$WANT_VERSION" in
        v*) release_tag="$WANT_VERSION" ;;
        *)  release_tag="v$WANT_VERSION" ;;
    esac
else
    # Ask GitHub which release is latest by *following a redirect*, not by
    # calling the API: api.github.com is rate limited to 60 requests/hour per
    # address and an unauthenticated installer has no token, while the HTML
    # redirect has no such limit and costs one round trip.
    effective=""
    if command -v curl >/dev/null 2>&1; then
        effective="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${github_base}/releases/latest" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
        effective="$(wget -q --server-response --spider "${github_base}/releases/latest" 2>&1 \
            | sed -n 's/^[[:space:]]*[Ll]ocation: //p' | tail -1 | tr -d '\r' || true)"
    else
        die "neither curl nor wget is available; install one of them and re-run"
    fi

    case "$effective" in
        */releases/tag/*) release_tag="${effective##*/releases/tag/}" ;;
        *) die "could not determine the latest release of ${REPO} (resolved to '${effective}'). If nothing has been released yet, pass --version <v>." ;;
    esac
fi

version="${release_tag#v}"
[ -n "$version" ] || die "could not read a version out of tag '${release_tag}'"

asset="bliz-${version}-${target}.tar.gz"
if [ -n "$BASE_URL" ]; then
    asset_url="${BASE_URL%/}/${asset}"
    sums_url="${BASE_URL%/}/SHA256SUMS"
else
    asset_url="${github_base}/releases/download/${release_tag}/${asset}"
    sums_url="${github_base}/releases/download/${release_tag}/SHA256SUMS"
fi

# ---------------------------------------------------------------------------
# Destination
# ---------------------------------------------------------------------------

if [ -z "$BIN_DIR" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set; pass --bin-dir <dir>"
    BIN_DIR="${HOME}/.local/bin"
fi
# `--bin-dir "~/bin"` arrives with the tilde intact when it was quoted, so the
# shell never had a chance to expand it.
case "$BIN_DIR" in
    "~") BIN_DIR="${HOME:-}" ;;
    "~/"*) BIN_DIR="${HOME:-}/${BIN_DIR#"~/"}" ;;
esac
dest="${BIN_DIR}/bliz"

if [ "$DRY_RUN" = 1 ]; then
    info "dry run — nothing will be downloaded or written"
    info "  platform      ${kernel} / ${machine}  ->  ${target}"
    info "  version       ${version}  (tag ${release_tag})"
    info "  asset         ${asset_url}"
    info "  checksums     ${sums_url}"
    info "  destination   ${dest}"
    [ "$smoke_ok" = 1 ] || info "  note          ${target} is not this host's architecture, so the smoke test would be skipped"
    exit 0
fi

case "$asset_url" in
    https://*) ;;
    *) warn "the download is not over https (${asset_url%%:*}://); integrity still comes from SHA256SUMS, but the transport is not confidential" ;;
esac

# ---------------------------------------------------------------------------
# Download, verify, extract
# ---------------------------------------------------------------------------

work="$(mktemp -d "${TMPDIR:-/tmp}/bliz-install.XXXXXX")"
cleanup() {
    if [ -n "${work:-}" ]; then rm -rf "$work"; fi
    return 0
}
trap cleanup EXIT

fetch() { # url dest -> 0 on success, 1 on failure
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "neither curl nor wget is available; install one of them and re-run"
    fi
}

info "bliz ${version} for ${target}"

# Fail closed when the checksums are absent. Skipping an unavailable check
# silently is how a supply-chain hole is born, so a missing SHA256SUMS is an
# error even though the download itself would have worked.
if ! fetch "$sums_url" "$work/SHA256SUMS"; then
    die "could not download SHA256SUMS from ${sums_url} — refusing to install an unverified binary"
fi

# SHA256SUMS is produced by `sha256sum *.tar.gz`, which writes a bare filename,
# but the same command invoked as `sha256sum ./*.tar.gz` writes "./name" and GNU
# coreutils' binary mode writes "*name". All three describe the same file, so
# strip the decoration rather than fail to find a checksum that is right there.
expected="$(awk -v n="$asset" '
    { p = $2; sub(/^\*/, "", p); sub(/^\.\//, "", p) }
    p == n { print $1; exit }
' "$work/SHA256SUMS")"
[ -n "$expected" ] || die "${asset} is not listed in SHA256SUMS — the package and its checksums disagree"

if ! fetch "$asset_url" "$work/$asset"; then
    die "could not download ${asset} from ${asset_url}"
fi

if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$work/$asset" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
    actual="$(openssl dgst -sha256 "$work/$asset" | awk '{print $NF}')"
else
    die "no sha256sum, shasum or openssl available — cannot verify the download"
fi

if [ "$actual" != "$expected" ]; then
    printf 'error: checksum mismatch for %s\n' "$asset" >&2
    printf '  expected  %s\n' "$expected" >&2
    printf '  actual    %s\n' "$actual" >&2
    printf 'The download is corrupt, or has been tampered with. Nothing was installed.\n' >&2
    exit 1
fi
info "  checksum      ok  (sha256 $(printf '%s' "$expected" | cut -c1-12)...)"

# Extract into a scratch directory first: nothing is written to the destination
# until a runnable binary exists in the temporary tree.
tar -xzf "$work/$asset" -C "$work" || die "could not extract ${asset}"

name="${asset%.tar.gz}"
bin_src=""
for cand in "$work/$name/bliz" "$work/$name/bliz.exe"; do
    if [ -f "$cand" ]; then bin_src="$cand"; break; fi
done
[ -n "$bin_src" ] || die "the archive does not contain a bliz binary (looked inside ${name}/)"

# ---------------------------------------------------------------------------
# Smoke test — before anything reaches the destination
# ---------------------------------------------------------------------------

if [ "$smoke_ok" = 1 ]; then
    reported="$("$bin_src" version 2>/dev/null)" || die "the downloaded binary for ${target} does not run on this machine"
    if [ "$reported" != "$version" ]; then
        die "the downloaded binary reports version ${reported} but the package is named ${version} — this release is internally inconsistent"
    fi
    info "  smoke test    ok  (it runs, and reports ${reported})"
else
    info "  smoke test    skipped (${target} is not this host's architecture)"
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

if [ ! -e "$BIN_DIR" ]; then
    mkdir -p "$BIN_DIR" || die "could not create ${BIN_DIR} — pass --bin-dir <dir> to choose somewhere writable"
fi
[ -d "$BIN_DIR" ] || die "${BIN_DIR} exists but is not a directory"
[ -w "$BIN_DIR" ] || die "${BIN_DIR} is not writable — pass --bin-dir <dir> or fix its permissions"

replaced=0
if [ -e "$dest" ]; then
    replaced=1
    [ -w "$dest" ] || die "${dest} exists and is not writable — pass --bin-dir <dir> or fix its permissions"
fi

# Write beside the destination and rename: a rename within one directory is
# atomic, so an interrupted install cannot leave a half-written binary on PATH.
staged="${BIN_DIR}/.bliz.new.$$"
cp "$bin_src" "$staged" || die "could not write to ${BIN_DIR}"
chmod 755 "$staged" || { rm -f "$staged"; die "could not make ${staged} executable"; }
mv -f "$staged" "$dest" || { rm -f "$staged"; die "could not install to ${dest}"; }

info ""
if [ "$replaced" = 1 ]; then
    info "replaced ${dest}"
else
    info "installed ${dest}"
fi

# ---------------------------------------------------------------------------
# PATH advice — the two ways a correct install still fails to be the one that
# runs: the directory is not searched at all, or something else is searched
# first.
# ---------------------------------------------------------------------------

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
        warn "${BIN_DIR} is not on your PATH, so \`bliz\` will not be found."
        case "$(basename "${SHELL:-sh}")" in
            zsh)  rc="~/.zshrc" ;;
            bash) rc="~/.bashrc" ;;
            ksh)  rc="~/.profile" ;;
            *)    rc="your shell's startup file" ;;
        esac
        printf '  Add this to %s:\n\n      export PATH="%s:$PATH"\n\n  Then restart your shell, or run\n\n      export PATH="%s:$PATH"\n\n' "$rc" "$BIN_DIR" "$BIN_DIR" >&2
        ;;
esac

shadow="$(command -v bliz 2>/dev/null || true)"
if [ -n "$shadow" ] && [ "$shadow" != "$dest" ]; then
    warn "a different bliz comes first on your PATH: ${shadow}"
    warn "run \`bliz version\` to see which one you are actually invoking"
fi

info "run \`bliz version\` to confirm (expecting ${version})"
