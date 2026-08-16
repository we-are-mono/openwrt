#!/bin/sh
# Dependency-free unit tests for the mono-update version / floor logic.
# Mirrors the ver_key/is_newer helpers and the floor comparison in the client.
set -u
fails=0

ver_key() {
	v=${1#mono-v}
	case "$v" in *-r*) r=${v##*-r};; *) r=0;; esac
	v=${v%-r*}
	IFS=. read -r a b c _ <<-EOF
	$v
	EOF
	echo "${a:-0} ${b:-0} ${c:-0} ${r:-0}"
}
is_newer() {
	case "$2" in mono-v*) ;; *) return 0;; esac
	set -- $(ver_key "$1") $(ver_key "$2")
	i=1
	while [ $i -le 4 ]; do
		eval "rr=\$$i; cc=\$$((i + 4))"
		[ "$rr" -gt "$cc" ] && return 0
		[ "$rr" -lt "$cc" ] && return 1
		i=$((i + 1))
	done
	return 1
}

# check_newer A B expected(yes/no)
check_newer() {
	if is_newer "$1" "$2"; then got=yes; else got=no; fi
	if [ "$got" = "$3" ]; then
		echo "ok   is_newer($1,$2)=$got"
	else
		echo "FAIL is_newer($1,$2)=$got want $3"; fails=$((fails+1))
	fi
}

echo "== is_newer =="
check_newer mono-v25.12.5-r3 mono-v25.12.5-r2 yes   # revision bump
check_newer mono-v25.12.5-r2 mono-v25.12.5-r3 no    # older revision
check_newer mono-v25.12.5-r3 mono-v25.12.5-r3 no    # equal is not newer
check_newer mono-v25.12.6-r1 mono-v25.12.5-r9 yes   # patch beats revision
check_newer mono-v25.12.5-r1 mono-v25.12.6-r1 no    # older patch
check_newer mono-v26.1.0-r1  mono-v25.12.5-r9 yes   # minor/major
check_newer mono-v25.12.5-r10 mono-v25.12.5-r9 yes  # multi-digit revision
check_newer mono-v25.12.10-r1 mono-v25.12.9-r1 yes  # multi-digit patch

echo "== is_newer non-mono second arg (dev / corrupt-mono_release fallback) =="
# When the SECOND arg isn't a mono-v tag, is_newer returns true so dev builds
# always update. Consequence: if BOTH /etc/mono_release and the floor file are
# non-mono (corrupt), the device would accept any signed release. That is why
# the floor is max(persisted, current) and both come from a baked/flashed tag
# in practice - documented here so the branch isn't changed unknowingly.
check_newer mono-v0.0.0-r0   dev     yes   # dev floor: anything is "newer"
check_newer mono-v25.12.5-r1 ""      yes   # empty
check_newer mono-v25.12.5-r1 garbage yes   # corrupt

echo "== floor (max of persisted + current), refuse tag<=floor =="
# accept_update TAG PERSISTED CURRENT -> prints accept/reject
accept_update() {
	tag=$1; persisted=$2; current=$3
	floor=$persisted
	case "$floor" in mono-v*) ;; *) floor="$current";; esac
	is_newer "$current" "$floor" && floor="$current"
	if is_newer "$tag" "$floor"; then echo accept; else echo reject; fi
}
# check_floor TAG PERSISTED CURRENT expected
check_floor() {
	got=$(accept_update "$1" "$2" "$3")
	if [ "$got" = "$4" ]; then
		echo "ok   floor tag=$1 persisted=$2 current=$3 -> $got"
	else
		echo "FAIL floor tag=$1 persisted=$2 current=$3 -> $got want $4"; fails=$((fails+1))
	fi
}
check_floor mono-v25.12.5-r6 mono-v25.12.5-r5 mono-v25.12.5-r5 accept  # normal forward
check_floor mono-v25.12.5-r5 mono-v25.12.5-r5 mono-v25.12.5-r5 reject  # equal to floor
check_floor mono-v25.12.5-r3 mono-v25.12.5-r5 mono-v25.12.5-r5 reject  # <= floor: downgrade blocked
# Downgrade survived a reboot: image got rolled to r3 (current=r3) but the
# persisted floor still remembers r5 -> attacker cannot walk it up to r4.
check_floor mono-v25.12.5-r4 mono-v25.12.5-r5 mono-v25.12.5-r3 reject
check_floor mono-v25.12.5-r6 mono-v25.12.5-r5 mono-v25.12.5-r3 accept  # but genuine r6 still ok
check_floor mono-v25.12.5-r1 "" dev accept                            # fresh dev, no floor

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
