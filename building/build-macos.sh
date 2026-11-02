#!/usr/bin/env bash
#
# build-macos.sh - one click macOS build for this repository.
#
# The counterpart of building/Build.bat: it walks the same steps, in the same order,
# so a local build and the CI build do not drift apart.
#
#   1. find a Haxe 4.3.x (+ Neko); download both into building/toolchain when missing
#   2. point haxelib at the repository-local .haxelib folder
#   3. install the libraries listed in building/libs.xml when they are missing
#   4. make sure lime's native library is there (--rebuild-lime forces a rebuild)
#      and, with --bootstrap-tools, run lime setup + the hxcpp/tools rebuilds first;
#      lime's own command line bytecode (tools/tools.n) is rebuilt when it is stale
#   5. check the C++ toolchain (Xcode command line tools)
#   6. run "haxelib run lime build mac", with hxcpp's compile cache enabled
#   7. check the app bundle is newer than the build start
#
# Usage:
#   ./building/build-macos.sh [--clean] [--debug] [--yes] [--no-cache]
#                             [--rebuild-lime] [--bootstrap-tools] [--dry-run]
#                             [--cache-dir DIR]
#                             [--haxe-home DIR] [--download-toolchain]
#                             [--arch x86_64|arm64]
#                             [--] [extra lime arguments...]
#
# --arch wraps the lime calls in "arch -<arch>", which is how the CI builds the x64
# artifact on an arm64 runner.
#
# Nothing outside the repository is modified unless a toolchain has to be downloaded.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/building"
TOOLCHAIN_DIR="$SCRIPT_DIR/toolchain"

HAXE_VERSION='4.3.7'
NEKO_VERSION='2.3.0'
LIME_PLATFORM='mac'
NDLL_ARCH='Mac64'
BIN_DIR='macos'
APP_NAME='CodenameEngine.app'

# ---------------------------------------------------------------- arguments
CLEAN=0
DEBUG=0
ASSUME_YES=0
NO_CACHE=0
REBUILD_LIME=0
BOOTSTRAP_TOOLS=0
DRY_RUN=0
DOWNLOAD_TOOLCHAIN=0
CACHE_DIR=''
HAXE_HOME=''
TARGET_ARCH=''
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --clean|-c) CLEAN=1 ;;
        --debug|-d) DEBUG=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-cache) NO_CACHE=1 ;;
        --rebuild-lime) REBUILD_LIME=1 ;;
        --bootstrap-tools) BOOTSTRAP_TOOLS=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --download-toolchain) DOWNLOAD_TOOLCHAIN=1 ;;
        --cache-dir) shift; CACHE_DIR="${1:-}" ;;
        --haxe-home) shift; HAXE_HOME="${1:-}" ;;
        --arch) shift; TARGET_ARCH="${1:-}" ;;
        -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; EXTRA_ARGS=("$@"); break ;;
        *) EXTRA_ARGS+=("$1") ;;
    esac
    shift
done

# ---------------------------------------------------------------- output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_STEP=$'\033[36m'; C_OFF=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_STEP=''; C_OFF=''
fi

LOG_FILE=''
log()  { printf '%s\n' "$*" | tee -a "${LOG_FILE:-/dev/null}" >/dev/null; printf '%s\n' "$*"; }
ok()   { log "${C_OK}$*${C_OFF}"; }
warn() { log "${C_WARN}$*${C_OFF}"; }
err()  { log "${C_ERR}$*${C_OFF}" >&2; }
step() { printf '\n%s== %s ==%s\n' "$C_STEP" "$*" "$C_OFF"; [ -n "$LOG_FILE" ] && printf '\n== %s ==\n' "$*" >>"$LOG_FILE" || true; }
die()  { err "FAILED: $*"; [ -n "$LOG_FILE" ] && printf 'FAILED: %s\n' "$*" >>"$LOG_FILE" || true; exit 1; }

# ---------------------------------------------------------------- helpers
have() { command -v "$1" >/dev/null 2>&1; }

# building/libs.xml installs almost every library with <git name=".." url=".."/>, which
# haxelib turns into "git clone", and the engine embeds the commit hash/date at compile
# time (source/funkin/backend/system/macros/GitCommitMacro.hx). The second one only
# degrades to "-", the first one fails outright.
git_version() { # version line when git is usable
    have git || return 1
    local out
    # macOS ships a stub that only offers to install the command line tools
    out="$(git --version 2>/dev/null | head -n1)"
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# Same idea as Build.bat: a missing git is installed instead of being left to the user.
# Windows unpacks the portable MinGit; on macOS homebrew can do it without a password.
install_git() { # returns 0 when git is usable afterwards
    if [ "$DRY_RUN" -eq 1 ]; then
        log '[dryrun] git would be installed now (brew install git)'
        return 1
    fi
    if have brew; then
        log 'installing git with homebrew'
        brew install git && have git && return 0
        return 1
    fi
    warn 'homebrew not found - install git with: xcode-select --install   (or: brew install git)'
    return 1
}

require_git() { # why it is needed, for the message
    local version
    if version="$(git_version)"; then
        ok "git --version -> $version"
        return 0
    fi
    err 'git is not installed (or not on PATH)'
    log "  $*"
    log '  every library in building/libs.xml is fetched with "haxelib git", which runs the git command'
    log '  install git, then run this script again:'
    log '    macOS         : xcode-select --install   (or: brew install git)'
    log '    Debian/Ubuntu : sudo apt-get install -y git'
    return 1
}


confirm() { # question, default(1=yes)
    local question="$1" default="${2:-1}" answer
    if [ "$ASSUME_YES" -eq 1 ]; then [ "$default" -eq 1 ]; return $?; fi
    if [ "$default" -eq 1 ]; then printf '%s [Y/n] ' "$question"; else printf '%s [y/N] ' "$question"; fi
    read -r answer || answer=''
    [ -z "$answer" ] && return "$default"
    case "$answer" in y|Y|yes|YES|是) return 0 ;; *) return 1 ;; esac
}

run() { # runs a command, tees its output into the log, returns its exit code
    if [ "$DRY_RUN" -eq 1 ]; then log "[dryrun] $*"; return 0; fi
    log "\$ $*"
    if [ -n "$LOG_FILE" ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    fi
    "$@"
}

# every lime/haxe call has to happen for the target architecture when --arch is given
lime_run() {
    if [ -n "$TARGET_ARCH" ]; then run arch "-$TARGET_ARCH" haxelib run lime "$@"
    else run haxelib run lime "$@"; fi
}

download() { # url destination
    local url="$1" dest="$2"
    if [ "$DRY_RUN" -eq 1 ]; then log "[dryrun] download $url -> $dest"; return 0; fi
    mkdir -p "$(dirname "$dest")"
    log "downloading $url"
    if have curl; then
        curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" >>"${LOG_FILE:-/dev/null}" 2>&1 || return 1
    elif have wget; then
        wget -q -O "$dest" "$url" >>"${LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        die 'neither curl nor wget is installed'
    fi
    local size
    size=$(wc -c <"$dest" 2>/dev/null || echo 0)
    [ "$size" -gt 102400 ] || die "download is only $size bytes - probably an error page ($url)"
}

# The release tarballs wrap everything in one versioned folder: flatten that.
extract_one_dir() { # archive destination
    local archive="$1" dest="$2" tmp="${2}.tmp"
    if [ "$DRY_RUN" -eq 1 ]; then log "[dryrun] extract $archive -> $dest"; return 0; fi
    rm -rf "$tmp" "$dest"; mkdir -p "$tmp"
    tar -xzf "$archive" -C "$tmp" || return 1
    local entries
    entries=$(find "$tmp" -mindepth 1 -maxdepth 1 | wc -l)
    if [ "$entries" -eq 1 ] && [ -d "$(find "$tmp" -mindepth 1 -maxdepth 1 | head -n1)" ]; then
        mv "$(find "$tmp" -mindepth 1 -maxdepth 1 | head -n1)" "$dest"
    else
        mv "$tmp" "$dest"
    fi
    rm -rf "$tmp"
}

haxe_version_of() { # path to haxe binary
    [ -x "$1" ] || return 1
    "$1" --version 2>/dev/null | head -n1
}

# ---------------------------------------------------------------- start
[ -f "$REPO_ROOT/project.xml" ] || die "project.xml not found - this folder must stay inside the repository"
cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

mkdir -p "$SCRIPT_DIR/logs" 2>/dev/null || true
LOG_FILE="$SCRIPT_DIR/logs/build-macos-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=''

printf '\n%s Codename Engine - one click macOS build %s\n\n' "$C_STEP" "$C_OFF"
log "repository : $REPO_ROOT"
log "log        : ${LOG_FILE:-（none）}"
[ "$DRY_RUN" -eq 1 ] && warn 'DRY RUN - nothing will be changed' || true

# ---------------------------------------------------------------- 1 toolchain
step '1/6 toolchain (Haxe + Neko + git)'

HAXE_BIN=''
if [ "$DOWNLOAD_TOOLCHAIN" -eq 0 ]; then
    for candidate in "$HAXE_HOME" "${HAXEPATH:-}" "$(dirname "$(command -v haxe 2>/dev/null || echo /nonexistent)")" /usr/local/bin /opt/homebrew/bin /usr/bin; do
        [ -n "$candidate" ] || continue
        version="$(haxe_version_of "$candidate/haxe")" || continue
        case "$version" in
            4.3.*) HAXE_BIN="$candidate"; ok "found Haxe $version at $candidate"; break ;;
            *) [ -n "${version:-}" ] && warn "ignoring Haxe $version at $candidate (need 4.3.x)" ;;
        esac
    done
    if [ -z "$HAXE_BIN" ]; then
        for dir in "$TOOLCHAIN_DIR"/haxe-*; do
            [ -d "$dir" ] || continue
            version="$(haxe_version_of "$dir/haxe")" || continue
            case "$version" in 4.3.*) HAXE_BIN="$dir"; ok "found Haxe $version at $dir"; break ;; esac
        done
    fi
fi

if [ -z "$HAXE_BIN" ]; then
    warn "no usable Haxe 4.3.x found - installing $HAXE_VERSION into $TOOLCHAIN_DIR"
    [ "$(uname -m)" = 'arm64' ] && warn 'the official macOS archive is x86_64; it runs under Rosetta'
    asset="haxe-$HAXE_VERSION-osx.tar.gz"
    archive="$TOOLCHAIN_DIR/$asset"
    [ -f "$archive" ] || download "https://github.com/HaxeFoundation/haxe/releases/download/$HAXE_VERSION/$asset" "$archive" || die 'Haxe download failed'
    extract_one_dir "$archive" "$TOOLCHAIN_DIR/haxe-$HAXE_VERSION" || die 'Haxe archive could not be extracted'
    [ "$DRY_RUN" -eq 1 ] || { HAXE_BIN="$TOOLCHAIN_DIR/haxe-$HAXE_VERSION"; ok "Haxe installed at $HAXE_BIN"; }
fi

NEKO_BIN=''
for candidate in "${NEKOPATH:-}" "$(dirname "$(command -v neko 2>/dev/null || echo /nonexistent)")" /usr/local/bin /opt/homebrew/bin /usr/bin; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/neko" ]; then NEKO_BIN="$candidate"; break; fi
done
if [ -z "$NEKO_BIN" ]; then
    for dir in "$TOOLCHAIN_DIR"/neko-*; do
        [ -x "$dir/neko" ] && { NEKO_BIN="$dir"; break; }
    done
fi
if [ -z "$NEKO_BIN" ]; then
    warn "no Neko found - installing $NEKO_VERSION into $TOOLCHAIN_DIR (haxelib needs it)"
    archive="$TOOLCHAIN_DIR/neko-$NEKO_VERSION-osx64.tar.gz"
    [ -f "$archive" ] || download "https://github.com/HaxeFoundation/neko/releases/download/v2-3-0/neko-$NEKO_VERSION-osx64.tar.gz" "$archive" || die 'Neko download failed'
    extract_one_dir "$archive" "$TOOLCHAIN_DIR/neko-$NEKO_VERSION" || die 'Neko archive could not be extracted'
    [ "$DRY_RUN" -eq 1 ] || { NEKO_BIN="$TOOLCHAIN_DIR/neko-$NEKO_VERSION"; ok "Neko installed at $NEKO_BIN"; }
fi

if [ "$DRY_RUN" -eq 0 ]; then
    [ -n "$HAXE_BIN" ] || die 'no Haxe available'
    export PATH="$HAXE_BIN:$PATH"
    if [ -n "$NEKO_BIN" ]; then
        export PATH="$NEKO_BIN:$PATH"
        export DYLD_LIBRARY_PATH="$NEKO_BIN:${DYLD_LIBRARY_PATH:-}"
    fi
    ok "$(haxe --version 2>&1 | head -n1 | sed 's/^/haxe --version -> /')"
fi

# git: needed to install the libraries (haxelib git) and, at compile time, to embed the
# commit hash/date. Missing git is installed like a missing Haxe, not left to the user.
if version="$(git_version)"; then ok "git --version -> $version"; else
    warn 'git not found - trying to install it'
    if install_git && version="$(git_version)"; then
        ok "git --version -> $version (just installed)"
    else
        warn 'git is missing - installing libraries and the in-game build info need it'
    fi
fi
if have git; then
    # the in-game build info (GitCommitMacro) reads this working copy
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn 'this folder is not a git checkout - the in-game build info will show "-"'
    elif [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        warn 'shallow git checkout - the in-game commit count/hash will be incomplete'
    fi
fi

# ---------------------------------------------------------------- 2 libraries
step '2/6 libraries (repository-local .haxelib)'
export HAXELIB_PATH="$REPO_ROOT/.haxelib"
mkdir -p "$HAXELIB_PATH" 2>/dev/null || true

missing=''
for lib in lime flixel openfl hxcpp; do
    [ -d "$HAXELIB_PATH/$lib" ] || missing="$missing $lib"
done
if [ -n "$missing" ]; then
    warn "the vendored library folder is missing:$missing"
    log 'running the setup command (installs everything listed in building/libs.xml)'
    require_git 'installing the missing libraries needs git' || die 'git is missing - install it and run this script again'
    run haxe -cp commandline -D analyzer-optimize --run Main setup -si --no-vscheck || die 'the library setup failed'
    [ "$DRY_RUN" -eq 1 ] || ok 'libraries installed'
    # same rule as Build.bat: only ask when something really had to be repaired
    if [ "$DRY_RUN" -eq 0 ] && ! confirm 'Libraries were installed. Compile now?' 1; then
        ok 'stopped after the library step'
        exit 0
    fi
else
    ok "using vendored libraries from $HAXELIB_PATH"
fi

# ---------------------------------------------------------- 2b bootstrap tools
if [ "$BOOTSTRAP_TOOLS" -eq 1 ]; then
    # what the CI ran by hand before every build: lime's own setup plus hxcpp's native
    # binaries. A normal local build does not need it, a fresh CI runner does.
    step '2b/6 tools (lime setup, hxcpp)'
    lime_run setup -alias -y -nocffi || warn 'lime setup failed - continuing'
    lime_run rebuild hxcpp || die 'lime rebuild hxcpp failed'
    lime_run rebuild tools || die 'lime rebuild tools failed'
fi

# ---------------------------------------------------------------- 3 native lib
step '3/6 lime native library (lime.ndll)'
lime_dir() { # folder of the lime version haxelib resolves (a dev checkout lives in "git")
    local root="$HAXELIB_PATH/lime"
    [ -d "$root" ] || return 1
    local version=''
    [ -f "$root/.current" ] && version="$(head -n1 "$root/.current" | tr -d '\r')"
    if [ -z "$version" ] || [ ! -d "$root/$version" ]; then
        version="$(ls -1 "$root" 2>/dev/null | grep -v '^\.' | sort -V | tail -n1)"
    fi
    [ -n "$version" ] || return 1
    echo "$root/$version"
}

ndll_path() {
    local dir
    dir="$(lime_dir)" || return 1
    echo "$dir/ndll/$NDLL_ARCH/lime.ndll"
}

# lime's command line is a neko bytecode file that ships inside the lime library
# (tools/tools.n). It can be older than the sources next to it: the cne-lime fork
# dropped the lime_audio_load primitive in its audio overhaul, but the committed
# bytecode still asks for it, so "haxelib run lime" dies with "Primitive not found"
# before a single file is compiled - and the build only reports a meaningless exit 1.
lime_capture() { # read-only probe: prints the output of "lime <args>"
    if [ -n "$TARGET_ARCH" ]; then arch "-$TARGET_ARCH" haxelib run lime "$@" 2>&1
    else haxelib run lime "$@" 2>&1; fi
}

lime_command_line_ok() {
    local output
    output="$(lime_capture --version || true)"
    case "$output" in
        *"Primitive not found"*|*"Could not load library"*|*"Module not found"*|*"Uncaught exception"*) return 1 ;;
    esac
    return 0
}

repair_lime_command_line() { # returns 0 when the command line works again
    local dir tools
    dir="$(lime_dir || true)"
    tools="$dir/tools"
    if [ -z "$dir" ] || [ ! -f "$tools/tools.hxml" ]; then
        warn 'cannot rebuild the lime command line: tools/tools.hxml is missing'
        return 1
    fi
    warn 'lime tools/tools.n is older than the lime sources - rebuilding it'
    if [ "$DRY_RUN" -eq 1 ]; then log "[dryrun] rebuild $tools/tools.n"; return 0; fi
    ( cd "$tools" && run haxe tools.hxml ) || true
    lime_command_line_ok
}

LIME_NDLL="$(ndll_path || true)"
if [ "$REBUILD_LIME" -eq 1 ] || [ -z "$LIME_NDLL" ] || [ ! -f "$LIME_NDLL" ]; then
    if [ "$REBUILD_LIME" -eq 1 ]; then warn 'rebuilding lime native by request'
    else warn 'lime.ndll is missing - it has to be compiled'; fi
    # No -64 here: on macOS that asks hxcpp for a 64-bit x86 build explicitly, which
    # fights the native architecture on an arm64 host. The target is chosen by the host
    # itself (or by the "arch -x86_64" wrapper when --arch is given), which is what the
    # build always relied on.
    lime_run rebuild "$LIME_PLATFORM" -nocolor -release || die 'lime rebuild failed'
    LIME_NDLL="$(ndll_path || true)"
    [ "$DRY_RUN" -eq 1 ] || { [ -f "$LIME_NDLL" ] && ok "lime.ndll ready: $LIME_NDLL" || warn 'lime.ndll is still missing - the C++ build will most likely fail'; }
else
    ok "lime.ndll present: $LIME_NDLL"
fi

# the command line itself has to work before anything else can start
if ! lime_command_line_ok; then
    if repair_lime_command_line; then
        [ "$DRY_RUN" -eq 1 ] || ok 'lime command line rebuilt'
    else
        err 'the lime command line still crashes - delete .haxelib/lime and run this script again'
    fi
fi

# ---------------------------------------------------------------- 4 toolchain
step '4/6 C++ toolchain (Xcode command line tools)'
if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode tools: $(xcode-select -p)"
    have clang++ || die 'clang++ is missing - run: xcode-select --install'
else
    die 'no Xcode command line tools - run: xcode-select --install'
fi

# ---------------------------------------------------------------- 5 build
step '5/6 building'

BUILD_ARGS=(build "$LIME_PLATFORM" -nocolor)
[ "$DEBUG" -eq 1 ] && BUILD_ARGS+=(-debug)
[ "$CLEAN" -eq 1 ] && BUILD_ARGS+=(-clean)

# hxcpp's own incremental check compares timestamps, so anything that rewrites the
# generated sources makes it recompile everything. The cache is keyed by a hash of the
# source, the flags and the compiler version, so even that pass only compiles what
# really changed.
if [ "$NO_CACHE" -eq 0 ]; then
    if [ -n "${CACHE_DIR:-}" ]; then
        cache_root="$CACHE_DIR"
    elif [ -n "${HXCPP_COMPILE_CACHE:-}" ]; then
        # CI points this at a workspace folder; honour it instead of inventing a path
        cache_root="$HXCPP_COMPILE_CACHE"
    else
        cache_root="$HOME/Library/Caches/cne-hxcpp"
        # keep the cache off a filesystem that is nearly full: the C++ step dies with
        # "No space left on device" long before anything useful is built
        avail_mb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
        if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 2048 ] 2>/dev/null; then
            cache_root="$REPO_ROOT/.cache/hxcpp"
            warn "less than 2 GB left on the home filesystem - compile cache goes to $cache_root"
        fi
    fi
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$cache_root" 2>/dev/null || true
    # one token on purpose: lime stores "NAME=VALUE" as the define name when they are split
    BUILD_ARGS+=("-DHXCPP_COMPILE_CACHE=$cache_root")
    log "compile cache: $cache_root"
else
    log 'compile cache disabled (--no-cache)'
fi

[ ${#EXTRA_ARGS[@]} -gt 0 ] && BUILD_ARGS+=("${EXTRA_ARGS[@]}")

log "configuration: $([ "$DEBUG" -eq 1 ] && echo debug || echo release)$([ "$CLEAN" -eq 1 ] && echo ' (clean)')"
START_TIME="$(date +%s)"
lime_run "${BUILD_ARGS[@]}"
BUILD_CODE=$?

# ---------------------------------------------------------------- 6 verify
step '6/6 result'
if [ "$DEBUG" -eq 1 ]; then OUT_DIR="export/debug/$BIN_DIR/bin"; else OUT_DIR="export/release/$BIN_DIR/bin"; fi
APP="$OUT_DIR/$APP_NAME"
BINARY="$APP/Contents/MacOS/CodenameEngine"

if [ "$BUILD_CODE" -ne 0 ]; then
    err "build failed (exit $BUILD_CODE)"
    [ -n "$LOG_FILE" ] && { log '--- first error lines ---'; grep -m 25 -E 'error:|Error:|Undefined symbols|cannot find' "$LOG_FILE" || true; }
    exit "$BUILD_CODE"
fi
if [ "$DRY_RUN" -eq 1 ]; then ok 'DRY RUN finished - nothing was built'; exit 0; fi
[ -e "$APP" ] || die "the build reported success but the bundle is missing: $APP"

ok "bundle : $APP"
[ -f "$BINARY" ] && ok "binary : $BINARY ($(du -h "$BINARY" | cut -f1))"
ok "built  : $(date -r "$APP" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
[ "$(date -r "$APP" +%s 2>/dev/null || echo 0)" -lt $((START_TIME - 5)) ] && warn 'the bundle is older than this run - the build was a no-op, try --clean' || true

printf '\n%s BUILD OK %s\n run: %s\n log: %s\n' "$C_OK" "$C_OFF" "$APP" "${LOG_FILE:-none}"
