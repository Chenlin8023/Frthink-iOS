# Frthink for iOS（重构版）

这是对 Android 应用 **Frthink**（v0.8.210，AI 长篇小说写作应用）的**功能等价 iOS 重构**——
基于对原 APK 的静态分析（架构见 `../analysis/Frthink-APK-分析报告.md`），以
Swift / SwiftUI / SwiftData 全新实现，**不含原应用的任何代码或资产**。

## 功能对照

| 功能 | Android 原版 | iOS 重构版 |
|---|---|---|
| 我的书架（封面/搜索/新建/分支/导出） | Compose | `BookshelfView` ✅ |
| 回收站（恢复/彻底删除/清空） | Room + 墓碑 | `TrashView` ✅ |
| 书稿编辑器（字数/查找替换/章节导航/书签/导入 .txt/.md） | WebView+CodeMirror | 原生 `TextEditor` ✅ |
| 续写锚（放置/取消/从锚点续写或替换） | Anchor 协议 | `ManuscriptEditorView` + `ContinuationSheet` ✅ |
| AI 对话气泡（流式/思考块/停止/版本/追加到正文） | OkHttp SSE | `ChatView` ✅ |
| 提示词预览（注入世界/人物/规则/正文尾部预算） | CompiledCloudPrompt | `PromptBuilder` ✅ |
| 人物卡（10 字段/编组/开关注入）+ 增量人物整理 | CharacterCard 库 | `CharacterCardsView` ✅ |
| 世界书（关键词触发注入/全局词条） | 世界书 | `WorldBookView` ✅ |
| 语料库（手动/正文收集） | CorpusLibrary | `CorpusListView` ✅ |
| 长期规则/味审查规则 + 增量归纳 | 规则系统 | `RulesView` ✅ |
| 剧情事件卡（起因/发展/结果，仅新增提取） | PlotEventCard | `EventsView` ✅ |
| 快照（手动/自动备份/恢复） | project_snapshots | `SnapshotsView` ✅ |
| 分任务模型（写作/摘要/翻译/整理） | StoredSettings | `SettingsView` ✅ |
| 凭证管理（多凭证/钥匙串加密/测试连接） | EncryptedSharedPreferences | `CredentialEditorSheet` ✅ |
| 预置 DeepSeek / OpenRouter / 自定义兼容服务 | /chat/completions | `LlmClient` ✅ |
| 消耗分析（输入/输出/缓存命中 tokens） | usage 统计 | `UsageRecord` ✅ |
| 逐段翻译（段缓存/只继续未完成/导出译文.txt） | translation_segments | `TranslationView` ✅ |
| 深色模式/触感反馈 | 外观设置 | `SettingsStore` ✅ |
| 全量存档导出/导入（JSON 信封） | FrthinkArchiveEnvelope | `ArchiveService`（frthink-archive v1）✅ |
| 前台服务长任务 | LlmTransferService | 用 `Task` 前台执行（iOS 无对应服务，长任务可后续接 BGTaskScheduler） |
| 正文块同步协议/多设备 | BodySync* | 未实现（iOS 版为单机版，存档导入导出替代） |

## 目录结构

```
FrthinkiOS/
├── project.yml                     # XcodeGen 工程定义
├── build_ipa.sh                    # macOS 上构建 .ipa 的脚本
└── Frthink/
    ├── App/                        # 入口、根导航、主题
    ├── Models/Models.swift         # SwiftData 模型（对应 Room schema）
    ├── Networking/LlmClient.swift  # OpenAI 兼容 SSE 网关（思考块/用量）
    ├── Prompts/PromptBuilder.swift # 提示词编译管线（续写/人物/规则/事件/翻译）
    ├── Storage/                    # Keychain、SettingsStore、存档
    └── Features/                   # 书架/书稿/对话/人物/世界/规则/快照/回收站/设置/翻译
```

## 从源码构建 .ipa（需要一台 macOS + Xcode 15+）

> 说明：.ipa 必须由 Xcode 在 macOS 上编译并签名后才能安装到 iPhone；
> Apple 不允许在 Windows 上直接生成可安装的 .ipa（需要 Apple 签名证书）。

```bash
# 1) 生成 Xcode 工程（或手动 brew install xcodegen）
xcodegen generate

# 2) 打开工程真机运行（第一次建议直接 Xcode ⌘R 装到手机验证）
open Frthink.xcodeproj

# 3) 命令行构建 .ipa（自动签名，需要配置开发者团队）
./build_ipa.sh --team YOUR_TEAM_ID            # 付费开发者账号，可上架/直装
./build_ipa.sh --team YOUR_TEAM_ID --method development   # 开发签名 ipa
```

没有付费开发者账号？可以用 **免费 Apple ID** 在 Xcode 里签名安装（7 天有效期）：
Xcode → Settings → Accounts 登录 Apple ID → Signing & Capabilities 选择
`Your Name (Personal Team)` → 直接连线手机 ⌘R 安装。

## 运行要求

- iOS 17.0+（SwiftData）
- 在「设置 → 凭证管理」配置任一模型服务：
  - DeepSeek 官方：`https://api.deepseek.com` + `deepseek-chat`
  - OpenRouter：`https://openrouter.ai/api/v1` + 任一模型 ID
  - 其他 OpenAI 兼容服务：填服务地址即可

## 法律与版权说明

- 本工程是对原应用**功能与架构的重实现**（功能不受版权保护），
  未复制原应用的代码、提示词文本、图标或资源文件。
- "Frthink" 名称与商标归原作者所有；上架前请替换应用名与图标。
- CodeMirror 6（原应用编辑器内核）为 MIT 许可，如需在 iOS 用 WebView 方案
  可自行按 MIT 条款引入。
