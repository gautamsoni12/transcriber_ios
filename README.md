# Transcriber

POC voice-notes app: record audio, transcribe it four different ways, and
compare what the engines actually produce.

```
transcriber/          SwiftUI app (iOS 26+, SwiftData, SPM)
transcriber_backend/  FastAPI service (Python 3.12, Cloud Run)
```

## The four modes

| Mode | What runs | Network |
|---|---|---|
| **Local (Apple)** | iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`; model fetched once via `AssetInventory` | offline |
| **Local (Whisper)** | WhisperKit CoreML, `openai_whisper-small` (`base` optional in Settings) | offline |
| **Cloud** | Upload to the backend: faster-whisper `small` then Claude polishes it | required |
| **Auto** | Apple locally for an instant result, then Claude improves it if you're online | optional |

Every engine sits behind one `TranscriptionService` protocol
([TranscriptionService.swift](transcriber/transcriber/Services/TranscriptionService.swift));
nothing in the UI imports `Speech` or `WhisperKit`.

## Layout

```
transcriber/transcriber/
  App/        app entry + SwiftData container
  Config/     AppConfig (UserDefaults) + Keychain wrapper
  Models/     Note, EngineRun, TranscriptionEngine
  Services/   recording, playback, the four engines, backend client
  Utils/      logging + stage timing, word-level diff
  Views/      notes list, record, detail, compare, settings
```

## Getting started

**Backend** — see [transcriber_backend/README.md](transcriber_backend/README.md)
for local `uvicorn` and Cloud Run deploy.

**App** — open `transcriber/transcriber.xcodeproj` and run. Xcode resolves
WhisperKit on first build.

Or from the command line:

```bash
xcodebuild -project transcriber/transcriber.xcodeproj -scheme transcriber \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
```

### Configuration

No URL or key is compiled in. Either type them into the in-app **Settings**
screen, or pre-seed first launch by copying
`transcriber/transcriber/Resources/Config.example.plist` to `Config.plist`
(gitignored) and filling it in. The API key lands in the Keychain either way.

The Cloud mode is optional — Apple, Whisper and Auto all work with no backend at
all.

## Metrics

Every run records model name, latency, word count, per-stage timings, and
confidence where the engine exposes it (Apple's `transcriptionConfidence`
attribute, Whisper's segment log-probabilities; the Claude polish pass has no
confidence to report). The note detail and compare screens show all of it, and
the same timings go to `os_log` under the `com.gotham.transcriber` subsystem.

## Compare view

From any note, **Run all engines** transcribes the same recording with Apple,
Whisper and Cloud, then aligns the three transcripts word by word (progressive
LCS merge in [WordDiff.swift](transcriber/transcriber/Utils/WordDiff.swift)) and
highlights every position where they disagree.

## POC scope

No accounts, no sync, no sharing. Minimal styling. One smoke test per backend
endpoint. Model downloads are on first use, not bundled.
