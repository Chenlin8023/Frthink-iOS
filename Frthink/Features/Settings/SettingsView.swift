import SwiftUI
import SwiftData

/// 设置（对应 Android: 凭证管理 / 分任务模型 / 预算 / 外观 / 消耗分析）
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var settings = SettingsStore.shared
    @Query private var usage: [UsageRecord]
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @State private var showCredentialEditor = false
    @State private var editingCred: ApiCredential?

    var body: some View {
        NavigationStack {
            List {
                credentialSection
                modelSection
                budgetSection
                usageSection
                appearanceSection
                archiveSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showCredentialEditor) {
                CredentialEditorSheet(credentials: $settings.credentials, credential: editingCred)
            }
        }
    }

    // MARK: 凭证
    private var credentialSection: some View {
        Section("凭证管理") {
            ForEach(settings.credentials) { c in
                Button {
                    settings.activeCredentialId = c.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.name)
                                if c.id == settings.activeCredentialId {
                                    Text("当前").font(.caption2).padding(3)
                                        .background(Color.green.opacity(0.2)).cornerRadius(4)
                                }
                            }
                            Text(c.baseURL).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.apiKey.isEmpty {
                            Text("未配置密钥").font(.caption2).foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                }
                .tint(.primary)
                .contextMenu {
                    Button("编辑凭证") { editingCred = c; showCredentialEditor = true }
                    Button("删除凭证", role: .destructive) {
                        KeychainStore.delete(key: c.keyRef)
                        settings.credentials.removeAll { $0.id == c.id }
                    }
                }
            }
            Button {
                editingCred = nil
                showCredentialEditor = true
            } label: {
                Label("新凭证", systemImage: "plus")
            }
        }
    }

    // MARK: 模型
    private var modelSection: some View {
        Section("模型（分任务配置，空＝用凭证默认）") {
            let cred = settings.activeCredential
            modelField("写作模型", binding: $settings.writingModel, fallback: cred?.model ?? "")
            modelField("摘要模型", binding: $settings.summaryModel, fallback: cred?.model ?? "")
            modelField("翻译模型", binding: $settings.translationModel, fallback: cred?.model ?? "")
            modelField("整理模型", binding: $settings.extractModel, fallback: cred?.model ?? "")
            Stepper("生成温度 \(String(format: "%.1f", settings.temperature))",
                    value: $settings.temperature, in: 0...2, step: 0.1)
            Stepper("输出上限 \(settings.maxOutputTokens) tokens",
                    value: $settings.maxOutputTokens, in: 256...32768, step: 256)
        }
    }

    private func modelField(_ title: String, binding: Binding<String>, fallback: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(fallback, text: binding)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: 预算
    private var budgetSection: some View {
        Section("预算") {
            Stepper("注入正文尾部 \(settings.contextBudget) 字", value: $settings.contextBudget, in: 500...30000, step: 500)
            Stepper("整理单段 \(settings.segmentBudget) 字", value: $settings.segmentBudget, in: 500...10000, step: 500)
        }
    }

    // MARK: 用量
    private var usageSection: some View {
        Section("消耗分析") {
            let input = usage.reduce(0) { $0 + $1.inputTokens }
            let output = usage.reduce(0) { $0 + $1.outputTokens }
            let cached = usage.reduce(0) { $0 + $1.cachedTokens }
            LabeledContent("请求数", value: "\(usage.count)")
            LabeledContent("输入 tokens", value: input.formatted())
            LabeledContent("输出 tokens", value: output.formatted())
            LabeledContent("缓存命中", value: cached.formatted())
            if !usage.isEmpty {
                Button("清空统计", role: .destructive) {
                    for u in usage { context.delete(u) }
                    try? context.save()
                }
            }
        }
    }

    // MARK: 外观
    private var appearanceSection: some View {
        Section("外观") {
            Picker("深色模式", selection: $appearanceMode) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Toggle("触感反馈", isOn: Binding(
                get: { settings.hapticsEnabled },
                set: { settings.hapticsEnabled = $0 }))
        }
    }

    // MARK: 全量存档
    private var archiveSection: some View {
        Section("全量存档") {
            Button("导出全部项目 (.json)") {
                let all = (try? context.fetch(FetchDescriptor<BookProject>())) ?? []
                let data = ArchiveService.exportAll(projects: all, context: context)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("备份-\(Date.now.formatted(date: .abbreviated, time: .shortened)).json")
                try? data.write(to: url)
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                    .first?.present(share, animated: true)
            }
        }
    }
}

/// 凭证编辑（对应 Android: ApiCredentialProfile + 加密保存 + 测试连接）
struct CredentialEditorSheet: View {
    @Binding var credentials: [ApiCredential]
    var credential: ApiCredential?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("凭证名称", text: $name)
                    TextField("服务地址（如 https://api.deepseek.com）", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("模型", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("密钥（已加密保存到钥匙串）") {
                    SecureField("API Key", text: $apiKey)
                    Button {
                        test()
                    } label: {
                        if testing { ProgressView(); Text("请求中…").padding(.leading, 6) }
                        else { Label("测试连接", systemImage: "bolt") }
                    }
                    .disabled(testing || baseURL.isEmpty || model.isEmpty)
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(testOK ? .green : .red)
                            .font(.caption)
                    }
                }
                Section {
                    Button("粘贴剪贴板密钥") { apiKey = UIPasteboard.general.string ?? "" }
                }
            }
            .navigationTitle(credential == nil ? "新凭证" : "编辑凭证")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(); dismiss() }
                        .disabled(name.isEmpty || baseURL.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let c = credential else { return }
        name = c.name; baseURL = c.baseURL; model = c.model; apiKey = c.apiKey
    }

    private func save() {
        var cleanBase = baseURL.trimmingCharacters(in: .whitespaces)
        while cleanBase.hasSuffix("/") { cleanBase.removeLast() }
        if var c = credential {
            c.name = name; c.baseURL = cleanBase; c.model = model; c.apiKey = apiKey
            credentials = credentials.map { $0.id == c.id ? c : $0 }
        } else {
            var c = ApiCredential(name: name, baseURL: cleanBase, model: model)
            c.apiKey = apiKey
            credentials.append(c)
        }
    }

    private func test() {
        testing = true; testResult = nil
        var probe = credential ?? ApiCredential(name: name, baseURL: baseURL, model: model)
        probe.baseURL = baseURL; probe.model = model; probe.apiKey = apiKey
        Task {
            do {
                let reply = try await LlmClient.testConnection(credential: probe)
                await MainActor.run { testing = false; testOK = true; testResult = "连接成功：\(reply.prefix(40))" }
            } catch {
                await MainActor.run { testing = false; testOK = false; testResult = error.localizedDescription }
            }
        }
    }
}
