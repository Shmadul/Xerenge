# A stand-in app with Burnout's bundle identifier and entitlements, built once
# by Xcode's automatic signing so that the App ID gets its capabilities and a
# development profile covering them is made. scripts/package-ios.sh then signs
# the real app (built with Ninja) with that profile.
cmake_minimum_required(VERSION 3.25)
project(BurnoutSigningStub LANGUAGES OBJC)

set(BUNDLE_ID "" CACHE STRING "The app's bundle identifier")
set(TEAM_ID "" CACHE STRING "The Apple developer team")

add_executable(burnout MACOSX_BUNDLE main.m)
set_target_properties(burnout PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "${BUNDLE_ID}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${BUNDLE_ID}"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${TEAM_ID}"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "Apple Development"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/../Burnout.entitlements"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "18.0"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE "YES")
