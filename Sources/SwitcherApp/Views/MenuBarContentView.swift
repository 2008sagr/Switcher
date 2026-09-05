import SwiftUI
import SwitcherCore

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettingsAction

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            HStack {
                Image(systemName: "keyboard")
                    .foregroundColor(.accentColor)
                Text("Switcher")
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .help(statusHelp)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // ── Main toggle + warnings ────────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label(
                        appState.isEnabled ? "Активен" : "На паузе",
                        systemImage: appState.isEnabled ? "checkmark.circle.fill" : "pause.circle"
                    )
                    .foregroundColor(appState.isEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $appState.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if !appState.hasAccessibility {
                    warningBanner(
                        icon: "exclamationmark.triangle.fill", color: .orange,
                        text: "Нужен доступ"
                    ) {
                        Button("Открыть") { openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent).controlSize(.mini)
                    }
                } else if !appState.engineRunning && appState.isEnabled {
                    warningBanner(
                        icon: "exclamationmark.circle.fill", color: .red,
                        text: "Движок остановлен"
                    ) {
                        Button("Перезапустить") { appState.engine.start() }
                            .buttonStyle(.borderedProminent).controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // ── Last switch + Undo ────────────────────────────────────────────
            if !appState.lastSwitchedWord.isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(appState.lastSwitchedWord)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(appState.lastSwitch?.replacedWith ?? "")
                                .font(.callout.monospaced())
                                .foregroundColor(.accentColor)
                                .lineLimit(1)
                        }
                        Text("последняя замена · \(appState.switchCount) всего")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Undo button (visible for 5 s after switch)
                    if appState.canUndo {
                        Button {
                            appState.engine.performUndoFromUI()
                            appState.lastSwitch = nil
                        } label: {
                            Label("Отменить", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Отменить замену (двойной Shift)")
                    } else {
                        // "Add to exceptions" button
                        if !appState.exclusions.contains(appState.lastSwitchedWord.lowercased()) {
                            Button {
                                appState.addException(appState.lastSwitchedWord)
                            } label: {
                                Image(systemName: "hand.raised")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Добавить «\(appState.lastSwitchedWord)» в исключения — больше не будет переключаться")
                        } else {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .help("Уже в исключениях")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            // ── Quick toggles ─────────────────────────────────────────────────
            VStack(spacing: 4) {
                QuickToggleRow(icon: "wand.and.sparkles", label: "Автопереключение",  isOn: $appState.autoSwitchEnabled)
                QuickToggleRow(icon: "shift.fill",         label: "Двойной Shift",     isOn: $appState.doubleShiftEnabled)
                QuickToggleRow(icon: "character.cursor.ibeam", label: "Конвертация выделенного",
                               isOn: $appState.convertSelectionEnabled)
                    .disabled(!appState.doubleShiftEnabled)
                    .opacity(appState.doubleShiftEnabled ? 1 : 0.5)
                    .help(appState.doubleShiftEnabled
                          ? "Двойной Shift на выделенном тексте меняет его раскладку на противоположную"
                          : "Требует включённого «Двойного Shift»")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // ── Footer ────────────────────────────────────────────────────────
            HStack {
                Button { openSettings() } label: {
                    Label("Настройки", systemImage: "gearshape").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Выйти", systemImage: "power").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 290)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func warningBanner<A: View>(icon: String, color: Color, text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.caption)
            Text(text).font(.caption).foregroundColor(.secondary)
            Spacer()
            action()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
        .cornerRadius(7)
    }

    // MARK: - Status

    private var statusColor: Color {
        if !appState.hasAccessibility { return .orange }
        if !appState.isEnabled        { return .secondary }
        if appState.engineRunning     { return .green }
        return .red
    }

    private var statusText: String {
        if !appState.hasAccessibility { return "Нет доступа" }
        if !appState.isEnabled        { return "На паузе" }
        if appState.engineRunning     { return "Активен" }
        return "Остановлен"
    }

    private var statusHelp: String {
        if !appState.hasAccessibility { return "Требуется доступ к специальным возможностям" }
        if !appState.isEnabled        { return "Switcher приостановлен" }
        if appState.engineRunning     { return "Движок активен и отслеживает ввод" }
        return "Движок не запустился — нажмите «Перезапустить»"
    }

    // MARK: - Actions

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettingsAction()
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Quick toggle row

struct QuickToggleRow: View {
    let icon:  String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(.accentColor).frame(width: 16)
            Text(label).font(.callout)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.75)
        }
    }
}
