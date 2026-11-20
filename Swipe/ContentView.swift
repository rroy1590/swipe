import AVFoundation
import Speech
import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: DictationEngine
    @State private var sandboxText: String = ""
    @State private var showSettings: Bool = false
    @FocusState private var isSandboxFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if engine.launchedFromKeyboardBanner && engine.phase == .listening {
                        returnToPreviousAppBanner
                    }

                    liveSessionCard
                    setupChecklistCard
                    keyboardSandboxCard

                    if !engine.history.isEmpty {
                        recentHistoryCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Swipe Dictation")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(engine: engine)
            }
        }
    }

    // MARK: - Banners & Cards

    private var returnToPreviousAppBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation is live")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Swipe back to your app — Swipe will stream text straight to your keyboard.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var liveSessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if engine.isOnDeviceSupported {
                    Label("On-Device", systemImage: "lock.shield")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Live 16-bar waveform
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(engine.audioLevels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(engine.phase == .listening ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(6, CGFloat(level) * 44))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 6)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !engine.partialText.isEmpty {
                Text(engine.partialText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let error = engine.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button {
                    if engine.phase == .listening {
                        engine.stopDictation()
                    } else {
                        engine.startDictation()
                    }
                } label: {
                    Label(
                        engine.phase == .listening ? "Stop Dictation" : "Test Dictation",
                        systemImage: engine.phase == .listening ? "stop.fill" : "mic.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.phase == .listening ? .red : .accentColor)
                .disabled(!engine.hasAllPermissions)

                if engine.isBackgroundArmed {
                    Button {
                        engine.disarmBackgroundSession()
                    } label: {
                        Image(systemName: "power")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Disarm background audio session")
                } else {
                    Button {
                        engine.armBackgroundSession()
                    } label: {
                        Text("Arm")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!engine.hasAllPermissions)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupChecklistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.headline)

            PermissionRow(
                title: "Microphone Access",
                subtitle: "Required so Swipe can capture your voice.",
                isGranted: engine.micPermission == .granted,
                actionTitle: engine.micPermission == .denied ? "Settings" : "Grant"
            ) {
                if engine.micPermission == .denied {
                    openSystemSettings()
                } else {
                    Task { await engine.requestMicrophonePermission() }
                }
            }

            Divider()

            PermissionRow(
                title: "Speech Recognition",
                subtitle: "Uses Apple's on-device SFSpeechRecognizer (no API key).",
                isGranted: engine.speechPermission == .authorized,
                actionTitle: engine.speechPermission == .denied ? "Settings" : "Grant"
            ) {
                if engine.speechPermission == .denied {
                    openSystemSettings()
                } else {
                    Task { await engine.requestSpeechPermission() }
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Swipe Keyboard")
                        .font(.subheadline.weight(.semibold))
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Swipe, then enable Allow Full Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings") {
                    openSystemSettings()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var keyboardSandboxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keyboard Sandbox")
                    .font(.headline)
                Spacer()
                if !sandboxText.isEmpty {
                    Button("Clear") {
                        sandboxText = ""
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            Text("Tap below, switch to Swipe via the Globe key, and test typing + dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $sandboxText)
                .focused($isSandboxFocused)
                .frame(minHeight: 110)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var recentHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Dictations")
                    .font(.headline)
                Spacer()
                Button("Clear", role: .destructive) {
                    engine.clearHistory()
                }
                .font(.caption.weight(.semibold))
            }

            ForEach(engine.history.prefix(5)) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text)
                        .font(.subheadline)
                    HStack {
                        Text(item.createdAt, style: .relative)
                        Text("·")
                        Text(String(format: "%.1fs", item.durationSeconds))
                        if item.isOnDevice {
                            Text("· On-Device")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

                if item.id != engine.history.prefix(5).last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Helpers

    private var statusTitle: String {
        switch engine.phase {
        case .listening: return "Listening"
        case .processing: return "Finalizing…"
        case .error: return "Attention Needed"
        case .ready, .idle, .launchingHost:
            return engine.isBackgroundArmed ? "Armed · Instant Keyboard Dictation" : "Idle"
        }
    }

    private var statusColor: Color {
        switch engine.phase {
        case .listening: return .red
        case .processing: return .orange
        case .error: return .red
        case .ready, .idle, .launchingHost:
            return engine.isBackgroundArmed ? .green : .secondary
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(isGranted ? .green : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var engine: DictationEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Recognition") {
                    Toggle("Prefer On-Device Recognition", isOn: $engine.settings.preferOnDeviceRecognition)
                    Toggle("Keep Session Warm in Background", isOn: $engine.settings.keepWarmInBackground)
                }

                Section("Text Formatting") {
                    Toggle("Auto-Capitalize Sentences", isOn: $engine.settings.autoCapitalize)
                    Toggle("Smart Punctuation Spacing", isOn: $engine.settings.smartPunctuationTidy)
                }

                Section("About Background Mode") {
                    Text("When enabled, Swipe keeps its audio session warm for up to 10 minutes after your first dictation so subsequent taps on the keyboard mic start recording instantly without switching apps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dictation Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        engine.saveSettings()
                        dismiss()
                    }
                }
            }
        }
    }
}
