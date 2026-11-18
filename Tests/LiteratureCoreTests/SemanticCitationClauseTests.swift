import Foundation
import LiteratureCore

// 引用段落解析：para 必须落在请求证据段集合内；页级语义逐字节不变。
enum SemanticCitationSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SemanticCitation", name: "paraAcceptedWhenInEvidence") {
                let sources = [AllowedSource(bookID: "b1", pageCount: 3, fingerprint: "fp1")]
                let refs = [AIReference(bookId: "b1", page: 1, para: 0),
                            AIReference(bookId: "b1", page: 2, para: 4)]
                let evidence: Set<SemanticAnchor> = [
                    SemanticAnchor(bookID: "b1", page: 1, paraIndex: 0),
                    SemanticAnchor(bookID: "b1", page: 2, paraIndex: 4),
                ]
                let decisions = ReferenceResolver.resolveWithParagraphs(refs, allowedSources: sources,
                                                                        evidenceParagraphs: evidence)
                try expectEqual(decisions, [.accepted(bookID: "b1", physicalPage: 1),
                                            .accepted(bookID: "b1", physicalPage: 2)])
            },
            TestDesc(suite: "SemanticCitation", name: "paraNotInEvidenceRejected") {
                let sources = [AllowedSource(bookID: "b1", pageCount: 3, fingerprint: "fp1")]
                let refs = [AIReference(bookId: "b1", page: 1, para: 5)]
                let decisions = ReferenceResolver.resolveWithParagraphs(
                    refs, allowedSources: sources,
                    evidenceParagraphs: [SemanticAnchor(bookID: "b1", page: 1, paraIndex: 0)])
                guard case .rejected(let bookID, let page, let reason) = decisions[0] else {
                    try failTest("expected rejection"); return
                }
                try expectEqual(bookID, "b1")
                try expectEqual(page, 1)
                try expectTrue(reason.contains("paragraph not in request evidence"))
            },
            TestDesc(suite: "SemanticCitation", name: "paraNilKeepsPageLevelSemanticsByteIdentical") {
                let sources = [AllowedSource(bookID: "b1", pageCount: 3, fingerprint: "fp1"),
                               AllowedSource(bookID: "bX", pageCount: 2, fingerprint: "fpX")]
                let refs = [AIReference(bookId: "b1", page: 2),
                            AIReference(bookId: "bZZ", page: 1),
                            AIReference(bookId: "b1", page: 9)]
                let evidence: Set<SemanticAnchor> = [SemanticAnchor(bookID: "b1", page: 2, paraIndex: 0)]
                let withParagraphs = ReferenceResolver.resolveWithParagraphs(refs, allowedSources: sources,
                                                                             evidenceParagraphs: evidence)
                let pageLevel = ReferenceResolver.resolve(refs, allowedSources: sources)
                try expectEqual(withParagraphs, pageLevel,
                                "para nil → page-level adjudication, byte-identical")
            },
            TestDesc(suite: "SemanticCitation", name: "outOfRangePageStillRejectedBeforeParaGate") {
                let sources = [AllowedSource(bookID: "b1", pageCount: 3, fingerprint: "fp1")]
                let refs = [AIReference(bookId: "b1", page: 9, para: 0)]
                let decisions = ReferenceResolver.resolveWithParagraphs(
                    refs, allowedSources: sources,
                    evidenceParagraphs: [SemanticAnchor(bookID: "b1", page: 9, paraIndex: 0)])
                guard case .rejected(_, _, let reason) = decisions[0] else {
                    try failTest("expected rejection"); return
                }
                try expectTrue(reason.contains("out of range"), "page gate precedes para gate")
            },
            TestDesc(suite: "SemanticCitation", name: "parseResponseReadsOptionalPara") {
                let withoutPara = try AIAssistantService.parseResponse(
                    #"{"answer":"a","references":[{"bookId":"b1","page":2}]}"#)
                try expectNil(withoutPara.references[0].para, "old responses decode with para=nil")
                let withPara = try AIAssistantService.parseResponse(
                    #"{"answer":"a","references":[{"bookId":"b1","page":2,"para":3}]}"#)
                try expectEqual(withPara.references[0].para, 3)
                let doublePara = try AIAssistantService.parseResponse(
                    #"{"answer":"a","references":[{"bookId":"b1","page":2,"para":3.0}]}"#)
                try expectEqual(doublePara.references[0].para, 3)
                let junkPara = try AIAssistantService.parseResponse(
                    #"{"answer":"a","references":[{"bookId":"b1","page":2,"para":"x"}]}"#)
                try expectNil(junkPara.references[0].para, "non-integer para = absent para (page-level)")
            },
            TestDesc(suite: "SemanticCitation", name: "selectionPayloadOmitsParaKeyWhenNil") {
                let legacy = AIRequestPayload.SelectionPayload(bookId: "b1", fingerprint: "fp", page: 1,
                                                               snippet: "s", source: "native")
                let legacyJSON = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
                try expectTrue(!legacyJSON.contains("para"), "nil para must not emit a key (old payload shape)")
                let decoded = try JSONDecoder().decode(AIRequestPayload.SelectionPayload.self,
                                                       from: Data(legacyJSON.utf8))
                try expectNil(decoded.para, "old payload round-trips with para=nil")

                let paragraph = AIRequestPayload.SelectionPayload(bookId: "b1", fingerprint: "fp", page: 1,
                                                                  snippet: "s", source: "native", para: 3)
                let paragraphJSON = String(decoding: try JSONEncoder().encode(paragraph), as: UTF8.self)
                try expectTrue(paragraphJSON.contains("\"para\":3"), "non-nil para serializes")
            },
            TestDesc(suite: "SemanticCitation", name: "citationNoteAndEvidenceHeaderSwitchOnPara") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://example.invalid/v1/chat/completions")!,
                                                      model: "m"))
                let pageLevel = AIPreview.Selection(bookID: "b1", fingerprint: "fp", physicalPage: 1, snippet: "s")
                let paragraph = AIPreview.Selection(bookID: "b1", fingerprint: "fp", physicalPage: 1,
                                                    snippet: "s", source: "native", ocrPage: nil, para: 3)
                // 既有页级综合：note 逐字节不变。
                let previewPage = try service.makeSynthesisPreview(question: "q", selections: [pageLevel, pageLevel])
                let transportPage = CountingTransport()
                _ = try? await service.send(preview: previewPage, confirmation: AIConfirmation(explicit: true, previewID: previewPage.id),
                                            transport: transportPage)
                try expectEqual(transportPage.lastPayload?.1.citationNote, AIAssistantService.synthesisCitationNote)
                let encodedPage = String(decoding: try OpenAIChatCompletionsAdapter.encode(transportPage.lastPayload!.1), as: UTF8.self)
                try expectTrue(encodedPage.contains("bookId=b1, page=1, fingerprint="),
                               "nil-para evidence header must keep the existing format verbatim")
                try expectTrue(!encodedPage.contains("para="), "nil para adds nothing to the header")

                // 混合检索综合：段级 note＋evidence 头带 para=。
                let previewPara = try service.makeSynthesisPreview(question: "q", selections: [paragraph, pageLevel])
                let transportPara = CountingTransport()
                _ = try? await service.send(preview: previewPara, confirmation: AIConfirmation(explicit: true, previewID: previewPara.id),
                                            transport: transportPara)
                try expectEqual(transportPara.lastPayload?.1.citationNote,
                                AIAssistantService.synthesisCitationNoteWithParagraphs)
                let encodedPara = String(decoding: try OpenAIChatCompletionsAdapter.encode(transportPara.lastPayload!.1), as: UTF8.self)
                try expectTrue(encodedPara.contains(", para=3"))
                try expectTrue(encodedPara.contains("page=1, para=3"))
            },
        ]
    }
}
