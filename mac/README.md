# Hey Aside for macOS

The original menu-bar app: "Hey Jarvis" (or "Hey Aside"), on-device Apple speech recognition, a Dynamic-Island-style overlay at the notch, and Ryan's voice. Requests go to Aside through its CLI.

## Requirements

- macOS 27 or newer on Apple silicon, Xcode command line tools (`xcode-select --install`)
- Aside installed and signed in (the CLI ships with the app at `~/.aside/cli`)

## Build and install

```bash
cd mac
./build.sh install
open ~/Applications/"Hey Aside.app"
```

Grant Microphone and Speech Recognition when asked. To keep those grants across rebuilds, create a self-signed code-signing certificate named **Hey Aside Local Signing** in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing); `build.sh` uses it when present and signs ad hoc otherwise.

Start at login: menu > Launch at Login.

## Settings

Most options are in the menu-bar menu. Others are `defaults` keys on `app.heyaside.mac`, for example:

```bash
defaults write app.heyaside.mac agentModel -string provider/model   # pin Aside sessions to a model (default: Aside's own)
defaults write app.heyaside.mac fastLane -bool false                # turn off the instant-answer lane
defaults write app.heyaside.mac fastModel -string oc/space-bunny-free  # 9router model for instant answers
defaults write app.heyaside.mac jevPath -string ~/aside-phone/tools/jev
```

The instant-answer lane needs 9router configured in Aside as a provider named `9router`, and Aside Phone's Jev door (`ln -s ~/aside-phone/tools/jev ~/.local/bin/jev`). Without them every request simply goes to Aside.

## Tests

```bash
swiftc -O -swift-version 5 -target arm64-apple-macos27.0 -framework AppKit -framework AVFoundation -framework Speech \
  -framework SwiftUI -framework ServiceManagement -framework CoreAudio -framework Metal -framework MetalKit \
  -framework CoreText -framework WebKit Sources/*.swift -o /tmp/HeyAside && /tmp/HeyAside --unit
```

All checks are silent (no microphone, no sound, no Aside session).

Logs: `~/Library/Logs/HeyAside/`.
