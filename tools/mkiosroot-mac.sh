#!/bin/bash
# macOS version of tools/mkiosroot.sh: build the SWEET iOS root (one
# case-sensitive journaled HFS+ volume holding the iOS OS root plus its
# SystemOS/AppOS cryptexes) straight from an IPSW, then apply
# tools/sweet-root-tweaks.py and write a raw image for the userdata partition
# (rd=ufsroot0). Used for the OnePlus 3 (2026-11-07).
#
#   mkiosroot-mac.sh IPSW OUT.img [SIZE]        (SIZE default 16g)
#
# Differences from the Linux script: the IPSW's APFS images are attached with
# hdiutil (no apfs-fuse), the volume is created by hdiutil, and files are
# copied with `ditto --nopreserveHFSCompression`: iOS ships its files
# LZFSE/LZBITMAP-compressed (decmpfs) and the XNU we build has no decompressor
# for those (AppleFSCompression is closed), so everything is stored plain,
# exactly what apfs-fuse produced on Linux. Needs sudo (owners/modes).
set -euo pipefail

[[ $# -ge 2 ]] || { sed -n '2,15p' "$0"; exit 2; }
ipsw=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$2 size=${3:-16g}
here=$(cd "$(dirname "$0")" && pwd)
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
sudo -n true || { echo "needs passwordless sudo" >&2; exit 1; }

work=$(mktemp -d /tmp/mkiosroot.XXXXXX)
attached=()
cleanup() {
	# ${a[@]+"${a[@]}"}: macOS bash 3.2 calls an empty array unbound under set -u
	for m in ${attached[@]+"${attached[@]}"}; do hdiutil detach -force "$m" >/dev/null 2>&1 || true; done
	rm -rf "$work"
}
trap cleanup EXIT

# Which DMGs are the OS root and the two cryptexes (BuildManifest, identity 0).
read -r osdmg sysdmg appdmg < <(unzip -p "$ipsw" BuildManifest.plist | python3 -c '
import plistlib, sys
m = plistlib.loads(sys.stdin.buffer.read())["BuildIdentities"][0]["Manifest"]
print(m["OS"]["Info"]["Path"], m["Cryptex1,SystemOS"]["Info"]["Path"], m["Cryptex1,AppOS"]["Info"]["Path"])')
echo "OS=$osdmg SystemOS=$sysdmg AppOS=$appdmg"
unzip -q -o "$ipsw" "$osdmg" "$sysdmg" "$appdmg" -d "$work"

attach() {     # attach IMAGE read-only, print its mount point (runs in $(...): no state)
	local img=$1 mp
	mp=$(hdiutil attach -nobrowse -readonly -owners on -noverify -mountrandom "$work" "$img" 2>/dev/null |
		awk -F'\t' '$NF ~ /^\// {print $NF}' | tail -1) || true
	if [[ -z $mp ]]; then   # raw APFS (the cryptexes)
		mp=$(hdiutil attach -nobrowse -readonly -owners on -noverify -mountrandom "$work" \
			-imagekey diskimage-class=CRawDiskImage "$img" | awk -F'\t' '$NF ~ /^\// {print $NF}' | tail -1)
	fi
	[[ -n $mp ]] || { echo "cannot attach $img" >&2; exit 1; }
	echo "$mp"
}
os=$(attach "$work/$osdmg");    attached+=("$os")
sysos=$(attach "$work/$sysdmg"); attached+=("$sysos")
appos=$(attach "$work/$appdmg"); attached+=("$appos")
echo "mounted: $os $sysos $appos"

hdiutil create -size "$size" -layout NONE -fs "Case-sensitive Journaled HFS+" \
	-volname iOSRoot "$work/root.dmg" >/dev/null
root=$(hdiutil attach -nobrowse -owners on -noverify -mountrandom "$work" "$work/root.dmg" |
	awk -F'\t' '$NF ~ /^\// {print $NF}' | tail -1)
attached=("$root" "${attached[@]}")
sudo chown 0:0 "$root"
echo "root volume at $root"

copy() {
	echo "copying $1 -> ${2#"$root"}"
	sudo mkdir -p "$2"
	sudo ditto --nopreserveHFSCompression --norsrc --noqtn "$1" "$2"
}
copy "$os" "$root"
copy "$sysos" "$root/private/preboot/Cryptexes/OS"
copy "$appos" "$root/private/preboot/Cryptexes/App"
# mount-point leftovers that are not part of the iOS root
sudo rm -rf "$root/.fseventsd" "$root/.Spotlight-V100" "$root/.Trashes" 2>/dev/null || true

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$root/System/Library/Caches/com.apple.dyld"
for f in "$root/$dsc"/*; do
	sudo ln -f "$f" "$root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file without a counterpart in the OS root to its root path.
for c in OS App; do
	(cd "$root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if ! sudo test -e "$root/$f" && ! sudo test -L "$root/$f"; then
			sudo mkdir -p "$root/$(dirname "$f")"
			src="$root/private/preboot/Cryptexes/$c/$f"
			if sudo test -L "$src"; then sudo cp -P "$src" "$root/$f"; else sudo ln "$src" "$root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores (owner _logd 272, modes, .migrated markers).
db="$root/private/var/db"
sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
: > "$work/empty"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -o 272 -g 272 -m 0644 "$work/empty" "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
sudo install -d -m 0700 -o 0 -g 0 "$root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$work/systembag.kb"
sudo install -m 0600 -o 0 -g 0 "$work/systembag.kb" "$root/private/var/keybags/systembag.kb"

# The SWEET bring-up changes (launchd, containers, migration, Setup, ...).
sudo python3 "$here/sweet-root-tweaks.py" "$root"

df -h "$root"
dev=$(df "$root" | awk 'NR==2 {print $1}')
hdiutil detach "$root" >/dev/null
attached=("$os" "$sysos" "$appos")
# verify, then write the raw volume (no partition map) for dd to userdata
hdiutil attach -nomount -noverify "$work/root.dmg" > "$work/attach.txt"
rdev=$(awk 'NR==1 {print $1}' "$work/attach.txt")
fsck_hfs -fn "$rdev" || true
hdiutil detach "$rdev" >/dev/null
hdiutil convert "$work/root.dmg" -format UDTO -o "$work/root" >/dev/null
mv "$work/root.cdr" "$out"
shasum -a 256 "$out" | tee "$out.sha256"
