import UIKit
import UniformTypeIdentifiers

// MARK: - Share Extension 入站收录壳

@objc(ShareViewController)
final class ShareViewController: UIViewController {

    /// 单件重名避让重试上限（随机段重试；ShareCapture.swift:74 先例同款）。
    private static let maxNameRetries = 3

    /// 在途异步读取计数（主线程读写；归零且扫描完 → 结算）。
    private var pending = 0
    private var scanFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        receiveAndComplete()
    }

    private func receiveAndComplete() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let inbox = shareInboxDirectory()
        for provider in providers {
            guard let inbox else { continue }   // 无组容器＝无处可写，只结算不写
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                pending += 1
                receivePDF(provider, inbox: inbox)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                pending += 1
                receiveURL(provider, inbox: inbox)
            }
        }
        scanFinished = true
        settle()
    }

    /// 计数结算：扫描完且在途归零才结算（绝不在写入在飞时取消扩展）。
    private func settle() {
        guard scanFinished, pending <= 0 else { return }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// 回调着陆点（provider 回调线程不定 → 归主线程再动共享状态）。
    private func land(_ body: () -> Void) {
        if Thread.isMainThread {
            pending -= 1
            body()
            settle()
        } else {
            DispatchQueue.main.sync {
                pending -= 1
                body()
                self.settle()
            }
        }
    }

    // MARK: App Group 收件箱（唯一写面）

    private func shareInboxDirectory() -> URL? {
        guard let container = ShareReceive.groupContainer() else { return nil }
        let inbox = ShareReceive.inboxDirectory(in: container)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            return inbox
        } catch {
            return nil
        }
    }

    /// 程序生成名落盘（重名避让 ≤3；全撞＝放弃本件，不覆盖既有文件）。
    private func writeUnique(_ data: Data, kind: ShareReceive.Kind, inbox: URL) -> Bool {
        for _ in 0..<Self.maxNameRetries {
            let name = ShareReceive.makeFileName(kind: kind)
            let target = inbox.appendingPathComponent(name, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try data.write(to: target, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: PDF 附件

    private func receivePDF(_ provider: NSItemProvider, inbox: URL) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { [weak self] data, _ in
            guard let self else { return }
            self.land {
                if let data, !data.isEmpty, data.count <= ShareReceive.maxFileBytes {
                    _ = self.writeUnique(data, kind: .pdf, inbox: inbox)
                }
            }
        }
    }

    // MARK: URL 分享

    private func receiveURL(_ provider: NSItemProvider, inbox: URL) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
            guard let self else { return }
            self.land {
                var target: URL?
                if let url = item as? URL {
                    target = url
                } else if let str = item as? String {
                    target = URL(string: str)
                }
                guard let url = target, url.scheme != nil else { return }   // 无 scheme 不猜
                let payload: Data
                do {
                    payload = try ShareReceive.makeTextPayload(
                        text: url.absoluteString,
                        sourceLines: ["source: share-extension"])
                } catch {
                    return   // fail-closed：坏载荷不入箱
                }
                _ = self.writeUnique(payload, kind: .text, inbox: inbox)
            }
        }
    }
}
