#!/bin/bash
# Checks that Resources/Info.plist has the version set in Juxta.xcodeproj. Xcode builds take
# MARKETING_VERSION and CURRENT_PROJECT_VERSION from the project for the app and its Quick
# Look extension; scripts/build.sh copies Info.plist as it is, so both must be bumped.
set -euo pipefail
cd "$(dirname "$0")/.."

project=Juxta.xcodeproj/project.pbxproj
failures=0

# check KEY SETTING: every value of SETTING in the project matches the plist's KEY.
check() {
    local plist values
    plist=$(plutil -extract "$1" raw Resources/Info.plist)
    values=$(sed -n "s/^[[:space:]]*$2 = \"\{0,1\}\([^\";]*\)\"\{0,1\};/\1/p" "$project" | sort -u)
    if [ -z "$values" ]; then
        echo "FAIL: $project doesn't set $2" >&2
        failures=$((failures + 1))
    elif [ "$values" != "$plist" ]; then
        echo "FAIL: Resources/Info.plist $1 is $plist, but $project has $2 = $(echo $values)" >&2
        failures=$((failures + 1))
    fi
}
check CFBundleShortVersionString MARKETING_VERSION
check CFBundleVersion CURRENT_PROJECT_VERSION

if [ "$failures" -gt 0 ]; then exit 1; fi
echo "version: $(plutil -extract CFBundleShortVersionString raw Resources/Info.plist) ($(plutil -extract CFBundleVersion raw Resources/Info.plist)) matches"
