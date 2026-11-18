import Foundation
@testable import LiteratureCore

// MARK: - ink_strokes 表 + InkGeometry + UI 状态机纯函数
//
// 触控/Pencil 本身无法合成——可测的全部抽进 Core。

enum InkStrokesSuite {
    static func tempDB(_ tag: String) throws -> (SQLiteDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("annotations.db")
        return (try SQLiteDatabase(path: url.path), url)
    }

    static func makeStore(_ tag: String) throws -> InkStrokesStore {
        let (db, _) = try tempDB(tag)
        return InkStrokesStore(db: db)
    }

    static func stroke(uuid: String = UUID().uuidString, book: String = "bA", page: Int = 3,
                       device: String = "dev-1", created: Double = 100,
                       color: String = "#FFDF3E", width: Double = 2,
                       points: [InkPoint]? = nil) -> InkStroke {
        InkStroke(strokeUUID: uuid, bookID: book, pageNumber: page, deviceID: device,
                  createdAt: created, color: color, lineWidth: width,
                  points: points ?? [InkPoint(x: 0.1, y: 0.1), InkPoint(x: 0.9, y: 0.9)])
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "InkStrokes", name: "ddlIdempotentAndSubschemaVersioned") {
                let (db, _) = try tempDB("ddl")
                _ = InkStrokesStore(db: db)
                _ = InkStrokesStore(db: db)   // 二次开：CREATE IF NOT EXISTS 幂等
                let probe = InkStrokesStore(db: db)
                try expectEqual(probe.storedSubschemaVersion, InkStrokesStore.subschemaVersion)
                try expectEqual(try probe.totalRowCount(), 0)
            },

            TestDesc(suite: "InkStrokes", name: "insertQueryTombstoneKeepsRowQueryable") {
                let store = try makeStore("tomb")
                let s = stroke(book: "bK", page: 7)
                try expectNotNil(try store.addStroke(s))
                try expectEqual(try store.strokes(bookID: "bK").count, 1)
                try expectEqual(try store.strokes(bookID: "bK", pageNumber: 7).count, 1)
                try expectTrue(try store.strokes(bookID: "bK", pageNumber: 8).isEmpty)
                // 幂等键：同 uuid 再插 → nil（跳过），不翻倍。
                try expectNil(try store.addStroke(s))
                try expectEqual(try store.totalRowCount(), 1)
                // 墓碑：活动视图消失、含墓碑视图保留、物理行数不变。
                try expectTrue(try store.tombstone(strokeUUID: s.strokeUUID))
                try expectTrue(try store.strokes(bookID: "bK").isEmpty)
                let withDeleted = try store.strokes(bookID: "bK", includeDeleted: true)
                try expectEqual(withDeleted.count, 1)
                try expectNotNil(withDeleted.first?.deletedAt)
                try expectEqual(try store.totalRowCount(), 1, "墓碑 = 行保留（无物理删除）")
                // 重复墓碑幂等 false；untombstone 恢复。
                try expectFalse(try store.tombstone(strokeUUID: s.strokeUUID))
                try expectTrue(try store.untombstone(strokeUUID: s.strokeUUID))
                try expectEqual(try store.strokes(bookID: "bK").count, 1)
            },

            TestDesc(suite: "InkStrokes", name: "coordinateRoundtripAcrossViewports") {
                let viewports = [
                    InkGeometry.PageViewport(originX: 0, originY: 0, width: 300, height: 400),
                    InkGeometry.PageViewport(originX: 20, originY: 40, width: 768, height: 1024),
                    InkGeometry.PageViewport(originX: -50, originY: 0, width: 50, height: 50),
                ]
                for vp in viewports {
                    for p in [InkPoint(x: 0, y: 0), InkPoint(x: 1, y: 1), InkPoint(x: 0.37, y: 0.83)] {
                        let v = InkGeometry.viewPoint(fromPageRelative: p, in: vp)
                        let back = InkGeometry.pageRelative(viewX: v.x, viewY: v.y, in: vp)
                        try expectTrue(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9,
                                       "roundtrip 失败: \(p) → \(v) → \(back) in \(vp)")
                    }
                }
            },

            TestDesc(suite: "InkStrokes", name: "simplifyCapsPointsAndKeepsShape") {
                var line: [InkPoint] = []
                for i in 0..<200 { line.append(InkPoint(x: Double(i) / 199, y: 0.5)) }
                let simplified = InkGeometry.simplify(points: line)
                try expectTrue(simplified.count <= InkGeometry.maxStrokePoints,
                               "直线共线点必须被收掉: \(simplified.count)")
                // 带噪声曲线：保转折、上限内。
                var curve: [InkPoint] = []
                for i in 0..<200 {
                    let t = Double(i) / 199
                    curve.append(InkPoint(x: t, y: t < 0.5 ? t * 0.2 : 0.1 + (t - 0.5) * 1.6))
                }
                let kept = InkGeometry.simplify(points: curve)
                try expectTrue(kept.count >= 2 && kept.count <= InkGeometry.maxStrokePoints)
                try expectTrue(InkGeometry.fitsByteBudget(points: kept), "抽稀后单笔必须 < 4KB")
                // 超窗拒收语义：>60 点未抽稀直接 validate 拒。
                let store = try makeStore("cap")
                try expectThrows(try store.validate(stroke(points: curve)),
                                 "超 60 点必须拒收（抽稀是调用方责任，store 层把门）")
            },

            TestDesc(suite: "InkStrokes", name: "hitTestWithinThreshold") {
                let vp = InkGeometry.PageViewport(originX: 0, originY: 0, width: 100, height: 100)
                let diag = [InkPoint(x: 0, y: 0), InkPoint(x: 1, y: 1)]   // 视图 (0,0)→(100,100)
                try expectTrue(InkGeometry.hitTest(viewX: 50, viewY: 50, strokePoints: diag,
                                                  viewport: vp, thresholdPoints: 5),
                               "对角线中点必须命中")
                try expectTrue(InkGeometry.hitTest(viewX: 52, viewY: 50, strokePoints: diag,
                                                  viewport: vp, thresholdPoints: 5),
                               "近旁 2pt 内必须命中")
                try expectFalse(InkGeometry.hitTest(viewX: 50, viewY: 80, strokePoints: diag,
                                                   viewport: vp, thresholdPoints: 5),
                                "远离必须不命中")
                try expectFalse(InkGeometry.hitTest(viewX: 50, viewY: 50, strokePoints: [],
                                                   viewport: vp, thresholdPoints: 5))
            },

            TestDesc(suite: "InkStrokes", name: "validateGuardsFailClosed") {
                let store = try makeStore("validate")
                try expectThrows(try store.validate(stroke(points: [InkPoint(x: 1.2, y: 0.5), InkPoint(x: 0.5, y: 0.5)])),
                                 "越界坐标必须拒收")
                try expectThrows(try store.validate(stroke(page: 0)), "页码 0 必须拒收")
                try expectThrows(try store.validate(stroke(width: 0)), "零线宽必须拒收")
                try expectThrows(try store.validate(stroke(color: "red")), "非 #RRGGBB 必须拒收")
                try expectThrows(try store.validate(stroke(uuid: "")), "空 uuid 必须拒收")
                try expectThrows(try store.validate(stroke(points: [InkPoint(x: 0.1, y: 0.1)])),
                                 "单点笔迹必须拒收")
                try expectNoThrow(try store.validate(stroke()))
                // 4KB 预算：大量抽稀后点也塞不进——构造超预算的点列先在 validate 拒。
                var fat: [InkPoint] = []
                for i in 0..<60 { fat.append(InkPoint(x: Double(i) / 59, y: Double(i % 7) / 7)) }
                try expectNoThrow(try store.validate(stroke(points: fat)))
            },

            TestDesc(suite: "InkStrokes", name: "deviceIdentityStablePerDefaults") {
                let a = UserDefaults(suiteName: "ink-test-a-\(UUID().uuidString)")!
                let b = UserDefaults(suiteName: "ink-test-b-\(UUID().uuidString)")!
                let ida1 = DeviceIdentity.deviceID(defaults: a)
                let ida2 = DeviceIdentity.deviceID(defaults: a)
                let idb = DeviceIdentity.deviceID(defaults: b)
                try expectEqual(ida1, ida2, "同一 defaults 必须稳定")
                try expectNotEqual(ida1, idb, "不同 defaults 必须不同身份")
                try expectEqual(a.string(forKey: DeviceIdentity.defaultsKey), ida1)
            },

            TestDesc(suite: "InkStrokes", name: "toolPickerConfigMapping") {
                let pen = InkToolSelection.paletteDefault
                try expectEqual(pen.colorHex, InkToolSelection.primaryColors[0])
                var config = InkToolSelection.toolPickerConfig(pen)
                try expectFalse(config.isMarker, "默认 pen")
                try expectEqual(config.colorHex, pen.colorHex)
                try expectEqual(config.width, pen.lineWidth)
                let marker = InkToolSelection(colorHex: "#8EC9FF", lineWidth: 5, tool: .marker)
                config = InkToolSelection.toolPickerConfig(marker)
                try expectTrue(config.isMarker, "marker 必须映射为 isMarker=true")
                try expectEqual(config.width, 5.0)
                // 琥珀不入选一级四色（琥珀 = OCR 来源专用信号色，零新增位点）。
                try expectFalse(InkToolSelection.primaryColors.contains { $0.caseInsensitiveCompare("#FFC000") == .orderedSame }
                                    || InkToolSelection.primaryColors.contains { $0.lowercased() == "#ffa000" },
                                "一级四色不得含琥珀系信号色")
            },

            TestDesc(suite: "InkStrokes", name: "sessionStackUndoRedoSequence") {
                var stack = InkSessionStack()
                try expectNil(stack.undo(), "空栈不可撤销")
                stack.record("s1")
                stack.record("s2")
                stack.record("s3")
                try expectEqual(stack.undo(), "s3")
                try expectEqual(stack.undo(), "s2")
                try expectEqual(stack.redo(), "s2")
                stack.record("s4")   // 新操作清空 redo
                try expectNil(stack.redo(), "新操作必须使 redo 失效")
                try expectEqual(stack.undo(), "s4")
                try expectEqual(stack.undo(), "s2", "redo 后 undoStack = [s1, s2, s4]")
                try expectEqual(stack.undo(), "s1")
                try expectNil(stack.undo())
                try expectEqual(stack.redo(), "s1")
            },

            TestDesc(suite: "InkStrokes", name: "sessionStackDrivesTombstoneRoundtrip") {
                let store = try makeStore("stack")
                let s = stroke()
                try expectNotNil(try store.addStroke(s))
                var stack = InkSessionStack()
                stack.record(s.strokeUUID)
                if let uuid = stack.undo() {
                    try expectTrue(try store.tombstone(strokeUUID: uuid))
                } else { try failTest("undo 必须给出 uuid") }
                try expectTrue(try store.strokes(bookID: s.bookID).isEmpty)
                if let uuid = stack.redo() {
                    try expectTrue(try store.untombstone(strokeUUID: uuid))
                } else { try failTest("redo 必须给出 uuid") }
                try expectEqual(try store.strokes(bookID: s.bookID).count, 1)
            },

            TestDesc(suite: "InkStrokes", name: "pointsJSONRoundtripAndBadInputRejected") {
                let pts = [InkPoint(x: 0, y: 0), InkPoint(x: 0.5, y: 0.25), InkPoint(x: 1, y: 1)]
                let json = InkGeometry.encodePoints(pts)
                try expectEqual(InkGeometry.decodePoints(json), pts)
                try expectNil(InkGeometry.decodePoints("not json"))
                try expectNil(InkGeometry.decodePoints("[[0.5]]"))        // 单元素对
                try expectNil(InkGeometry.decodePoints("[[1.5, 0.2]]"))   // 越界
                try expectNil(InkGeometry.decodePoints("[[0.1, \"x\"]]")) // 非 double
            },
        ]
    }
}
