#!/usr/bin/env bash
# Copies the Concord design system's Haggler target into the add-on:
#   dist/haggler/Tokens.lua -> Host/Tokens.lua   (sets ns.Tokens; no global, so no clash with Concord)
#   dist/icons/*            -> media/icons/      (atlas PNGs per stroke weight, Icons.lua manifest, LICENSES/)
#   assets/fonts/atkinson-* -> media/fonts/      (the heading face and its OFL; the DS bundles it beside dist)
# The design system itself is never changed. Every copy is checked before anything is replaced.
# Haggler-local tokens live in Host/LocalTokens.lua, which this script never touches.
#
# Usage: tools/sync-design.sh [path/to/design-system/dist]
set -euo pipefail

DEFAULT_DIST="$HOME/Developer/wow-concord/mockups/design-system/dist"
DIST="${1:-$DEFAULT_DIST}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKENS_SOURCE="$DIST/haggler/Tokens.lua"
ICONS_SOURCE="$DIST/icons"
FONTS_SOURCE="$DIST/../assets/fonts"
HEADING_FONT_SOURCE="$FONTS_SOURCE/atkinson-hyperlegible-next-semibold.ttf"
HEADING_LICENCE_SOURCE="$FONTS_SOURCE/atkinson-hyperlegible-next-OFL.txt"
# The names Host/Tokens.lua points at (Interface\AddOns\Haggler\media\fonts\...).
HEADING_FONT_TARGET="media/fonts/AtkinsonHyperlegibleNext-SemiBold.ttf"
HEADING_LICENCE_TARGET="media/fonts/OFL-AtkinsonHyperlegibleNext.txt"

fail() {
	echo "sync-design: $*" >&2
	exit 1
}

[[ -f "$TOKENS_SOURCE" ]] || fail "tokens not found: $TOKENS_SOURCE"
[[ -f "$ICONS_SOURCE/Icons.lua" ]] || fail "icon manifest not found: $ICONS_SOURCE/Icons.lua"
[[ -d "$ICONS_SOURCE/LICENSES" ]] || fail "icon licences not found: $ICONS_SOURCE/LICENSES"
[[ -f "$HEADING_FONT_SOURCE" ]] || fail "heading font not found: $HEADING_FONT_SOURCE"
[[ -f "$HEADING_LICENCE_SOURCE" ]] || fail "heading font licence not found: $HEADING_LICENCE_SOURCE"
grep -q 'SIL Open Font License' "$HEADING_LICENCE_SOURCE" || fail "$HEADING_LICENCE_SOURCE is not the OFL"
# Every add-on font the tokens name must be one this script or the repo ships.
for face in $(grep -oE 'media\\\\fonts\\\\[A-Za-z0-9._-]+' "$TOKENS_SOURCE" | sort -u | sed 's/.*\\//'); do
	[[ -f "$REPO_ROOT/media/fonts/$face" || "media/fonts/$face" == "$HEADING_FONT_TARGET" ]] ||
		fail "tokens name media/fonts/$face, which nothing ships"
done

# Both generated files must write into the add-on namespace and never assign a global.
for file in "$TOKENS_SOURCE" "$ICONS_SOURCE/Icons.lua"; do
	if grep -qE '^(Concord_Tokens|Concord_Icons)[[:space:]]*=' "$file"; then
		fail "$file assigns a global; the Haggler target must not"
	fi
	grep -q '^local _, ns = \.\.\.' "$file" || fail "$file does not read the add-on namespace"
done
if command -v luajit >/dev/null; then
	luajit -e "
		local ns = {}
		assert(loadfile('$TOKENS_SOURCE'))('Haggler', ns)
		assert(type(ns.Tokens) == 'table' and ns.Tokens.version, 'no tokens')
		assert(loadfile('$ICONS_SOURCE/Icons.lua'))('Haggler', ns)
		assert(type(ns.Icons) == 'table' and type(ns.Icons.texcoords) == 'table', 'no icon texcoords')
		assert(ns.Icons.texcoords['triangle-alert'], 'no triangle-alert icon')
		assert(rawget(_G, 'Concord_Tokens') == nil and rawget(_G, 'Concord_Icons') == nil, 'global leaked')
	"
fi

# The client's own font never ships. The DS's check reads every font's name table, not just its
# file name; it runs on the sources, before any copy touches the add-on, and is mandatory.
CLIENT_FONT_CHECK="$DIST/../build/check-client-fonts.ts"
[[ -f "$CLIENT_FONT_CHECK" ]] || fail "client font check not found: $CLIENT_FONT_CHECK"
command -v node >/dev/null || fail "node not found; the client font check needs it"
FONT_CHECK_OUTPUT="$(node "$CLIENT_FONT_CHECK" -- "$TOKENS_SOURCE" "$ICONS_SOURCE" "$HEADING_FONT_SOURCE" "$HEADING_LICENCE_SOURCE")" ||
	fail "client font check failed on the sources"
# A pass prints exactly one line with a non-zero count; anything else (no files checked) fails.
FONT_CHECK_PASS='^check-client-fonts: checked [1-9][0-9]* files, 0 findings$'
[[ "$FONT_CHECK_OUTPUT" =~ $FONT_CHECK_PASS ]] || fail "client font check did not pass: $FONT_CHECK_OUTPUT"

cp "$TOKENS_SOURCE" "$REPO_ROOT/Host/Tokens.lua"
rm -rf "$REPO_ROOT/media/icons"
mkdir -p "$REPO_ROOT/media/icons"
cp -R "$ICONS_SOURCE/." "$REPO_ROOT/media/icons/"
cp "$HEADING_FONT_SOURCE" "$REPO_ROOT/$HEADING_FONT_TARGET"
cp "$HEADING_LICENCE_SOURCE" "$REPO_ROOT/$HEADING_LICENCE_TARGET"
echo "sync-design: wrote Host/Tokens.lua, media/icons/ and $HEADING_FONT_TARGET"
