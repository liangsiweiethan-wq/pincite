import Foundation
import CoreGraphics
@testable import LiteratureSearchUI

// MARK: -：快照裁剪几何纯函数套件
//
// 契约：cropRatio 正常归一化；选区越页界 clamp；零面积/倒置
// 返回 nil；cropedImageSize 换算四舍五入语义断言固定；比例恒等（全页选区→
// (0,0,1,1)）。CoreGraphics 跨平台类型，无 AppKit。

enum SnapshotGeometrySuite {
    static var tests: [TestDesc] {
        let page = CGRect(x: 0, y: 0, width: 400, height: 600)
        return [
            TestDesc(suite: "SnapshotGeometry", name: "cropRatioNormalizesInsidePage") {
            let ratio = try expectNotNil(SnapshotGeometry.cropRatio(
                pageBounds: page,
                selectionRect: CGRect(x: 100, y: 150, width: 200, height: 300)))
            try expectEqual(ratio.origin.x, 0.25)
            try expectEqual(ratio.origin.y, 0.25)
            try expectEqual(ratio.width, 0.5)
            try expectEqual(ratio.height, 0.5)
        },

        TestDesc(suite: "SnapshotGeometry", name: "fullPageSelectionIsIdentityRatio") {
            let ratio = try expectNotNil(SnapshotGeometry.cropRatio(
                pageBounds: page, selectionRect: page))
            try expectEqual(ratio, CGRect(x: 0, y: 0, width: 1, height: 1))
        },

        TestDesc(suite: "SnapshotGeometry", name: "selectionBeyondPageClampsToIntersection") {
            let ratio = try expectNotNil(SnapshotGeometry.cropRatio(
                pageBounds: page,
                selectionRect: CGRect(x: -100, y: 300, width: 1000, height: 600)))
            // 交集 = (0, 300, 400, 300) → (0, 0.5, 1, 0.5)。
            try expectEqual(ratio, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        },

        TestDesc(suite: "SnapshotGeometry", name: "degenerateSelectionsRejected") {
            try expectNil(SnapshotGeometry.cropRatio(
                pageBounds: page,
                selectionRect: CGRect(x: 10, y: 10, width: 0, height: 50)), "零宽")
            try expectNil(SnapshotGeometry.cropRatio(
                pageBounds: page,
                selectionRect: CGRect(x: 10, y: 10, width: 50, height: 0)), "零高")
            try expectNil(SnapshotGeometry.cropRatio(
                pageBounds: page,
                selectionRect: CGRect(x: 500, y: 700, width: 30, height: 30)), "不相交")
            try expectNil(SnapshotGeometry.cropRatio(
                pageBounds: page, selectionRect: .null), "null rect")
            try expectNil(SnapshotGeometry.cropRatio(
                pageBounds: CGRect(x: 0, y: 0, width: 0, height: 0), selectionRect: page),
                "零面积页")
        },

        TestDesc(suite: "SnapshotGeometry", name: "offsetPageBoundsHandled") {
            let offsetPage = CGRect(x: 20, y: 30, width: 400, height: 600)
            let ratio = try expectNotNil(SnapshotGeometry.cropRatio(
                pageBounds: offsetPage,
                selectionRect: CGRect(x: 120, y: 330, width: 200, height: 300)))
            try expectEqual(ratio, CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        },

        TestDesc(suite: "SnapshotGeometry", name: "cropedImageSizeRoundingPinned") {
            let size = SnapshotGeometry.cropedImageSize(
                pagePixel: CGSize(width: 1600, height: 2400),
                ratio: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
            try expectEqual(size.width, 800)
            try expectEqual(size.height, 1200)
            // 1600 × 1/3 = 533.33 → 533（round）；2400 × 1/3 = 800。
            let third = SnapshotGeometry.cropedImageSize(
                pagePixel: CGSize(width: 1600, height: 2400),
                ratio: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1.0 / 3.0))
            try expectEqual(third.width, 533)
            try expectEqual(third.height, 800)
        },

        TestDesc(suite: "SnapshotGeometry", name: "cropedImageSizeFloorsAtOne") {
            let tiny = SnapshotGeometry.cropedImageSize(
                pagePixel: CGSize(width: 1600, height: 2400),
                ratio: CGRect(x: 0, y: 0, width: 0.0001, height: 0.0001))
            try expectEqual(tiny.width, 1)
            try expectEqual(tiny.height, 1)
            let bad = SnapshotGeometry.cropedImageSize(
                pagePixel: CGSize(width: 0, height: 0),
                ratio: CGRect(x: 0, y: 0, width: 1, height: 1))
            try expectEqual(bad.width, 1)
            try expectEqual(bad.height, 1)
        },

        TestDesc(suite: "SnapshotGeometry", name: "badgeLabelsContractSpotCheck") {
            try expectEqual(FollowBadgeLabels.labels(count: 0), [])
            try expectEqual(FollowBadgeLabels.labels(count: 27).last, "aa", "第 27 = aa")
            try expectEqual(FollowBadgeLabels.labels(count: 52).last, "az", "第 52 = az")
            try expectEqual(FollowBadgeLabels.labels(count: 53).last, "ba", "第 53 = ba")
        },
        ]
    }
}
