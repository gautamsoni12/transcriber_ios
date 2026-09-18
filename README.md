# Transcriber

POC voice-notes app: record audio, transcribe it four different ways, and
compare what the engines actually produce.

```
transcriber/   SwiftUI app (iOS 26+, SwiftData, SPM)
```

The FastAPI service behind the Cloud and Auto modes lives in its own repository:
[gautamsoni12/transcriber_backend](https://github.com/gautamsoni12/transcriber_backend). Clone it alongside this one
if you want to run the full stack locally.

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

**Backend** — see the [backend repo](https://github.com/gautamsoni12/transcriber_backend) for local `uvicorn` and
Cloud Run deploy. The app works without it: Apple, Whisper and Auto are all
fully offline.

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

The deployed backend is:

```
https://transcriber-backend-226858186002.us-central1.run.app
```

Its `API_KEY` is on the Cloud Run service under **Containers → Variables &
Secrets**. Don't commit it — `Config.plist` is gitignored for that reason, and
anything in it is extractable from a built IPA.

The Cloud mode is optional — Apple, Whisper and Auto all work with no backend at
all.

## Metrics

Every run records model name, latency, word count, per-stage timings, and
confidence where the engine exposes it (Apple's `transcriptionConfidence`
attribute, Whisper's segment log-probabilities; the Claude polish pass has no
confidence to report). The note detail and compare screens show all of it, and
the same timings go to `os_log` under the `com.expandlabs.transcriber` subsystem.

## Compare view

From any note, **Run all engines** transcribes the same recording with Apple,
Whisper and Cloud, then aligns the three transcripts word by word (progressive
LCS merge in [WordDiff.swift](transcriber/transcriber/Utils/WordDiff.swift)) and
highlights every position where they disagree.

## Verifying

### Word diff

```bash
./transcriber/Tools/verify-worddiff.sh
```

Compiles `WordDiff` standalone against the macOS toolchain and runs the
alignment cases. No simulator, no test target.

### Engines

The simulator can't feed the microphone, so DEBUG builds take a `--selftest`
flag that runs a bundled speech sample (`Resources/sample.wav`) through one
engine and prints the transcript, stage timings, confidence, and agreement
against the known text:

```bash
xcrun simctl launch --console-pty booted com.expandlabs.transcriber --selftest whisper

# Cloud/Auto can be pointed at a backend without going through Settings:
xcrun simctl launch --console-pty booted com.expandlabs.transcriber --selftest cloud \
  --backend http://localhost:8000 --api-key "$API_KEY"
```

Where each engine stands:

| Engine | Simulator | Notes |
|---|---|---|
| Whisper | passes | 100% agreement with the sample; `download 85s · load 5s · transcribe 3s` on first run, ~3s after |
| Cloud | passes | Verified against a local container: upload, multipart, auth, and error mapping |
| Apple | device only | `SpeechTranscriber.isAvailable` is false in the simulator; the app reports that rather than failing deeper |
| Auto | device only | Its local half is the Apple engine |

### Backend

Its tests and the offline container check live in the
[backend repo](https://github.com/gautamsoni12/transcriber_backend).

## Manual test pass

On a real device (Apple and Auto need one):

1. **Settings** — leave the backend blank first. Apple, Whisper and Auto should
   all still work; Cloud should say it needs configuring.
2. **Apple** — record a few sentences. First run downloads the locale model with
   a progress bar; later runs should be near-instant. Turn on airplane mode and
   repeat: it must still work.
3. **Whisper** — same, but expect a ~480 MB download on first use. Switch to
   `base` in Settings and confirm the next run downloads the smaller model.
4. **Cloud** — fill in the backend URL and key, tap *Test connection*, then
   record. You should get both a raw and a polished transcript, plus a title and
   summary.
5. **Auto** — record while online: the Apple transcript should appear first and
   then be replaced by the polished version. Repeat in airplane mode and confirm
   it keeps the local result instead of erroring.
6. **Failure handling** — record with Cloud while offline. The recording should
   be held, with the choice to retry, save the audio without a transcript, or
   discard.
7. **Compare** — open a note, tap *Run all engines*, and check the three
   transcripts, the highlighted disagreements, and the metrics table.

## POC scope

No accounts, no sync, no sharing. Minimal styling. One smoke test per backend
endpoint. Model downloads happen on first use rather than being bundled — except
the backend's ASR weights, which are baked into the container image so Cloud Run
cold starts don't pay for them.

`Resources/sample.wav` (200 KB) ships in every build; only the DEBUG-only
self-test reads it.
