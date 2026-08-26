<p align="center">
  <img src="icon/icon_design.png" width="140" alt="OpenVoice" />
</p>

<h1 align="center">OpenVoice</h1>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  No account, no server — choose OpenAI, Google, OpenCode Zen/Go, or local Ollama.<br/>
  Cloud requests go directly to the selected provider; keys, glossary, and history stay on your Mac.
</p>

---

## Installation

1. Download [OpenVoice.dmg](../../releases/latest);
2. Open it and drag **OpenVoice** into the **Applications** folder;
3. First launch: in Applications, **right-click OpenVoice → Open** (the app is not yet Apple-notarized, so double-clicking directly will be blocked).

## Setup

A guided setup walks you through everything on first launch:

1. **Model source** — choose OpenAI, Google, OpenCode Zen/Go, or local Ollama. Cloud API keys are stored only in your Mac's Keychain; Ollama requires no key;
2. **Microphone access** — used only while you are speaking;
3. **Accessibility access** — required for the global hotkey and for writing text at the cursor position.

One more system setting: **System Settings → Keyboard → "Press 🌐 key" → "Do nothing"**, otherwise Fn triggers the built-in system dictation.

Once done, the OpenVoice icon appears in the menu bar and you're ready to go.

## Usage

| Action | Keys |
|---|---|
| Start / end voice input | `Fn` |
| Translation input (speak Chinese, get English) | Start with `Fn + Left Shift`, end with `Fn` |
| Cancel current recording | `Esc` |

While speaking, a small floating bar with a live volume waveform appears near the bottom of the screen. Press Fn again, wait a second or two, and the polished text appears right at your cursor.

A few handy details:

- **Command selected text**: select some text, press Fn and say "translate this into Chinese", "make it shorter", or "turn this into a list" — the selection is replaced in place;
- **Translation language**: the target language can be switched temporarily from the floating bar; the default is configurable in Settings;
- **Glossary**: add names, project names, and commonly misheard words under Settings → Glossary, and recognition will prefer your spelling;
- **Transcription history**: menu bar icon → History; every entry can be copied with one click;
- **Context**: by default a small amount of text near the cursor is read to improve recognition; each item can be turned off individually under Settings → Privacy;
- A single recording is capped at 10 minutes; during the last minute the floating bar shows a countdown, then transcribes automatically so nothing is lost.

Cost depends on the selected provider and model. OpenCode Go uses its subscription allowance, while Ollama runs locally without API charges.

## License

Free for personal and other non-commercial use ([PolyForm Noncommercial 1.0.0](LICENSE.md)); contact the author before any commercial use.
