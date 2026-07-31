#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
build_root="$project_root/build/release"
derived_data="$build_root/DerivedData"
staging_root="$build_root/dmg-root"
dist_dir="$project_root/dist"
app_name="Taskbar S"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Taskbar/Info.plist")"
versioned_dmg="$dist_dir/Taskbar-S-$version.dmg"
stable_dmg="$dist_dir/Taskbar-S.dmg"

if [[ "$build_root" != "$project_root"/build/release ]]; then
  print -u2 "Refusing to clean an unexpected build directory: $build_root"
  exit 1
fi

/bin/rm -rf "$build_root"
/bin/mkdir -p "$staging_root" "$dist_dir"

/usr/bin/xcodebuild \
  -project "$project_root/Taskbar.xcodeproj" \
  -scheme Taskbar \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$derived_data" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  clean build

app_path="$derived_data/Build/Products/Release/$app_name.app"
if [[ ! -d "$app_path" ]]; then
  print -u2 "Release app was not produced at: $app_path"
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/ditto "$app_path" "$staging_root/$app_name.app"
/bin/ln -s /Applications "$staging_root/Applications"

/bin/rm -f "$versioned_dmg" "$stable_dmg"
/usr/bin/hdiutil create \
  -volname "$app_name" \
  -srcfolder "$staging_root" \
  -format UDZO \
  -ov \
  "$versioned_dmg"

/usr/bin/hdiutil verify "$versioned_dmg"
/bin/cp "$versioned_dmg" "$stable_dmg"

(
  cd "$dist_dir"
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
    "${versioned_dmg:t}" \
    "${stable_dmg:t}" \
    > SHA256SUMS.txt
)

print "Created: $versioned_dmg"
print "Created: $stable_dmg"
print "Created: $dist_dir/SHA256SUMS.txt"
