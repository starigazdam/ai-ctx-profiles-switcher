#!/bin/sh
# Write confinement for run-probes.sh: run a command with no network, and with every
# mount read-only except $TMPDIR, kernel pseudo file systems and device nodes.
# It always starts the command through `unshare -rnm` (new user, network and mount
# namespaces). There is no path to the remounts without unshare.
#   d=$(mktemp -d) && TMPDIR=$d experiments/native-isolation/ro-run.sh \
#       experiments/native-isolation/run-probes.sh; ls -A "$d"   # empty = nothing left behind
# RO_RUN_UNSHARE (default -rnm) exists only to test the inner guards: with -rm the
# network guard must stop the run, with -rn the mount namespace guard must stop it.
set -e
[ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] || { echo "ro-run: set TMPDIR to an existing directory"; exit 3; }
[ $# -gt 0 ] || { echo "ro-run: usage: ro-run.sh <command> [args...]"; exit 3; }

# shellcheck disable=SC2016  # $-expansion happens in the inner shell
inner='
set -e
outer="$1"; shift
# Guards before any remount: a private mount namespace, and no interface but lo.
[ "$(readlink /proc/self/ns/mnt)" != "$outer" ] \
    || { echo "ro-run: not in a private mount namespace"; exit 3; }
ifs="$(awk -F: '\''NR > 2 {gsub(/ /, "", $1); if ($1 != "lo") print $1}'\'' /proc/net/dev)"
[ -z "$ifs" ] || { echo "ro-run: network interfaces present: $ifs"; exit 3; }
skip() {  # mounts that stay as they are: pseudo file systems and device nodes
    case "$1" in /proc|/proc/*|/sys|/sys/*|/dev/pts|/dev/mqueue|"$TMPDIR") return 0 ;; esac
    [ -c "$1" ]
}
# Field 5 of mountinfo is the mount point, field 6 its options.
awk '\''{print $5}'\'' /proc/self/mountinfo | sort -u | while read -r m; do
    skip "$m" && continue
    mount -o remount,bind,ro "$m" 2>/dev/null \
        || { mount --bind "$m" "$m" && mount -o remount,bind,ro "$m"; } \
        || { echo "ro-run: cannot make $m read-only"; exit 3; }
done
mount --bind "$TMPDIR" "$TMPDIR"
mount -o remount,bind,rw "$TMPDIR"
# The last mountinfo entry for a path is the visible one. List every visible rw mount.
rwlist() { awk '\''{o[$5]=$6} END {for (m in o) if (o[m] ~ /(^|,)rw(,|$)/) print m}'\'' /proc/self/mountinfo | sort; }
rw="$(rwlist | while read -r m; do skip "$m" || echo "$m"; done)"
[ -z "$rw" ] || { echo "ro-run: still writable: $rw"; exit 3; }
for m in "$HOME" /tmp /var/tmp /dev/shm /run; do
    if touch "$m/.ro-run-probe" 2>/dev/null; then rm -f "$m/.ro-run-probe"; echo "ro-run: $m is writable"; exit 3; fi
done
echo "ro-run: all mounts read-only except $TMPDIR, /proc, /sys, /dev/pts, /dev/mqueue and device nodes; no network"
echo "ro-run: writable mounts: $(rwlist | tr "\n" " ")"
exec "$@"
'
# shellcheck disable=SC2086  # RO_RUN_UNSHARE is a flag word
exec unshare ${RO_RUN_UNSHARE:--rnm} sh -c "$inner" ro-run "$(readlink /proc/self/ns/mnt)" "$@"
