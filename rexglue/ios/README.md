# iOS

The same recompiled title, built for arm64 iOS (18 or newer) and installed on
your own iPhone or iPad with a paid Apple developer account. Rendering goes
through MoltenVK (Vulkan on Metal), which is the Vulkan library itself on iOS.
Developed on an iPhone 15 Pro Max.

Nothing from the game is in the app: its files are copied from your disc into
the app's Documents folder.

## What you need

* A Mac with Xcode, and the disc extracted into `game/` as for the desktop
  build (`scripts/extract-image`, see SETUP.md).
* The desktop build's code generator, `rexglue-sdk/out/<mac preset>/Release/rexglue`
  (`scripts/setup-sdk.sh`), and the generated code and shaders
  (`scripts/build.sh --game game --generate-only`).
* A paid developer account signed in to Xcode. The app reserves the console's
  4 GiB address spaces up front, which takes the Extended Virtual Addressing
  capability; a free account cannot have it.

## Signing

Copy `signing.local.example` to `signing.local` (git-ignored) and fill in your
bundle identifier, team, certificate and phone.

The provisioning profile is made by Xcode's automatic signing, from a stand-in
app with the same identifier and entitlements (`Burnout.entitlements`). Build it
once, with the phone connected:

```
cmake -S rexglue/ios/signing-stub -B rexglue/ios/signing-stub/build -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
      -DBUNDLE_ID=<your bundle id> -DTEAM_ID=<your team>
xcodebuild -project rexglue/ios/signing-stub/build/BurnoutSigningStub.xcodeproj \
      -scheme burnout -destination "id=<the phone's UDID>" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

That registers the identifier with both capabilities and leaves a profile in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles`, which
`scripts/package-ios.sh` finds by itself.

## Building

```
cmake -S rexglue -B rexglue/build-ios -G Ninja -DREXSDK_DIR=$PWD/rexglue-sdk \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
      -DCMAKE_C_FLAGS=-mcpu=apple-a14 -DCMAKE_CXX_FLAGS=-mcpu=apple-a14 \
      -DREXGLUE_CODEGEN=$PWD/rexglue-sdk/out/<mac preset>/Release/rexglue
ninja -C rexglue/build-ios burnout rexgpu-plume
./scripts/package-ios.sh --install       # build-ios/package/Burnout.app, signed and installed
./scripts/package-ios.sh --push-game     # game/ into the app's Documents (resumable)
```

`--push-game` copies only what the phone does not already have, so it can be
stopped and run again. A home-screen icon of your own can sit beside the
repository as `icon.png` (or be named by `XERENGE_IOS_ICON`); it is never
committed.

## On the phone

* **Settings → Apps → Burnout Revenge**: resolution (900p by default; native
  costs about twice the GPU work), screen (stretch by default: the console's
  16:9 picture scaled onto the whole screen, so the game's full-screen overlays
  - the crash letterbox and flash, the videos - cover it; widescreen widens the
  cameras to the phone's shape undistorted but keeps those overlays in a 16:9
  box; or 16:9 with bars), culling, bloom, motion blur, the FPS counter and the
  touch controls. Read at every start.
* **Touch controls**: a floating stick on the left half; RT and LT bottom
  right, A B X Y above them; LB and RB in the top corners, Back and Start top
  middle. They hide while a controller is connected.
* **Documents** (Finder or the Files app): `game/`, `user/` (saves),
  `burnout.log`, and an optional `xerenge.conf` whose keys override the
  Settings page and whose `env.NAME = value` lines set any variable the game or
  the renderer reads (see `src/ios_launch.mm`).

## What differs from the desktop

* `src/ios_launch.mm`: what `run.sh` does on a desktop - paths into the
  sandbox, the renderer's switches, the Settings page.
* `src/ios_touch.mm`: the on-screen controls, an SDL virtual gamepad.
* In the SDK: UIKit as SDL's video driver, `main` handed to `SDL_RunApp`, no
  Vulkan loader (MoltenVK is loaded from `Frameworks/`), guest memory in a Mach memory entry
  (RAM only; the sandbox refuses POSIX shared memory), and FFmpeg's
  ARM Apple configuration carrying the soundtrack's WMA and MP3 decoders.
* In plume: SDL makes the Metal-layer surface on Apple platforms, and the
  native Metal backend is left out.
