# Hey Aside for Windows

A tray app: say **"Hey Jarvis"** (or press **Ctrl+Alt+J**), ask, and Aside does it. A black island at the top centre of the screen shows Jarvis listening, working and talking, with the same blue orb as the Mac version.

## Requirements

- Windows 10 or 11, x64, with a microphone
- [Aside](https://aside.com/download), signed in, and the **Aside CLI** (Aside Settings > Developer, or the signed PowerShell installer in [Aside's developer docs](https://docs.aside.com/help/developers)). Check: `aside --version` in a new terminal.
- Python 3.12 or 3.13: `winget install Python.Python.3.13`
- About 600 MB of disk for packages and models

## Install

```powershell
git clone https://github.com/ThoughtTaken27/hey-aside.git "$HOME\hey-aside"
cd "$HOME\hey-aside\windows"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`-ExecutionPolicy Bypass` applies to that one command only; your system policy is not changed. The script:

1. makes a private Python environment in `windows\.venv`,
2. installs the exact packages in `requirements.txt`, each verified against its SHA-256 hash (the list is generated from `requirements.in`),
3. downloads the wake-word model (openWakeWord, ~6 MB) and the speech-to-text model (Whisper base.en, ~145 MB),
4. adds Hey Aside to your login items (`HKCU\...\Run\HeyAside`, no admin) and starts it.

The first time it listens, Windows may ask for microphone access: allow it (Settings > Privacy & security > Microphone > "Let desktop apps access your microphone").

## Use

- **"Hey Jarvis"**, then your request. A bare "Hey Jarvis" gets "Yes, sir?" and he waits.
- **Ctrl+Alt+J** or click the tray orb: start talking without the wake word, cut Jarvis off while he speaks, or finish your sentence right away.
- Click the island: same as the hotkey.
- Follow-ups for 30 s after an answer need no wake word. "Thanks" / "that's all" / "bye" ends the conversation.
- Within 10 minutes, a new conversation continues the same Aside chat.
- Tray menu: Talk now, Mute microphone, Speak replies, Show Jarvis's words, Start at login, settings, log, Quit.

Voice barge-in is not supported on Windows (there is no system echo cancellation to keep Jarvis from hearing himself). Use the hotkey or a click to interrupt.

## Settings

`%APPDATA%\HeyAside\settings.json` (tray > Open settings file). Restart Hey Aside after editing.

| Key | Default | What it does |
| --- | --- | --- |
| `wakeThreshold` | `0.5` | Lower (0.3) if "Hey Jarvis" is missed, higher (0.7) if it wakes by itself |
| `hotkey` | `ctrl+alt+j` | Any `ctrl/alt/shift/win` + letter, digit, `space` or `f1`-`f24` |
| `silence` | `1.2` | Seconds of quiet that end your sentence |
| `followUpSeconds` | `30` | Follow-up window after an answer |
| `whisperModel` | `base.en` | `small.en` is more accurate and slower |
| `voice` / `rate` | `en-GB-RyanNeural` / `+9%` | Any Edge neural voice |
| `permission` | `ask` | Aside session permission (`ask` = Guard) |
| `agentModel` | empty | Pin Aside sessions to a model (`provider/model`); empty uses Aside's default |
| `asideCli` | empty | Full path to `aside.exe` if it is not found automatically |
| `jev` | empty | Path to Aside Phone's `tools\jev` for ~2 s answers to plain questions (needs Node and the Aside Phone server) |
| `micDevice` | `null` | A device index or name from `python -m sounddevice` |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| No tray orb after install | Check `%LOCALAPPDATA%\HeyAside\Logs\heyaside.log`; run `.venv\Scripts\python -m heyaside --verbose` from this folder to see errors |
| "Aside CLI not found" | Install the CLI, open a new terminal, confirm `aside --version`, or set `asideCli` |
| Never wakes | Microphone permission for desktop apps; the right `micDevice`; lower `wakeThreshold` |
| Robotic voice instead of Ryan | Microsoft's read-aloud service did not answer (no internet, or a service change). Jarvis falls back to Windows' British voice for 5 minutes, then tries Ryan again. Do not upgrade packages by hand: `requirements.txt` is hash-locked |
| Answers are cut short | By design: speech is capped at a few sentences; the full answer is in the Aside chat |

## Uninstall

```powershell
cd "$HOME\hey-aside\windows"
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the login entry, stops the app, and deletes its settings, models and logs. Then delete the folder.

## Develop

```powershell
.venv\Scripts\python -m pip install pytest==9.1.1
.venv\Scripts\python -m pytest -q tests
```
