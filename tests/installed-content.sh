#!/bin/sh
# Compare installed payload to this checkout; preserve the user's UCI conffile.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/luci-app-fm350/files"
LIST=$(mktemp /tmp/fm350-content.XXXXXX)
trap 'rm -f "$LIST"' EXIT
find "$SOURCE" -type f | sort > "$LIST"
n=0
while IFS= read -r f; do
	rel="${f#$SOURCE}"
	[ "$rel" = /etc/config/fm350 ] && continue
	cmp -s "$f" "$rel" || { echo "FAIL installed content: $rel"; exit 1; }
	n=$((n+1))
done < "$LIST"
[ "$n" -gt 0 ]
echo "PASS installed-content ($n files; UCI conffile excluded)"
