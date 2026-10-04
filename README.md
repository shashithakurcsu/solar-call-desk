# Solar Call Desk

An experimental native macOS app for AI-assisted phone conversations. Built with SwiftUI, Core Audio, and the OpenAI Realtime API, with a local command interface for a user-authorized agent.

**Status: prototype.** Two-way voice and individual Phone button actions have been exercised during development. The complete automatic voice → dial → conversation → hangup workflow still needs end-to-end live validation. Phone UI control supports one observed display layout and is not a general telephony API.

## Features

- **Call desk:** review a number and hand it to Apple's Phone app; launch the installed WhatsApp app separately.
- **Voice lab:** local microphone/speaker rehearsal or an external audio bridge using two isolated virtual devices.
- **Realtime conversation:** streaming speech, input/AI transcripts, interruption handling, one introduction, and a controlled farewell.
- **Remembered setup:** audio device UIDs, route acknowledgements, and API audio/cost consent. Optional API-key persistence uses macOS Keychain.
- **Local agent commands:** prepare one number/message, start once, request stop/hangup, and retrieve that job's transcript for a summary.
- **Guarded Phone controls:** verify the exact number using local OCR before pressing Call or Hang Up. Ambiguous views and stale images stop the operation.
- **Offline checks:** synthetic audio, call lifecycle, command/IPC, credential persistence, and visual-control tests.

The default voice identity is **“I am Nox, an AI assistant.”** Conversation instructions are editable in Voice lab. The shared defaults for agent calls live in `Sources/VoiceBridge/VoiceConversationInstructions.swift`.

## Requirements

- An Apple Silicon Mac for the included test scripts, which currently target `arm64`.
- Swift 6 or newer and a macOS SDK with the system frameworks used by the app. The package deployment target is macOS 14.
- Apple's Phone app and a working calling configuration for Phone handoff. Availability depends on the installed OS and account/carrier setup.
- Your own OpenAI API key and access to the configured Realtime model for voice sessions. API usage is billed separately from ChatGPT.
- For external calls: two independently configured virtual audio buses. The current diagnostic recognizes primary BlackHole 2ch and 16ch devices. Drivers are installed separately and are not included here.

The visual Phone controller currently requires the observed **1496 × 967 display geometry**, the known Phone notification layout, and the same notification window throughout a job. Other layouts are rejected. The Mac must be awake and logged in, with Phone frontmost during control operations. Locked/sleeping operation, away-from-iPhone carrier behavior, and WhatsApp audio routing remain unverified.

## Build

```sh
git clone https://github.com/shashithakurcsu/solar-call-desk.git
cd solar-call-desk
./scripts/build-app.sh
open "dist/Solar Call Desk.app"
```

The scripts use `DEVELOPER_DIR` when provided, otherwise `xcode-select -p`. To use an installed Command Line Tools toolchain explicitly:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
./scripts/build-app.sh
```

The build creates a local app and ZIP under `dist/`. With no local signing configuration, it uses ad-hoc signing. This can cause macOS to ask for permissions again after a rebuild. To review stable local signing options, run:

```sh
python3 scripts/configure-local-signing.py --help
python3 scripts/configure-local-signing.py
```

The second command is a dry run. Creating or choosing a signing identity is an explicit separate action. Never commit signing configuration, certificates with private keys, or Keychain exports. Release binaries are not provided by this initial source release.

Optional generated app icon:

```sh
xcrun swift scripts/generate-icon.swift scripts/AppIcon.iconset
python3 scripts/pack-icon.py
./scripts/build-app.sh
```

The icon is generated from the included drawing code; no screenshot or personal asset is needed.

## Set up voice

1. Open **Voice lab**. Use its permission-only **Allow microphone access** button if needed; no Start/Stop rehearsal is required to grant access.
2. Enter your API key in the app. Saving it in Keychain is optional and requires an explicit choice. No key belongs in the CLI or repository.
3. Choose **Local rehearsal** for microphone/headphone conversation, or **External audio bridge** for a configured call route.
4. For the tested external arrangement, set Voice lab input to BlackHole 2ch and output to BlackHole 16ch. In the calling app, select the reciprocal output/input:

   ```text
   Calling app output → BlackHole 2ch  → Voice lab input
   Voice lab output   → BlackHole 16ch → Calling app microphone
   ```

5. Acknowledge audio upload/costs and the exact isolated route. Those choices are remembered; changing the route requires a new acknowledgement.
6. Start a voice rehearsal manually, or leave Voice lab idle for an agent-controlled job.

Starting an API session sends the selected input audio and conversation instructions to OpenAI. Local device discovery does not record audio. The virtual-bus diagnostic uses local synthetic tones only and must be run with no calls or recordings using those devices. Its acknowledgement is deliberately per-test.

The default model and voice are defined in `VoiceBridgeConfiguration` in `Sources/VoiceBridge/VoiceTypes.swift`; adjust them for the models available to your API account.

## Agent-controlled calls

Enable **Sambha control** in Connections to expose the same-user Unix socket. “Sambha” is the local agent integration name; the app does not bundle an agent, a ChatGPT account, or a hosted remote service.

For automatic Phone controls, also grant the app **Accessibility** and **Screen Recording** through Connections → Phone automation setup. Those setup buttons do not dial or start audio. Phone popup images are processed locally in memory.

See [agent operating instructions](Sambha/README.md) and the [machine-readable contract](Sambha/OPERATING-CONTRACT.json). Only start a job after the user authorizes its recipient, verified number, and message. A user-owned agent with access to this Mac can invoke the CLI; this repository provides no public network listener.

Successful URL handoff, generated speech, recipient acknowledgement, and hangup UI evidence are distinct. `hangup_requested_panel_closed` means a verified Hang Up click was posted and the popup then closed; it does not independently prove carrier termination. Do not retry an ambiguous call.

## Tests

These commands use synthetic data and fake providers. They do not place calls, start audio capture, contact the Realtime API, or prompt for OS permissions:

```sh
./scripts/test.sh
./scripts/phone-control-self-check.sh
./scripts/phone-visual-self-check.sh
python3 scripts/local-signing-self-check.py
```

`test.sh` runs CallCore, native callback, voice, command/IPC, and persistence checks. The command tests create local test Unix sockets. SwiftPM tests are also available with `swift test` on a fully configured toolchain.

The visual test runner optionally accepts explicitly supplied local screenshot fixtures. No real call screenshots are included in this repository. Default tests use generated fixtures. Scripts named `Run*`, `Inspect*`, `VirtualBusPreflight`, and the HAL test launchers are developer diagnostics; review them before use. Live diagnostic modes require their explicit run flag and may access audio devices.

## Code map

| Module | Responsibility |
| --- | --- |
| `CallCore` | Number validation and call lifecycle evidence |
| `HALAudioCore` | Native callback buffers and Core Audio primitives |
| `VoiceBridge` | Device routing, Realtime protocol, playback and transcript state |
| `PhoneControl` | Bounded Accessibility inspection and local visual button control |
| `CallAutomation` | Per-job deduplication and private Unix-socket commands |
| `SolarCallDesk` | SwiftUI app and runtime integration |

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and [SECURITY.md](SECURITY.md) for privacy boundaries.

## Contributors

Created and maintained by [shashithakurcsu](https://github.com/shashithakurcsu), with AI development assistance from **Codex (OpenAI)** and troubleshooting and design-review guidance from **Claude (Anthropic)**. See [CONTRIBUTORS.md](CONTRIBUTORS.md) for contribution details.

## License

Project source is released under the [MIT License](LICENSE). External system frameworks, services, and separately installed drivers retain their own licenses and terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
