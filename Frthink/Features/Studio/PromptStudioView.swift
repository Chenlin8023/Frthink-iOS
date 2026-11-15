import SwiftUI
import SwiftData

/// 提示词编排（酒馆 Prompt Manager 的等价界面）。
///
/// 与功能页同步的规则：
/// - 这里改的是「每项目 × 每任务」的块配置（UserDefaults），续写面板的预览直接按它渲染；
/// - 续写面板里对整段 system/user 的编辑是「本次会话的临时覆盖」，不清空则一直生效；
/// - 未做任何自定义时，续写仍走 v1.9 原有拼装，保证默认行为不变。
struct PromptStudioView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context

    @State private var task: PromptTask = .continuation
    @State private var blocks: [PromptBlock] = []
    @State private var expandedKey: String?
    @State private var showPreview = false
    @State private var loaded = false

    var body: some View {
        List {
            introSection
            blocksSection
            footerSection
        }
        .navigationTitle("提示词编排")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().font(.caption) }
        }
        .sheet(isPresented: $showPreview) {
            PromptPreviewSheet(project: project, blocks: blocks, task: task)
        }
        .onAppear(perform: load)
        .onChange(of: task) { _, _ in load() }
        .onChange(of: blocks) { _, newValue in
            guard loaded else { return }
            PromptBlockStore.save(newValue, project.id, task)
        }
    }

    // MARK: 头部

    private var introSection: some View {
        Section {
            Picker("任务", selection: $task) {
                ForEach(PromptTask.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            LabeledContent("状态", value: PromptBlockStore.hasCustom(project.id, task) ? "已自定义" : "内置默认")
            Text("拖动右侧手柄调整顺序；点一行展开编辑内容。{{tone}} 这样的变量会在生成时替换成实际内容。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: 块列表

    private var blocksSection: some View {
        Section("提示词块（\(blocks.count)）") {
            ForEach($blocks) { $block in
                blockRow($block)
            }
            .onMove { from, to in
                blocks.move(fromOffsets: from, toOffset: to)
            }
        }
    }

    @ViewBuilder
    private func blockRow(_ block: Binding<PromptBlock>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: block.enabled).labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.wrappedValue.title).font(.footnote)
                    Text("\(block.wrappedValue.role) · \(block.wrappedValue.injectionLabel) · \(block.wrappedValue.body.count) 字")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(block.wrappedValue.isBuiltin ? "内置" : "自定义")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedKey = (expandedKey == block.wrappedValue.key) ? nil : block.wrappedValue.key
            }

            if expandedKey == block.wrappedValue.key {
                TextEditor(text: block.body)
                    .font(.caption)
                    .frame(minHeight: 170)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

                HStack(spacing: 10) {
                    Menu {
                        ForEach(PromptBlockStore.availableVars, id: \.self) { name in
                            Button("{{\(name)}}") {
                                block.wrappedValue.body += "{{\(name)}}"
                            }
                        }
                    } label: {
                        Label("插入变量", systemImage: "curlybraces").font(.caption)
                    }

                    Menu {
                        Button("system") { block.wrappedValue.role = "system" }
                        Button("user") { block.wrappedValue.role = "user" }
                    } label: {
                        Label(block.wrappedValue.role, systemImage: "arrow.left.arrow.right").font(.caption)
                    }

                    Menu {
                        Button("总是") { block.wrappedValue.injection = "always" }
                        ForEach(PromptBlockStore.availableVars, id: \.self) { name in
                            Button("有 \(name) 时") { block.wrappedValue.injection = "ifHas:\(name)" }
                        }
                        Button("不注入") { block.wrappedValue.injection = "never" }
                    } label: {
                        Label(block.wrappedValue.injectionLabel, systemImage: "line.3.horizontal.decrease").font(.caption)
                    }

                    Spacer()

                    Button("恢复内置") {
                        if let def = PromptBlockStore.defaults(for: task)
                            .first(where: { $0.key == block.wrappedValue.key }) {
                            block.wrappedValue = def
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: 底部

    private var footerSection: some View {
        Section {
            Button {
                showPreview = true
            } label: {
                Label("预览最终提示词", systemImage: "eye")
            }
            Button {
                PromptBlockStore.reset(project.id, task)
                blocks = PromptBlockStore.defaults(for: task)
                expandedKey = nil
            } label: {
                Label("恢复全部内置默认", systemImage: "arrow.uturn.backward")
            }
            .foregroundStyle(.red)
        } footer: {
            Text("变量为空时，勾了「有 X 时」的块会自动跳过（比如没有人物卡就不会塞空的【人物设定】）。")
                .font(.caption2)
        }
    }

    // MARK: 动作

    private func load() {
        blocks = PromptBlockStore.load(project.id, task)
        loaded = true
    }
}

/// 预览：用当前块 + 真实数据渲染一次（不发送请求）
struct PromptPreviewSheet: View {
    let project: BookProject
    let blocks: [PromptBlock]
    let task: PromptTask

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var systemText = ""
    @State private var userText = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        ProgressView().padding()
                    } else {
                        section(title: "System（\(systemText.count) 字）", text: systemText)
                        section(title: "User（\(userText.count) 字）", text: userText)
                    }
                }
                .padding(16)
            }
            .navigationTitle("提示词预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onAppear(perform: compose)
        }
    }

    private func section(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).bold()
            Text(text)
                .font(.caption2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        }
    }

    private func compose() {
        let vars = PromptAssembler.vars(project: project,
                                        context: modelContext,
                                        instruction: "（预览：这里是本轮指令占位）")
        let compiled = PromptAssembler.compose(project: project,
                                               context: modelContext,
                                               instruction: "（预览：这里是本轮指令占位）",
                                               blocks: blocks,
                                               vars: vars)
        systemText = compiled.messages[0].content
        userText = compiled.messages[1].content
        loading = false
    }
}
