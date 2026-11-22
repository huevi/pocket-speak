# Pocket Speak

Select text on macOS and press **Option–Escape** to hear it read aloud with Kyutai’s full English Pocket TTS model. The menu bar lets you choose from five voices and set the reading speed. Speech runs on your Mac after the initial model download.

## Build and run

Requires macOS 14 or newer, an Intel Mac with AVX2 or an Apple Silicon Mac, and the Xcode Command Line Tools. The Intel build has been tested on an i7 iMac. Apple Silicon uses the corresponding upstream engine binary and still needs a hardware smoke test.

Install the Command Line Tools with `xcode-select --install` if needed. Build the app from Terminal.

```sh
git clone https://github.com/huevi/pocket-speak.git
cd pocket-speak
./scripts/build.sh
open "build/Pocket Speak.app"
```

For regular use, move the app to your Applications folder before opening it and granting Accessibility access. The build script downloads and verifies the matching upstream Pocket TTS executable. Python, PyTorch, and a paid Apple Developer account are unnecessary.

## First launch

1. Click **Download**. Pocket Speak shows progress for about 252 MB of English model files and five presets. If interrupted, **Retry** reuses the files that already downloaded and passed verification. A partially transferred file downloads again.
2. Click **Play Sample** and make sure you can hear Alba. Choose **Continue**.
3. Open **Accessibility Settings** from the app and turn on Pocket Speak. Permission lets the app read highlighted text and, if needed, copy it briefly. The app detects the grant and advances to the shortcut test.
4. Highlight the sample and press **⌥ Esc**. If macOS reads it with an Apple voice, turn off or reassign **Speak Selection** in **System Settings → Accessibility → Read & Speak**. Press **⌥ Esc** again during reading to stop.

Open **Pocket → Setup…** to revisit setup, **Pocket → Voice** to change the voice, or **Pocket → Speed** to choose a pitch-preserving rate for the next reading. The first read after changing voices may take a little longer because the app reloads the engine for the new voice. The app generates one sentence at a time to avoid feeding audio to the player mid-word.

Model files are stored in `~/Library/Application Support/Pocket Speak/English Model v4`. The engine uses those verified local files to generate speech. Selected text is sent only to the bundled engine over localhost. The setup download contacts Hugging Face and the build fetches the engine from GitHub.

## Signing and sharing

The build script ad-hoc signs the app and its engine on your Mac. That is a local signature with no Apple-issued developer identity. It works for building from source without a paid membership. macOS may require you to re-grant Accessibility when a new ad-hoc build replaces an old one.

This repo distributes source. Downloaded app bundles are subject to Gatekeeper, including checks for an identified developer and notarization. Developer ID signing and notarization are the path to an ordinary direct-download installer outside the Mac App Store. See [Apple’s distribution guide](https://developer.apple.com/macos/distribution/) and [Gatekeeper help](https://support.apple.com/en-us/102445).

## Verify a clean setup

```sh
assets="$(mktemp -d)"
./scripts/build.sh --check download "$assets"
./scripts/build.sh --check offline "$assets"
```

The first check cancels a download after progress is reported, retries, verifies each file, and generates speech for all five voices. The second check starts a fresh engine from those assets with external network access blocked, repeats the five synthesis checks, and plays the onboarding sample.

## Credits

- Pocket Speak source is MIT licensed.
- [Kyutai Pocket TTS](https://github.com/kyutai-labs/pocket-tts) supplies the MIT-licensed engine and the English configuration adapted in `Resources/english.yaml`. The engine’s license is bundled with the app.
- [Kyutai’s public Pocket TTS model files](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning) are published under CC BY 4.0. See [Kyutai’s voice credits](https://huggingface.co/kyutai/tts-voices) for the original voice sources. The app downloads these assets from Kyutai.
