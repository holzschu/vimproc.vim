#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo 'Usage: bash ci/audit-exports.sh vimproc.xcframework.zip published-vimproc.zip' >&2
    exit 2
fi
artifact=$1
baseline=$2
require_equal() {
    if [[ $1 != "$2" ]]; then
        printf '%s: expected %s, got %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}
printf '%s  %s\n' '400dcf3f4414562a9c62f1541b349be4176bdae9f7fcd95a5c7ed34046586982' "$baseline" | shasum -a 256 -c -
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
unzip -q "$artifact" -d "$temporary/candidate"
unzip -q "$baseline" -d "$temporary/published"
root="$temporary/candidate/vimproc.xcframework"
published="$temporary/published/vimproc.xcframework/ios-arm64/vimproc.framework/vimproc"
xcrun nm -arch arm64 -gjU "$published" | LC_ALL=C sort -u > "$temporary/expected.txt"
require_equal "$(wc -l < "$temporary/expected.txt" | tr -d ' ')" 31 'Published export count'
plist=/usr/libexec/PlistBuddy
{
    $plist -c 'Print :AvailableLibraries:0:LibraryIdentifier' "$root/Info.plist"
    $plist -c 'Print :AvailableLibraries:1:LibraryIdentifier' "$root/Info.plist"
} | LC_ALL=C sort > "$temporary/identifiers.txt"
printf '%s\n' ios-arm64 ios-arm64_x86_64-simulator > "$temporary/expected-identifiers.txt"
diff -u "$temporary/expected-identifiers.txt" "$temporary/identifiers.txt"
if $plist -c 'Print :AvailableLibraries:2' "$root/Info.plist" >/dev/null 2>&1; then
    echo 'Unexpected third xcframework slice.' >&2
    exit 1
fi
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    binary="$root/$slice/vimproc.framework/vimproc"
    expected=arm64
    if [[ $slice == *simulator ]]; then expected='arm64 x86_64'; fi
    actual=$(xcrun lipo -archs "$binary" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)
    require_equal "$actual" "$expected" "$slice architectures"
    for arch in $expected; do
        xcrun nm -arch "$arch" -gjU "$binary" | LC_ALL=C sort -u > "$temporary/actual.txt"
        diff -u "$temporary/expected.txt" "$temporary/actual.txt"
        minimum=$(xcrun vtool -arch "$arch" -show-build "$binary" | awk '$1 == "minos" {print $2}')
        require_equal "$minimum" 14.0 "$slice $arch minimum OS"
        xcrun otool -arch "$arch" -L "$binary" | awk '/^\t/ {print $1}' > "$temporary/dependencies.txt"
        while IFS= read -r dependency; do
            case "$dependency" in
                @rpath/vimproc.framework/vimproc|@rpath/ios_system.framework/ios_system|/usr/lib/libSystem.B.dylib) ;;
                *) echo "Unexpected dependency: $dependency" >&2; exit 1 ;;
            esac
        done < "$temporary/dependencies.txt"
        printf 'PASS: %s %s, iOS 14.0, 31 published exports\n' "$slice" "$arch"
    done
done
