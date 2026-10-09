// The iOS launcher: what run.sh does on a desktop and Settings.java on Android.
// An app is started without arguments or environment, so this sets both, before
// anything reads them, from the app's own Documents directory:
//
//   Documents/game/          the extracted disc (default.xex and the rest)
//   Documents/user/          saves and settings the title writes
//   Documents/burnout.log    the log, readable from Finder's Files tab
//   Documents/xerenge.conf   optional, for testing: overrides the app's page in
//                            the Settings app (render_resolution = WxH or
//                            native, fill_screen, touch_controls, culling,
//                            bloom, motion_blur, fps_counter), and env.NAME =
//                            value lines for any variable the game or the
//                            renderer reads

#import <Foundation/Foundation.h>

#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace {

std::string Trim(const std::string& text) {
  const size_t first = text.find_first_not_of(" \t\r");
  if (first == std::string::npos) {
    return {};
  }
  const size_t last = text.find_last_not_of(" \t\r");
  return text.substr(first, last - first + 1);
}

std::map<std::string, std::string> ReadConf(const std::string& path) {
  std::map<std::string, std::string> values;
  std::ifstream file(path);
  std::string line;
  while (std::getline(file, line)) {
    line = line.substr(0, line.find('#'));
    const size_t equals = line.find('=');
    if (equals == std::string::npos) {
      continue;
    }
    const std::string key = Trim(line.substr(0, equals));
    if (!key.empty()) {
      values[key] = Trim(line.substr(equals + 1));
    }
  }
  return values;
}

}  // namespace

extern "C" void XerengeIOSStartTouchControls();  // ios_touch.mm

extern "C" void RexIOSPrepareLaunch(std::vector<std::string>* args) {
  const char* home = std::getenv("HOME");
  const std::string documents = std::string(home ? home : ".") + "/Documents";
  auto conf = ReadConf(documents + "/xerenge.conf");
  // A key from xerenge.conf, else from the app's page in the Settings app
  // (Settings.bundle; a switch reads as "true"/"false"), else empty.
  NSUserDefaults* settings = NSUserDefaults.standardUserDefaults;
  auto value = [&](const char* key) -> std::string {
    if (auto it = conf.find(key); it != conf.end()) {
      return it->second;
    }
    id setting = [settings objectForKey:@(key)];
    if ([setting isKindOfClass:NSString.class]) {
      return [setting UTF8String];
    }
    if ([setting isKindOfClass:NSNumber.class]) {
      return [setting boolValue] ? "true" : "false";
    }
    return {};
  };

  // The defaults match the Android launcher's.
  if (value("bloom") != "true") {
    setenv("XERENGE_NO_BLOOM", "1", 1);
  }
  if (value("motion_blur") != "true") {
    setenv("XERENGE_NO_MOTION_BLUR", "1", 1);
  }
  for (const char* name : {"XERENGE_D3D_TARGETS", "XERENGE_D3D_UI", "XERENGE_SKIP_LOGOS",
                           "XERENGE_REAL_SHADERS", "XERENGE_D3D_DRAWS", "XERENGE_SECONDARY_TICKS"}) {
    setenv(name, "1", 1);
  }
  // A phone is wider than 16:9. Filling it widens the game's cameras to the
  // screen's shape (widescreen.cpp) and keeps the interface in a 16:9 box;
  // fill_screen = false keeps the console's shape between black bars.
  if (value("fill_screen") == "false") {
    setenv("XERENGE_ASPECT_16_9", "1", 1);
  }
  if (value("fps_counter") == "true") {
    setenv("XERENGE_FPS_SHOW", "1", 1);
  }
  // A phone's native resolution is three times the console's pixels and more:
  // 900 lines keep it sharp at about half the GPU work (and heat) of drawing
  // at the screen's own size. render_resolution = native draws at that. Only
  // the height counts when the screen is filled: the width follows its shape.
  const std::string resolution = value("render_resolution");
  if (resolution.empty()) {
    setenv("XERENGE_RENDER_RESOLUTION", "1600x900", 1);
  } else if (resolution != "native") {
    setenv("XERENGE_RENDER_RESOLUTION", resolution.c_str(), 1);
  }
  // Drawing fewer of the cars and props that are off screen: what traffic
  // costs the render thread. Off unless asked for, as on the desktop.
  if (value("culling") == "true") {
    setenv("XERENGE_CULL", "1", 1);
  }
  // XERENGE_SNAPSHOT_SECONDS (env.XERENGE_SNAPSHOT_SECONDS = 20,40, or from
  // devicectl's --environment-variables) saves frames where Finder can reach
  // them; the renderer's default, logs/, is not writable inside the bundle.
  setenv("XERENGE_SNAPSHOT_DIR", documents.c_str(), 0);
  for (const auto& [key, val] : conf) {
    if (key.rfind("env.", 0) == 0 && key.size() > 4) {
      setenv(key.substr(4).c_str(), val.c_str(), 1);
    }
  }

  if (value("touch_controls") != "false") {
    XerengeIOSStartTouchControls();
  }

  const std::string log_level = value("log_level").empty() ? "info" : value("log_level");
  for (std::string arg : {
           "--game_data_root=" + documents + "/game",
           "--user_data_root=" + documents + "/user",
           std::string("--gpu_plugin=plume"),
           std::string("--gpu_backend=plume"),
           std::string("--no-vulkan_async_skip_incomplete_frames"),
           "--log_level=" + log_level,
           "--log_file=" + documents + "/burnout.log",
           std::string("--log_max_file_size_mb=32"),
           std::string("--log_max_files=3"),
           std::string("--fullscreen"),
       }) {
    args->push_back(std::move(arg));
  }
}
