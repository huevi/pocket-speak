# Pocket Speak

Pocket Speak reads selected English text aloud on your Mac. Select text and press **Option–Escape** to start. Press it again to stop.

## Install

You need macOS 14 or newer, an Apple Silicon Mac or an Intel Mac with AVX2, and Apple’s Command Line Tools. If needed, install the tools with `xcode-select --install`.

```sh
git clone https://github.com/huevi/pocket-speak.git
cd pocket-speak
./scripts/build.sh
```

Move **build/Pocket Speak.app** to your **Applications** folder, then open it from there.

## First launch

1. Click **Download** to get the English model and five voices (about 252 MB).
2. Click **Play Sample**, then **Continue**.
3. Click **Open Accessibility Settings** and enable Pocket Speak so it can read selected text.
4. Select the sample text and press **Option–Escape** to try it.

## Everyday use

Click the **speech bubble** in the menu bar to change **Voice** or **Speed**, reopen setup, or turn on **Open at Login**. **Stop Speaking** appears while a read is active.

If you hear Apple’s voice instead, open **System Settings → Accessibility → Read & Speak** and turn off or change the shortcut for **Speak Selection**.

## Update an existing install

1. Quit the app from its menu.
2. Keep a backup of the old app outside Applications. Put the new app in the same Applications location, then open it.
3. If setup asks for Accessibility again, remove the old entry under **Privacy & Security → Accessibility** and add the updated app from Applications.

## Privacy and storage

Speech runs offline after setup. Selected text stays on your Mac. Models are stored in `~/Library/Application Support/Pocket Speak/English Model v4`.

## Verify a build

The build is ad-hoc signed. Intel builds have been tested on hardware. Apple Silicon still needs a hardware test.

```sh
assets="$(mktemp -d)"
./scripts/build.sh --check download "$assets"
./scripts/build.sh --check offline "$assets"
```

These checks test download retry, all five voices, and offline sample playback.

## Credits

- App source is [MIT licensed](LICENSE).
- [Kyutai Pocket TTS](https://github.com/kyutai-labs/pocket-tts) provides the MIT-licensed engine.
- The [model files](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning) are licensed CC BY 4.0. See [Kyutai’s voice credits](https://huggingface.co/kyutai/tts-voices).
