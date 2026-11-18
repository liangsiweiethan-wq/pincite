import Foundation
@testable import LiteratureCore

enum PageLabelSuite {
    static var tests: [TestDesc] {
        [
            // Labeled fixture PDF (hand-assembled /PageLabels tree)
            TestDesc(suite: "PageLabel", name: "labeledFixtureExtraction") {
                let dir = Fixtures.makeTempDir("labels")
                defer { Fixtures.cleanup(dir) }
                let url = dir.appendingPathComponent("labeled.pdf")
                try SyntheticPDFMaker.writeLabeledPDF(
                    pages: [.init(text: "Cover Page"), .init(text: "Index Volume"), .init(text: "Body One")],
                    labelRules: [(0, "", "D", 1), (1, "Back", "D", 5)],
                    to: url
                )
                try expectTrue(PageLabelDeclaration.declaresPageLabels(fileURL: url), "structural catalog check must see the declaration")
                let result = try PDFTextExtractor.extract(url: url)
                try expectEqual(result.pageCount, 3)
                try expectEqual(result.pages[0].physicalPage, 1)
                try expectEqual(result.pages[0].label, "1")
                try expectEqual(result.pages[1].label, "Back5")
                try expectEqual(result.pages[2].label, "Back6")
                for page in result.pages {
                    try expectNil(page.printedPage, "printed folio: unknown in v1, never guessed")
                }
            },

            // PDFs without /PageLabels: label unknown (PDFKit would fabricate 1,2,3 — we must not)
            TestDesc(suite: "PageLabel", name: "plainPDFHasUnknownLabel") {
                let dir = Fixtures.makeTempDir("labels-plain")
                defer { Fixtures.cleanup(dir) }
                let url = Fixtures.makePDF(pages: [
                    .init(lines: ["alpha one"]),
                    .init(lines: ["beta two"]),
                ], in: dir, named: "plain.pdf")
                try expectFalse(PageLabelDeclaration.declaresPageLabels(fileURL: url))
                let result = try PDFTextExtractor.extract(url: url)
                try expectEqual(result.pages.map(\.physicalPage), [1, 2])
                for page in result.pages {
                    try expectNil(page.label, "label must be unknown (nil) when the PDF declares no /PageLabels")
                    try expectNil(page.printedPage)
                }
            },

            // Negative: body text mentions PageLabels but the catalog declares none
            // — raw byte scanning would false-positive; the structural check must not.
            TestDesc(suite: "PageLabel", name: "contentMentionDoesNotFakeDeclaration") {
                let dir = Fixtures.makeTempDir("labels-mention")
                defer { Fixtures.cleanup(dir) }
                let url = Fixtures.makePDF(pages: [
                    .init(lines: ["This paper studies PageLabels trees in PDF files."]),
                ], in: dir, named: "mention.pdf")
                try expectFalse(PageLabelDeclaration.declaresPageLabels(fileURL: url),
                                "catalog-level check must not be fooled by body text")
                let result = try PDFTextExtractor.extract(url: url)
                try expectNil(result.pages[0].label, "label stays unknown despite body-text keyword")
            },
        ]
    }
}
