import SwiftUI
import SwiftData

// MARK: - 正文为空时的引导条（各 AI 功能页共用）

struct EmptyBodyHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("正文还是空的").font(.subheadline.weight(.semibold))
                Text("先到「书稿」页：点右上角的导入图标选择 .txt / .md 文件（支持 GBK / UTF-8），或直接在编辑器里粘贴文字。有了正文，本页功能即可使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
    }
}

// MARK: - 可编辑提示词区（反黑箱：所有 AI 功能发送前可见、可修改）

struct PromptEditorSection: View {
    @State private var expanded = false
    @Binding var systemText: String
    @Binding var userText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                Label(expanded ? "收起提示词" : "查看提示词（发送前可修改）",
                      systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            if expanded {
                Text("System").font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $systemText).font(.caption).frame(minHeight: 110)
                    .border(Color.secondary.opacity(0.3))
                Text("User").font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $userText).font(.caption).frame(minHeight: 130)
                    .border(Color.secondary.opacity(0.3))
                Text("共 \(userText.count) 字").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 使用教程（对应 Android: 应用内引导）

struct HelpView: View {
    var body: some View {
        List {
            Section("第一次使用（3 步出稿）") {
                step(1, "配置模型密钥", "我的书架右上角齿轮 ⚙ 进入设置 → 凭证管理 → 长按当前凭证 → 「编辑凭证」→ 填 API Key → 「测试连接」。预置 DeepSeek 官方 / OpenRouter，也可自定义 OpenAI 兼容地址。")
                step(2, "新建书目", "「我的书架」→ 右上角 + → 新建书目（填书名，梗概可选）。")
                step(3, "导入正文 / 开始写作", "进入书 → 「书稿」页 → 右上角导入图标选 .txt/.md（GBK、UTF-8 都支持），或直接粘贴/输入。空白书也可以直接点「续写」让 AI 起稿。")
            }
            Section("推荐流水线（酒馆式工作法）") {
                step(1, "选定工作范围", "书稿页键盘条「章节导航」或各分析面板的「更改」→ 点章节即选中该章为分析范围；也可自定义字符区间。范围会显示在每个分析面板顶部。")
                step(2, "人物卡分析", "人物页 ✨ → 按选定范围分段提取出场角色（确定故事参与角色）。")
                step(3, "语料 / 事件 / 文风", "对同一范围分别跑 语料收集、事件提取、长期规则归纳 —— 都是前期资料工作。")
                step(4, "续写", "在范围面板把续写锚设为范围末尾（或书稿页放锚）→ 右上角「续写」→ 剧情梗概 + 写作规范 + 尾部正文 + 你的续写大纲（本轮指令）自动集成为最终提示词 → 生成新故事。")
            }
            Section("核心工作流（进入一本书后的 5 个页签）") {
                step(0, "书稿", "正文编辑器。续写锚：把锚放在想继续的位置，AI 只从锚后生成；查找替换、章节导航、书签在键盘工具条；导入正文在右上角。右上角「续写」= 提示词预览 → 生成 → 追加到正文 / 从锚点替换 / 仅存气泡。")
                step(0, "对话", "气泡式 AI 续写。支持思考块、停止、回复多版本；对话历史会注入后续上下文。")
                step(0, "人物", "人物卡库。右上角 ✨ = 人物整理：AI 分段读正文、增量提取人物事实（只增不减、同名合并）。左滑/点卡片可编辑，右上角 + 手动新建。")
                step(0, "世界", "世界书词条（关键词命中正文时注入）。右上角书本图标 → 语料库：手动记录设定事实，或「语料收集」让 AI 从正文提取世界观设定。")
                step(0, "事件", "剧情事件卡：AI 以场景为单位提取「起因 / 发展 / 结果」，自动去重，可编辑删除。")
            }
            Section("右上角 ··· 菜单（在工作台内）") {
                step(0, "翻译", "逐段翻译整本书，按段缓存（重开只翻未完成的段），可导出 译文-*.txt。翻译模型在设置里单独配置。")
                step(0, "长期规则", "文风/句式/对白等写作规则，可手动添加，或「归纳」让 AI 从正文增量总结（只输出新增）。全局规则对所有书生效。")
                step(0, "快照", "正文版本备份。导入正文、恢复快照会自动备份当前正文；也可手动「保存快照」。恢复 = 整个正文回到该版本。")
                step(0, "导出书项目", "导出本书全部数据（正文+人物卡+世界书+语料+规则+事件+对话）为 .json 存档，可换设备导入。")
            }
            Section("书架页操作") {
                step(0, "长按封面", "创建分支（复制当前书稿开新书）、导出、移入回收站。回收站可恢复或彻底删除（右上角垃圾桶）。")
                step(0, "导入存档", "书架右上角 + → 导入存档 (.json)：恢复之前导出的书项目。")
            }
            Section("设置页") {
                step(0, "分任务模型", "写作 / 摘要 / 翻译 / 整理可各配一个模型，留空则用凭证默认模型。")
                step(0, "预算", "「注入正文尾部」= 每次续写带多少字上下文；「整理单段」= 人物整理/语料收集每次处理的字数。字数越大效果越好、消耗越高。")
                step(0, "消耗分析", "累计输入/输出 tokens 与缓存命中统计。")
            }
            Section("提示") {
                Text("· 所有数据只存在本机（SwiftData + 钥匙串），密钥不会上传。\n· AI 功能都需要先配好密钥并测试连接。\n· 大部头书建议先在设置里把「整理单段」调到 3000–6000。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("使用教程")
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if n > 0 {
                    Text("第\(n)步")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
