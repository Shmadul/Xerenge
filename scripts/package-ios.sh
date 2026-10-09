#!/bin/sh
# Packs the iOS build (rexglue/build-ios) into Burnout.app, signs it with the
# development profile made by rexglue/ios/signing-stub, and installs it.
#
#   ./scripts/package-ios.sh                 -> rexglue/build-ios/package/Burnout.app
#   ./scripts/package-ios.sh --install       ... and install it on the device
#   ./scripts/package-ios.sh --push-game     copy game/ into the app's Documents
#
# Your Apple account and phone come from rexglue/ios/signing.local (git-ignored;
# copy signing.local.example) or the same names in the environment:
#
#   XERENGE_IOS_BUNDLE_ID   a bundle identifier of your own, e.g. com.you.burnout
#   XERENGE_IOS_TEAM        your team ID (the OU of your Apple Development certificate)
#   XERENGE_IOS_IDENTITY    that certificate's SHA-1: security find-identity -v -p codesigning
#   XERENGE_IOS_DEVICE      the phone's identifier: xcrun devicectl list devices
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -f "$root/rexglue/ios/signing.local" ]; then
    . "$root/rexglue/ios/signing.local"
fi
project="$root/rexglue"
build="$project/build-ios"
sdk_out="$root/rexglue-sdk/out/ios-arm64"
# Its own directory: CMake's burnout.app is the same path on a case-insensitive disk.
app="$build/package/Burnout.app"

bundle_id=$XERENGE_IOS_BUNDLE_ID
team=$XERENGE_IOS_TEAM
identity=$XERENGE_IOS_IDENTITY
device=$XERENGE_IOS_DEVICE
for name in XERENGE_IOS_BUNDLE_ID XERENGE_IOS_TEAM XERENGE_IOS_IDENTITY XERENGE_IOS_DEVICE; do
    if [ -z "$(eval echo \$$name)" ]; then
        echo "$name is not set - see rexglue/ios/signing.local.example" >&2
        exit 1
    fi
done

install= push_game=
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --push-game) push_game=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# The profile Xcode made for this bundle identifier (newest first).
find_profile() {
    ls -t "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision 2>/dev/null |
    while IFS= read -r p; do
        if security cms -D -i "$p" 2>/dev/null | grep -q "<string>$team.$bundle_id</string>"; then
            printf '%s\n' "$p"
            break
        fi
    done
}

if [ -z "$push_game" ] || [ -n "$install" ]; then
    profile=$(find_profile)
    if [ -z "$profile" ]; then
        echo "no provisioning profile for $team.$bundle_id - build rexglue/ios/signing-stub with Xcode first" >&2
        exit 1
    fi

    echo "== assembling $app"
    rm -rf "$app"
    mkdir -p "$app/Frameworks"
    cp "$build/burnout.app/burnout" "$app/burnout"
    # The GPU plugin is looked up beside the executable; the runtime is found
    # through the executable's @executable_path rpath.
    cp "$build/librexgpu-plume.dylib" "$app/"
    cp "$sdk_out/librexruntime.dylib" "$app/"
    # MoltenVK is the Vulkan library itself on iOS (no loader); the runtime and
    # SDL look for it at Frameworks/libMoltenVK.dylib.
    cp -L "$sdk_out/libMoltenVK.dylib" "$app/Frameworks/libMoltenVK.dylib"
    install_name_tool -id @rpath/libMoltenVK.dylib "$app/Frameworks/libMoltenVK.dylib"

    sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
    version=$(cat "$root/VERSION" 2>/dev/null || echo 0.0.0)
    sed -e "s/@BUNDLE_ID@/$bundle_id/" -e "s/@VERSION@/$version/" \
        -e "s/@BUILD@/$(date +%Y%m%d%H%M)/" -e "s/@SDK_VERSION@/$sdk_version/g" \
        "$project/ios/Info.plist" > "$app/Info.plist"
    plutil -convert binary1 "$app/Info.plist"
    printf 'APPL????' > "$app/PkgInfo"
    # The app's page in the Settings app (resolution, fill screen, controls).
    cp -R "$project/ios/Settings.bundle" "$app/"

    # A home-screen icon of your own, if there is one: kept outside the
    # repository (beside it, or XERENGE_IOS_ICON), since box art is not ours to
    # publish. The middle square is cut out, scaled to 1024 and compiled by
    # actool into Assets.car, which makes every size iOS asks for.
    icon=${XERENGE_IOS_ICON:-$root/../icon.png}
    if [ -f "$icon" ]; then
        echo "== icon from $icon"
        catalog="$build/icon/Assets.xcassets"
        rm -rf "$build/icon"
        mkdir -p "$catalog/AppIcon.appiconset"
        width=$(sips -g pixelWidth "$icon" | awk '/pixelWidth/ {print $2}')
        height=$(sips -g pixelHeight "$icon" | awk '/pixelHeight/ {print $2}')
        side=$((width < height ? width : height))
        sips -s format png --cropToHeightWidth "$side" "$side" "$icon" \
            --out "$build/icon/square.png" > /dev/null
        sips -z 1024 1024 "$build/icon/square.png" \
            --out "$catalog/AppIcon.appiconset/icon-1024.png" > /dev/null
        cat > "$catalog/AppIcon.appiconset/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
        printf '{ "info" : { "author" : "xcode", "version" : 1 } }\n' > "$catalog/Contents.json"
        xcrun actool "$catalog" --compile "$app" --platform iphoneos \
            --minimum-deployment-target 18.0 --app-icon AppIcon \
            --target-device iphone --target-device ipad \
            --output-partial-info-plist "$build/icon/icon-info.plist" > /dev/null
        # actool names the icon files; the app's Info.plist has to point at them.
        plutil -convert xml1 "$app/Info.plist"
        /usr/libexec/PlistBuddy -c "Merge $build/icon/icon-info.plist" "$app/Info.plist" > /dev/null
        plutil -convert binary1 "$app/Info.plist"
    fi
    cp "$profile" "$app/embedded.mobileprovision"

    # The signature carries the profile's identifiers and get-task-allow, plus
    # the two kernel entitlements the app asks for.
    xcent="$build/Burnout.xcent"
    security cms -D -i "$profile" > "$build/profile.plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$build/profile.plist" > "$xcent"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$xcent" 2>/dev/null || true

    echo "== signing"
    for lib in "$app/Frameworks/libMoltenVK.dylib" "$app/librexruntime.dylib" "$app/librexgpu-plume.dylib"; do
        codesign --force --sign "$identity" --timestamp=none "$lib"
    done
    codesign --force --sign "$identity" --timestamp=none --entitlements "$xcent" "$app"
    codesign --verify --deep --strict "$app"
    echo "signed: $app"
fi

if [ -n "$install" ]; then
    echo "== installing on $device"
    xcrun devicectl device install app --device "$device" "$app"
fi

if [ -n "$push_game" ]; then
    if [ ! -f "$root/game/default.xex" ]; then
        echo "no extracted game at $root/game" >&2
        exit 1
    fi
    # Resumable: only the files the phone lacks, or holds at another size (an
    # interrupted copy), go over. They are staged as APFS clones - no space,
    # no time - and sent in one transfer, which merges into Documents/game.
    stage="$build/push-stage"
    rm -rf "$stage"
    mkdir -p "$stage"
    echo "== comparing with the phone"
    xcrun devicectl device info files --device "$device" \
        --domain-type appDataContainer --domain-identifier "$bundle_id" \
        --subdirectory Documents --json-output "$stage/device.json" > /dev/null
    python3 -I - "$stage/device.json" "$root/game" "$stage/game" <<'EOF'
import json, os, shutil, subprocess, sys
listing, game, staged = sys.argv[1:4]
on_phone = {f["relativePath"]: f["metadata"]["size"]
            for f in json.load(open(listing))["result"]["files"]
            if not f["resources"]["isDirectory"]}
count = size = 0
for folder, _, names in os.walk(game):
    for name in names:
        path = os.path.join(folder, name)
        rel = os.path.relpath(path, game)
        if on_phone.get("game/" + rel) != os.path.getsize(path):
            os.makedirs(os.path.join(staged, os.path.dirname(rel)), exist_ok=True)
            subprocess.run(["cp", "-c", path, os.path.join(staged, rel)], check=True)
            count += 1
            size += os.path.getsize(path)
print(f"{count} files ({size / 2**20:.0f} MiB) to send")
EOF
    if [ -d "$stage/game" ]; then
        echo "== copying them into the app's Documents/game"
        xcrun devicectl device copy to --device "$device" \
            --domain-type appDataContainer --domain-identifier "$bundle_id" \
            --source "$stage/game" --destination Documents/game > /dev/null
    fi
    rm -rf "$stage"
    echo "the game is on the phone"
fi
