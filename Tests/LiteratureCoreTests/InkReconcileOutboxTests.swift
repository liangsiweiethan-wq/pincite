import Foundation
@testable import LiteratureCore

// MARK: -：canvas 身份结算 + ShareOutbox 队列结算 + 会话栈方向语义
//
// 清空判定两向单测——「未落库笔不清空 / 已落库笔
// 剔除」；失败注入回归——模拟上传 3 连败断言队列恰 1 份；
// 会话栈方向语义（撤销画笔 = 补墓碑 / 撤销擦除 = 解墓碑）
// 与墓碑联动闭环。iOS UIKit 施加面（PKCanvasView/InkOverlayView）由 iOS
// 编译门 + 模拟器， 同规）。

enum InkReconcileOutboxSuite {

    /// 结算测试桩件。
    private struct StubItem: ShareOutboxItem {
        var outboxID: String
        var payloadText: String
        func outboxPayload() throws -> Data { Data(payloadText.utf8) }
    }

    /// 始终失败的 uploader（失败注入）。
    private struct FailingUploader {
        var attempts = 0
        mutating func upload(payload: Data, item: StubItem) async throws {
            attempts += 1
            throw StubError("attempt \(attempts) failed")
        }
    }

    struct StubError: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { message = m }
        var description: String { message }
    }

    static var tests: [TestDesc] {
        [
            // InkCanvasReconcile 两向 ──

            TestDesc(suite: "InkReconcileOutbox", name: "persistedStrokesRemovedFromCanvas") {
                // baseline=2（既有未落库 2 笔），新增 3 笔全落库 → 保留 [0,1]。
                let keep = InkCanvasReconcile.keepIndices(total: 5, baseline: 2,
                                                          persistedRelative: [0, 1, 2])
                try expectEqual(keep, [0, 1], "已落库笔剔除（禁计数比对——旧计数法在本例误清全部）")
            },

            TestDesc(suite: "InkReconcileOutbox", name: "unpersistedStrokesNeverCleared") {
                let keep = InkCanvasReconcile.keepIndices(total: 5, baseline: 2,
                                                          persistedRelative: [])
                try expectEqual(keep, [0, 1, 2, 3, 4], "落库失败笔留画布（旧计数法在本例可能误清）")
            },

            TestDesc(suite: "InkReconcileOutbox", name: "mixedOutcomeKeepsExactlyFailedOnes") {
                let keep = InkCanvasReconcile.keepIndices(total: 6, baseline: 1,
                                                          persistedRelative: [0, 2])
                try expectEqual(keep, [0, 2, 4, 5], "新增段相对 1/3（未落库）= 全局 2/4 保留，相对 0/2（已落库）= 全局 1/3 剔除")
                try expectTrue(InkCanvasReconcile.shouldKeep(globalIndex: 2, total: 6, baseline: 1,
                                                             persistedRelative: [0, 2]))
                try expectTrue(InkCanvasReconcile.shouldKeep(globalIndex: 4, total: 6, baseline: 1,
                                                             persistedRelative: [0, 2]))
                try expectFalse(InkCanvasReconcile.shouldKeep(globalIndex: 1, total: 6, baseline: 1,
                                                              persistedRelative: [0, 2]),
                                "全局下标 1 = 新增段相对 0（已落库）→ 不保留")
                try expectFalse(InkCanvasReconcile.shouldKeep(globalIndex: 3, total: 6, baseline: 1,
                                                              persistedRelative: [0, 2]),
                                "全局下标 3 = 新增段相对 2（已落库）→ 不保留")
            },

            TestDesc(suite: "InkReconcileOutbox", name: "reconcileInputsFailClosed") {
                try expectEqual(InkCanvasReconcile.keepIndices(total: 0, baseline: 3,
                                                               persistedRelative: [0]), [])
                // baseline > total：夹回 total（全量视为既有，全保留）。
                try expectEqual(InkCanvasReconcile.keepIndices(total: 3, baseline: 9,
                                                               persistedRelative: [0]), [0, 1, 2])
                // baseline < 0：夹回 0（全量视为新增段）。
                try expectEqual(InkCanvasReconcile.keepIndices(total: 2, baseline: -1,
                                                               persistedRelative: [0, 1]), [])
                // persistedRelative 越界项（相对下标 ≥ 段长）忽略不崩溃：
                // baseline=1 前缀保 0；相对 0（全局 1）落库剔除；相对 1（全局 2）保留。
                try expectEqual(InkCanvasReconcile.keepIndices(total: 3, baseline: 1,
                                                               persistedRelative: [0, 5, -2]), [0, 2])
            },

            // ShareOutbox 失败注入回归 ──

            TestDesc(suite: "InkReconcileOutbox", name: "tripleUploadFailureEnqueuesExactlyOneCopy") {
                let item = StubItem(outboxID: "a1", payloadText: "hello")
                var uploader = FailingUploader()
                let outcome = await ShareOutbox.flush([item]) { payload, item in
                    // 闭包内 ≤3 次换名重试（生产 ShareCapture.flush 同形）；
                    // 穷尽重试抛最后错误 = 本件失败。
                    var lastError: Error?
                    for _ in 0..<3 {
                        do {
                            try await uploader.upload(payload: payload, item: item)
                            return
                        } catch {
                            lastError = error
                        }
                    }
                    throw lastError ?? StubError("exhausted")
                }
                try expectEqual(outcome.sent, [String](), "全败：sent 空")
                try expectEqual(outcome.remaining.count, 1, "失败件恰 1 份入队（双份入队问题回归断言固定）")
                try expectEqual(outcome.remaining.first?.outboxID, "a1")
                try expectNotNil(outcome.error, "错误在队列结算后如实上抛")
                try expectEqual(uploader.attempts, 3, "闭包内 3 连败（重试语义由闭包表达）")
            },

            TestDesc(suite: "InkReconcileOutbox", name: "mixedOutcomePartitionsWithoutDuplication") {
                let items = [
                    StubItem(outboxID: "ok-1", payloadText: "a"),
                    StubItem(outboxID: "bad-1", payloadText: "b"),
                    StubItem(outboxID: "ok-2", payloadText: "c"),
                    StubItem(outboxID: "bad-2", payloadText: "d"),
                ]
                let outcome = await ShareOutbox.flush(items) { _, item in
                    if item.outboxID.hasPrefix("bad") { throw StubError(item.outboxID) }
                }
                try expectEqual(outcome.sent, ["ok-1", "ok-2"])
                try expectEqual(outcome.remaining.map(\.outboxID), ["bad-1", "bad-2"],
                                "失败件各恰一份、保持输入序")
                try expectEqual(Set(outcome.sent).isDisjoint(with: outcome.remaining.map(\.outboxID)), true)
                try expectNotNil(outcome.error, "首个错误保留（bad-1）")
            },

            TestDesc(suite: "InkReconcileOutbox", name: "payloadValidationFailureGoesToRemainingOnce") {
                struct BadItem: ShareOutboxItem {
                    var outboxID: String { "bad-payload" }
                    func outboxPayload() throws -> Data { throw StubError("payload rejected") }
                }
                let outcome = await ShareOutbox.flush([BadItem()]) { _, _ in
                    try failTest("载荷校验失败件不应触达上传")
                }
                try expectEqual(outcome.sent, [String]())
                try expectEqual(outcome.remaining.count, 1)
                try expectNotNil(outcome.error)
            },

            TestDesc(suite: "InkReconcileOutbox", name: "allSuccessLeavesEmptyQueue") {
                let items = [StubItem(outboxID: "x", payloadText: "1"),
                             StubItem(outboxID: "y", payloadText: "2")]
                let outcome = await ShareOutbox.flush(items) { _, _ in }
                try expectEqual(outcome.sent, ["x", "y"])
                try expectTrue(outcome.remaining.isEmpty)
                try expectNil(outcome.error)
                // 空队列直通。
                let empty = await ShareOutbox.flush([StubItem]()) { _, _ in
                    try failTest("空队列不应触达上传")
                }
                try expectTrue(empty.sent.isEmpty && empty.remaining.isEmpty && empty.error == nil)
            },

            // 会话栈方向语义 ──

            TestDesc(suite: "InkReconcileOutbox", name: "legacyUndoRedoStringAPIUnchanged") {
                var stack = InkSessionStack()
                stack.record("s1")
                stack.record("s2")
                try expectEqual(stack.undo(), "s2")
                try expectEqual(stack.redo(), "s2")
                stack.record(kind: .erase, strokeUUID: "e1")   // 新操作清 redo
                try expectNil(stack.redo())
                try expectEqual(stack.undo(), "e1", "旧签名回 uuid（方向语义走 undoOp）")
            },

            TestDesc(suite: "InkReconcileOutbox", name: "directionalOpsDriveTombstoneBothWays") {
                let store = try InkStrokesSuite.makeStore("dir-ops")
                let drawn = InkStrokesSuite.stroke(uuid: "draw-1", book: "bK", page: 2)
                let erased = InkStrokesSuite.stroke(uuid: "erase-1", book: "bK", page: 2)
                try expectNotNil(try store.addStroke(drawn))
                try expectNotNil(try store.addStroke(erased))
                var stack = InkSessionStack()
                stack.record(drawn.strokeUUID)                          // 画一笔
                if (try? store.tombstone(strokeUUID: erased.strokeUUID)) != true {
                    try failTest("预置擦除态失败")
                }
                stack.record(kind: .erase, strokeUUID: erased.strokeUUID)  // 擦一笔
                // 撤销 1：擦除 → 解墓碑（恢复 erased）。
                guard let op1 = stack.undoOp() else { try failTest("undoOp 必须有值") }
                try expectEqual(op1.kind, InkSessionOpKind.erase)
                try expectTrue(try store.untombstone(strokeUUID: op1.strokeUUID))
                try expectEqual(try store.strokes(bookID: "bK").count, 2)
                // 撤销 2：画笔 → 补墓碑（移除 drawn）。
                guard let op2 = stack.undoOp() else { try failTest("undoOp 必须有值") }
                try expectEqual(op2.kind, InkSessionOpKind.draw)
                try expectTrue(try store.tombstone(strokeUUID: op2.strokeUUID))
                try expectEqual(try store.strokes(bookID: "bK").count, 1)
                // 重做 1：画笔恢复 = 解墓碑。
                guard let rop1 = stack.redoOp() else { try failTest("redoOp 必须有值") }
                try expectEqual(rop1.kind, InkSessionOpKind.draw)
                try expectTrue(try store.untombstone(strokeUUID: rop1.strokeUUID))
                // 重做 2：擦除重放 = 补墓碑。
                guard let rop2 = stack.redoOp() else { try failTest("redoOp 必须有值") }
                try expectEqual(rop2.kind, InkSessionOpKind.erase)
                try expectTrue(try store.tombstone(strokeUUID: rop2.strokeUUID))
                try expectEqual(try store.strokes(bookID: "bK").count, 1, "终态 = 只有 drawn 可见")
                // 两撤两重做后回到满栈（两操作皆在 undo 侧）；redo 侧空。
                try expectEqual(stack.undoOps.count, 2, "回到初始满栈")
                try expectNil(stack.redoOp())
                // 再撤销一次仍方向正确（erase → 解墓碑）。
                guard let again = stack.undoOp() else { try failTest("undoOp 必须有值") }
                try expectEqual(again.kind, InkSessionOpKind.erase)
            },

            TestDesc(suite: "InkReconcileOutbox", name: "eraserToolPickerConfigPinned") {
                let eraser = InkToolSelection(colorHex: "#8EC9FF", lineWidth: 2, tool: .eraser)
                let config = InkToolSelection.toolPickerConfig(eraser)
                try expectFalse(config.isMarker, "eraser 不经 PKToolPicker（划掉即擦除手势语义）")
                try expectTrue(InkTool.allCases.contains(.eraser), "InkTool 三 case（pen/marker/eraser）")
            },
        ]
    }
}
