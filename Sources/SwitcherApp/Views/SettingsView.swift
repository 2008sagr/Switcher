import SwiftUI
import UniformTypeIdentifiers
import SwitcherCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .environmentObject(appState)
                .tabItem { Label("Основное", systemImage: "gearshape") }

            DetectionTab()
                .environmentObject(appState)
                .tabItem { Label("Распознавание", systemImage: "wand.and.sparkles") }

            DictionaryTab()
                .environmentObject(appState)
                .tabItem { Label("Словарь", systemImage: "text.book.closed") }

            AppsTab()
                .environmentObject(appState)
                .tabItem { Label("Приложения", systemImage: "app.badge.checkmark") }

            AboutTab()
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 500, height: 420)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Поведение") {
                Toggle("Включить Switcher", isOn: $appState.isEnabled)
                Toggle("Автопереключение при вводе слова", isOn: $appState.autoSwitchEnabled)
                    .help("Автоматически переключает раскладку и заменяет текст после ввода слова не в той раскладке.")
                Toggle("Конвертировать выделение двойным Shift", isOn: $appState.doubleShiftEnabled)
                    .help("Выделите текст и дважды нажмите Shift, чтобы конвертировать его между раскладками. Без выделения — отменяет последнюю замену.")
            }

            Section("Обучение") {
                Toggle("Учиться на исправлениях", isOn: $appState.learningEnabled)
                    .help("Отмена двойным Shift → слово добавляется в исключения. Двойной Shift с выделением → каждое конвертированное слово добавляется в правила исправлений.")
            }

            Section("Разрешения") {
                HStack {
                    Image(systemName: appState.hasAccessibility ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundColor(appState.hasAccessibility ? .green : .red)
                    Text("Доступ к специальным возможностям")
                    Spacer()
                    if !appState.hasAccessibility {
                        Button("Открыть настройки") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Section("Запуск") {
                Toggle("Запускать при входе", isOn: $appState.launchAtLoginEnabled)
                    .help("Запускать Switcher автоматически при входе в систему.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Detection Tab

struct DetectionTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Распознавание слов") {
                Toggle("Проверять орфографию", isOn: $appState.spellCheckEnabled)
                    .help("Использует встроенную проверку орфографии macOS. Если словарь языка недоступен, применяется частотный анализ n-грамм.")

                HStack {
                    Text("Минимальная длина слова")
                    Spacer()
                    Stepper("\(appState.minWordLength) симв.", value: $appState.minWordLength, in: 2...10)
                }
                .help("Слова короче этого значения не будут триггерить автопереключение.")
            }

            Section("Как работает отмена") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Дважды нажмите Shift без выделения, чтобы отменить последнюю замену.", systemImage: "arrow.uturn.backward")
                    Label("Исходное слово восстанавливается, раскладка возвращается.", systemImage: "keyboard")
                    if appState.learningEnabled {
                        Label("Обучение включено — отменённые слова добавляются в исключения.", systemImage: "brain")
                            .foregroundColor(.accentColor)
                        Label("Двойной Shift — конвертированные слова добавляются в правила исправлений.", systemImage: "brain")
                            .foregroundColor(.accentColor)
                    }
                }
                .font(.callout)
            }

            Section("Поддерживаемые пары раскладок") {
                LayoutPairRow(flag1: "🇬🇧", lang1: "Английский (QWERTY)", flag2: "🇷🇺", lang2: "Русский (ЙЦУКЕН)")
            }

            Section("Статистика") {
                HStack {
                    Text("Переключений раскладки")
                    Spacer()
                    Text("\(appState.switchCount)").foregroundColor(.secondary).monospacedDigit()
                }
                if !appState.lastSwitchedWord.isEmpty {
                    HStack {
                        Text("Последнее слово")
                        Spacer()
                        Text(appState.lastSwitchedWord).foregroundColor(.secondary).font(.body.monospaced())
                    }
                }
                Button("Сбросить статистику") {
                    appState.switchCount = 0
                    appState.lastSwitchedWord = ""
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictionary Tab

enum DictionarySection { case exceptions, corrections }

struct DictionaryTab: View {
    @EnvironmentObject var appState: AppState

    @State private var section:       DictionarySection = .exceptions
    @State private var searchText:    String = ""
    @State private var newWord:       String = ""
    @State private var selectedWords: Set<String> = []

    @State private var showImportPanel  = false
    @State private var showExportPanel  = false
    @State private var importError:     String? = nil
    @State private var showImportAlert  = false

    private var filtered: [String] {
        let all = appState.dictionary.exceptions
        if searchText.isEmpty { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 10) {

            // ── Section picker ────────────────────────────────────────────────
            Picker("", selection: $section) {
                Text("Исключения").tag(DictionarySection.exceptions)
                Text("Исправления").tag(DictionarySection.corrections)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .corrections {
                CorrectionsView()
                    .environmentObject(appState)
            } else {

            // ── Toolbar ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                TextField("Поиск…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Spacer()

                Button { showImportPanel = true } label: {
                    Label("Импорт", systemImage: "square.and.arrow.down")
                }
                Button { exportDictionary() } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }

                if !selectedWords.isEmpty {
                    Button(role: .destructive) {
                        selectedWords.forEach { appState.removeException($0) }
                        selectedWords = []
                    } label: {
                        Label("Удалить (\(selectedWords.count))", systemImage: "trash")
                    }
                }
            }

            // ── Word list ─────────────────────────────────────────────────────
            if appState.dictionary.exceptions.isEmpty {
                emptyState
            } else {
                List(filtered, id: \.self, selection: $selectedWords) { word in
                    HStack {
                        Text(word)
                            .font(.body.monospaced())
                        Spacer()
                        Button {
                            appState.removeException(word)
                            selectedWords.remove(word)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .opacity(selectedWords.isEmpty || selectedWords.contains(word) ? 1 : 0.3)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 160)
            }

            // ── Add word ──────────────────────────────────────────────────────
            HStack {
                TextField("Добавить исключение…", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button("Добавить") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // ── Footer info ───────────────────────────────────────────────────
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(SwitchDictionary.fileURL.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(appState.dictionary.exceptions.count) слов")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } // end else (exceptions section)
        }
        .padding(.vertical, 4)
        // ── Import file picker ──────────────────────────────────────────────
        .fileImporter(
            isPresented: $showImportPanel,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Ошибка импорта", isPresented: $showImportAlert, presenting: importError) { _ in
            Button("ОК") {}
        } message: { err in
            Text(err)
        }
    }

    // MARK: - Helpers

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "hand.raised.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Нет исключений")
                .font(.headline)
            Text("Слова из этого списка не будут триггерить автопереключение.\nНажмите ✕ рядом со словом в меню\nили добавьте слово вручную ниже.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        appState.addException(w)
        newWord = ""
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.title                = "Экспорт словаря"
        panel.nameFieldStringValue = "switcher-dictionary.json"
        panel.allowedContentTypes  = [.json]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url,
           let data = appState.dictionary.exportJSON() {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            importError = err.localizedDescription
            showImportAlert = true
        case .success(let urls):
            guard let url = urls.first,
                  let data = try? Data(contentsOf: url) else { return }

            do {
                let imported: SwitchDictionary
                if url.pathExtension.lowercased() == "json" {
                    imported = try SwitchDictionary.fromJSON(data)
                } else {
                    imported = SwitchDictionary.fromText(String(data: data, encoding: .utf8) ?? "")
                }
                appState.importDictionary(imported, merging: true)
            } catch {
                importError = "Не удалось разобрать файл: \(error.localizedDescription)"
                showImportAlert = true
            }
        }
    }
}

// MARK: - Corrections View

struct CorrectionsView: View {
    @EnvironmentObject var appState: AppState

    @State private var fromWord: String = ""
    @State private var toWord:   String = ""

    var body: some View {
        VStack(spacing: 10) {

            // ── List ──────────────────────────────────────────────────────────
            if appState.correctionRules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("Нет исправлений")
                        .font(.headline)
                    Text("Добавьте правило — например, «чтото» → «что-то».\nДвижок применяет замену при завершении ввода слова.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                List {
                    ForEach(appState.correctionRules, id: \.from) { rule in
                        HStack(spacing: 8) {
                            Text(rule.from)
                                .font(.body.monospaced())
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(rule.to)
                                .font(.body.monospaced())
                                .foregroundColor(.accentColor)
                            Spacer()
                            Button {
                                appState.removeCorrection(from: rule.from)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 120)
            }

            // ── Add rule ──────────────────────────────────────────────────────
            HStack(spacing: 6) {
                TextField("Введено (напр. чтото)", text: $fromWord)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                TextField("Заменить на (напр. что-то)", text: $toWord)
                    .textFieldStyle(.roundedBorder)
                Button("Добавить") { addRule() }
                    .disabled(fromWord.trimmingCharacters(in: .whitespaces).isEmpty ||
                              toWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onSubmit { addRule() }

            HStack {
                Image(systemName: "info.circle").foregroundColor(.secondary)
                Text("Исправления применяются до переключения раскладки и работают на любом языке.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(appState.correctionRules.count) правил")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func addRule() {
        let f = fromWord.trimmingCharacters(in: .whitespaces)
        let t = toWord.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        appState.addCorrection(from: f, to: t)
        fromWord = ""
        toWord   = ""
    }
}

// MARK: - Apps Tab

struct AppsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Автопереключение отключено в этих приложениях:")
                .font(.callout)
                .foregroundColor(.secondary)

            if appState.excludedApps.isEmpty {
                appsEmptyState
            } else {
                List {
                    ForEach(appState.excludedApps, id: \.self) { bundleID in
                        ExcludedAppRow(bundleID: bundleID) {
                            appState.removeExcludedApp(bundleID)
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 120)
            }

            HStack {
                Button("Добавить приложение…") { showPicker = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                if !appState.excludedApps.isEmpty {
                    Text("Исключено: \(appState.excludedApps.count)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showPicker) {
            AppPickerSheet { bundleID in
                appState.addExcludedApp(bundleID)
            }
        }
    }

    private var appsEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Нет исключённых приложений")
                .font(.headline)
            Text("Добавьте приложения, в которых автопереключение нежелательно,\nнапример редакторы кода или терминалы.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Excluded App Row

struct ExcludedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        appURL?.deletingPathExtension().lastPathComponent ?? bundleID
    }

    private var icon: NSImage? {
        guard let url = appURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let nsImage = icon {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app")
                    .frame(width: 24, height: 24)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).font(.callout)
                Text(bundleID).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button { onRemove() } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - App Picker Sheet

struct RunningAppInfo: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
}

struct AppPickerSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var apps: [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                $0.bundleIdentifier != nil &&
                $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap { app -> RunningAppInfo? in
                guard let bid = app.bundleIdentifier else { return nil }
                return RunningAppInfo(id: bid, name: app.localizedName ?? bid, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Выберите приложение")
                    .font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }
            .padding(16)

            Divider()

            if apps.isEmpty {
                VStack {
                    Spacer()
                    Text("Нет других запущенных приложений")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(height: 200)
            } else {
                List(apps) { app in
                    Button {
                        onSelect(app.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                            Text(app.name).font(.callout)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.bordered)
            }
        }
        .frame(width: 280, height: 320)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard.badge.eye")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            VStack(spacing: 4) {
                Text("Switcher")
                    .font(.title.bold())
                Text("Автопереключатель раскладки клавиатуры")
                    .foregroundColor(.secondary)
                Text("Версия 1.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "wand.and.sparkles",     text: "Автоматически определяет и исправляет ввод в неверной раскладке")
                FeatureRow(icon: "shift.fill",             text: "Двойной Shift конвертирует выделенный текст")
                FeatureRow(icon: "arrow.uturn.backward",  text: "Двойной Shift без выделения отменяет последнюю замену")
                FeatureRow(icon: "brain",                 text: "Учится на исправлениях, чтобы не повторять ошибки")
                FeatureRow(icon: "text.book.closed",      text: "Редактируемый словарь исключений с импортом/экспортом")
                FeatureRow(icon: "app.badge.checkmark",   text: "Исключения по приложениям для редакторов и терминалов")
                FeatureRow(icon: "text.badge.checkmark",  text: "Правила исправления опечаток — напр. чтото → что-то")
            }

            Spacer()
        }
        .padding(.top, 8)
    }
}

// MARK: - Reusable components

struct LayoutPairRow: View {
    let flag1, lang1, flag2, lang2: String
    var body: some View {
        HStack {
            Text(flag1); Text(lang1).font(.callout); Spacer()
            Image(systemName: "arrow.left.arrow.right").foregroundColor(.secondary).font(.caption)
            Spacer(); Text(lang2).font(.callout); Text(flag2)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.accentColor).frame(width: 20)
            Text(text).font(.callout)
        }
    }
}
