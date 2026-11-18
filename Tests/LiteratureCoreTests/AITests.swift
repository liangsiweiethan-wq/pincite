import Foundation
@testable import LiteratureCore

/// Counting mock transport — the zero-request guarantees are asserted against it.
final class CountingTransport: AITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(URL, AIRequestPayload)] = []
    let reply: String

    init(reply: String = #"{"answer":"这是一个回答","references":[{"bookId":"b1","page":1}]}"#) {
        self.reply = reply
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var lastPayload: (URL, AIRequestPayload)? {
        lock.lock(); defer { lock.unlock() }
        return calls.last
    }

    func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?) async throws -> String {
        lock.lock(); calls.append((endpoint, payload)); lock.unlock()
        return reply
    }

    /// 新协议签名：mock 无挂起点，忽略令牌按原语义完成。
    func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
              cancellation: AICancellationToken?) async throws -> String {
        try await send(endpoint, payload: payload, apiKey: apiKey)
    }
}

/// 挂起式 stub transport —— send 挂起直到令牌取消才恢复，用于
/// 验证协议契约（挂起前检查 + 令牌回调中断 + 取消错误传播）。
final class HangingTransport: AITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var sawCancelCallback = false
    private(set) var observedCancelBeforeSuspend = false

    var cancelWasObserved: Bool {
        lock.lock(); defer { lock.unlock() }
        return sawCancelCallback || observedCancelBeforeSuspend
    }

    func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
              cancellation: AICancellationToken?) async throws -> String {
        do {
            try cancellation?.check()   // 协议契约：任何挂起/出网动作前先检查
        } catch {
            lock.lock(); observedCancelBeforeSuspend = true; lock.unlock()
            throw error
        }
        return try await withCheckedThrowingContinuation { raw in
            let token = cancellation
            lock.lock()
            continuation = raw
            lock.unlock()
            token?.onCancel { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.sawCancelCallback = true
                let pending = self.continuation
                self.continuation = nil
                self.lock.unlock()
                pending?.resume(throwing: AIAssistantError.cancelled)
            }
        }
    }
}

enum AISuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AI", name: "defaultStateIsUnconfigured") {
                let service = AIAssistantService()
                try expectNil(service.configuration, "default must be unconfigured")
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 1, snippet: "s")
                try expectThrows(try service.makePreview(question: "q", selection: selection), "unconfigured -> notConfigured")
            },
            TestDesc(suite: "AI", name: "unconfiguredSendTouchesTransportZeroTimes") {
                let service = AIAssistantService()
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 1, snippet: "s")
                let forged = AIPreview(id: UUID(), question: "q", selection: selection, serviceHost: "x", model: "m")
                let confirmation = AIConfirmation(explicit: true, previewID: forged.id)
                try await expectThrowsAsync({
                    try await service.send(preview: forged, confirmation: confirmation, transport: transport)
                }, "even a forged confirmation fails before the transport")
                try expectEqual(transport.callCount, 0, "unconfigured service -> zero network calls")
            },
            TestDesc(suite: "AI", name: "missingConfirmationMeansZeroRequests") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "user-chosen-model"))
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 3, snippet: "选中的中文片段")
                let preview = try service.makePreview(question: "解释", selection: selection)
                try await expectThrowsAsync({
                    try await service.send(preview: preview, confirmation: nil, transport: transport)
                }, "missing confirmation -> confirmationRequired")
                try expectEqual(transport.callCount, 0, "no explicit confirmation -> zero requests")
            },
            TestDesc(suite: "AI", name: "nonExplicitConfirmationCannotExist") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m"))
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 1, snippet: "s")
                let preview = try service.makePreview(question: "q", selection: selection)
                try expectNil(AIConfirmation(explicit: false, previewID: preview.id), "non-explicit confirmation cannot be constructed")
                try expectEqual(transport.callCount, 0)
            },
            TestDesc(suite: "AI", name: "confirmationBoundToADifferentPreviewIsRejected") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m"))
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 1, snippet: "s")
                let previewA = try service.makePreview(question: "q", selection: selection)
                let previewB = try service.makePreview(question: "q", selection: selection)
                let wrong = try expectNotNil(AIConfirmation(explicit: true, previewID: previewB.id))
                try await expectThrowsAsync({
                    try await service.send(preview: previewA, confirmation: wrong, transport: transport)
                }, "confirmation is bound to the exact preview the user saw")
                try expectEqual(transport.callCount, 0)
            },
            TestDesc(suite: "AI", name: "explicitConfirmationSendsExactlyThePreviewedContent") {
                let service = AIAssistantService()
                let endpoint = URL(string: "https://api.example.test/ask")!
                try service.configure(AIConfiguration(serviceURL: endpoint, model: "user-chosen-model", apiKey: "sk-test"))
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b123", fingerprint: "abc", physicalPage: 7, snippet: "原文片段 snippet")
                let preview = try service.makePreview(question: "这句话什么意思？", selection: selection)
                try expectEqual(preview.model, "user-chosen-model", "model shown = model configured, nothing inferred")
                try expectEqual(preview.serviceHost, "api.example.test")
                try expectEqual(preview.selection.snippet, "原文片段 snippet")

                let confirmation = try expectNotNil(AIConfirmation(explicit: true, previewID: preview.id))
                let response = try await service.send(preview: preview, confirmation: confirmation, transport: transport)
                try expectEqual(transport.callCount, 1)
                let (calledEndpoint, payload) = try expectNotNil(transport.lastPayload)
                try expectEqual(calledEndpoint, endpoint)
                try expectEqual(payload.model, "user-chosen-model")
                try expectEqual(payload.selection.snippet, "原文片段 snippet")
                try expectEqual(payload.selection.bookId, "b123")
                try expectEqual(payload.selection.page, 7)
                try expectEqual(response.answerText, "这是一个回答")
            },
            TestDesc(suite: "AI", name: "responseParsingIsStrictAboutShape") {
                let raw = "noise prefix {\"answer\":\"好的\",\"references\":[{\"bookId\":\"b1\",\"page\":2},{\"bookId\":\"unknown\",\"page\":9}]} noise suffix"
                let parsed = try AIAssistantService.parseResponse(raw)
                try expectEqual(parsed.answerText, "好的")
                try expectEqual(parsed.references.count, 2)
                try expectThrows(try AIAssistantService.parseResponse("no json here"))
                try expectThrows(try AIAssistantService.parseResponse("{\"wrong\":1}"))
            },
            TestDesc(suite: "AI", name: "openAIAdapterCarriesOnlyConfirmedEvidencePayload") {
                let selection = AIRequestPayload.SelectionPayload(
                    bookId: "b1", fingerprint: "fp1", page: 4,
                    snippet: "public fixture text", source: "native"
                )
                let payload = AIRequestPayload(
                    model: "explicit-model", question: "Reply with exactly OK.",
                    selection: selection, selections: nil, citationNote: nil
                )
                let data = try OpenAIChatCompletionsAdapter.encode(payload)
                let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                try expectEqual(obj["model"] as? String, "explicit-model")
                try expectEqual(obj["stream"] as? Bool, false)
                let messages = obj["messages"] as! [[String: String]]
                try expectTrue(messages[1]["content"]?.contains("public fixture text") == true)
                try expectTrue(messages[1]["content"]?.contains("bookId=b1, page=4") == true)
                let answer = try OpenAIChatCompletionsAdapter.answerJSON(
                    from: Data(#"{"choices":[{"message":{"content":"{\"answer\":\"OK\",\"references\":[]}"}}]}"#.utf8)
                )
                try expectEqual(try AIAssistantService.parseResponse(answer).answerText, "OK")
                try expectThrows(try OpenAIChatCompletionsAdapter.answerJSON(from: Data("{}".utf8)))
            },
            TestDesc(suite: "AI", name: "livePublicPromptUsesExplicitModelAndConfirmation") {
                guard ProcessInfo.processInfo.environment["LITERATURESEARCH_LIVE_AI"] == "1" else { return }
                let account = Process()
                account.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                account.arguments = ["find-generic-password", "-w", "-a", "tester", "-s", "example-ai-service"]
                let pipe = Pipe()
                account.standardOutput = pipe
                account.standardError = Pipe()
                try account.run()
                let credential = pipe.fileHandleForReading.readDataToEndOfFile()
                account.waitUntilExit()
                guard account.terminationStatus == 0, let key = String(data: credential, encoding: .utf8), !key.isEmpty else {
                    throw TestFailure(message: "existing credential unavailable; secret not displayed")
                }
                let service = AIAssistantService()
                try service.configure(AIConfiguration(
                    serviceURL: URL(string: "https://api.example.com/v1/chat/completions")!,
                    model: "example-model", apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                let selection = AIPreview.Selection(
                    bookID: "public-fixture", fingerprint: "public-fixture-sha",
                    physicalPage: 1, snippet: "Public test fixture only. No research text."
                )
                let preview = try service.makePreview(question: "Reply with exactly OK.", selection: selection)
                let confirmation = try expectNotNil(AIConfirmation(explicit: true, previewID: preview.id))
                let answer = try await service.send(
                    preview: preview, confirmation: confirmation, transport: URLSessionAITransport()
                )
                try expectTrue(!answer.answerText.isEmpty, "live response is present; do not print answer")
            },
        ]
    }
}

enum ReferenceResolverSuite {
    static let sources = [
        AllowedSource(bookID: "b1", pageCount: 5, fingerprint: "fp1"),
        AllowedSource(bookID: "b2", pageCount: 2, fingerprint: "fp2"),
    ]

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ReferenceResolver", name: "acceptsReferencesInsideInputIDs") {
                let decisions = ReferenceResolver.resolve([AIReference(bookId: "b1", page: 3)], allowedSources: sources)
                try expectEqual(decisions, [.accepted(bookID: "b1", physicalPage: 3)])
            },
            TestDesc(suite: "ReferenceResolver", name: "rejectsUnknownBookID") {
                let decisions = ReferenceResolver.resolve([AIReference(bookId: "bZZ", page: 1)], allowedSources: sources)
                try expectEqual(decisions.count, 1)
                guard case .rejected(let id, let page, let reason) = decisions[0] else { try failTest("expected rejection") }
                try expectEqual(id, "bZZ")
                try expectEqual(page, 1)
                try expectTrue(reason.contains("unknown-book-id"), "only input IDs are allowed")
            },
            TestDesc(suite: "ReferenceResolver", name: "rejectsOutOfBoundsPages") {
                let decisions = ReferenceResolver.resolve([
                    AIReference(bookId: "b1", page: 0),
                    AIReference(bookId: "b1", page: 6),
                    AIReference(bookId: "b2", page: 3),
                ], allowedSources: sources)
                try expectEqual(decisions.count, 3)
                for d in decisions {
                    guard case .rejected(_, _, let reason) = d else { try failTest("expected rejection") }
                    try expectTrue(reason.contains("out of range"), "pages are 1-based and bounded by pageCount")
                }
            },
            TestDesc(suite: "ReferenceResolver", name: "rejectsStaleFingerprintEcho") {
                let decisions = ReferenceResolver.resolve([AIReference(bookId: "b1", page: 1, fingerprint: "OLD")], allowedSources: sources)
                guard case .rejected(_, _, let reason) = decisions[0] else { try failTest("expected rejection") }
                try expectTrue(reason.contains("stale"))
            },
            TestDesc(suite: "ReferenceResolver", name: "citationVerificationValidatesLiveIndex") {
                let dir = Fixtures.makeTempDir("cite-verify")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let bookOk = IndexStore.BookRow(
                    id: "b1", realPath: "/tmp/lit-tests/b1.pdf", rootPath: "/tmp/lit-tests",
                    relPath: "b1.pdf", fileName: "b1.pdf",
                    firstFingerprint: "fp1", fingerprint: "fp1", fileSize: 100, mtime: 0,
                    pageCount: 5, status: "ok", indexedAt: 0)
                try store.upsertBook(bookOk)

                let bookErr = IndexStore.BookRow(
                    id: "bErr", realPath: "/tmp/lit-tests/bErr.pdf", rootPath: "/tmp/lit-tests",
                    relPath: "bErr.pdf", fileName: "bErr.pdf",
                    firstFingerprint: "fpErr", fingerprint: "fpErr", fileSize: 100, mtime: 0,
                    pageCount: 3, status: "error", indexedAt: 0)
                try store.upsertBook(bookErr)

                let service = SearchService(store: store)

                // 1. Valid citation: bookID in store with status "ok", page <= pageCount, fingerprint matches
                try expectTrue(try service.verifyCitation(bookID: "b1", page: 3, expectedFingerprint: "fp1"))

                // 2. Missing book: bookID not in library -> false
                try expectFalse(try service.verifyCitation(bookID: "bUnknown", page: 1, expectedFingerprint: "fp1"))

                // 3. Status not ok: book in library with status "error" -> false
                try expectFalse(try service.verifyCitation(bookID: "bErr", page: 1, expectedFingerprint: "fpErr"))

                // 4. Page out of bounds: page > pageCount or page < 1 -> false
                try expectFalse(try service.verifyCitation(bookID: "b1", page: 6, expectedFingerprint: "fp1"))
                try expectFalse(try service.verifyCitation(bookID: "b1", page: 0, expectedFingerprint: "fp1"))

                // 5. Fingerprint drifted: index fingerprint != expectedFingerprint -> false
                try expectFalse(try service.verifyCitation(bookID: "b1", page: 3, expectedFingerprint: "fpOldDrifted"))
            },
            TestDesc(suite: "AI", name: "synthesisPreviewCarriesAllPassagesAndCitationNote") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m", apiKey: nil))
                let sels = (0..<3).map { i in
                    AIPreview.Selection(bookID: "b\(i)", fingerprint: "fp\(i)", physicalPage: i + 1, snippet: "片段\(i)", source: "native", ocrPage: nil)
                }
                let preview = try service.makeSynthesisPreview(question: "综合回答", selections: sels)
                try expectEqual(preview.selections.count, 3)
                try expectEqual(preview.selections[2].bookID, "b2")
                let transport = CountingTransport()
                let confirmation = try expectNotNil(AIConfirmation(explicit: true, previewID: preview.id))
                _ = try await service.send(preview: preview, confirmation: confirmation, transport: transport)
                try expectEqual(transport.callCount, 1)
                let (_, payload) = try expectNotNil(transport.lastPayload)
                try expectEqual(payload.selections?.count, 3)
                try expectTrue(payload.citationNote?.isEmpty == false, "synthesis payload carries the citation-only note")
                try expectEqual(payload.selections?[0].bookId, "b0")
            },

            TestDesc(suite: "AI", name: "synthesisPreviewRequiresConfiguredAndNonEmpty") {
                let service = AIAssistantService()
                let sels = [AIPreview.Selection(bookID: "b", fingerprint: "f", physicalPage: 1, snippet: "s")]
                do { _ = try service.makeSynthesisPreview(question: "q", selections: sels); throw TestFailure(message: "unconfigured must throw") }
                catch { }
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m", apiKey: nil))
                do { _ = try service.makeSynthesisPreview(question: "q", selections: []); throw TestFailure(message: "empty must throw") }
                catch { }
            },

            // MARK: — 可取消传输（协议契约 + 取消传播 + 超时可配）

            TestDesc(suite: "AI", name: "cancelledTokenBeforeSendMeansZeroRequests") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m"))
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 1, snippet: "s")
                let preview = try service.makePreview(question: "q", selection: selection)
                let confirmation = try expectNotNil(AIConfirmation(explicit: true, previewID: preview.id))
                let token = AICancellationToken()
                token.cancel()   // 发送前已取消
                do {
                    _ = try await service.send(preview: preview, confirmation: confirmation,
                                               transport: transport, cancellation: token)
                    try failTest("cancelled token must throw before the transport")
                } catch let e as AIAssistantError {
                    try expectEqual(e, .cancelled, "must surface .cancelled, not transport error")
                }
                try expectEqual(transport.callCount, 0, "pre-cancelled token -> zero network calls")
            },

            TestDesc(suite: "AI", name: "hangingTransportResumesWithCancelledWhenTokenFires") {
                let transport = HangingTransport()
                let token = AICancellationToken()
                let payload = AIRequestPayload(
                    model: "m", question: "q",
                    selection: AIRequestPayload.SelectionPayload(
                        bookId: "b1", fingerprint: "f", page: 1, snippet: "s"),
                    selections: nil, citationNote: nil)
                let work = Task {
                    try await transport.send(URL(string: "https://api.example.test/ask")!,
                                             payload: payload, apiKey: nil, cancellation: token)
                }
                try await Task.sleep(nanoseconds: 50_000_000)   // 挂起稳定后再取消
                try expectFalse(token.isCancelled)
                token.cancel()
                do {
                    _ = try await work.value
                    try failTest("cancelled hang must not return a reply")
                } catch let e as AIAssistantError {
                    try expectEqual(e, .cancelled, "stub must resume with .cancelled")
                }
                try expectTrue(transport.cancelWasObserved, "stub must have observed the cancel callback")
            },

            TestDesc(suite: "AI", name: "serviceSendWithoutTokenKeepsLegacySemantics") {
                // 旧签名（无 token）路径不回归：默认转发 cancellation=nil，
                // 计数 transport 正常返回。
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m"))
                let transport = CountingTransport()
                let selection = AIPreview.Selection(bookID: "b1", fingerprint: "f", physicalPage: 1, snippet: "s")
                let preview = try service.makePreview(question: "q", selection: selection)
                let confirmation = try expectNotNil(AIConfirmation(explicit: true, previewID: preview.id))
                let response = try await service.send(preview: preview, confirmation: confirmation, transport: transport)
                try expectEqual(response.answerText, "这是一个回答")
                try expectEqual(transport.callCount, 1)
            },

            TestDesc(suite: "AI", name: "urlSessionTransportTimeoutDefaultsTo120AndIsConfigurable") {
                try expectEqual(URLSessionAITransport().timeout, 120, "默认超时 120s")
                try expectEqual(URLSessionAITransport(timeout: 42).timeout, 42, "超时可配")
                // 取消令牌基本契约：幂等取消、isCancelled 可见。
                let token = AICancellationToken()
                try expectFalse(token.isCancelled)
                token.cancel()
                token.cancel()   // 幂等
                try expectTrue(token.isCancelled)
                try expectThrows(try token.check(), "check() on cancelled token must throw")
            },
        ]
    }
}
