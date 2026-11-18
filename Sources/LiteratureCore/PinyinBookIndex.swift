import Foundation
import CoreFoundation

// MARK: - 拼音书目检索（调研 B 组条目 1/2/8 落地）
//
// 需求：输入 "yangshu" / "yangshuyi" 能找到虚构中文书。
// 方案：导入侧预生成拼音投影（零第三方依赖，系统 CFStringTransform），
// 存独立 book_pinyin 表（不动 books schema），查询侧把 ASCII 字母查询词
// 走同一归一函数后做包含匹配。
// 多音字局限：单投影对多音字只含一种读音
//（CFStringTransform 对常见词组有一定消歧，如 重庆→chongqing，但无保证）。
// 读音不同的别名检索需双投影/分词表，登记 （需多音字数据表，非注释级修复）。

public enum PinyinNorm {
    /// 【归一投影契约】非 CJK 输入一律输出
    /// **小写字母/数字串**。流程：NFC → StripDiacritics → MandarinLatin →
    /// StripDiacritics → 小写 → 仅留字母数字字符。
    /// 边界断言见 PinyinSyllableGate/queryContractBoundaryFourClasses：
    ///   - 大小写折叠："FaLv" → "falv"（用户 shift/大写锁定态照常归一）；
    ///   - 控制字符/空格/标点滤除："fa\tlv" → "falv"；
    ///   - 非 ASCII 拉丁字母折 ASCII："café" → "cafe"、"nǚ" → "nu"；
    ///   - **全角不折叠**："ｆａｌｖ" → "ｆａｌｖ"（NFC 不做宽度折叠，宽度
    /// 折叠属 NFKC，不在本函数基准）——这正是 isPinyinQuery 必须从窄
    ///     拒绝全角的根由：全角 needle 若放行，与 ASCII 库存投影 instr 永假，
    ///     静默零命中。
    /// 设计理由：查询词与库存值走同一函数，保证基准一致（查询侧不引入
    /// 库存侧没有的归一步骤，反之亦然）。
    public static func transform(_ text: String) -> String {
        // 预归一：NFC 稳定多音字上下文与全半角差异（Foundation 预组合映射）。
        let mutable = NSMutableString(string: text.precomposedStringWithCanonicalMapping)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let lowered = (mutable as String).lowercased()
        // 只保留字母数字（去空格/标点/分隔符）：拼音连写与西文单词统一。
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 【查询门控契约】基准＝**长度 ≥2 的纯
    /// ASCII 字母串**（大小写不限）。只有这类词触发书目拼音匹配，其余查询
    /// （中文/数字/标点/单字符/空串）零开销短路。
    /// 显式拒绝（各自理由——本谓词建模的是"用户键盘直出的拼音检索意图"，
    /// nv/lv 是拼音用户的键盘形态；拒绝≠输入非法，而是"非键盘直出形态不进
    /// 拼音门"）：
    ///   - 带调拼音（"nǚ"）：来自复制粘贴注音，不是键盘检索输入；
    ///   - 全角字母（"ｆａｌｖ"）：IME 全角态误切产物；transform 不折叠全角
    ///     （见 transform 契约注释），门控放行只会静默零命中；
    ///   - 非 ASCII Unicode 字母（"café" 的 é）：西文词检索另有主链路；
    ///   - ASCII 控制字符/数字/标点：不可能出自键盘拼音输入（控制字符来自
    ///     剪贴板/文件误粘贴；数字/标点不构成全拼音节串词形）。
    /// 大小写**不拒**："FaLv" 合法（shift/大写锁定是正常键盘态，小写折叠
    /// 交 transform）。下游固定契约：bookIDsMatchingPinyin 对非本基准输入
    /// 一律空集（PinyinSyllableGate/nonPinyinQueryNeedleReturnsEmpty）。
    public static func isPinyinQuery(_ term: String) -> Bool {
        term.count >= 2 && term.allSatisfy { ($0.isASCII && $0.isLetter) }
    }
}

/// 全拼 IME 音节判定器（设计取舍：判定器提前落地，
/// 签名对齐
/// `enum PinyinSyllables { static func isParseable(_ asciiLetters: String) -> Bool }`；
enum PinyinSyllables {

    /// 音节表按声母分组（每行一组，便于对照权威音节表增删；总数 414 断言在
    /// PinyinSyllableComplete/tableScaleAndShapeInvariant，改动须连测试一起改
    static let syllables: Set<String> = [
        // 零声母
        "a", "ai", "an", "ang", "ao", "e", "ei", "en", "eng", "er", "o", "ou",
        // y / w（i/u/ü 行的拼写形态）
        "ya", "yo", "yao", "ye", "you", "yan", "yin", "yang", "ying", "yu",
        "yue", "yuan", "yun", "yong", "yi",
        "wa", "wai", "wei", "wan", "wen", "wang", "weng", "wo", "wu",
        // b p m f
        "ba", "bo", "bai", "bei", "bao", "ban", "ben", "bang", "beng", "bi",
        "bie", "biao", "bian", "bin", "bing", "bu",
        "pa", "po", "pai", "pei", "pao", "pou", "pan", "pen", "pang", "peng",
        "pi", "pie", "piao", "pian", "pin", "ping", "pu",
        "ma", "me", "mo", "mai", "mei", "mao", "mou", "man", "men", "mang",
        "meng", "mi", "mie", "miao", "miu", "mian", "min", "ming", "mu",
        "fa", "fo", "fei", "fou", "fan", "fen", "fang", "feng", "fu",
        // d t（含扩展 dei/den/dia（嗲）/tei（忒））
        "da", "dai", "dao", "dei", "de", "dan", "den", "dang", "deng", "dou",
        "di", "dia", "die", "diao", "diu", "dian", "ding", "dong", "du", "duo",
        "dui", "duan", "dun",
        "ta", "tai", "tao", "tei", "te", "tan", "tang", "teng", "tou", "ti",
        "tie", "tiao", "tian", "ting", "tong", "tu", "tuo", "tui", "tuan",
        "tun",
        // n l（含扩展 ne/nou/nun/lou/lia/lo；lv/nv/lve/nve 惯用形：ü→v 的
        // IME 约定，本判定器的存在理由）
        "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "nou",
        "ni", "nie", "niao", "niu", "nian", "nin", "niang", "ning", "nong",
        "nu", "nuo", "nuan", "nun", "nue", "nv", "nve",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "lou", "lo",
        "li", "lia", "lie", "liao", "liu", "lian", "lin", "liang", "ling",
        "long", "lu", "luo", "luan", "lun", "lue", "lv", "lve",
        // g k h（含扩展 kei（剋））
        "ga", "gai", "gao", "ge", "gei", "gen", "geng", "gan", "gang", "gou",
        "gu", "gua", "guo", "guai", "gui", "guan", "gun", "gong", "guang",
        "ka", "kai", "kao", "ke", "kei", "kan", "kang", "ken", "keng", "kou",
        "ku", "kua", "kuo", "kuai", "kui", "kuan", "kun", "kong", "kuang",
        "ha", "hai", "hang", "hao", "he", "hei", "han", "hen", "heng", "hou",
        "hu",
        "hua", "huo", "huai", "hui", "huan", "hun", "hong", "huang",
        // j q x（含 iong 系 jiong/qiong/xiong）
        "ji", "jia", "jiao", "jie", "jiu", "jian", "jin", "jiang", "jing",
        "jiong", "ju", "jue", "juan", "jun",
        "qi", "qia", "qiao", "qie", "qiu", "qian", "qin", "qiang", "qing",
        "qiong", "qu", "que", "quan", "qun",
        "xi", "xia", "xiao", "xie", "xiu", "xian", "xin", "xiang", "xing",
        "xiong", "xu", "xue", "xuan", "xun",
        // zh ch sh（含扩展 zhei（这）/shei（谁）/chua（欻））
        "zha", "zhai", "zhao", "zhe", "zhei", "zhen", "zhang", "zheng", "zhan",
        "zhi", "zhong", "zhou", "zhu", "zhua", "zhuo", "zhuai", "zhui",
        "zhuan", "zhun", "zhuang",
        "cha", "chai", "chao", "che", "chan", "chen", "chang", "cheng", "chi",
        "chong", "chou", "chu", "chua", "chuo", "chuai", "chui", "chuan",
        "chun", "chuang",
        "sha", "shai", "shao", "she", "shei", "shen", "shan", "shang", "sheng",
        "shi", "shou", "shu", "shua", "shuo", "shuai", "shui", "shuan",
        "shun", "shuang",
        // r z c s（含扩展 rua（挼）；补 zou/cou/can/cang/san/sang/zan/zhou/
        // chou/rao/ren/rong 等缺收）
        "re", "ran", "rao", "ren", "rang", "reng", "ri", "rong", "rou", "ru",
        "rua", "ruo", "rui", "ruan", "run",
        "za", "zai", "zao", "zan", "zang", "ze", "zei", "zen", "zeng", "zi",
        "zong", "zou", "zu", "zuo", "zui", "zuan", "zun",
        "ca", "cai", "cao", "can", "cang", "ce", "cen", "ceng", "ci", "cong",
        "cou", "cu", "cuo", "cui", "cuan", "cun",
        "sa", "sai", "sao", "san", "sang", "se", "sen", "seng", "si", "song",
        "sou", "su", "suo", "sui", "suan", "sun",
    ]

    /// 整词完全可切分为合法音节串才 true。输入预期为归一小写 ASCII 字母串
    /// （调用方传 PinyinNorm.transform 产物；防御性小写与字母校验降级处理）。
    /// 长度 O(n·6) 查表，查询词量级零负担。
    static func isParseable(_ asciiLetters: String) -> Bool {
        let s = asciiLetters.lowercased()
        guard s.count >= 2, s.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let chars = Array(s)
        let n = chars.count
        var dp = [Bool](repeating: false, count: n + 1)
        dp[0] = true
        for i in 0..<n where dp[i] {
            let maxJ = min(i + 6, n)
            for j in (i + 1)...maxJ where !dp[j] {
                if syllables.contains(String(chars[i..<j])) { dp[j] = true }
            }
        }
        return dp[n]
    }

    static func collectForms(for norm: String) -> [String] {
        guard isParseable(norm) else { return [norm] }
        let alias = norm.replacingOccurrences(of: "v", with: "u")
        return alias == norm ? [norm] : [norm, alias]
    }
}

extension IndexStore {
    /// 为缺拼音投影的书补齐（开库与索引批末调用；幂等，只处理 NULL 行）。
    @discardableResult
    public func backfillPinyinIfNeeded() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try backfillPinyinIfNeededLocked()
    }

    /// Caller must hold the lock (IndexStore.init 迁移段直接调用).
    func backfillPinyinIfNeededLocked() throws -> Int {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS book_pinyin(
            book_id TEXT PRIMARY KEY,
            pinyin_norm TEXT NOT NULL
        ) WITHOUT ROWID;
        """)
        let missing = try db.prepare("""
        SELECT b.id, b.file_name, b.title, b.author FROM books b
        LEFT JOIN book_pinyin p ON p.book_id = b.id
        WHERE p.book_id IS NULL;
        """)
        var updates: [(String, String)] = []
        while try missing.step() {
            let id = missing.text(0)
            let source = [missing.text(1), missing.text(2), missing.text(3)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            updates.append((id, PinyinNorm.transform(source)))
        }
        guard !updates.isEmpty else { return 0 }
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let ins = try db.prepare("INSERT OR REPLACE INTO book_pinyin(book_id, pinyin_norm) VALUES(?, ?);")
            for (id, pinyin) in updates {
                try ins.reset(); try ins.clearBindings()
                try ins.bindText(1, id)
                try ins.bindText(2, pinyin)
                try ins.run()
            }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
        return updates.count
    }

    /// 拼音包含匹配（needle 已归一）：命中的 book_id 有序数组——主形态命中
    /// 在前、别名命中在后，组内按 book_id ASC（collect 查询显式 `ORDER BY book_id ASC`，主/别名两处 collect 共用该
    /// 语句，输出全序断言在 SQL 层，不再依赖 WITHOUT ROWID 存储序的实现细节；
    /// 跨书排序断言见 PinyinSyllableGate/collectOrderMainGroupThenAliasGroup-
    /// BookIdAsc 与 crossBookOrderPrimaryBeforeAlias）。书目不存在（已删除/
    /// 被清）的投影行自然不进结果——调用方按 book(byID:) 降级处理。
    public func bookIDsMatchingPinyin(_ needle: String) throws -> [String] {
        // （方案 A 固定契约）：先于任何 DB 访问拒绝非拼音查询。
        guard PinyinNorm.isPinyinQuery(needle) else { return [] }
        lock.lock(); defer { lock.unlock() }
        let norm = PinyinNorm.transform(needle)
        guard norm.count >= 2 else { return [] }
        // ORDER BY book_id ASC——主/别名两处 collect 共用本语句，
        // 组内全序由此断言固定（SQL 契约，不依赖存储实现序）。
        let stmt = try db.prepare("SELECT book_id FROM book_pinyin WHERE instr(pinyin_norm, ?) > 0 ORDER BY book_id ASC;")
        var seen = Set<String>()
        var out: [String] = []
        func collect(_ form: String) throws {
            try stmt.reset(); try stmt.clearBindings()
            try stmt.bindText(1, form)
            while try stmt.step() {
                let id = stmt.text(0)
                if seen.insert(id).inserted { out.append(id) }
            }
        }
        for form in PinyinSyllables.collectForms(for: norm) {
            try collect(form)
        }
        return out
    }

    /// 删除书的拼音投影（deleteBookLocked 同步清理，防孤儿行；调用方持锁）。
    func deletePinyinRowLocked(bookID: String) throws {
        let stmt = try db.prepare("DELETE FROM book_pinyin WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        try stmt.run()
    }
}
