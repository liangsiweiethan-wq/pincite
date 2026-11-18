import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 四段式速读合成套件

enum SpeedReadPresetSuite {
    static func selection(_ id: String, page: Int, snippet: String) -> AIPreview.Selection {
        AIPreview.Selection(bookID: id, fingerprint: "fp-\(id)", physicalPage: page, snippet: snippet)
    }

    static var tests: [TestDesc] {
        [

            TestDesc(suite: "SpeedRead", name: "presetCarriesFourQuestionsAndFormatInstruction") {
                let question = SpeedReadPreset.questionText(focus: nil)
                try expectTrue(question.contains("背景"), "第 1 问背景")
                try expectTrue(question.contains("前人"), "第 2 问前人不足")
                try expectTrue(question.contains("动机"), "批判性动机问")
                try expectTrue(question.contains("方法"), "第 3 问方法")
                try expectTrue(question.contains("结果"), "第 4 问结果")
                try expectTrue(question.contains("批判性判断"), "第 4 问保留批判问思想（自写文案）")
                // 段式指令：四个固定标题。
                for title in SpeedReadPreset.sectionTitles {
                    try expectTrue(question.contains("### \(title)"), "段式指令含 \(title)")
                }
                try expectTrue(question.contains("（依据："), "页码锚点格式指令")
                try expectTrue(question.contains("只准引用"), "只准引用所给 passages")
            },

            TestDesc(suite: "SpeedRead", name: "builderEmbedsFocusAndBookList") {
                let selections = [selection("b1", page: 1, snippet: "a"), selection("b2", page: 2, snippet: "b")]
                let withFocus = SpeedReadQuestionBuilder.build(selections: selections, question: "关注方法论")
                try expectTrue(withFocus.contains("关注方法论"), "用户附加关注点并入")
                try expectTrue(withFocus.contains("b1"), "证据书目并入")
                let withoutFocus = SpeedReadQuestionBuilder.build(selections: selections)
                try expectFalse(withoutFocus.contains("关注点"), "无关注点不渲染该行")
            },


            TestDesc(suite: "SpeedRead", name: "budgetBoundariesAtFiveNineNineNineToSixZeroZeroOne") {
                try expectEqual(SpeedReadPreset.speedReadCharBudget, 6000, "常数集中一处")
                func make(_ count: Int) -> [AIPreview.Selection] {
                    [selection("b1", page: 1, snippet: String(repeating: "字", count: count))]
                }
                let under = SpeedReadBudget.trim(selections: make(5999))
                try expectFalse(under.truncated)
                try expectEqual(under.droppedCharCount, 0)
                let exact = SpeedReadBudget.trim(selections: make(6000))
                try expectFalse(exact.truncated, "恰在预算内不裁")
                try expectEqual(exact.droppedCharCount, 0)
                let over = SpeedReadBudget.trim(selections: make(6001))
                try expectTrue(over.truncated)
                try expectEqual(over.droppedCharCount, 1, "丢弃计数如实")
                try expectEqual(over.selections[0].snippet.count, 6000)
            },

            TestDesc(suite: "SpeedRead", name: "budgetEvenTrimAcrossSelectionsWithHonestCount") {
                let selections = [
                    selection("b1", page: 1, snippet: String(repeating: "a", count: 4000)),
                    selection("b2", page: 2, snippet: String(repeating: "b", count: 4000)),
                ]
                let outcome = SpeedReadBudget.trim(selections: selections)
                try expectTrue(outcome.truncated)
                try expectEqual(outcome.selections[0].snippet.count, 3000, "均匀份额 budget/2")
                try expectEqual(outcome.selections[1].snippet.count, 3000)
                try expectEqual(outcome.droppedCharCount, 2000, "丢弃计数如实")
            },

            TestDesc(suite: "SpeedRead", name: "budgetSingleOversizedSnippetTruncated") {
                let selections = [selection("b1", page: 1, snippet: String(repeating: "x", count: 9000))]
                let outcome = SpeedReadBudget.trim(selections: selections)
                try expectEqual(outcome.selections[0].snippet.count, 6000, "单块超预算截到预算")
                try expectEqual(outcome.droppedCharCount, 3000)
            },


            TestDesc(suite: "SpeedRead", name: "parserFullFourSectionsWithAnchors") {
                let answer = """
                ### 背景
                该研究处于示例学科争论背景。（依据：b1 第 3 页）
                ### 前人不足
                前人方法忽略制度语境。（依据：b2 第 7 页）
                ### 方法
                提出概念映射方法。（依据：b1 第 12 页）
                ### 结论
                结果支撑其目标。（依据：b2 第 21 页）
                """
                let card = try expectNotNil(SpeedReadCardParser.parse(answerText: answer))
                try expectEqual(card.sections.count, 4, "恒为段式标题顺序四段")
                try expectEqual(card.sections.map(\.title), SpeedReadPreset.sectionTitles)
                try expectFalse(card.sections.contains { $0.isMissing })
                try expectEqual(card.sections[0].anchors, [SpeedReadAnchor(bookID: "b1", page: 3)])
                try expectEqual(card.sections[3].anchors, [SpeedReadAnchor(bookID: "b2", page: 21)])
            },

            TestDesc(suite: "SpeedRead", name: "parserMissingSectionFlaggedHonestly") {
                let answer = """
                ### 背景
                有内容。
                ### 方法
                有内容。
                """
                let card = try expectNotNil(SpeedReadCardParser.parse(answerText: answer))
                let missing = card.sections.filter(\.isMissing).map(\.title)
                try expectEqual(missing, ["前人不足", "结论"], "缺段如实标记")
                try expectTrue(card.sections[0].text.contains("有内容"))
            },

            TestDesc(suite: "SpeedRead", name: "parserOutOfOrderSectionsReanchoredToPresetOrder") {
                let answer = """
                ### 结论
                结论段。
                ### 背景
                背景段。
                ### 方法
                方法段。
                ### 前人不足
                前人段。
                """
                let card = try expectNotNil(SpeedReadCardParser.parse(answerText: answer))
                try expectEqual(card.sections.map(\.title), SpeedReadPreset.sectionTitles,
                                "段序乱仍按标题归位，输出恒为预设顺序")
                try expectTrue(card.sections[0].text.contains("背景段"))
                try expectTrue(card.sections[3].text.contains("结论段"))
            },

            TestDesc(suite: "SpeedRead", name: "parserExtractsMultipleAnchorsPerSection") {
                let answer = """
                ### 背景
                双重依据。（依据：b1 第 2 页）（依据：b2 第 9 页）
                ### 前人不足
                无锚点段落。
                ### 方法
                方法。
                ### 结论
                结论。
                """
                let card = try expectNotNil(SpeedReadCardParser.parse(answerText: answer))
                try expectEqual(card.sections[0].anchors.count, 2)
                try expectEqual(card.sections[0].anchors[1], SpeedReadAnchor(bookID: "b2", page: 9))
                try expectTrue(card.sections[1].anchors.isEmpty, "无锚点段落如实空")
            },

            TestDesc(suite: "SpeedRead", name: "parserReturnsNilForNonCompliantAnswer") {
                try expectNil(SpeedReadCardParser.parse(answerText: "模型没有按段式回答，一整段自由文本。"),
                              "整篇不合规返 nil（调用方整卡降级为普通 answer）")
                try expectNil(SpeedReadCardParser.parse(answerText: ""))
            },


            TestDesc(suite: "SpeedRead", name: "speedReadPurposeRoundTripAndAllCases") {
                let purpose = AIPurpose.speedRead
                try expectEqual(purpose.rawValue, "speedRead")
                let decoded = try JSONDecoder().decode(AIPurpose.self, from: Data("\"speedRead\"".utf8))
                try expectEqual(decoded, purpose, "Codable round-trip")
                let encoded = String(data: try JSONEncoder().encode(purpose), encoding: .utf8)
                try expectEqual(encoded, "\"speedRead\"")
                try expectTrue(AIPurpose.allCases.contains(.speedRead), "allCases 含 speedRead")
                try expectFalse(purpose.displayName.isEmpty, "displayName 非空（穷尽 switch 降级处理）")
            },

            TestDesc(suite: "SpeedRead", name: "speedReadPurposeResolvesThroughExistingChain") {
                // speedRead 绑定档案后 resolveConfiguration(for:) 走既有链正常。
                let dir = Fixtures.makeTempDir("speedread-route")
                defer { Fixtures.cleanup(dir) }
                try await MainActor.run {
                    let keys = InMemoryKeyStorage()
                    let store = AIProfilesStore(directory: dir,
                                                defaults: UserDefaults(suiteName: "speedread-\(UUID().uuidString)")!,
                                                keyStorage: keys)
                    let profile = AIProfile(name: "云端渠道", baseURL: "https://api.example.com/v1",
                                            model: "model-a")
                    store.upsert(profile)
                    try store.upsertKey("sk-1", for: profile.id)
                    store.bind(.speedRead, to: profile.id)
                    guard case .success(let cfg) = store.resolveConfiguration(for: .speedRead) else {
                        try failTest("speedRead 绑定后应可解析")
                        return
                    }
                    try expectEqual(cfg.model, "model-a")
                    try expectEqual(cfg.apiKey, "sk-1")
                }
            },
        ]
    }
}
