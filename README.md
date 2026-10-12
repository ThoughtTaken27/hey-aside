# Hey Aside (Jarvis)

Say **"Hey Jarvis"**, ask for anything, and your [Aside](https://aside.com) agent does it. Jarvis shows what it is doing in a small black island at the top of the screen and reads the answer back in a British voice ("Ryan").

Jarvis is a thin voice front end: the real work (browsing, email, calendar, school sites, memory, skills) is done by Aside itself, through its official CLI. Nothing here replaces or reimplements the agent.

| | Folder | Built with | Status |
| --- | --- | --- | --- |
| **Windows 10/11** | [`windows/`](windows/) | Python + Qt, offline wake word and speech-to-text | new port; same flow and look as the Mac app |
| **macOS 27+ (Apple silicon)** | [`mac/`](mac/) | Swift, Apple's on-device speech | the original |

## How a request flows

```text
"Hey Jarvis" (on-device wake word)
   -> you talk; it stops listening ~1.2 s after you finish
   -> speech to text on this computer (no audio leaves it)
   -> aside --permission ask "<your words + voice-mode instructions>"   (or resumes the same chat for follow-ups)
   -> the island shows Aside's steps ("Opening the calendar")
   -> the answer, trimmed for speech, is read aloud by Ryan
   -> 30 s of follow-up listening, no wake word needed; "thanks" or "that's all" ends it
```

While Aside works you can say "Hey Jarvis, what are you doing?", "stop", "actually, ..." (steers it), or ask for something else (queued for after).

## Privacy and safety

- Microphone audio is processed on your computer and never saved or uploaded. Only the text of what you asked goes to Aside, exactly as if you typed it.
- Only the reply text goes to the speech service (Microsoft Edge's read-aloud voice). If that service is down, Windows/macOS speak with a built-in voice instead.
- Aside sessions start in **Guard** permission (`--permission ask`): Aside asks before touching anything outside its usual scope. Change it only if you understand Aside's permission modes.
- Mute really releases the microphone.
- No API keys, tokens or accounts are stored by Jarvis. It uses the Aside app you are already signed in to.

## Optional: instant answers

With [Aside Phone](https://github.com/ThoughtTaken27/aside-phone) running and 9router set up, plain questions ("what's 17 times 23") can be answered in about two seconds through its `tools/jev` command instead of a full Aside session. See each platform's README.

## Credits

- The Mac orb is a native Metal port of the Fluid Orb from [Rare UI](https://www.rareui.com) (MIT with Commons Clause and attribution).
- Wake word: [openWakeWord](https://github.com/dscripka/openWakeWord). Speech to text: [faster-whisper](https://github.com/SYSTRAN/faster-whisper). Voice: [edge-tts](https://github.com/rany2/edge-tts).

## License

MIT for this code. Models downloaded at install time keep their licenses (openWakeWord's pretrained "hey jarvis": CC BY-NC-SA 4.0, personal non-commercial use; Whisper: MIT).
