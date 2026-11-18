import Foundation
@testable import LiteratureCore

// MARK: - 更新 FileClone 测试
//
// 断言面：同卷 clone 成功路径（rc==0＋size 一致，返回 true）；注入失败钩子
// → 回退 copy 成功（返回 false）；clone 后 size 不符 → 删半成品走回退；
// 回退后 size 仍不符 → 抛错不静默。跨卷（EXDEV）路径经注入钩子等价覆盖。

enum FileCloneSuite {
    static var tests: [TestDesc] {
        [
            // 同卷 clone 快路：APFS 上 clonefile(3) 真调用成功（rc==0），
            // 返回 true，size 与源一致（门禁机 macOS/APFS 前提）。
            TestDesc(suite: "FileClone", name: "sameVolumeCloneReturnsTrueWithMatchingSize") {
                let dir = Fixtures.makeTempDir("clone-ok")
                defer { Fixtures.cleanup(dir) }
                let src = dir.appendingPathComponent("src.pdf")
                let dst = dir.appendingPathComponent("dst.pdf")
                let payload = Data(String(repeating: "clone-payload-", count: 4096).utf8)   // ~56KB
                try payload.write(to: src)
                FileClone.cloneHook = nil
                defer { FileClone.cloneHook = nil }
                let cloned = try FileClone.cloneOrCopy(from: src, to: dst)
                try expectTrue(cloned, "APFS same-volume clonefile must succeed (rc==0)")
                try expectEqual(FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int64,
                                Int64(payload.count))
            },

            // 注入失败钩子（模拟 ENOTSUP/EXDEV/EPERM）→ 回退 copy 成功。
            TestDesc(suite: "FileClone", name: "cloneFailureFallsBackToCopy") {
                let dir = Fixtures.makeTempDir("clone-fallback")
                defer { Fixtures.cleanup(dir) }
                let src = dir.appendingPathComponent("src.bin")
                let dst = dir.appendingPathComponent("dst.bin")
                try Data("fallback payload".utf8).write(to: src)
                FileClone.cloneHook = { _, _ in 45 }   // ENOTSUP
                defer { FileClone.cloneHook = nil }
                let cloned = try FileClone.cloneOrCopy(from: src, to: dst)
                try expectFalse(cloned, "fallback path reports false")
                try expectTrue(FileManager.default.fileExists(atPath: dst.path))
                try expectEqual(try String(contentsOf: dst, encoding: .utf8), "fallback payload")
            },

            // clone 后 size 不符（半克隆假成功注入）→ 删半成品走回退。
            TestDesc(suite: "FileClone", name: "sizeMismatchAfterCloneFallsBack") {
                let dir = Fixtures.makeTempDir("clone-mismatch")
                defer { Fixtures.cleanup(dir) }
                let src = dir.appendingPathComponent("m.bin")
                let dst = dir.appendingPathComponent("m-out.bin")
                try Data(String(repeating: "Z", count: 1024).utf8).write(to: src)
                FileClone.cloneHook = { _, dstPath in
                    // 伪造「clone 返回 0 但半成品」：目的件只写一半。
                    try? Data(String(repeating: "Z", count: 512).utf8).write(to: URL(fileURLWithPath: dstPath))
                    return 0
                }
                defer { FileClone.cloneHook = nil }
                let cloned = try FileClone.cloneOrCopy(from: src, to: dst)
                try expectFalse(cloned, "size mismatch triggers fallback")
                try expectEqual(FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int64,
                                Int64(1024), "fallback copy restores full content")
            },

            // 回退后 size 仍不符/回退本身失败 → 抛错（结果永不假装已拷贝）。
            TestDesc(suite: "FileClone", name: "unfixableCloneThrows") {
                let dir = Fixtures.makeTempDir("clone-throw")
                defer { Fixtures.cleanup(dir) }
                let src = dir.appendingPathComponent("t.bin")
                let dst = dir.appendingPathComponent("t-out.bin")
                try Data("real content".utf8).write(to: src)
                // 钩子「clone 成功」但随后删源件——rc==0 → size 校验发现目的
                // 缺失 → 回退 copyItem 因源缺失而失败 → 抛错（不静默假装）。
                FileClone.cloneHook = { srcPath, _ in
                    try? FileManager.default.removeItem(atPath: srcPath)
                    return 0
                }
                defer { FileClone.cloneHook = nil }
                try expectThrows(try FileClone.cloneOrCopy(from: src, to: dst),
                                 "fallback failure must surface, not pretend success")
            },
        ]
    }
}
