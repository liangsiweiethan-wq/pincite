import Foundation
@testable import LiteratureCore


enum FavoritesStoreSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "FavoritesStore", name: "roundTripAllFourKinds") {
                let dir = Fixtures.makeTempDir("fav-roundtrip")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)

                let tBook = FavoriteTarget.book(bookID: "bA", fileName: "a.pdf", title: "Title A")
                let tPage = FavoriteTarget.page(bookID: "bA", fileName: "a.pdf", pageNumber: 7,
                                                snippet: "some snippet", utf16Start: 3, utf16End: 15)
                let tQuote = FavoriteTarget.quote(bookID: "bB", fileName: "b.pdf", pageNumber: 2,
                                                  sentence: "a memorable sentence")
                let tSearch = FavoriteTarget.search(query: "normierung")

                let id1 = try favorites.add(tBook, category: "papers", tags: ["a", "b"])
                let id2 = try favorites.add(tPage)
                let id3 = try favorites.add(tQuote, tags: ["c"])
                let id4 = try favorites.add(tSearch, category: "papers")

                let all = try favorites.all()
                try expectEqual(all.count, 4)
                // creation order preserved
                try expectEqual(all.map { $0.id }, [id1, id2, id3, id4])
                try expectEqual(all[0].target, tBook)
                try expectEqual(all[1].target, tPage)
                try expectEqual(all[2].target, tQuote)
                try expectEqual(all[3].target, tSearch)
                try expectEqual(all[0].kind, .book)
                try expectEqual(all[1].kind, .page)
                try expectEqual(all[2].kind, .quote)
                try expectEqual(all[3].kind, .search)
                try expectEqual(all[0].category, "papers")
                try expectEqual(all[0].tags, ["a", "b"])
                try expectEqual(all[1].tags, [])
                try expectEqual(all[2].tags, ["c"])
                try expectEqual(all[3].category, "papers")
                // dates round-trip as REAL epoch seconds
                try expectTrue(all[0].createdAt.timeIntervalSince1970 > 0)

                // per-kind filtering
                try expectEqual(try favorites.favorites(kind: .book).count, 1)
                try expectEqual(try favorites.favorites(kind: .page).first?.id, id2)
                try expectEqual(try favorites.favorites(kind: .quote).first?.target, tQuote)
                try expectEqual(try favorites.favorites(kind: .search).count, 1)
            },

            TestDesc(suite: "FavoritesStore", name: "pageTargetWithoutOffsetsRoundTrips") {
                let dir = Fixtures.makeTempDir("fav-page-nooff")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                let t = FavoriteTarget.page(bookID: "bA", fileName: "a.pdf", pageNumber: 3,
                                            snippet: "s", utf16Start: nil, utf16End: nil)
                let id = try favorites.add(t)
                let got = try expectNotNil(try favorites.all().first)
                try expectEqual(got.id, id)
                try expectEqual(got.target, t)
            },

            TestDesc(suite: "FavoritesStore", name: "categoriesAndTagsAreDeduplicated") {
                let dir = Fixtures.makeTempDir("fav-cats")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                _ = try favorites.add(.search(query: "q1"), category: "papers", tags: ["x", "y"])
                _ = try favorites.add(.search(query: "q2"), category: "papers", tags: ["y", "z"])
                _ = try favorites.add(.search(query: "q3"), category: "drafts", tags: ["x"])
                _ = try favorites.add(.search(query: "q4")) // no category, no tags

                try expectEqual(try favorites.categories(), ["drafts", "papers"])
                try expectEqual(try favorites.tags(), ["x", "y", "z"])
            },

            TestDesc(suite: "FavoritesStore", name: "batchSetCategoryAddTagsDelete") {
                let dir = Fixtures.makeTempDir("fav-batch")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                let id1 = try favorites.add(.search(query: "q1"), category: "old", tags: ["a"])
                let id2 = try favorites.add(.search(query: "q2"), tags: ["b"])
                let id3 = try favorites.add(.search(query: "q3"), tags: ["a"])

                try favorites.setCategory(ids: [id1, id2], category: "new")
                let afterCat = try favorites.all()
                try expectEqual(afterCat.first { $0.id == id1 }?.category, "new")
                try expectEqual(afterCat.first { $0.id == id2 }?.category, "new")
                try expectEqual(afterCat.first { $0.id == id3 }?.category, "")

                // merge-union: existing tags kept, new appended, no duplicates
                try favorites.addTags(ids: [id1, id2, id3], tags: ["b", "c", "a"])
                let afterTags = try favorites.all()
                try expectEqual(afterTags.first { $0.id == id1 }?.tags, ["a", "b", "c"])
                try expectEqual(afterTags.first { $0.id == id2 }?.tags, ["b", "c", "a"])
                try expectEqual(afterTags.first { $0.id == id3 }?.tags, ["a", "b", "c"])

                try favorites.delete(ids: [id1, id3])
                let remaining = try favorites.all()
                try expectEqual(remaining.count, 1)
                try expectEqual(remaining[0].id, id2)
            },
        ]
    }
}
