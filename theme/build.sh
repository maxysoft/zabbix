#!/usr/bin/env bash
set -euo pipefail

DIR="$(dirname "$(readlink -f "$0")")"
OUT="$DIR/nord-theme.css"
IMAGE="$(sed -n 's/^ *image: *\(zabbix\/zabbix-web-nginx-pgsql:.*\)$/\1/p' "$DIR/../compose.yaml" | head -n 1)"
[ -n "$IMAGE" ] || { echo "build.sh: no zabbix-web-nginx-pgsql image in compose.yaml" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
docker run --rm --entrypoint cat "$IMAGE" /usr/share/zabbix/assets/styles/dark-theme.css >"$tmp"

# Each source color is a key of the Zabbix dark theme; a target must never be another key (substitutions run in sequence).
while IFS='|' read -r from to; do
	pattern="$(printf '%s' "$from" | sed -E 's/[().]/\\&/g')"
	[[ $from == \#* ]] && pattern+='\b'
	sed -i -E "s/$pattern/$to/Ig" "$tmp"
done <<'MAP'
#0e1012|#2e3440
#f2f2f2|#eceff4
#737373|#d8dee9
#4796c4|#81a1c1
rgba(71, 150, 196, 0.5)|rgba(129, 161, 193, 0.5)
#4f4f4f|#5e81ac
#ffffff|#eceff4
#59db8f|#a3be8c
#2b2b2b|#3b4252
#383838|#434c5e
#303030|#2e3440
#f3a914|#ebcb8b
#454545|#4c566a
#9c9c9c|#81a1c1
rgba(194, 194, 194, 0.5)|rgba(208, 135, 112, 1)
rgba(135, 209, 255, 0.55)|rgba(129, 161, 193, 0.55)
rgba(135, 209, 255, 0.85)|rgba(129, 161, 193, 0.85)
rgba(30, 135, 227, 0.35)|rgba(94, 129, 172, 0.35)
rgba(0, 0, 0, 0.5)|rgba(46, 52, 64, 0.5)
#69808d|#8fbcbb
#414141|#81a1c1
rgba(94, 115, 126, 0.5)|rgba(94, 129, 172, 0.5)
#525252|#4c566a
#3d3d3d|#4c566a
#e45959|#bf616a
#e99003|#d08770
rgba(43, 43, 43, 0.7)|rgba(59, 66, 82, 0.7)
rgba(128, 128, 128, 0.15)|rgba(76, 86, 106, 0.15)
rgba(43, 43, 43, 0.3)|rgba(59, 66, 82, 0.3)
rgba(1, 1, 1, 0.75)|rgba(216, 222, 233, 0.75)
rgba(0, 0, 0, 0.15)|rgba(46, 52, 64, 0.15)
#1c1c1c|#1e232d
#2f9f5e|#69894d
#191919|#1e232d
#787878|#5e81ac
#2f280a|#2e3440
rgba(242, 242, 242, 0.1)|rgba(236, 239, 244, 0.1)
#202020|#2e3440
#0d0d0d|#2e3440
#0e0e0e|#2e3440
#0d0f11|#2e3440
rgba(0, 0, 0, 0.35)|rgba(46, 52, 64, 0.35)
rgba(43, 43, 43, 0.35)|rgba(59, 66, 82, 0.35)
#c2c2c2|#d9c59d
#808080|#434c5e
rgba(255, 255, 255, 0.9)|rgba(236, 239, 244, 0.9)
rgba(0, 0, 0, 0.9)|rgba(46, 52, 64, 0.9)
#29a847|#a3be8c
#a3a3a3|#88c0d0
rgba(43, 43, 43, 0.2)|rgba(59, 66, 82, 0.2)
#34af67|#a3be8c
rgba(242, 242, 242, 0.2)|rgba(236, 239, 244, 0.2)
#f1a50b|#d08770
#d64e4e|#bf616a
rgba(242, 242, 242, 0.7)|rgba(236, 239, 244, 0.7)
rgba(0, 0, 0, 0.2)|rgba(46, 52, 64, 0.2)
rgba(255, 255, 255, 0.3)|rgba(236, 239, 244, 0.3)
rgba(255, 255, 255, 0.2)|rgba(236, 239, 244, 0.2)
rgba(128, 128, 128, 0.1)|rgba(76, 86, 106, 0.1)
rgba(0, 0, 0, 0.8)|rgba(46, 52, 64, 0.8)
rgba(228, 89, 89, 0.2)|rgba(191, 97, 106, 0.2)
rgba(71, 150, 196, 0.35)|rgba(129, 161, 193, 0.35)
rgba(118, 141, 153, 0.35)|rgba(136, 192, 208, 0.35)
#404040|#2e3440
rgba(167, 136, 32, 0.35)|rgba(235, 203, 139, 0.35)
rgba(233, 144, 3, 0.6)|rgba(235, 203, 139, 0.6)
rgba(69, 69, 69, 0.35)|rgba(76, 86, 106, 0.35)
rgba(43, 43, 43, 0)|rgba(59, 66, 82, 0)
rgba(0, 0, 0, 0.4)|rgba(46, 52, 64, 0.4)
#ffc859|#ebcb8b
#97aab3|#8fbcbb
#7499ff|#5e81ac
#ffa059|#ffb882
#e97659|#d08770
rgba(43, 43, 43, 0.8)|rgba(59, 66, 82, 0.8)
#f24f1d|#d08770
rgba(0, 0, 0, 0.1)|rgba(46, 52, 64, 0.1)
#009900|#a3be8c
#cc0000|#bf616a
#ff5555|#bf616a
#ff9b9b|#d98d95
#69818d|#8fbcbb
#acbbc2|#d8dee9
#1f2c33|#2e3440
MAP

install -m 644 "$tmp" "$OUT"
