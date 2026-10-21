#!/bin/bash
# Smoke test for juxta-diff: exit statuses, --save and reading .juxta files back, option
# replacement, re-saving, and usage errors. Builds the debug binary, or the release one
# with --release, and works in a temp folder it removes afterwards.
#   scripts/test-juxta-diff.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

config=debug
if [ "${1:-}" = "--release" ]; then config=release; fi
swift build -c $config --product juxta-diff >/dev/null
J="$(swift build -c $config --show-bin-path)/juxta-diff"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/juxta-diff-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
timers=Fixtures/pairs/23-show-output-timers
same=Fixtures/pairs/14-identical
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# expect STATUS COMMAND...: runs it with stdout in $tmp/out and stderr in $tmp/err.
expect() {
    local want=$1; shift
    local got=0
    "$@" >"$tmp/out" 2>"$tmp/err" || got=$?
    [ "$got" -eq "$want" ] || fail "exit $got, expected $want: $*"
}
# contains FILE TEXT: the file has a line containing TEXT.
contains() { grep -qF -- "$2" "$1" || fail "$1 lacks \"$2\""; }
empty() { [ ! -s "$1" ] || fail "$1 isn't empty: $(head -c 200 "$1")"; }

# pasted NAME TEXT: a .juxta with the same pasted TEXT on both sides.
pasted() {
    local bytes sha
    bytes=$(printf '%s' "$2" | wc -c | tr -d ' ')
    sha=$(printf '%s' "$2" | shasum -a 256 | cut -d' ' -f1)
    {
        printf 'juxta-comparison 1\nsaved: 2026-10-21T14:03:12-04:00\nnote:\noptions:\n'
        for side in left right; do
            printf '\n%s\nname: %s\nsource: pasted\nbytes: %s\nsha256: %s\n' "$side" "$side" "$bytes" "$sha"
        done
        printf '\n--- left\n%s\n--- right\n%s\n' "$2" "$2"
    } >"$tmp/$1"
}

# Exit statuses follow diff.
expect 0 "$J" $same/left.cfg $same/right.cfg
expect 1 "$J" $timers/left.txt $timers/right.txt
expect 2 "$J" $timers/left.txt "$tmp/missing.txt"

# --save prints nothing unless a mode is asked for, and keeps the exit status.
expect 1 "$J" --save "$tmp/t.juxta" --note "-checked by script" -t $timers/left.txt $timers/right.txt
empty "$tmp/out"
contains "$tmp/t.juxta" "note: -checked by script"
contains "$tmp/t.juxta" "options: ignore-timers"
expect 0 "$J" --save "$tmp/same.juxta" $same/left.cfg $same/right.cfg
empty "$tmp/out"
expect 1 "$J" --save "$tmp/s.juxta" --stats $timers/left.txt $timers/right.txt
contains "$tmp/out" "hunks="

# Standard input is saved with "-" as its source.
expect 1 "$J" --save "$tmp/stdin.juxta" - $timers/right.txt <$timers/left.txt
contains "$tmp/stdin.juxta" "source: -"

# A .juxta file uses its saved options, unless ignore options replace them.
"$J" --stats -t $timers/left.txt $timers/right.txt | sed 's/ ms=.*//' >"$tmp/t-direct" || true
"$J" --stats -w $timers/left.txt $timers/right.txt | sed 's/ ms=.*//' >"$tmp/w-direct" || true
expect 1 "$J" "$tmp/t.juxta"
sed 's/ ms=.*//' "$tmp/out" | cmp -s - "$tmp/t-direct" || fail "saved options weren't used"
expect 1 "$J" -w "$tmp/t.juxta"
sed 's/ ms=.*//' "$tmp/out" | cmp -s - "$tmp/w-direct" || fail "-w didn't replace the saved options"
expect 0 "$J" "$tmp/same.juxta"
for mode in --stats --json --rows --html; do expect 1 "$J" $mode "$tmp/t.juxta"; done
expect 1 "$J" --html "$tmp/t.juxta"
contains "$tmp/out" '<p class="note">-checked by script</p>'
contains "$tmp/out" "Saved "
expect 1 "$J" --json "$tmp/t.juxta"
contains "$tmp/out" '"saved":{'

# Re-saving keeps sources and edited sides; --note replaces the note, else it's kept.
# The right side is edited to say "FULL/DR " where it said "INIT/DROTHER": same length.
LC_ALL=C sed 's#INIT/DROTHER#FULL/DR     #' "$tmp/stdin.juxta" >"$tmp/edited.juxta"
expect 1 "$J" --html "$tmp/edited.juxta"
contains "$tmp/out" "The right side was edited after it was saved"
expect 1 "$J" --save "$tmp/resaved.juxta" "$tmp/edited.juxta"
empty "$tmp/out"
contains "$tmp/resaved.juxta" "source: -"
contains "$tmp/resaved.juxta" "source: $PWD/$timers/right.txt"
contains "$tmp/resaved.juxta" "$(grep '^sha256' "$tmp/stdin.juxta" | tail -1)"
expect 1 "$J" --json "$tmp/resaved.juxta"
contains "$tmp/out" '"edited":["right"]'
expect 1 "$J" --save "$tmp/renoted.juxta" "$tmp/t.juxta"
contains "$tmp/renoted.juxta" "note: -checked by script"
contains "$tmp/renoted.juxta" "options: ignore-timers"
expect 1 "$J" --save "$tmp/renoted.juxta" --note "new note" -i "$tmp/t.juxta"
contains "$tmp/renoted.juxta" "note: new note"
contains "$tmp/renoted.juxta" "options: ignore-case"

# Identical pasted sides are identical, though they have no bytes of their own to compare.
pasted pasted.juxta $'interface Gi0/1\n shutdown\n'
expect 0 "$J" "$tmp/pasted.juxta"
contains "$tmp/out" "hunks=0"
expect 0 "$J" --json "$tmp/pasted.juxta"
contains "$tmp/out" '"byteIdentical":null'
contains "$tmp/out" '"identical":true'

# Trouble and usage errors exit 2.
printf 'hello\n' >"$tmp/bad.juxta"
expect 2 "$J" "$tmp/bad.juxta"
contains "$tmp/err" "isn’t a valid Juxta comparison"
expect 2 "$J" --save "$tmp/missing/out.juxta" $timers/left.txt $timers/right.txt
for args in "--note x $timers/left.txt $timers/right.txt" \
            "--save" \
            "--save $tmp/x.juxta --note" \
            "--save $tmp/out.txt $timers/left.txt $timers/right.txt" \
            "--save - $timers/left.txt $timers/right.txt" \
            "--save --json $timers/left.txt $timers/right.txt" \
            "$timers/left.txt" \
            "--paths $tmp/t.juxta" \
            "--save $tmp/x.juxta - -"; do
    # shellcheck disable=SC2086
    expect 2 "$J" $args
    contains "$tmp/err" "juxta-diff: "
done
[ ! -e "$tmp/x.juxta" ] && [ ! -e "$tmp/out.txt" ] || fail "a usage error wrote a file"

if [ $failures -eq 0 ]; then echo "juxta-diff: all checks passed"; else echo "$failures failed" >&2; exit 1; fi
