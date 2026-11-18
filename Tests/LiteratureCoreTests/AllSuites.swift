import Foundation

// Central registry of every synthetic suite. Both entry points share one list:
//   - Tests/RunnerMain        — executable `literaturesearch-tests`
// (`swift run literaturesearch-tests`; exit code = result)
// - Tests/SwiftTestBridge — `.testTarget` bridge so `swift test` runs
//     the same cases (one serialized swift-testing case per TestDesc).
// A suite that is not listed here is not executed (不登记就不会被执行).
public enum TestRegistry {
    static let allSuites: [[TestDesc]] = [
        NormalizationSuite.tests,
        PageLabelSuite.tests,
        ExclusionSuite.tests,
        IndexSearchSuite.tests,
        ParallelMaterializeSuite.tests,
        IncrementalSuite.tests,
        EdgeCaseSuite.tests,
        AISuite.tests,
        ReferenceResolverSuite.tests,
        DeepLinkHistorySuite.tests,
        RegressionSuite.tests,
        CoverageClassificationSuite.tests,
        OCRIndexingSuite.tests,
        HitRouterSuite.tests,
        DesignGuardSuite.tests,
        SyncWatchSuite.tests,
        CoveragePublicationSuite.tests,
        CitationExportSuite.tests,
        CitationFormatSuite.tests,
        CitationPuritySuite.tests,
        QuoteCopySuite.tests,
        QuoteSharedStateTests.tests,
        QuoteSuite.tests,
        HighlightStoreSuite.tests,
        AnnotationPlanSuite.tests,
        FavoritesStoreSuite.tests,
        HighlightExportSuite.tests,
        SmartJumpSuite.tests,
        VersionGroupSuite.tests,
        ReadingPositionStoreSuite.tests,
        PinyinBookIndexSuite.tests,
        AutoTOCSuite.tests,
        ReadingHistorySuite.tests,
        WebDAVSyncSuite.tests,
        WebDAVSettingsSuite.tests,
        WebDAVIndexUploadSuite.tests,
        SecretStoreSuite.tests,
        AppSupportPathsSuite.tests,
        AIProfilesSuite.tests,
        SelfHealSuite.tests,
        PageNumberServiceSuite.tests,
        MetadataFetchSuite.tests,
        KeybindingSuite.tests,
        A11yAuditSuite.tests,
        iOSCompileGateSuite.tests,
        IndexReplicaSuite.tests,
        ReadOnlySearchSuite.tests,
        WritingPolicySuite.tests,
        InkStrokesSuite.tests,
        AnnotationMergeSuite.tests,
        ShareInboxSuite.tests,
        WatchCompanionSuite.tests,
        QuerySyntaxSuite.tests,
        SimilarBooksSuite.tests,
        IndexQueueSuite.tests,
        ReindexBookSuite.tests,
        SearchContextSuite.tests,
        HighlightAggregationSuite.tests,
        AnnotationUndoSuite.tests,
        AnnotationExportPipelineSuite.tests,
        MarksStoreSuite.tests,
        ReadingSessionStoreSuite.tests,
        WorkbenchMappingSuite.tests,
        SnapshotGeometrySuite.tests,
        FollowBadgeSuite.tests,
        InkReconcileOutboxSuite.tests,
        BurnExportFrontMatterDailySuite.tests,
        FoundationModelsTransportSuite.tests,
        RCSContextBuilderSuite.tests,
        SpeedReadPresetSuite.tests,
        ReviewSelfCheckSuite.tests,
        SmartCollectionsSuite.tests,
        ClassificationRulesSuite.tests,
        TableGridSuite.tests,
        LocalAPISuite.tests,
        ReadingStatsSuite.tests,
        ReadingStatsConcurrencySuite.tests,
        DetectBodyStartArgParsingSuite.tests,
        SearchDetailedParitySuite.tests,
        RoundRobinStressSuite.tests,
        MatchingPageCountsMemoryParitySuite.tests,
        MaterializationPhasePerformanceGateSuite.tests,
        MatchingBooksDeterminismSuite.tests,
        PinyinDualFormSuite.tests,
        IndexingRegressionSuite.tests,
        PinyinSyllableGateSuite.tests,
        PinyinSyllableCompleteSuite.tests,
        PinyinOrderContractSuite.tests,
        WordLevelIndexSuite.tests,
        OcrDualEngineSuite.tests,
        MinerUDriverSuite.tests,
        CrossValidationGateSuite.tests,
        DoclingDriverSuite.tests,
        OcrReorderSuite.tests,
        ContentCategorySuite.tests,
        ContentCategoryFilterSuite.tests,
        AnnotationEncryptionSuite.tests,
        ShareReceiveTests.tests,
        QuoteVerificationTests.tests,
        RestoreFailClosedSuite.tests,
        MCPBridgeSuite.tests,
        MCPServeShellSuite.tests,
        TermRouteSyntaxSuite.tests,
        LibrarySnapshotStoreSuite.tests,
        SemanticCitationSuite.tests,
        FulltextSplitSuite.tests,
        ExtractionTextCacheSuite.tests,
        IndexQueueProgressSuite.tests,
        IndexPendingSuite.tests,
        LibraryFileWatcherSuite.tests,
        FileCloneSuite.tests,
        IndexAssetsManifestSuite.tests,
        SearchEngineSuite.tests,
        PageTextSourceSuite.tests,
        SearchMemoryStoreSuite.tests,
        SearchCompletionSuite.tests,
        MCPToolWalkSuite.tests,
        AnnotationExportHTMLTXTSuite.tests,
        LocalAPIIdleTimerSuite.tests,
        MetadataSiteAdapterSuite.tests,
        FileNameNormalizationSuite.tests,
        JournalTierStoreSuite.tests,
        SnapshotRetentionSuite.tests,
        RefreshConsoleSuite.tests,
        RefreshConsoleMergeSuite.tests,
        PagesStatsCacheTests.tests,
        PageStatsIndexTests.tests,
        RenameRebindSuite.tests,
    ]

    /// Flat case list (default-mounted suites only).
    static var flatCases: [TestDesc] { allSuites.flatMap { $0 } }

    /// Executable-runner suite list with optional environment filters.
    static func resolvedSuites(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [[TestDesc]] {
        var suites = allSuites
        // Optional suite filter.
        let only = environment["LIT_TESTS_ONLY"]
        let nameOnly = environment["LIT_TEST_NAME"]
        let filtered = suites.map { suite in
            suite.filter { (only == nil || $0.suite == only) && (nameOnly == nil || $0.name == nameOnly) }
        }.filter { !$0.isEmpty }
        return filtered.isEmpty ? suites : filtered
    }

    /// `swift test` bridge helpers: flat case count for the parameterized test
    /// and one labeled run per flat index (failure messages carry suite/name).
    public static var caseCount: Int { allSuites.reduce(0) { $0 + $1.count } }

    public static func runCase(_ index: Int) async throws {
        var remaining = index
        for suite in allSuites {
            if remaining < suite.count {
                let test = suite[remaining]
                do {
                    try await test.body()
                } catch {
                    throw TestFailure(message: "\(test.suite)/\(test.name): \(error)")
                }
                return
            }
            remaining -= suite.count
        }
        throw TestFailure(message: "synthetic case index out of range: \(index) (caseCount=\(caseCount))")
    }
}

/// Executable entry wrapper: RunnerMain calls this so TestRunner/TestDesc stay
/// internal while the swift-testing bridge shares the same registry.
public enum SyntheticTestMain {
    public static func run() async {
        await TestRunner.main(TestRegistry.resolvedSuites())
    }
}
