import Foundation

/// 小说机内容常量集（母版 analysis/novel-machine-ref/novel 的 iOS 等价物）
///
/// 全部是"可被用户整本覆盖的默认值"：
/// - 基调预设 / 世界观 / 标签词表 / 关系维度 / 18 条写手规则，读写都经 ContentPlan；
/// - 应用不做本地内容过滤，这里也不含任何审查逻辑，只提供母版验证过的措辞。
enum ContentKit {

    // MARK: - 关系维度

    struct RelDim: Codable, Identifiable, Hashable {
        var n: String        // 维度名
        var d: String        // 含义（进状态档提示词）
        var initial: Int     // 初值 0-100
        var id: String { n }
    }

    enum DimSet: String, CaseIterable, Identifiable {
        case vanilla, ntr
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vanilla: return "常规六维"
            case .ntr: return "寝取六维"
            }
        }
    }

    /// 母版 lib/state.js:70-77
    static let vanillaDims: [RelDim] = [
        RelDim(n: "信任", d: "她对他的放心程度", initial: 10),
        RelDim(n: "亲密", d: "身体和情感的贴近程度", initial: 10),
        RelDim(n: "支配", d: "谁说了算，越高越是男方主导", initial: 10),
        RelDim(n: "服从", d: "她配合的意愿（意愿，不是权力）", initial: 10),
        RelDim(n: "羞耻", d: "羞耻阈值，越高越不容易被羞到", initial: 50),
        RelDim(n: "欲求", d: "积压的欲望，涨到顶就该有一场", initial: 20)
    ]

    /// 母版 lib/state.js:79-86
    static let ntrDims: [RelDim] = [
        RelDim(n: "知情", d: "视点人物知道多少真相（0 全不知，100 全知）", initial: 5),
        RelDim(n: "隐瞒", d: "女主瞒着他多少", initial: 10),
        RelDim(n: "共享", d: "她被分享出去的程度（独占的反面）", initial: 0),
        RelDim(n: "依恋", d: "她心里还向着谁（0 全在第三者，100 全在他）", initial: 80),
        RelDim(n: "屈辱", d: "视点人物被架在一旁的受辱强度", initial: 0),
        RelDim(n: "沉沦", d: "身体和欲望滑落的程度", initial: 5)
    ]

    static func dims(for set: DimSet) -> [RelDim] {
        switch set {
        case .vanilla: return vanillaDims
        case .ntr: return ntrDims
        }
    }

    // MARK: - 标签词表（母版 server.js:170-178 + index.html:347）

    struct TagGroup: Identifiable {
        var g: String
        var t: [String]
        var id: String { g }
    }

    static let tagGroups: [TagGroup] = [
        TagGroup(g: "关系结构", t: ["单对单", "3P", "多P", "双飞", "群交", "交换", "NTR", "NTL",
                                   "偷情", "包养", "三角", "公开"]),
        TagGroup(g: "权属调教", t: ["主奴", "支配", "臣服", "调教", "惩戒", "奖赏", "项圈", "契约",
                                   "命令", "羞耻训练"]),
        TagGroup(g: "场所", t: ["卧室", "浴室", "厨房", "办公室", "教室", "试衣间", "车里", "电梯",
                               "阳台", "野外", "旅馆"]),
        TagGroup(g: "行为", t: ["前戏", "口交", "乳交", "足交", "手交", "素股", "插入", "后入",
                               "骑乘", "肛", "双插", "道具", "束缚", "蒙眼", "内射", "颜射"]),
        TagGroup(g: "强度", t: ["暗示", "中度", "露骨", "极端"]),
        TagGroup(g: "情绪", t: ["甜", "羞", "侵", "堕", "报复", "补偿", "试探", "失守"]),
        TagGroup(g: "装置", t: ["偷窥", "误会", "录音录像", "赌约", "醉酒", "被迫同居", "撞见"]),
        TagGroup(g: "世界书选项", t: ["户外", "露出", "捆绑", "放置", "深喉", "后入", "乳头交",
                                  "尿道开发", "合意强暴", "言语侮辱", "角色扮演", "女攻", "白虎"])
    ]

    static var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for g in tagGroups {
            for t in g.t where !seen.contains(t) {
                seen.insert(t)
                out.append(t)
            }
        }
        return out
    }

    /// 强度档位（逐章 OutlineItem.strength 取值；空 = 按基调自动）
    static let strengthLevels: [String] = ["暗示", "中度", "露骨", "极端"]

    /// 群体场面的判词（母版 autotags 自查口径）
    static let groupSceneWords: [String] = ["多P", "群交", "3P", "双飞", "交换"]

    // MARK: - 基调预设（母版 index.html:370-393 原文）

    struct TonePreset: Identifiable {
        var name: String
        var tone: String
        var opts: [String]
        var cadenceStart: Int
        var cadenceEvery: Int
        var dimSet: DimSet
        var id: String { name }
    }

    static let tonePresets: [TonePreset] = [
        TonePreset(
            name: "轻喜剧",
            tone: "日常向轻喜剧，两人互相喜欢，做爱是件开心事，不是考验。对话多、反应夸张、有笑点，允许笑场、吐槽、中途打断。成年向，写具体，不写抒情，不留心理阴影。",
            opts: ["户外", "角色扮演"], cadenceStart: 4, cadenceEvery: 2, dimSet: .vanilla),
        TonePreset(
            name: "纯爱慢热",
            tone: "温柔日常，关系健康，情绪克制而细腻。先有信任再有身体，节奏慢，重心在两个人怎么靠近。成年向，写具体但不激烈。",
            opts: [], cadenceStart: 6, cadenceEvery: 3, dimSet: .vanilla),
        TonePreset(
            name: "冷调悬疑",
            tone: "悬疑冷硬，性事与危险交织，情绪不外露。描写克制但具体，不解释感受，只写动作和后果。",
            opts: ["放置", "露出", "女攻"], cadenceStart: 4, cadenceEvery: 2, dimSet: .vanilla),
        TonePreset(
            name: "调教向",
            tone: "权力关系明确，主从分明，服从与奖励是主轴。写得具体，不回避，不淡出。",
            opts: ["捆绑", "放置", "言语侮辱", "后入"], cadenceStart: 3, cadenceEvery: 2, dimSet: .vanilla),
        TonePreset(
            name: "官能直给",
            tone: "欲望驱动。短句，节奏快，少铺垫，多动作和对白，不写心理独白。",
            opts: ["后入", "深喉", "乳头交", "合意强暴", "扩肛"], cadenceStart: 2, cadenceEvery: 1, dimSet: .vanilla),
        TonePreset(
            name: "双形态切换",
            tone: "日常与变身交替，两种状态来回拉扯，情绪反差大。写具体，注意两种形态的身体差异。",
            opts: ["白虎", "户外", "尿道开发", "大尺寸扶她"], cadenceStart: 4, cadenceEvery: 2, dimSet: .vanilla),
        TonePreset(
            name: "寝取",
            tone: "第三者主导，但根子是内因：她的忠贞是外壳，底下藏着从未被满足的癖好，第三者只是撬开它的那个人。他必须有具体的权力来源（把柄、债务、职位、旧恩）和明确想要的东西，威胁必须可信，不能只是一味强势。三个人的变化要递进：她 察觉→确认→默许→共谋→崩坏；他 愤怒→自我说服→合理化→旁观成瘾→同谋；第三者 试探→加码→支配→收网。每六章至少推进一格，不许原地。秘密分层：读者知道多少、她知道多少、他知道多少，每八章揭一层。主角允许无力，但不许一个表情演到底。每八章回收一条旧伏笔。结尾必须有一个不可逆的结果。耻辱当兴奋写，不当痛苦写；旁白为主，多写视点人物的观察和心理。",
            opts: ["合意强暴", "言语侮辱", "露出", "放置", "女攻"], cadenceStart: 4, cadenceEvery: 2, dimSet: .ntr)
    ]

    // MARK: - 世界观预设（母版 index.html:360-368 原文）

    struct WorldPreset: Identifiable {
        var name: String
        var text: String
        var id: String { name }
    }

    static let worldPresets: [WorldPreset] = [
        WorldPreset(name: "都市现代", text: "现在的城市。有手机、汽车、电梯、监控，警察管用，开房要身份证。上班挣钱、还房贷，出事能报警，也能被拍下来发到网上。"),
        WorldPreset(name: "武侠江湖", text: "古代江湖。没有电、手机、汽车、公司和官府办案。走路由马和船，传话靠人和信鸽，付钱用银子。门派、镖局、客栈、渡口、破庙、药铺。"),
        WorldPreset(name: "东方仙侠", text: "修真界。有宗门、灵脉、丹药、法器，能御剑飞。没灵根连门槛都进不去，规矩是宗门定的，长老一句话定生死。"),
        WorldPreset(name: "西方玄幻", text: "剑与魔法的大陆。有王国、城堡、教会、行会、酒馆和森林。国王和领主说了算，教会管戒律，行会管价钱；雇人办事要给金币。没有电也没有枪。"),
        WorldPreset(name: "民国近代", text: "民国年间。黄包车、租界、巡捕、报馆、烟馆、当铺。银元最硬，兵和巡捕谁都惹不起，女人没靠山就只能靠人。电话稀罕，传话靠人跑。"),
        WorldPreset(name: "末世废土", text: "灾变以后。城市烂了，没水没电，净水和汽油比钱贵，路上有匪帮和哨卡。有车有枪才说得上话，谁守着一口井谁就是这儿的王。"),
        WorldPreset(name: "灵异民俗", text: "南方乡下和旧镇。祠堂、祖坟、神婆、丧事规矩、庙会、老宅。村规比法律管用，夜里不上山，不问名字，不信外人。")
    ]

    // MARK: - 世界书槽位（母版 lib/project.js:4-14 阈值与权重照搬）

    static func slotBand(order: Int) -> String {
        if order >= 90000 { return "protocol" }
        if order >= 80000 { return "appear" }
        if order >= 9990 { return "variant" }
        if order >= 8888 { return "note" }
        if order >= 8770 { return "leak" }
        if order >= 8500 { return "opt" }
        return "opt2"
    }

    static func slotWeight(_ band: String) -> Int {
        switch band {
        case "variant": return 0
        case "appear", "opt", "opt2", "note": return 1
        case "leak": return 2
        case "protocol": return 3
        default: return 1
        }
    }

    static func slotTitle(_ band: String) -> String {
        switch band {
        case "protocol": return "叙事协议"
        case "variant": return "角色版本"
        case "appear": return "外观/生理"
        case "opt": return "偏好选项"
        case "opt2": return "其他"
        case "leak": return "破墙等级"
        case "note": return "说明"
        default: return "其他"
        }
    }

    // MARK: - 写手规则（母版 lib/rules.js 18 条原文，占位符替换）

    static let perspectiveToken = "{{perspective}}"
    static let toneToken = "{{tone}}"

    /// 18 条母版原文；结构（编号/段落）不得改动，措辞可整本覆盖（见 ContentPlan.rulesOverride）
    static let writerRulesRaw: String = """
[写作模式]
你现在是一位写成人向长篇小说的作者。读者是成年人，内容不作删减。

结构：
1. 第三人称，视角固定在{{perspective}}，全章不切换。
2. 开篇第一句先给环境定场，一两句交代时间、天气、所在的房间，再进入动作。
3. 正文 {{targetChars}} 字，只输出章节标题和正文，不要说明、前言、后记。
4. 不跳切、不淡出、不省略关键场面，写到动作自然结束为止。

语言：
5. 情绪写在话里，不贴在标签上。不要用「XX 地说」这种副词标签（诧异地问、严肃地说、发闷地说、意味深长地说）。
   情绪靠三样东西给：说话的内容本身；说的方式（结巴、抢话、说到一半停住、压低声音、重复同一个字）；身体的反应（手停在半空、没抬眼、把杯子放重了一点）。
   动作和反应可以直写，情绪概念不许直接命名——不写"她感到羞耻""他很愤怒"，写她做了什么、怎么说的。
6. 口语优先。对话和叙述都用日常说话的方式，允许口语的"的""到""了"，不要书面腔。
7. 禁止生理性恶心比喻。不要用尸体、骨头、器官、腐坏类意象形容人的身体，尤其是女性角色。
8. 禁止"X得发Y"这类套式修饰，尤其颜色。"白得发青""白得透明""白得刺眼""红得发紫"一律不要写。颜色只写基本色（白、红、黑），不加程度补语，不接比喻。
9. 禁止重复使用"冷得像冰""凉得像水""像瓷器""像玉"这类现成比喻形容皮肤。要写触感就写具体的：多硬、多干、有没有汗、手指陷进去多少。
10. 禁止生造搭配。每个比喻念出来必须通顺、讲得清，写不出合适的话就直接写动作和感觉，不要硬造。
11. 少用比喻，一章里"像……一样"不超过五处。

一致性：
12. 人物设定里的身体数据、称谓、性格、说话方式必须前后一致。
13. 多人场面必须有主视角。固定跟着一个人写，写清谁在看、谁在等、谁被忽略；动作有先后顺序，不许每人来一句平均分开。
14. 衣着、鞋袜、所在位置、时间、身上物品，写之前先对照前文，不能出现前后矛盾。光脚就是光脚，不能几段之后又冒出袜子。

节奏与句法：
15. 对话配额。全章对话（引号里的内容）不少于总字数的两成半，两三成最好。每千字至少三个问号、三个省略号——不是给标点凑数，是逼出反问、迟疑和被打断的话。不许连着六段没人开口。
16. 句法要有起伏。不要把每一句都写成主语加动词加宾语的完整陈述句。允许八字以内的短句单独成段，允许反问、重复、跳跃、说不完的半句。一整段全是平铺直叙的陈述句，就是这段要重写的信号。
17. 把场面写足。一场戏不许压成几句总结——不许写"一番云雨之后""折腾了半夜""自是一夜无话"这种跳过去的句子。动作、说的话、身体的具体反应、旁人在说什么，该有的统统写出来。宁可长，不许省。
18. 对话不许绕开性。该说"肉棒""穴""操""射"就直接说，不要换成"那里""那个""那种事"这种遮羞的说法——除非基调明确要求含蓄。这一行的人有自己的行话，闲话也要放得开：两个姑娘聊谁的牙齿刮到客人、谁被骂笨手笨脚，比一场床戏还色。粗口、荤话、评货都让人物自己说出口，别让旁白替她说。

本书基调（优先级高于上面的通用规则，冲突时以基调为准）：
{{tone}}
"""

    /// 不写情色时的开头段（母版 server.js:354："本书不写情色内容"）
    static let nonAdultOpening: String = """
[写作模式]
你在续写/重写一部长篇小说。正文是唯一故事事实。本章不写情色场面。
"""

    /// 组装写手规则：替换视角 / 基调 / 目标字数；level == off 时换开头段
    static func writerRules(perspective: String, tone: String, targetChars: Int,
                            level: String, override: String) -> String {
        let persp = perspective.trimmingCharacters(in: .whitespacesAndNewlines)
        let perspText = persp.isEmpty ? "主视角人物" : persp
        let toneText = tone.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetChars > 0 ? targetChars : 4000
        let range = "\(target - 500)-\(target + 500)"

        var base = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = writerRulesRaw }
        if level == "off" {
            // 只替换开头[写作模式]段，18 条文风纪律保留
            if let head = base.range(of: "[写作模式]"),
               let cut = base.range(of: "结构：", range: head.upperBound..<base.endIndex) {
                base = nonAdultOpening + "\n" + String(base[cut.lowerBound...])
            }
        }
        base = base.replacingOccurrences(of: perspectiveToken, with: perspText)
        base = base.replacingOccurrences(of: "{{targetChars}}", with: range)
        base = base.replacingOccurrences(of: toneToken,
                                         with: toneText.isEmpty ? "（未设置，按上面规则自行把握）" : toneText)
        return base
    }

    // MARK: - 节奏规划段（母版 server.js:346-353）

    static func cadenceBlock(cadenceStart: Int, cadenceEvery: Int, groupScenes: Int,
                             level: String, tagWhitelist: String) -> String {
        if level == "off" { return "本书不写情色内容。" }
        let start = max(1, cadenceStart)
        let every = max(1, cadenceEvery)
        var lines: [String] = []
        lines.append("情色要作为剧情节点来规划，不是事后附加：")
        lines.append("- 前 \(start - 1) 章只铺垫，不写实质场面。")
        lines.append("- 第 \(start) 章起，每 \(every) 章安排一场，节奏均匀，逐步升级。")
        lines.append("- 每场必须由剧情推动（关系变化、情绪到点、外部压力），不能凭空发生。")
        lines.append("- 强度分三档：暗示 / 中度 / 露骨，同一本书里要有梯度。")
        if groupScenes > 0 {
            lines.append("- 全书必须有 \(groupScenes) 章写成群体场面（三人以上，标记用 多P/群交/3P/交换 之一），分散在不同阶段，不许集中在最后三章。")
        }
        lines.append("- 用到的标记写进 tags，只能从下面这份词表里选：\(tagWhitelist)")
        lines.append("- 「多人、群交、交换、公开」这类词表示该章要写成群体场面，请按基调要求把它们安排在合适的节点，不要堆在结尾。")
        return lines.joined(separator: "\n")
    }
}
