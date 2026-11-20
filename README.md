# Swipe — Custom iOS Dictation Keyboard Prototype

A modern Swift / SwiftUI iOS prototype (`iOS 17+`) demonstrating a custom system-wide keyboard (`UIInputViewController`) with **on-device Apple `SFSpeechRecognizer` dictation**.

## Architecture

Because iOS custom keyboard extensions do not have direct `AVAudioSession` microphone access (and run under a strict ~50 MB memory ceiling), **Swipe** uses Apple's sanctioned **Host App + App Group + Darwin IPC** bridge:

1. **`Swipe` (Host App)**
   - Requests Microphone (`AVAudioApplication.requestRecordPermission`) and Speech Recognition (`SFSpeechRecognizer.requestAuthorization`) permissions.
   - Runs `AVAudioEngine` + on-device `SFSpeechAudioBufferRecognitionRequest` (`addsPunctuation = true`, live RMS waveform metering).
   - Registers the `swipe://dictate` URL scheme and `UIBackgroundModes: audio` so once armed on first dictation, the audio session stays warm in the background for up to 10 minutes — subsequent dictations start/stop directly from the keyboard with **zero app switching**.
2. **`SwipeKeyboard` (Keyboard App Extension)**
   - Full QWERTY / Numbers / Symbols SwiftUI keyboard hosted inside `KeyboardViewController`.
   - Top dictation toolbar with warm-session status indicator, one-tap **Dictate** pill, live 16-bar waveform overlay, streaming partial transcript preview, **Keys** toggle, and one-tap **Undo** for the last dictated block.
   - Inserts context-aware formatted text via `textDocumentProxy.insertText(...)` (smart spacing + sentence-start capitalization).
3. **`SwipeShared` (Shared Source Group)**
   - `AppGroupStore` (`group.com.roy.raunak.Swipe`) for sharing `DictationSnapshot`, settings, and history.
   - `DarwinNotificationBridge` (`CFNotificationCenterGetDarwinNotifyCenter`) for instant cross-process wakeups without polling.
   - `TranscriptFormatter` for clean insertion at any cursor position.

## Running in Xcode (macOS + Physical iPhone)

> **Note:** On-device microphone dictation requires a physical iPhone (the iOS Simulator cannot capture real speech reliably for keyboard extensions).

1. Open `Swipe.xcodeproj` in Xcode 15+ (or regenerate via `xcodegen generate` using `project.yml`).
2. Select your **Development Team** under **Signing & Capabilities** for both the `Swipe` and `SwipeKeyboard` targets.
3. Verify the **App Groups** capability (`group.com.roy.raunak.Swipe`) matches across:
   - `Swipe/Swipe.entitlements`
   - `SwipeKeyboard/SwipeKeyboard.entitlements`
   - `SwipeShared/DictationConfig.swift` (`DictationConfig.appGroupID`)
4. Build and run the **`Swipe`** scheme on your iPhone.
5. In the **Swipe** app, grant **Microphone** and **Speech Recognition** permissions.
6. Enable the keyboard in **Settings → General → Keyboard → Keyboards → Add New Keyboard → Swipe**, then tap **Swipe** and enable **Allow Full Access**.
7. Test directly in the app's **Keyboard Sandbox** (or in Messages / Notes): switch via the Globe key and tap **Dictate**.
