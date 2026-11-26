#!/bin/sh
# Tests conf_from_uci in gundil-gateway-luci (the LuCI helper) without an
# OpenWrt router: uci's config_* functions are stubbed.
#   sh gateway/packaging/luci/test-helper.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

# The function only, without "/lib/functions.sh" (not on this machine).
sed -n '/^conf_from_uci()/,/^}/p' "$HERE/gundil-gateway-luci" |
	grep -v '/lib/functions.sh' > "$T/fn.sh"

# case NAME EXPECT(0|1) uci-values...  (password home_key update_server)
check() {
	name=$1 want=$2 PW=$3 HK=$4 US=$5
	(
		config_load() { :; }
		config_get() {
			case "$3" in
			password) eval "$1=\$PW" ;; home_key) eval "$1=\$HK" ;;
			update_server) eval "$1=\$US" ;; name) eval "$1='Gundil Router'" ;;
			*) eval "$1=\${4:-}" ;;
			esac
		}
		config_get_bool() { eval "$1=1"; }
		. "$T/fn.sh"
		conf_from_uci "$T/out.conf"
	)
	got=$?
	if [ "$got" != "$want" ]; then
		echo "FAIL $name: exit $got, want $want"; fail=1
	elif [ "$want" = 0 ] && [ -n "$HK" ] && ! grep -q "^home_key = $HK\$" "$T/out.conf"; then
		echo "FAIL $name: no home_key in the config"; fail=1
	else
		echo "ok   $name"
	fi
	rm -f "$T/out.conf"
}

check "home key, no update server" 0 "" "GUNDIL-PAIR-abc" ""
check "password, no update server" 0 "0123456789" "" ""
check "home key and update server" 0 "" "GUNDIL-PAIR-abc" "GUNDIL-UPDATE-x"
check "nothing set" 1 "" "" ""
check "short password" 1 "short" "" ""
exit $fail
