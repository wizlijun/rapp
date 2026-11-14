# Pure helpers for package-macos.sh signing; source it, nothing runs here.
# Tested by scripts/test-package.sh with recorded security/codesign output.

# Sub-programs and the code-signing identifiers they must end up with.
EXPECTED_IDS="rapp-service:com.rapp.service rapp-hub:com.rapp.hub rapp-term:com.rapp.term rapp-host:com.rapp.host rapp-client:com.rapp.client"

# pick_identity <find-identity text> [set|unset] [RAPP_SIGN_APP value]
# Prints "<kind> <sha>", kind = devid|dev|custom|adhoc (sha is "-" for adhoc).
# Order: explicit RAPP_SIGN_APP (empty = ad-hoc) > Developer ID Application >
# Apple Development > ad-hoc. Apple Distribution is never picked.
pick_identity() {
    local ids=$1 flag=${2-unset} val=${3-} sha
    pick_by_name() { printf '%s\n' "$ids" | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"$1:.*/\1/p" | head -1; }
    if [ "$flag" = set ]; then
        if [ -z "$val" ]; then
            echo "adhoc -"
        elif printf '%s\n' "$ids" | grep -F "$val" | grep -q 'Developer ID Application'; then
            echo "devid $val"
        else
            echo "custom $val"
        fi
        return 0
    fi
    sha=$(pick_by_name "Developer ID Application")
    if [ -n "$sha" ]; then echo "devid $sha"; return 0; fi
    sha=$(pick_by_name "Apple Development")
    if [ -n "$sha" ]; then echo "dev $sha"; return 0; fi
    echo "adhoc -"
}

# runtime_flags <kind>: hardened runtime + timestamp only for Developer ID.
runtime_flags() { [ "${1-}" = devid ] && echo "--options runtime --timestamp" || true; }

# is_cdhash_dr <codesign -d -r- output>: true when the designated requirement is
# a bare cdhash (ad-hoc), which changes on every build.
is_cdhash_dr() { printf '%s\n' "$1" | grep -q 'designated => cdhash H"'; }

# identifier_of <codesign -d -v output>: value of the Identifier= line.
identifier_of() { printf '%s\n' "$1" | sed -n 's/^Identifier=//p' | head -1; }
