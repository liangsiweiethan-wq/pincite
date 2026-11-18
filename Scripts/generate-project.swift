// generate-project.swift — deterministic Xcode project generator.
//
// Usage:  swift Scripts/generate-project.swift
//
// Produces app/LiteratureSearch.xcodeproj/project.pbxproj with FIXED
// identifiers derived from file paths (md5), so repeated runs are
// byte-identical. Requires nothing beyond the Swift toolchain. Targets:
//   LiteratureCore          (static library, macOS, module LiteratureCore)
//   LiteratureSearchUI      (static library, macOS, deps core)
//   LiteratureSearch        (macOS app, deps UI + core + widget, embeds widget)
//   LiteratureSearchWidget  (macOS WidgetKit extension, embeds shared core files)
//   LiteratureSearchiOS     (iOS app: compiles ALL core + UI sources directly,
//                            embeds iOS widget + watch app)
//   LiteratureSearchWidgetiOS   (iOS WidgetKit extension, systemSmall/Medium/Large)
//   LiteratureSearchWatch   (watchOS summary app: compiles core sources MINUS
//                            the two PDFKit files, embeds watch widget)
//   LiteratureSearchWidgetWatch (watchOS widgets: circular/rectangular/corner/inline)
// LiteratureSearchShare (iOS Share Extension,:  compiles the
//                            ShareViewController shell + ShareReceive.swift
//                            ONLY — credential-free closure by construction)
//
// the watch targets also compile WatchCompanion.swift (daily-quote /
//   reading-progress payload, Foundation-only) alongside WatchSummary.swift.
//
// Cross-platform apps deliberately compile the core sources into the target
// instead of linking per-platform static libraries: two same-named static
// libraries built into one derived-data products dir collide
// ("Multiple commands produce libLiteratureCore.a"). This mirrors the widget
// extensions, which already compile their shared core files directly.
//
// Cross-device targets are UNSIGNED placeholders for a development-signing
// environment: DEVELOPMENT_TEAM is empty, CloudKit is not referenced. They
// build with CODE_SIGNING_ALLOWED=NO for the iOS/watchOS SDKs.
//
// Schemes are intentionally NOT emitted: xcodebuild/Xcode auto-generate usable
// per-target schemes, while a handwritten minimal scheme crashed xcodebuild.
//
// pbxproj is whitespace-insensitive; this generator emits plain 4-space
// indentation (deliberately avoids escape-sequence pitfalls).

import Foundation
import CryptoKit

let fm = FileManager.default

let scriptPath = CommandLine.arguments[0]
let repoRoot = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().deletingLastPathComponent()
let pbxprojDir = repoRoot.appendingPathComponent("app/LiteratureSearch.xcodeproj")

// MARK: - File inventory (deterministic order)

func listSwiftFiles(_ dir: URL, prefix: String) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".swift") }
        .sorted()
        .map { prefix + "/" + $0 }
}

let coreDir = repoRoot.appendingPathComponent("Sources/LiteratureCore")
let allCoreFiles = listSwiftFiles(coreDir, prefix: "../Sources/LiteratureCore")

func lastComponentCompat(_ path: String) -> String { (path as NSString).lastPathComponent }

let coreFiles = allCoreFiles
let uiFiles = listSwiftFiles(repoRoot.appendingPathComponent("Sources/LiteratureSearchUI"), prefix: "../Sources/LiteratureSearchUI")
let appFiles = listSwiftFiles(repoRoot.appendingPathComponent("Sources/LiteratureSearchApp"), prefix: "../Sources/LiteratureSearchApp")
let widgetFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/Widget"), prefix: "../app/Widget")
let iosAppFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/iOS"), prefix: "../app/iOS")
let iosWidgetFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/WidgetiOS"), prefix: "../app/WidgetiOS")
let watchAppFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/watch"), prefix: "../app/watch")
let watchWidgetFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/WidgetWatch"), prefix: "../app/WidgetWatch")
let watchSharedFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/WatchShared"), prefix: "../app/WatchShared")
let shareExtFiles = listSwiftFiles(repoRoot.appendingPathComponent("app/ShareExtension"), prefix: "../app/ShareExtension")

// Foundation-only core files compiled directly into widget extensions
// (no package reference needed inside Xcode).
let deepLinkFile = "../Sources/LiteratureCore/DeepLink.swift"
let sharedHistoryFile = "../Sources/LiteratureCore/SharedHistoryStore.swift"
let sharedQuoteStateFile = "../Sources/LiteratureCore/SharedQuoteState.swift"
let watchSummaryCoreFile = "../Sources/LiteratureCore/WatchSummary.swift"

let widgetSharedCore = [deepLinkFile, sharedHistoryFile, sharedQuoteStateFile].sorted()
let iosWidgetSharedCore = [deepLinkFile, sharedHistoryFile].sorted()
// WatchSummary is self-contained on purpose (own error type, no IndexStore);
// Fingerprint is CryptoKit-only and needed for its index stamp.
// WatchCompanion (daily-quote/progress payload) is likewise
// Foundation-only and self-contained — compiled into both watch targets.
let watchWidgetSharedCore = [deepLinkFile, sharedHistoryFile, watchSummaryCoreFile,
                             "../Sources/LiteratureCore/Fingerprint.swift",
                             "../Sources/LiteratureCore/WatchCompanion.swift"].sorted()

// Share Extension 入站收录——Extension
// target 直编的 Core 闭包 = 仅 ShareReceive.swift（自包含 Foundation-only，
// 约束「Extension 不持凭据」：类型零共享，WebDAV/SecretStore 物理不在
// target 内）。
let shareExtSharedCore = ["../Sources/LiteratureCore/ShareReceive.swift"]

let appPlist = "../app/Support/LiteratureSearch-Info.plist"
let appAssetCatalog = "../app/Support/Resources/Assets.xcassets"
let widgetPlist = "../app/Support/LiteratureSearchWidget-Info.plist"
let appEnt = "../app/Support/LiteratureSearch.entitlements"
let widgetEnt = "../app/Support/LiteratureSearchWidget.entitlements"
let iosAppPlist = "../app/Support/LiteratureSearchiOS-Info.plist"
let iosWidgetPlist = "../app/Support/LiteratureSearchWidgetiOS-Info.plist"
let iosAppEnt = "../app/Support/LiteratureSearchiOS.entitlements"
let iosWidgetEnt = "../app/Support/LiteratureSearchWidgetiOS.entitlements"
let watchAppPlist = "../app/Support/LiteratureSearchWatch-Info.plist"
let watchWidgetPlist = "../app/Support/LiteratureSearchWidgetWatch-Info.plist"
let watchAppEnt = "../app/Support/LiteratureSearchWatch.entitlements"
let watchWidgetEnt = "../app/Support/LiteratureSearchWidgetWatch.entitlements"
let sharePlist = "../app/Support/LiteratureSearchShare-Info.plist"
let shareEnt = "../app/Support/LiteratureSearchShare.entitlements"

// MARK: - Deterministic identifiers

func uuid(_ seed: String) -> String {
    String(Insecure.MD5.hash(data: Data(seed.utf8)).map { String(format: "%02X", $0) }.joined().prefix(24))
}

func q(_ s: String) -> String { "\"\(s)\"" }

let coreTargetID = uuid("target:LiteratureCore")
let uiTargetID = uuid("target:LiteratureSearchUI")
let appTargetID = uuid("target:LiteratureSearch")
let widgetTargetID = uuid("target:LiteratureSearchWidget")
let iosAppTargetID = uuid("target:LiteratureSearchiOS")
let iosWidgetTargetID = uuid("target:LiteratureSearchWidgetiOS")
let watchAppTargetID = uuid("target:LiteratureSearchWatch")
let watchWidgetTargetID = uuid("target:LiteratureSearchWidgetWatch")
let shareTargetID = uuid("target:LiteratureSearchShare")
let projectID = uuid("project:LiteratureSearch")

let coreProductRefID = uuid("product:libLiteratureCore.a")
let uiProductRefID = uuid("product:libLiteratureSearchUI.a")
let appProductRefID = uuid("product:LiteratureSearch.app")
let widgetProductRefID = uuid("product:LiteratureSearchWidget.appex")
let iosAppProductRefID = uuid("product:LiteratureSearchiOS.app")
let iosWidgetProductRefID = uuid("product:LiteratureSearchWidgetiOS.appex")
let watchAppProductRefID = uuid("product:LiteratureSearchWatch.app")
let watchWidgetProductRefID = uuid("product:LiteratureSearchWidgetWatch.appex")
let shareProductRefID = uuid("product:LiteratureSearchShare.appex")

func fileRefID(_ path: String) -> String { uuid("fileref:" + path) }
func buildFileID(_ target: String, _ path: String) -> String { uuid("buildfile:\(target):" + path) }
func groupID(_ name: String) -> String { uuid("group:" + name) }
func configListID(_ owner: String) -> String { uuid("xcconfiglist:" + owner) }
func configID(_ owner: String, _ name: String) -> String { uuid("xcconfig:\(owner):\(name)") }
func phaseID(_ target: String, _ kind: String) -> String { uuid("phase:\(kind):" + target) }
func proxyID(_ dependent: String, _ provider: String) -> String { uuid("proxy:\(dependent):\(provider)") }
func dependencyID(_ dependent: String, _ provider: String) -> String { uuid("dep:\(dependent):\(provider)") }

let embedPhaseID = uuid("phase:embed:LiteratureSearch")
let widgetCopyPhaseID = uuid("phase:copyfiles:LiteratureSearchWidget")
let iosEmbedPhaseID = uuid("phase:embed:LiteratureSearchiOS")
let iosEmbedWatchPhaseID = uuid("phase:embedwatch:LiteratureSearchiOS")
let watchEmbedPhaseID = uuid("phase:embed:LiteratureSearchWatch")
let coreLinkBuildFileID = uuid("buildfile:app:linkcore")
let uiLinkBuildFileID = uuid("buildfile:app:linkui")
let widgetEmbedBuildFileID = uuid("buildfile:app:embedwidget")
let iosWidgetEmbedBuildFileID = uuid("buildfile:iosapp:embedioswidget")
let iosShareEmbedBuildFileID = uuid("buildfile:iosapp:embedshareext")
let watchAppEmbedBuildFileID = uuid("buildfile:iosapp:embedwatchapp")
let watchWidgetEmbedBuildFileID = uuid("buildfile:watchapp:embedwatchwidget")

// MARK: - Platforms

enum Platform {
    case macOS
    case iOS
    case watchOS

    var sdkroot: String {
        switch self {
        case .macOS: return "macosx"
        case .iOS: return "iphoneos"
        case .watchOS: return "watchos"
        }
    }

    /// (setting name, value) pairs; device families constrain app targets.
    var deployment: [(String, String)] {
        switch self {
        case .macOS: return [("MACOSX_DEPLOYMENT_TARGET", "13.0")]
        case .iOS: return [("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
                           ("TARGETED_DEVICE_FAMILY", "\"1,2\""),
                           ("SUPPORTS_MACCATALYST", "NO")]
        case .watchOS: return [("WATCHOS_DEPLOYMENT_TARGET", "10.0"),
                               ("TARGETED_DEVICE_FAMILY", "\"4\"")]
        }
    }
}

// MARK: - Target source lists

let coreTargetSources = coreFiles
let uiTargetSources = uiFiles
let appTargetSources = appFiles
let widgetTargetSources = (widgetFiles + widgetSharedCore).sorted()
let iosAppTargetSources = (iosAppFiles + uiFiles + allCoreFiles).sorted()
let iosWidgetTargetSources = (iosWidgetFiles + iosWidgetSharedCore).sorted()
// The watch is summary-only by design: it gets exactly the DeepLink +
// SharedHistoryStore + WatchSummary(+Fingerprint) closure — no index engine,
// no SQLite, no PDFKit.
let watchAppTargetSources = (watchAppFiles + watchSharedFiles + watchWidgetSharedCore).sorted()
let watchWidgetTargetSources = (watchWidgetFiles + watchSharedFiles + watchWidgetSharedCore).sorted()
// Share Extension（壳 + 仅 ShareReceive.swift Core 闭包）。
let shareTargetSources = (shareExtFiles + shareExtSharedCore).sorted()

// MARK: - Emit sections

var pbxBuildFile: [String] = []
var pbxFileReference: [String] = []
var sourcesFilesByTarget: [String: [String]] = [:]
var emittedFileRefs = Set<String>()

func emitSource(_ path: String, target: String) {
    emitFileRef(path)
    let bfID = buildFileID(target, path)
    let name = lastComponentCompat(path)
    pbxBuildFile.append("    \(bfID) /* \(name) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileRefID(path)) /* \(name) */; };")
    sourcesFilesByTarget[target, default: []].append("        \(bfID) /* \(name) in Sources */,")
}

func emitFileRef(_ path: String) {
    guard !emittedFileRefs.contains(path) else { return }
    emittedFileRefs.insert(path)
    let name = lastComponentCompat(path)
    pbxFileReference.append("    \(fileRefID(path)) /* \(name) */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = \(q(path)); sourceTree = SOURCE_ROOT; };")
}

func emitProductRef(_ id: String, _ name: String, fileType: String) {
    pbxFileReference.append("    \(id) /* \(name) */ = {isa = PBXFileReference; explicitFileType = \(q(fileType)); includeInIndex = 0; path = \(q(name)); sourceTree = BUILT_PRODUCTS_DIR; };")
}

func emitPlistRef(_ path: String) {
    guard !emittedFileRefs.contains(path) else { return }
    emittedFileRefs.insert(path)
    let name = lastComponentCompat(path)
    pbxFileReference.append("    \(fileRefID(path)) /* \(name) */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = text.plist.xml; path = \(q(path)); sourceTree = SOURCE_ROOT; };")
}

// Asset catalogs are folder references (no fileEncoding, folder.assetcatalog).
func emitAssetCatalogRef(_ path: String, target: String) {
    guard !emittedFileRefs.contains(path) else { return }
    emittedFileRefs.insert(path)
    let name = lastComponentCompat(path)
    pbxFileReference.append("    \(fileRefID(path)) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = \(q(path)); sourceTree = SOURCE_ROOT; };")
    pbxBuildFile.append("    \(buildFileID(target, path)) /* \(name) in Resources */ = {isa = PBXBuildFile; fileRef = \(fileRefID(path)) /* \(name) */; };")
}

for path in coreTargetSources { emitSource(path, target: "LiteratureCore") }
for path in uiTargetSources { emitSource(path, target: "LiteratureSearchUI") }
for path in appTargetSources { emitSource(path, target: "LiteratureSearch") }
for path in widgetTargetSources { emitSource(path, target: "LiteratureSearchWidget") }
for path in iosAppTargetSources { emitSource(path, target: "LiteratureSearchiOS") }
for path in iosWidgetTargetSources { emitSource(path, target: "LiteratureSearchWidgetiOS") }
for path in watchAppTargetSources { emitSource(path, target: "LiteratureSearchWatch") }
for path in watchWidgetTargetSources { emitSource(path, target: "LiteratureSearchWidgetWatch") }
for path in shareTargetSources { emitSource(path, target: "LiteratureSearchShare") }
for plist in [appPlist, widgetPlist, iosAppPlist, iosWidgetPlist, watchAppPlist, watchWidgetPlist, sharePlist] {
    emitPlistRef(plist)
}
emitAssetCatalogRef(appAssetCatalog, target: "LiteratureSearch")

// link + embed build files
pbxBuildFile.append("    \(coreLinkBuildFileID) /* libLiteratureCore.a in Frameworks */ = {isa = PBXBuildFile; fileRef = \(coreProductRefID) /* libLiteratureCore.a */; };")
pbxBuildFile.append("    \(uiLinkBuildFileID) /* libLiteratureSearchUI.a in Frameworks */ = {isa = PBXBuildFile; fileRef = \(uiProductRefID) /* libLiteratureSearchUI.a */; };")
pbxBuildFile.append("    \(widgetEmbedBuildFileID) /* LiteratureSearchWidget.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = \(widgetProductRefID) /* LiteratureSearchWidget.appex */; };")
pbxBuildFile.append("    \(iosWidgetEmbedBuildFileID) /* LiteratureSearchWidgetiOS.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = \(iosWidgetProductRefID) /* LiteratureSearchWidgetiOS.appex */; };")
pbxBuildFile.append("    \(iosShareEmbedBuildFileID) /* LiteratureSearchShare.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = \(shareProductRefID) /* LiteratureSearchShare.appex */; };")
pbxBuildFile.append("    \(watchAppEmbedBuildFileID) /* LiteratureSearchWatch.app in Embed Watch Content */ = {isa = PBXBuildFile; fileRef = \(watchAppProductRefID) /* LiteratureSearchWatch.app */; };")
pbxBuildFile.append("    \(watchWidgetEmbedBuildFileID) /* LiteratureSearchWidgetWatch.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = \(watchWidgetProductRefID) /* LiteratureSearchWidgetWatch.appex */; };")

emitProductRef(coreProductRefID, "libLiteratureCore.a", fileType: "archive.ar")
emitProductRef(uiProductRefID, "libLiteratureSearchUI.a", fileType: "archive.ar")
emitProductRef(appProductRefID, "LiteratureSearch.app", fileType: "wrapper.application")
emitProductRef(widgetProductRefID, "LiteratureSearchWidget.appex", fileType: "wrapper.app-extension")
emitProductRef(iosAppProductRefID, "LiteratureSearchiOS.app", fileType: "wrapper.application")
emitProductRef(iosWidgetProductRefID, "LiteratureSearchWidgetiOS.appex", fileType: "wrapper.app-extension")
emitProductRef(watchAppProductRefID, "LiteratureSearchWatch.app", fileType: "wrapper.application")
emitProductRef(watchWidgetProductRefID, "LiteratureSearchWidgetWatch.appex", fileType: "wrapper.app-extension")
emitProductRef(shareProductRefID, "LiteratureSearchShare.appex", fileType: "wrapper.app-extension")

// Groups (children deduplicated: shared files are members of multiple targets
// but must appear in the Files group exactly once, or xcodebuild rejects the
// project as malformed).
var seenChild = Set<String>()
func child(_ id: String, _ name: String) -> String {
    "\(id) /* \(name) */"
}

var sourceChildren: [String] = []
for path in (coreTargetSources + uiTargetSources + appTargetSources + widgetTargetSources
        + iosAppTargetSources + iosWidgetTargetSources
        + watchAppTargetSources + watchWidgetTargetSources
        + shareTargetSources
        + [appPlist, widgetPlist, iosAppPlist, iosWidgetPlist, watchAppPlist, watchWidgetPlist, sharePlist, appAssetCatalog]).sorted() {
    if seenChild.insert(path).inserted {
        sourceChildren.append("\(fileRefID(path)) /* \(lastComponentCompat(path)) */")
    }
}

let mainGroupID = uuid("group:main")
let filesGroupID = groupID("files")
let productsGroupID = groupID("products")

func groupBlock(_ id: String, name: String?, children: [String]) -> String {
    var s = "    \(id) = {\n        isa = PBXGroup;\n        children = (\n"
    for c in children { s += "            \(c),\n" }
    s += "        );\n"
    if let name { s += "        name = \(q(name));\n" }
    s += "        sourceTree = \"<group>\";\n    };"
    return s
}

let mainGroupBlock = groupBlock(mainGroupID, name: "LiteratureSearch", children: [
    child(filesGroupID, "Sources"),
    child(productsGroupID, "Products"),
])
let filesGroupBlock = groupBlock(filesGroupID, name: "Sources", children: sourceChildren)
let productsGroupBlock = groupBlock(productsGroupID, name: "Products", children: [
    child(appProductRefID, "LiteratureSearch.app"),
    child(widgetProductRefID, "LiteratureSearchWidget.appex"),
    child(coreProductRefID, "libLiteratureCore.a"),
    child(uiProductRefID, "libLiteratureSearchUI.a"),
    child(iosAppProductRefID, "LiteratureSearchiOS.app"),
    child(iosWidgetProductRefID, "LiteratureSearchWidgetiOS.appex"),
    child(watchAppProductRefID, "LiteratureSearchWatch.app"),
    child(watchWidgetProductRefID, "LiteratureSearchWidgetWatch.appex"),
    child(shareProductRefID, "LiteratureSearchShare.appex"),
])

// Build configurations

// All generated targets are team-empty by default; set signing in Xcode if needed.
func developmentTeamSetting(_ owner: String) -> String { "\"\"" }

func settingsDict(_ platform: Platform, extra: [(String, String)], release: Bool,
                  developmentTeam: String) -> String {
    var base: [(String, String)] = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("DEVELOPMENT_TEAM", developmentTeam),
        ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
        ("SDKROOT", platform.sdkroot),
        ("SWIFT_VERSION", "5.0"),
        ("SWIFT_OPTIMIZATION_LEVEL", release ? "\"-O\"" : "\"-Onone\""),
        ("GCC_OPTIMIZATION_LEVEL", release ? "s" : "0"),
    ]
    if platform == .macOS {
        base.append(("COMBINE_HIDPI_IMAGES", "YES"))
        base.append(("ENABLE_HARDENED_RUNTIME", "YES"))
    }
    base.append(contentsOf: platform.deployment)
    base.append(contentsOf: extra)
    var out = ""
    for (k, v) in base.sorted(by: { $0.0 < $1.0 }) {
        out += "            \(k) = \(v);\n"
    }
    return out
}

func configSection(_ owner: String, platform: Platform, extra: [(String, String)]) -> [String] {
    let team = developmentTeamSetting(owner)
    return ["Debug", "Release"].map { name in
        let release = (name == "Release")
        return """
            \(configID(owner, name)) /* \(name) */ = {
                isa = XCBuildConfiguration;
                buildSettings = {
            \(settingsDict(platform, extra: extra, release: release, developmentTeam: team))            };
                name = \(name);
            };
        """
    }
}

let appExtra: [(String, String)] = [
    ("ASSETCATALOG_COMPILER_APPICON_NAME", q("AppIcon")),
    ("CODE_SIGN_ENTITLEMENTS", q(appEnt)),
    ("INFOPLIST_FILE", q(appPlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app")),
]
let coreExtra: [(String, String)] = [
    ("DEFINES_MODULE", "YES"),
    ("PRODUCT_NAME", q("LiteratureCore")),
    ("SKIP_INSTALL", "YES"),
]
let uiExtra: [(String, String)] = [
    ("DEFINES_MODULE", "YES"),
    ("PRODUCT_NAME", q("LiteratureSearchUI")),
    ("SKIP_INSTALL", "YES"),
]
let widgetExtra: [(String, String)] = [
    ("CODE_SIGN_ENTITLEMENTS", q(widgetEnt)),
    ("INFOPLIST_FILE", q(widgetPlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app.widget")),
    ("SKIP_INSTALL", "YES"),
    ("WRAPPER_EXTENSION", "appex"),
]
let iosAppExtra: [(String, String)] = [
    ("CODE_SIGN_ENTITLEMENTS", q(iosAppEnt)),
    ("INFOPLIST_FILE", q(iosAppPlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app.ios")),
    ("SUPPORTS_MACCATALYST", "NO"),
]
let iosWidgetExtra: [(String, String)] = [
    ("CODE_SIGN_ENTITLEMENTS", q(iosWidgetEnt)),
    ("INFOPLIST_FILE", q(iosWidgetPlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app.ios.widget")),
    ("SKIP_INSTALL", "YES"),
    ("WRAPPER_EXTENSION", "appex"),
]
let watchAppExtra: [(String, String)] = [
    ("CODE_SIGN_ENTITLEMENTS", q(watchAppEnt)),
    ("INFOPLIST_FILE", q(watchAppPlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app.ios.watchkitapp")),
    ("WK_APPLICATION", "YES"),
]
let watchWidgetExtra: [(String, String)] = [
    ("CODE_SIGN_ENTITLEMENTS", q(watchWidgetEnt)),
    ("INFOPLIST_FILE", q(watchWidgetPlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app.ios.watchkitapp.widget")),
    ("SKIP_INSTALL", "YES"),
    ("WRAPPER_EXTENSION", "appex"),
]
// Share Extension（iOS；App Group 沿用既有 entitlements 同组）。
let shareExtra: [(String, String)] = [
    ("CODE_SIGN_ENTITLEMENTS", q(shareEnt)),
    ("INFOPLIST_FILE", q(sharePlist)),
    ("PRODUCT_BUNDLE_IDENTIFIER", q("com.example.literaturesearch.app.ios.share")),
    ("SKIP_INSTALL", "YES"),
    ("WRAPPER_EXTENSION", "appex"),
]

let configSections = (configSection("project", platform: .macOS, extra: [])
    + configSection("core", platform: .macOS, extra: coreExtra)
    + configSection("ui", platform: .macOS, extra: uiExtra)
    + configSection("app", platform: .macOS, extra: appExtra)
    + configSection("widget", platform: .macOS, extra: widgetExtra)
    + configSection("iosapp", platform: .iOS, extra: iosAppExtra)
    + configSection("ioswidget", platform: .iOS, extra: iosWidgetExtra)
    + configSection("watchapp", platform: .watchOS, extra: watchAppExtra)
    + configSection("watchwidget", platform: .watchOS, extra: watchWidgetExtra)
    + configSection("shareext", platform: .iOS, extra: shareExtra))
    .joined(separator: "\n")

func configList(_ owner: String) -> String {
    """
        \(configListID(owner)) = {
            isa = XCConfigurationList;
            buildConfigurations = (
                \(configID(owner, "Debug")) /* Debug */,
                \(configID(owner, "Release")) /* Release */,
            );
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Release;
        };
    """
}

func sourcesPhase(_ target: String) -> String {
    let files = sourcesFilesByTarget[target] ?? []
    return """
        \(phaseID(target, "sources")) /* Sources */ = {
            isa = PBXSourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (
        \(files.joined(separator: "\n"))
            );
            runOnlyForDeploymentPostprocessing = 0;
        };
    """
}

func frameworksPhase(_ target: String, files: [String]) -> String {
    var fileLines = ""
    for f in files { fileLines += "            \(f),\n" }
    return """
        \(phaseID(target, "frameworks")) /* Frameworks */ = {
            isa = PBXFrameworksBuildPhase;
            buildActionMask = 2147483647;
            files = (
            \(fileLines));
            runOnlyForDeploymentPostprocessing = 0;
        };
    """
}

func resourcesPhase(_ target: String, files: [String]) -> String {
    var fileLines = ""
    for f in files { fileLines += "            \(f),\n" }
    return """
        \(phaseID(target, "resources")) /* Resources */ = {
            isa = PBXResourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (
            \(fileLines));
            runOnlyForDeploymentPostprocessing = 0;
        };
    """
}

func containerProxy(_ dependent: String, _ provider: String, _ providerTargetID: String) -> String {
    """
        \(proxyID(dependent, provider)) /* PBXContainerItemProxy */ = {
            isa = PBXContainerItemProxy;
            containerPortal = \(projectID) /* Project object */;
            proxyType = 1;
            remoteGlobalIDString = \(providerTargetID);
            remoteInfo = \(provider);
        };
    """
}

func targetDependency(_ dependent: String, _ provider: String, _ providerTargetID: String) -> String {
    """
        \(dependencyID(dependent, provider)) /* PBXTargetDependency */ = {
            isa = PBXTargetDependency;
            target = \(providerTargetID) /* \(provider) */;
            targetProxy = \(proxyID(dependent, provider)) /* PBXContainerItemProxy */;
        };
    """
}

func nativeTarget(_ name: String, targetID: String, owner: String,
                  phases: [String], dependencies: [(String, String, String)],
                  productRefID: String, productName: String, productType: String) -> String {
    var phaseLines = ""
    for p in phases { phaseLines += "            \(p),\n" }
    var depLines = ""
    for (dependent, provider, _) in dependencies {
        depLines += "            \(dependencyID(dependent, provider)) /* PBXTargetDependency */,\n"
    }
    return """
        \(targetID) /* \(name) */ = {
            isa = PBXNativeTarget;
            buildConfigurationList = \(configListID(owner));
            buildPhases = (
        \(phaseLines)        );
            buildRules = (
            );
            dependencies = (
        \(depLines)        );
            name = \(name);
            productName = \(name);
            productReference = \(productRefID) /* \(productName) */;
            productType = \(q(productType));
        };
    """
}

let appDeps: [(String, String, String)] = [
    ("LiteratureSearch", "LiteratureSearchWidget", widgetTargetID),
    ("LiteratureSearch", "LiteratureCore", coreTargetID),
    ("LiteratureSearch", "LiteratureSearchUI", uiTargetID),
]
let uiDeps: [(String, String, String)] = [
    ("LiteratureSearchUI", "LiteratureCore", coreTargetID),
]
let iosAppDeps: [(String, String, String)] = [
    ("LiteratureSearchiOS", "LiteratureSearchWidgetiOS", iosWidgetTargetID),
    ("LiteratureSearchiOS", "LiteratureSearchWatch", watchAppTargetID),
    ("LiteratureSearchiOS", "LiteratureSearchShare", shareTargetID),
]
let watchAppDeps: [(String, String, String)] = [
    ("LiteratureSearchWatch", "LiteratureSearchWidgetWatch", watchWidgetTargetID),
]

let nativeTargets = [
    nativeTarget("LiteratureCore", targetID: coreTargetID, owner: "core",
                 phases: [phaseID("LiteratureCore", "sources"), phaseID("LiteratureCore", "frameworks")],
                 dependencies: [], productRefID: coreProductRefID,
                 productName: "libLiteratureCore.a",
                 productType: "com.apple.product-type.library.static"),
    nativeTarget("LiteratureSearchUI", targetID: uiTargetID, owner: "ui",
                 phases: [phaseID("LiteratureSearchUI", "sources"), phaseID("LiteratureSearchUI", "frameworks")],
                 dependencies: uiDeps, productRefID: uiProductRefID,
                 productName: "libLiteratureSearchUI.a",
                 productType: "com.apple.product-type.library.static"),
    nativeTarget("LiteratureSearch", targetID: appTargetID, owner: "app",
                 phases: [phaseID("LiteratureSearch", "sources"), phaseID("LiteratureSearch", "frameworks"),
                          phaseID("LiteratureSearch", "resources"), embedPhaseID],
                 dependencies: appDeps, productRefID: appProductRefID,
                 productName: "LiteratureSearch.app",
                 productType: "com.apple.product-type.application"),
    nativeTarget("LiteratureSearchWidget", targetID: widgetTargetID, owner: "widget",
                 phases: [phaseID("LiteratureSearchWidget", "sources"), phaseID("LiteratureSearchWidget", "frameworks"), widgetCopyPhaseID],
                 dependencies: [], productRefID: widgetProductRefID,
                 productName: "LiteratureSearchWidget.appex",
                 productType: "com.apple.product-type.app-extension"),
    nativeTarget("LiteratureSearchiOS", targetID: iosAppTargetID, owner: "iosapp",
                 phases: [phaseID("LiteratureSearchiOS", "sources"), phaseID("LiteratureSearchiOS", "frameworks"),
                          iosEmbedPhaseID, iosEmbedWatchPhaseID],
                 dependencies: iosAppDeps, productRefID: iosAppProductRefID,
                 productName: "LiteratureSearchiOS.app",
                 productType: "com.apple.product-type.application"),
    nativeTarget("LiteratureSearchShare", targetID: shareTargetID, owner: "shareext",
                 phases: [phaseID("LiteratureSearchShare", "sources"), phaseID("LiteratureSearchShare", "frameworks")],
                 dependencies: [], productRefID: shareProductRefID,
                 productName: "LiteratureSearchShare.appex",
                 productType: "com.apple.product-type.app-extension"),
    nativeTarget("LiteratureSearchWidgetiOS", targetID: iosWidgetTargetID, owner: "ioswidget",
                 phases: [phaseID("LiteratureSearchWidgetiOS", "sources"), phaseID("LiteratureSearchWidgetiOS", "frameworks")],
                 dependencies: [], productRefID: iosWidgetProductRefID,
                 productName: "LiteratureSearchWidgetiOS.appex",
                 productType: "com.apple.product-type.app-extension"),
    nativeTarget("LiteratureSearchWatch", targetID: watchAppTargetID, owner: "watchapp",
                 phases: [phaseID("LiteratureSearchWatch", "sources"), phaseID("LiteratureSearchWatch", "frameworks"),
                          watchEmbedPhaseID],
                 dependencies: watchAppDeps, productRefID: watchAppProductRefID,
                 productName: "LiteratureSearchWatch.app",
                 productType: "com.apple.product-type.application"),
    nativeTarget("LiteratureSearchWidgetWatch", targetID: watchWidgetTargetID, owner: "watchwidget",
                 phases: [phaseID("LiteratureSearchWidgetWatch", "sources"), phaseID("LiteratureSearchWidgetWatch", "frameworks")],
                 dependencies: [], productRefID: watchWidgetProductRefID,
                 productName: "LiteratureSearchWidgetWatch.appex",
                 productType: "com.apple.product-type.app-extension"),
].joined(separator: "\n")

// Assemble

var out = "// Generated by Scripts/generate-project.swift — do not edit by hand.\n"
out += "// Deterministic: fixed inventory + md5-derived identifiers; regenerate any time.\n"
out += """
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {
    };
    objectVersion = 56;
    objects = {

//* Begin PBXBuildFile section */
\(pbxBuildFile.joined(separator: "\n"))
//* End PBXBuildFile section */

//* Begin PBXContainerItemProxy section */
\(containerProxy("LiteratureSearch", "LiteratureSearchWidget", widgetTargetID))
\(containerProxy("LiteratureSearch", "LiteratureCore", coreTargetID))
\(containerProxy("LiteratureSearch", "LiteratureSearchUI", uiTargetID))
\(containerProxy("LiteratureSearchUI", "LiteratureCore", coreTargetID))
\(containerProxy("LiteratureSearchiOS", "LiteratureSearchWidgetiOS", iosWidgetTargetID))
\(containerProxy("LiteratureSearchiOS", "LiteratureSearchWatch", watchAppTargetID))
\(containerProxy("LiteratureSearchiOS", "LiteratureSearchShare", shareTargetID))
\(containerProxy("LiteratureSearchWatch", "LiteratureSearchWidgetWatch", watchWidgetTargetID))
//* End PBXContainerItemProxy section */

//* Begin PBXCopyFilesBuildPhase section */
    \(embedPhaseID) /* Embed App Extensions */ = {
        isa = PBXCopyFilesBuildPhase;
        buildActionMask = 2147483647;
        dstPath = "";
        dstSubfolderSpec = 13;
        files = (
            \(widgetEmbedBuildFileID) /* LiteratureSearchWidget.appex in Embed App Extensions */,
        );
        name = "Embed App Extensions";
        runOnlyForDeploymentPostprocessing = 0;
    };
    \(widgetCopyPhaseID) /* CopyFiles */ = {
        isa = PBXCopyFilesBuildPhase;
        buildActionMask = 2147483647;
        dstPath = "";
        dstSubfolderSpec = 10;
        files = (
        );
        runOnlyForDeploymentPostprocessing = 0;
    };
    \(iosEmbedPhaseID) /* Embed App Extensions */ = {
        isa = PBXCopyFilesBuildPhase;
        buildActionMask = 2147483647;
        dstPath = "";
        dstSubfolderSpec = 13;
        files = (
            \(iosWidgetEmbedBuildFileID) /* LiteratureSearchWidgetiOS.appex in Embed App Extensions */,
            \(iosShareEmbedBuildFileID) /* LiteratureSearchShare.appex in Embed App Extensions */,
        );
        name = "Embed App Extensions";
        runOnlyForDeploymentPostprocessing = 0;
    };
    \(iosEmbedWatchPhaseID) /* Embed Watch Content */ = {
        isa = PBXCopyFilesBuildPhase;
        buildActionMask = 2147483647;
        dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";
        dstSubfolderSpec = 16;
        files = (
            \(watchAppEmbedBuildFileID) /* LiteratureSearchWatch.app in Embed Watch Content */,
        );
        name = "Embed Watch Content";
        runOnlyForDeploymentPostprocessing = 0;
    };
    \(watchEmbedPhaseID) /* Embed App Extensions */ = {
        isa = PBXCopyFilesBuildPhase;
        buildActionMask = 2147483647;
        dstPath = "";
        dstSubfolderSpec = 13;
        files = (
            \(watchWidgetEmbedBuildFileID) /* LiteratureSearchWidgetWatch.appex in Embed App Extensions */,
        );
        name = "Embed App Extensions";
        runOnlyForDeploymentPostprocessing = 0;
    };
//* End PBXCopyFilesBuildPhase section */

//* Begin PBXFileReference section */
\(pbxFileReference.joined(separator: "\n"))
//* End PBXFileReference section */

//* Begin PBXFrameworksBuildPhase section */
\(frameworksPhase("LiteratureCore", files: []))
\(frameworksPhase("LiteratureSearchUI", files: []))
\(frameworksPhase("LiteratureSearch", files: [
    coreLinkBuildFileID + " /* libLiteratureCore.a in Frameworks */",
    uiLinkBuildFileID + " /* libLiteratureSearchUI.a in Frameworks */",
]))
\(frameworksPhase("LiteratureSearchWidget", files: []))
\(frameworksPhase("LiteratureSearchiOS", files: []))
\(frameworksPhase("LiteratureSearchWidgetiOS", files: []))
\(frameworksPhase("LiteratureSearchWatch", files: []))
\(frameworksPhase("LiteratureSearchWidgetWatch", files: []))
//* End PBXFrameworksBuildPhase section */

//* Begin PBXGroup section */
\(mainGroupBlock)
\(filesGroupBlock)
\(productsGroupBlock)
//* End PBXGroup section */

//* Begin PBXNativeTarget section */
\(nativeTargets)
//* End PBXNativeTarget section */

//* Begin PBXProject section */
    \(projectID) /* Project object */ = {
        isa = PBXProject;
        buildConfigurationList = \(configListID("project"));
        compatibilityVersion = "Xcode 14.0";
        developmentRegion = zh_CN;
        hasScannedForEncodings = 0;
        knownRegions = (
            en,
            Base,
        );
        mainGroup = \(mainGroupID);
        productRefGroup = \(productsGroupID);
        projectDirPath = "";
        projectRoot = "";
        targets = (
            \(coreTargetID) /* LiteratureCore */,
            \(uiTargetID) /* LiteratureSearchUI */,
            \(appTargetID) /* LiteratureSearch */,
            \(widgetTargetID) /* LiteratureSearchWidget */,
            \(iosAppTargetID) /* LiteratureSearchiOS */,
            \(iosWidgetTargetID) /* LiteratureSearchWidgetiOS */,
            \(watchAppTargetID) /* LiteratureSearchWatch */,
            \(watchWidgetTargetID) /* LiteratureSearchWidgetWatch */,
            \(shareTargetID) /* LiteratureSearchShare */,
        );
    };
//* End PBXProject section */

//* Begin PBXResourcesBuildPhase section */
\(resourcesPhase("LiteratureSearch", files: [
    buildFileID("LiteratureSearch", appAssetCatalog) + " /* Assets.xcassets in Resources */",
]))
//* End PBXResourcesBuildPhase section */

//* Begin PBXSourcesBuildPhase section */
\(sourcesPhase("LiteratureCore"))
\(sourcesPhase("LiteratureSearchUI"))
\(sourcesPhase("LiteratureSearch"))
\(sourcesPhase("LiteratureSearchWidget"))
\(sourcesPhase("LiteratureSearchiOS"))
\(sourcesPhase("LiteratureSearchWidgetiOS"))
\(sourcesPhase("LiteratureSearchWatch"))
\(sourcesPhase("LiteratureSearchWidgetWatch"))
\(sourcesPhase("LiteratureSearchShare"))
//* End PBXSourcesBuildPhase section */

//* Begin PBXTargetDependency section */
\(targetDependency("LiteratureSearch", "LiteratureSearchWidget", widgetTargetID))
\(targetDependency("LiteratureSearch", "LiteratureCore", coreTargetID))
\(targetDependency("LiteratureSearch", "LiteratureSearchUI", uiTargetID))
\(targetDependency("LiteratureSearchUI", "LiteratureCore", coreTargetID))
\(targetDependency("LiteratureSearchiOS", "LiteratureSearchWidgetiOS", iosWidgetTargetID))
\(targetDependency("LiteratureSearchiOS", "LiteratureSearchWatch", watchAppTargetID))
\(targetDependency("LiteratureSearchiOS", "LiteratureSearchShare", shareTargetID))
\(targetDependency("LiteratureSearchWatch", "LiteratureSearchWidgetWatch", watchWidgetTargetID))
//* End PBXTargetDependency section */

//* Begin XCBuildConfiguration section */
\(configSections)
//* End XCBuildConfiguration section */

//* Begin XCConfigurationList section */
\(configList("project"))
\(configList("core"))
\(configList("ui"))
\(configList("app"))
\(configList("widget"))
\(configList("iosapp"))
\(configList("ioswidget"))
\(configList("watchapp"))
\(configList("watchwidget"))
\(configList("shareext"))
//* End XCConfigurationList section */
    };
    rootObject = \(projectID) /* Project object */;
}
"""

try fm.createDirectory(at: pbxprojDir, withIntermediateDirectories: true)
try out.write(to: pbxprojDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

let data = try Data(contentsOf: pbxprojDir.appendingPathComponent("project.pbxproj"))
let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
print("generated: \(pbxprojDir.path)")
print("core: \(coreTargetSources.count), ui: \(uiTargetSources.count), app: \(appTargetSources.count), widget: \(widgetTargetSources.count)")
print("iosApp(=core+ui+iOS): \(iosAppTargetSources.count), iosWidget: \(iosWidgetTargetSources.count)")
print("watchApp(summary closure): \(watchAppTargetSources.count), watchWidget: \(watchWidgetTargetSources.count)")
print("shareExt(credential-free closure): \(shareTargetSources.count)")
print("pbxproj sha256: \(digest.prefix(16))")
