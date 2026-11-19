import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - AI 配置设置面板（多档案/按用途路由/连通测试/密钥文件状态卡）
//
// 存储层=AIProfilesStore（UI 层，密钥入 Keychain）。本视图只做编辑与
// 展示；测试按钮为用户显式点击（不违反零默认发送门），最小 POST 直发。
// 档案类型选择（云端/端上）——端上档案隐藏 URL/密钥字段并
// 显示体检卡（逐项状态＋contextTokens，探针按需调用不轮询）；路由区
// 端上档案行名带「端上」徽标。STORM 分档建议作提示文案不强制。

struct AIProfilesSettingsView: View {
    let store: AIProfilesStore
    @Environment(\.dismiss) private var dismiss
    @State private var newProfileName = ""
    @State private var newProfileURL = ""
    @State private var newProfileModel = ""
    @State private var newProfileKey = ""
    @State private var keyDrafts: [UUID: String] = [:]
    @State private var testResults: [UUID: String] = [:]
    @State private var keyFileLine = ""
    /// 端上模型体检状态（onAppear 按需探针一次；无 Timer 无轮询）。
    @State private var onDeviceStatus: OnDeviceModelStatus?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.aiProfilesSettingsTitle).font(.headline)
                Spacer()
                // 豁免：.defaultAction 是系统 default 按钮（回车角色），非实键绑定，不进注册表。
                Button(L10n.commonDone) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
            Form {
                profilesSection
                routingSection
                keyFileSection
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            refreshKeyFile()
            refreshOnDeviceStatus()
        }
    }

    // MARK: 档案区

    private var profilesSection: some View {
        Section(L10n.aiProfilesSectionTitle) {
            ForEach(store.profiles, id: \.id) { profile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profile.name + (store.isDefault(profile.id) ? L10n.aiProfilesDefaultBadge : ""))
                            .font(.headline)
                        Spacer()
                        if store.defaultProfileID != profile.id {
                            Button(L10n.aiProfilesSetDefault) { store.setDefault(id: profile.id) }
                        }
                        Button(L10n.aiProfilesDelete, role: .destructive) { store.deleteProfile(id: profile.id) }
                    }
                    // 档案类型选择（云端/端上；缺省云端）。
                    Picker(L10n.aiProfileKindLabel, selection: kindBinding(profile)) {
                        Text(L10n.aiProfileKindCloud).tag(OnDeviceProfileKind.cloud)
                        Text(L10n.aiProfileKindOnDevice).tag(OnDeviceProfileKind.onDevice)
                    }
                    .pickerStyle(.segmented)
                    if OnDeviceProfileKind.isOnDevice(profile.kind) {
                        // 端上档案：无 URL/密钥可言（数据不出设备），显示体检卡。
                        if let status = onDeviceStatus {
                            OnDeviceHealthCard(status: status)
                        }
                        HStack {
                            Button(L10n.aiOnDeviceHealthTitle) { refreshOnDeviceStatus() }
                            Text(L10n.aiOnDevicePerfNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        TextField(L10n.aiProfilesFieldName, text: nameBinding(profile))
                        TextField(L10n.aiProfilesFieldURL, text: urlBinding(profile))
                        TextField(L10n.aiProfilesFieldModel, text: modelBinding(profile))
                        HStack {
                            SecureField(L10n.aiProfilesFieldKey, text: Binding(
                                get: { keyDrafts[profile.id] ?? "" },
                                set: { keyDrafts[profile.id] = $0 }))
                            Button(L10n.aiProfilesSaveKey) {
                                if let draft = keyDrafts[profile.id] {
                                    try? store.upsertKey(draft, for: profile.id)
                                    keyDrafts[profile.id] = ""
                                }
                            }
                            .disabled((keyDrafts[profile.id] ?? "").isEmpty)
                            Text(keyStateLabel(profile.id))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(L10n.aiProfilesTest) { testProfile(profile) }
                            if let result = testResults[profile.id] {
                                Text(result).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                TextField(L10n.aiProfilesNewName, text: $newProfileName)
                TextField(L10n.aiProfilesFieldURL, text: $newProfileURL)
                TextField(L10n.aiProfilesFieldModel, text: $newProfileModel)
                SecureField(L10n.aiProfilesFieldKey, text: $newProfileKey)
                Button(L10n.aiProfilesAdd) { addProfile() }
            }
        }
    }

    /// 档案类型绑定（经 upsert 写回；不改 store 公共面）。
    private func kindBinding(_ profile: AIProfile) -> Binding<String> {
        Binding(get: { profile.kind ?? OnDeviceProfileKind.cloud },
                set: { newValue in
                    var updated = profile
                    updated.kind = newValue
                    store.upsert(updated)
                })
    }

    /// 端上体检：按需探针（无 Timer、无轮询）。
    private func refreshOnDeviceStatus() {
        onDeviceStatus = makeOnDeviceModelProbe()?.status()
    }

    private func nameBinding(_ profile: AIProfile) -> Binding<String> {
        Binding(get: { profile.name }, set: { store.rename(profile.id, name: $0) })
    }

    private func urlBinding(_ profile: AIProfile) -> Binding<String> {
        Binding(get: { profile.baseURL }, set: { store.updateEndpoint(profile.id, url: $0) })
    }

    private func modelBinding(_ profile: AIProfile) -> Binding<String> {
        Binding(get: { profile.model }, set: { store.updateModel(profile.id, model: $0) })
    }

    private func keyStateLabel(_ id: UUID) -> String {
        store.keyConfigured(account: id.uuidString) ? L10n.aiProfilesKeySet : L10n.aiProfilesKeyMissing
    }

    private func addProfile() {
        let name = newProfileName.isEmpty ? L10n.aiProfilesNewName : newProfileName
        let profile = AIProfile(name: name, baseURL: newProfileURL, model: newProfileModel, note: "")
        store.upsert(profile)
        if !newProfileKey.isEmpty { try? store.upsertKey(newProfileKey, for: profile.id) }
        newProfileName = ""; newProfileURL = ""; newProfileModel = ""; newProfileKey = ""
    }

    // MARK: 路由区

    private var routingSection: some View {
        Section(L10n.aiProfilesRoutingTitle) {
            ForEach(AIPurpose.allCases, id: \.rawValue) { purpose in
                Picker(purpose.displayName, selection: Binding(
                    get: { store.profileID(for: purpose) },
                    set: { store.bind(purpose, to: $0) })) {
                    Text(L10n.aiProfilesFollowDefault).tag(UUID?.none)
                    ForEach(store.profiles, id: \.id) { profile in
                        Text(profile.name
                             + (OnDeviceProfileKind.isOnDevice(profile.kind)
                                ? L10n.aiProfilesOnDeviceBadge : ""))
                            .tag(UUID?.some(profile.id))
                    }
                }
            }
        }
    }

    // MARK: 密钥文件状态卡（只读；不读内容）

    private var keyFileSection: some View {
        Section(L10n.aiProfilesKeyFileTitle) {
            Text(keyFileLine).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshKeyFile() {
        let path = NSString(string: "~/.config/literaturesearch/keys/api.key").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? NSNumber else {
            keyFileLine = L10n.aiProfilesKeyFileMissing
            return
        }
        keyFileLine = perms.intValue == 0o600 ? L10n.aiProfilesKeyFileOK : L10n.aiProfilesKeyFilePerms
    }

    // MARK: 连通测试（用户显式点击；最小 POST；HTTPS 强制）

    private func testProfile(_ profile: AIProfile) {
        testResults[profile.id] = L10n.aiProfilesTesting
        let key = (try? store.readKeyFromStorage(account: profile.id.uuidString)) ?? ""
        guard let url = URL(string: profile.baseURL), url.scheme == "https" else {
            testResults[profile.id] = L10n.aiProfilesTestBadURL
            return
        }
        let t0 = Date()
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": profile.model,
                                   "messages": [["role": "user", "content": L10n.aiProfilesProbePrompt]],
                                   "max_tokens": 16]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                testResults[profile.id] = code == 200
                    ? String(format: "%@ %dms", L10n.aiProfilesTestOK, ms)
                    : "\(L10n.aiProfilesTestFail) HTTP \(code)"
            } catch {
                testResults[profile.id] = "\(L10n.aiProfilesTestFail) \(error.localizedDescription)"
            }
        }
    }
}
