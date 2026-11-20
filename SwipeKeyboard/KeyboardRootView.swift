import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var viewModel: KeyboardViewModel

    var body: some View {
        VStack(spacing: 6) {
            topDictationBar

            if viewModel.shouldShowDictationOverlay {
                dictationOverlayView
            } else {
                keyboardRowsView
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Dictation & Utility Bar

    private var topDictationBar: some View {
        HStack(spacing: 8) {
            if let notice = viewModel.inlineNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if viewModel.isDictating && viewModel.showKeysWhileDictating {
                Button {
                    viewModel.showKeysWhileDictating = false
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                        Text(viewModel.snapshot.partialText.isEmpty ? "Listening…" : viewModel.snapshot.partialText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isHostSessionWarm ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 7, height: 7)
                    Text(viewModel.isHostSessionWarm ? "Instant Mic Ready" : "Swipe Dictation")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 6)

                Spacer(minLength: 4)

                if viewModel.lastInsertedDictationCount > 0 {
                    Button {
                        viewModel.undoLastDictation()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                viewModel.toggleDictation()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.isDictating ? "stop.fill" : "mic.fill")
                        .font(.caption.weight(.bold))
                    Text(viewModel.isDictating ? "Stop" : "Dictate")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(viewModel.isDictating ? Color.red : Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 36)
    }

    // MARK: - Active Dictation Panel

    private var dictationOverlayView: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.snapshot.phase == .listening ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(dictationStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.showKeysWhileDictating = true
                } label: {
                    Label("Keys", systemImage: "keyboard")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Live 16-bar waveform driven by host app RMS audio levels
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(viewModel.snapshot.audioLevels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(viewModel.snapshot.phase == .listening ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(6, CGFloat(level) * 52))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: 56)
            .padding(.horizontal, 12)

            Text(
                viewModel.snapshot.partialText.isEmpty
                    ? (viewModel.snapshot.phase == .launchingHost
                        ? "Switching to Swipe once to arm the microphone…"
                        : "Speak naturally — live text will appear here")
                    : viewModel.snapshot.partialText
            )
            .font(.subheadline)
            .foregroundStyle(viewModel.snapshot.partialText.isEmpty ? .secondary : .primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, 12)

            HStack(spacing: 10) {
                if viewModel.needsInputModeSwitchKey {
                    ActionKeyButton(systemImage: "globe", width: 44) {
                        viewModel.advanceInputMode()
                    }
                }

                Button {
                    viewModel.cancelDictation()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.stopDictation()
                } label: {
                    Label(
                        viewModel.snapshot.phase == .processing ? "Finalizing…" : "Done & Insert",
                        systemImage: "checkmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.snapshot.phase == .processing)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dictationStatusText: String {
        switch viewModel.snapshot.phase {
        case .launchingHost: return "Opening Swipe…"
        case .listening:
            return viewModel.snapshot.isOnDevice ? "Listening · On-Device" : "Listening"
        case .processing: return "Finalizing transcript…"
        default: return "Dictation"
        }
    }

    // MARK: - QWERTY / Numbers / Symbols Rows

    private var keyboardRowsView: some View {
        let rows: [[String]] = {
            switch viewModel.layoutMode {
            case .letters: return viewModel.letterRows
            case .numbers: return viewModel.numberRows
            case .symbols: return viewModel.symbolRows
            }
        }()

        return VStack(spacing: 9) {
            // Row 1
            HStack(spacing: 5) {
                ForEach(rows[0], id: \.self) { key in
                    CharacterKeyButton(label: key) {
                        viewModel.insertCharacter(key)
                    }
                }
            }

            // Row 2
            HStack(spacing: 5) {
                if viewModel.layoutMode == .letters {
                    Spacer(minLength: 12)
                }
                ForEach(rows[1], id: \.self) { key in
                    CharacterKeyButton(label: key) {
                        viewModel.insertCharacter(key)
                    }
                }
                if viewModel.layoutMode == .letters {
                    Spacer(minLength: 12)
                }
            }

            // Row 3 (Shift / Symbols + keys + Backspace)
            HStack(spacing: 5) {
                if viewModel.layoutMode == .letters {
                    ActionKeyButton(
                        systemImage: shiftIconName,
                        isHighlighted: viewModel.shiftState != .lowercase,
                        width: 42
                    ) {
                        viewModel.tapShift()
                    }
                } else {
                    ActionKeyButton(
                        title: viewModel.layoutMode == .numbers ? "#+=" : "123",
                        width: 42
                    ) {
                        viewModel.toggleSymbolsKey()
                    }
                }

                HStack(spacing: 5) {
                    ForEach(rows[2], id: \.self) { key in
                        CharacterKeyButton(label: key) {
                            viewModel.insertCharacter(key)
                        }
                    }
                }

                BackspaceKeyButton(
                    onPressStart: { viewModel.startBackspaceRepeat() },
                    onPressEnd: { viewModel.stopBackspaceRepeat() }
                )
            }

            // Row 4 (123/ABC, Globe, Space, Return)
            HStack(spacing: 5) {
                ActionKeyButton(
                    title: viewModel.layoutMode == .letters ? "123" : "ABC",
                    width: 48
                ) {
                    viewModel.toggleModeKey()
                }

                if viewModel.needsInputModeSwitchKey {
                    ActionKeyButton(systemImage: "globe", width: 42) {
                        viewModel.advanceInputMode()
                    }
                }

                Button {
                    viewModel.tapSpace()
                } label: {
                    Text("space")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(keySurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
                }
                .buttonStyle(.plain)

                ActionKeyButton(title: "return", width: 74) {
                    viewModel.tapReturn()
                }
            }
        }
    }

    private var shiftIconName: String {
        switch viewModel.shiftState {
        case .lowercase: return "shift"
        case .shifted: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }

    private var keySurfaceColor: Color {
        Color(.systemBackground)
    }
}

// MARK: - Keycap Components

private struct CharacterKeyButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
        }
        .buttonStyle(.plain)
    }
}

private struct ActionKeyButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var isHighlighted: Bool = false
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .medium))
                } else if let title {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(isHighlighted ? Color(.systemBackground) : .primary)
            .frame(width: width, height: 42)
            .background(
                isHighlighted ? Color.primary : Color(.systemGray4),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
        }
        .buttonStyle(.plain)
    }
}

private struct BackspaceKeyButton: View {
    let onPressStart: () -> Void
    let onPressEnd: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 42, height: 42)
            .background(
                isPressed ? Color(.systemGray3) : Color(.systemGray4),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPressStart()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onPressEnd()
                    }
            )
    }
}
