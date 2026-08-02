#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
output_dir="$project_root/build"
temporary_derived_data="$(/usr/bin/mktemp -d /tmp/taskbars-local-build.XXXXXX)"
app_name="Taskbar S"
signing_identity="${TASKBARS_SIGNING_IDENTITY:-$(
  /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/awk '/"Apple Development:/{ print $2; exit }'
)}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
  print "No Apple Development identity found; using an ad-hoc local signature."
else
  print "Using a stable Apple Development signature for local permissions."
fi

cleanup() {
  /bin/rm -rf "$temporary_derived_data"
}
trap cleanup EXIT

/usr/bin/xcodebuild \
  -project "$project_root/Taskbar.xcodeproj" \
  -scheme Taskbar \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$temporary_derived_data" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  build

built_app="$temporary_derived_data/Build/Products/Debug/$app_name.app"
if [[ ! -d "$built_app" ]]; then
  print -u2 "Local app was not produced at: $built_app"
  exit 1
fi

if [[ "$output_dir" != "$project_root/build" ]]; then
  print -u2 "Refusing to replace an unexpected output directory: $output_dir"
  exit 1
fi

/bin/rm -rf "$output_dir"
/bin/mkdir -p "$output_dir"
/usr/bin/ditto "$built_app" "$output_dir/$app_name.app"
/usr/bin/codesign --verify --deep --strict --verbose=1 "$output_dir/$app_name.app"

print "Created: $output_dir/$app_name.app"
