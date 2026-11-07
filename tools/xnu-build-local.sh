#!/bin/bash
# Build the SWEET/OP3 XNU kernel on a local Intel Mac with the same steps as
# .github/workflows/xnu.yml (blacktop/darwin-xnu-build at the pinned DXB_SHA).
#
# Needs: Xcode 16.0 at /Applications/Xcode_16.app (same as the CI runner),
#        and KDK 13.5 (22G74) in /Library/Developer/KDKs (build.sh would
#        otherwise try to sudo-install it). No Homebrew: bash 5, cmake and ninja
#        are set up under ~/xnu-tools (XNU_TOOLS) on the first run, jq ships with macOS 15.
#
# usage: tools/xnu-build-local.sh [--reset] [--clean] [--keep-going]
#   (default)     incremental: copy patches, apply the ones not yet applied,
#                 relink the kernel and recompile only what changed
#   --reset       restore dxb/xnu to the pristine tag and re-apply every patch
#                 (needed after editing an existing patch; recompiles more)
#   --clean       delete the whole work dir and build from scratch
#   --keep-going  make -k (collect all compile errors in one run, like CI)
#   --auto-reset  do a --reset by itself when an applied patch changed or was
#                 removed (CI on the self-hosted runner, where branches differ)
# Env: XNU_WORK (default ~/xnu-work), MACOS_VERSION, KERNEL_CONFIG, MACHINE_CONFIG
#
# Result: $XNU_WORK/out/kernel.<config>.<machine> (+ SHA256SUMS), log in $XNU_WORK/build.log
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${XNU_WORK:-$HOME/xnu-work}
DXB=$WORK/dxb
DXB_REPO=https://github.com/blacktop/darwin-xnu-build
DXB_SHA=$(sed -n 's/^ *DXB_SHA: *//p' "$REPO/.github/workflows/xnu.yml")
export MACOS_VERSION=${MACOS_VERSION:-13.5}
export KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}
export MACHINE_CONFIG=${MACHINE_CONFIG:-SWEET}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode_16.app/Contents/Developer}

RESET=0 KEEP_GOING=0 AUTO_RESET=0
for a in "$@"; do
    case $a in
    --clean) rm -rf "${WORK:?}" ;;
    --reset) RESET=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    --auto-reset) AUTO_RESET=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
    esac
done

[ -n "$DXB_SHA" ] || { echo "DXB_SHA not found in xnu.yml"; exit 1; }
[ -d "$DEVELOPER_DIR" ] || { echo "Xcode not found: $DEVELOPER_DIR"; exit 1; }
ls -d /Library/Developer/KDKs/KDK_13.5_22G74.kdk >/dev/null 2>&1 || echo "warning: KDK 13.5 (22G74) not installed, build.sh will try to sudo-install it"

# ---- tools without Homebrew (Homebrew no longer supports Intel Macs) ----
# shared by all work dirs (local ~/xnu-work and the CI runner's ~/xnu-work-ci)
TOOLS=${XNU_TOOLS:-$HOME/xnu-tools}
BASH_VER=5.2.37
mkdir -p "$TOOLS/bin" "$WORK/out"
export PATH="$TOOLS/bin:$TOOLS/venv/bin:$PATH"
# build.sh only checks that xcodes/gum exist (Xcode is installed; gum is only
# used for the interactive version menu, MACOS_VERSION is set here)
for t in xcodes gum; do printf '#!/bin/sh\nexit 0\n' > "$TOOLS/bin/$t"; chmod +x "$TOOLS/bin/$t"; done
command -v jq >/dev/null || { echo "jq missing (/usr/bin/jq ships with macOS 15)"; exit 1; }
if [ ! -x "$TOOLS/venv/bin/cmake" ] || [ ! -x "$TOOLS/venv/bin/ninja" ]; then
    echo "== installing cmake + ninja (pip)"
    /usr/bin/python3 -m venv "$TOOLS/venv"
    "$TOOLS/venv/bin/pip" install -q --upgrade pip
    "$TOOLS/venv/bin/pip" install -q cmake ninja
fi
# bash >= 4.4: build.sh expands possibly empty arrays under set -u
if [ ! -x "$TOOLS/bin/bash" ]; then
    echo "== building GNU bash $BASH_VER"
    src=$(mktemp -d)
    for m in https://ftpmirror.gnu.org/bash https://ftp.gnu.org/gnu/bash https://mirrors.kernel.org/gnu/bash; do
        curl -sSLf --connect-timeout 20 --max-time 300 --retry 2 -o "$src/bash.tgz" "$m/bash-$BASH_VER.tar.gz" && break
        echo "   $m failed"
    done
    tar xzf "$src/bash.tgz" -C "$src"
    (cd "$src/bash-$BASH_VER" && ./configure -q --prefix="$TOOLS" --without-bash-malloc >/dev/null && make -s -j"$(sysctl -n hw.ncpu)" >/dev/null && make -s install >/dev/null)
    rm -rf "$src"
fi
BASH5=$TOOLS/bin/bash
"$BASH5" -c '[ "${BASH_VERSINFO[0]}" -ge 5 ]'
echo "== tools: $("$BASH5" --version | head -1), cmake $(cmake --version | head -1 | awk '{print $3}'), ninja $(ninja --version), $(jq --version)"

if [ ! -f "$DXB/.prepared-$DXB_SHA" ]; then
    rm -rf "${DXB:?}"
    git init -q "$DXB"
    git -C "$DXB" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
    git -C "$DXB" checkout -q FETCH_HEAD
    # --- same build.sh tweaks as the workflow's "Fetch build script" step ---
    # libfirehose_kernel is built arm64e-only; the SWEET kernel is plain arm64
    sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$DXB/build.sh"
    grep -q 'VALID_ARCHS="x86_64 arm64e arm64"' "$DXB/build.sh"
    # OnePlus 3: the arm64 slice of libfirehose_kernel must be ARMv8.0 as well
    python3 - "$DXB/build.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
anchor = "s|$(SDKROOT)/usr/local/include|$(FAKEROOT_DIR)/usr/local/include|g' \"${SRCROOT}/xcodeconfig/libfirehose_kernel.xcconfig\"\n"
i = s.index(anchor) + len(anchor)
ls = s.rindex('\n', 0, i - 1) + 1
indent = s[ls:len(s[:ls]) + (len(s[ls:]) - len(s[ls:].lstrip(' ')))]
line = indent + "printf '\\nOTHER_CFLAGS[arch=arm64] = $(inherited) -mcpu=cortex-a57\\n' >> \"${SRCROOT}/xcodeconfig/libfirehose_kernel.xcconfig\"\n"
open(p, 'w', encoding='utf-8').write(s[:i] + line + s[i:])
PY
    grep -q 'mcpu=cortex-a57' "$DXB/build.sh"
    touch "$DXB/.prepared-$DXB_SHA"
fi

# our patches/scripts go next to blacktop's (theirs have no numeric prefix)
rm -f "$DXB"/patches/[0-9]*.patch "$DXB"/patches/[0-9]*.sh
cp "$REPO"/xnu/patches/*.patch "$REPO"/xnu/patches/*.sh "$DXB/patches/"

STATE=$DXB/.applied-patches   # "<sha256>  <name>" of every patch/script in the xnu tree
reset_xnu() {
    echo "== resetting xnu sources to $(git -C "$DXB/xnu" describe --tags)"
    git -C "$DXB/xnu" checkout -q -- .
    git -C "$DXB/xnu" clean -fdxq
    rm -f "$STATE"
}
need_reset() {  # $1 = reason
    if [ "$AUTO_RESET" = 1 ]; then echo "== $1: resetting (--auto-reset)"; reset_xnu; return 0; fi
    echo "== $1: run with --reset"; exit 1
}
[ "$RESET" = 1 ] && [ -d "$DXB/xnu/.git" ] && reset_xnu

# First run / after a reset: build.sh runs the stage scripts and applies every
# patch itself (exactly like CI). Later runs: the stage scripts are not
# re-runnable, so build.sh skips that step (CODEQL=1 only guards it) and only
# patches that are new since the last run are applied here.
if [ -d "$DXB/xnu/.git" ] && [ -f "$STATE" ]; then
    # 1) anything that cannot be done incrementally?
    while read -r _ n; do
        [ -f "$DXB/patches/$n" ] || { need_reset "$n was removed from the repo"; break; }
    done < "$STATE"
fi
if [ -f "$STATE" ]; then
    for f in "$DXB"/patches/[0-9]*.sh "$DXB"/patches/[0-9]*.patch; do
        n=$(basename "$f"); h=$(shasum -a 256 "$f" | cut -d' ' -f1)
        old=$(awk -v n="$n" '$2 == n {print $1}' "$STATE")
        if [ -n "$old" ] && [ "$old" != "$h" ]; then need_reset "$n changed since it was applied"; break; fi
        case $n in *.sh) [ -z "$old" ] && { need_reset "new stage script $n"; break; } ;; esac
    done
fi
if [ -f "$STATE" ]; then
    # 2) apply the new patches
    for f in "$DXB"/patches/[0-9]*.patch; do
        n=$(basename "$f")
        awk -v n="$n" '$2 == n {f=1} END {exit !f}' "$STATE" && continue
        echo "== applying new patch $n"
        if ! git -C "$DXB/xnu" apply "$f"; then need_reset "$n does not apply"; break; fi
        echo "$(shasum -a 256 "$f" | cut -d' ' -f1)  $n" >> "$STATE"
    done
fi
FULL=1
[ -d "$DXB/xnu/.git" ] && [ -f "$STATE" ] && FULL=0
export CODEQL=$(( 1 - FULL ))
echo "== mode: $([ "$FULL" = 1 ] && echo "full patch run (build.sh applies everything)" || echo incremental)"

# build.sh skips the kernel when it already exists: remove it so make relinks
KC=$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')
rm -f "$DXB/build/xnu.obj/kernel.$KC" "$DXB/fakeroot/System/Library/Kernels/kernel.$KC"

export MAKEFLAGS=""
[ "$KEEP_GOING" = 1 ] && MAKEFLAGS=-k
cd "$DXB"
start=$(date +%s)
set +e
"$BASH5" build.sh 2>&1 | tee "$WORK/build.log"
rc=${PIPESTATUS[0]}
set -e
echo "== build.sh exit $rc after $(( ($(date +%s) - start) / 60 )) min (log: $WORK/build.log)"

if [ "$FULL" = 1 ] && [ -d "$DXB/xnu/.git" ]; then
    # build.sh silently skips patches that do not apply: ours must all be in
    if grep -E "Skipping patch .*/patches/[0-9]{4}-" "$WORK/build.log"; then
        echo "== some of our patches were NOT applied (see above)"; rc=1
    else
        (cd "$DXB/patches" && shasum -a 256 [0-9]*.sh [0-9]*.patch) > "$STATE"
        echo "== recorded $(wc -l < "$STATE" | tr -d ' ') applied patches/scripts"
    fi
fi

if [ -f "$DXB/fakeroot/System/Library/Kernels/kernel.$KC" ]; then
    # the .link dir contains read-only files: clear the old copy first
    chmod -R u+w "$WORK/out" && rm -rf "${WORK:?}"/out/kernel.*
    cp -R "$DXB/fakeroot/System/Library/Kernels/." "$WORK/out/"
    (cd "$WORK/out" && find . -maxdepth 1 -type f -name 'kernel.*' -exec shasum -a 256 {} + | sed 's| \./| |' > SHA256SUMS)
    ls -la "$WORK/out"
fi
exit "$rc"
