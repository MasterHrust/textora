# Textora

Textora is an open-source macOS writing assistant that helps you rewrite selected text directly inside other apps (mail, chats, browsers, editors, and more).

[Support the project](https://paypal.me/RShytskou)

All AI requests are sent directly from your Mac using your own API key (BYO key).  
This repository does not include a Textora backend proxy.

## Features

- Floating helper near focused text inputs (with Accessibility permission).
- Rewrite modes: `Fix`, `Shorten`, `Formal`, `Humanize`.
- Works in native apps and web/Electron apps (AX + clipboard fallback).
- Per-app text access consent controls.
- First-run setup wizard (API key first, then Accessibility).
- Provider support: OpenAI, Gemini, Claude, and Other OpenAI-compatible APIs.

## Requirements

- macOS 14+
- Xcode 15+
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the Xcode project from `project.yml`

## Repository Structure

```text
apps/macos-app/
  Sources/            Swift source code
  Resources/          Assets and plist files
  Textora.xcodeproj/  Xcode project
  project.yml         XcodeGen project definition
```

## Build and Run

### Xcode

1. Open `apps/macos-app/Textora.xcodeproj`.
2. Select scheme `Textora`.
3. Run the app.

### Regenerate Project (optional)

```bash
cd apps/macos-app
xcodegen generate
```

### Command-line Build

```bash
cd apps/macos-app
xcodebuild -project Textora.xcodeproj -scheme Textora -configuration Debug -sdk macosx build
```

### Release Verification (DMG/App)

After installing `Textora.app`, verify macOS sees the correct app identity:

```bash
plutil -p "/Applications/Textora.app/Contents/Info.plist"
codesign -dv --verbose=4 "/Applications/Textora.app" 2>&1
spctl -a -vv "/Applications/Textora.app"
xattr -l "/Applications/Textora.app"
```

Expected:
- `CFBundleIdentifier` is `com.textora.app`
- `codesign` identifier is `com.textora.app`
- no `com.apple.quarantine` xattr after trusted install path

## First Launch Setup

1. Open quick setup wizard.
2. Add an API key (default provider: OpenAI).
3. Verify connection.
4. Complete setup and grant Accessibility permission.

Provider key links:

- OpenAI: <https://platform.openai.com/api-keys>
- Gemini: <https://aistudio.google.com/app/apikey>
- Claude: <https://console.anthropic.com/settings/keys>

For `Other AI`, set:

- OpenAI-compatible base URL (e.g. `https://api.example.com/v1`)
- model ID
- API token

## Permissions

Textora requires **Accessibility** permission to:

- read selected/focused text reliably
- replace text directly in input fields

You can grant access in macOS Settings under:
`Privacy & Security` -> `Accessibility`.

## Privacy

- API keys are stored locally in the Data Protection Keychain. Textora never falls back to the legacy login keychain.
- Textora does not route your data through an app-owned backend in this repository.
- Your provider's data policies and terms apply when using their API.

## Known Limitations

- Some apps expose limited accessibility metadata, so fallback behavior may be used.
- Auto-apply may be restricted in certain secure or custom text controls.
- Provider-side rate limits and model availability affect response quality and speed.

## Contributing

Contributions are welcome:

1. Create a feature branch.
2. Keep changes focused and documented.
3. Ensure the app builds successfully.
4. Open a pull request with a clear summary and test notes.

## Support

If Textora helps you, you can support development here: [paypal.me/RShytskou](https://paypal.me/RShytskou).

## License

MIT
