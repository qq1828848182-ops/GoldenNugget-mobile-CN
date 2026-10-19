import SwiftUI
import Minimuxer

/// Settings: what this build is, and the switches that change what a run does.
///
/// A plain `Form` in the system's grouped style.  The platform draws the
/// surface, the section headers, the row insets, the disclosure chrome and the
/// Liquid Glass; every colour and font here is semantic, so light and dark and
/// the user's text size all work without a palette of our own.
///
/// The About half is what a bug report actually needs — version, build, and the
/// two log files with their sizes.  The Apply half is the one switch that is not
/// a development switch: Skip Setup.  The Development half sits behind a master
/// switch because every row on it changes a real device.
struct SettingsView: View {
    // Reactive mirrors of `DevSettings.Key`, so a toggle redraws the page. The
    // engine reads the same strings through `DevSettings.effective`.
    @AppStorage(DevSettings.Key.enabled) private var devModeOn = false
    @AppStorage(DevSettings.Key.forcePartialRestore) private var forcePartialRestore = false
    @AppStorage(DevSettings.Key.verboseLog) private var verboseLog = true
    @AppStorage(DevSettings.Key.skipAfcMedia) private var skipAfcMedia = false

    /// Skip Setup's switch. Observed rather than mirrored with a second
    /// `@AppStorage` on the same key: the store is what the engine reads.
    @ObservedObject private var skipSetup = SkipSetupSettings.shared

    /// Read through `engine` rather than recomputed in the body, because a log is
    /// written by another thread while this page is open.
    @State private var logs = LogSizes()

    /// The setup guide, as a full-screen cover.
    ///
    /// It is the same view the app opens with on a first launch, on purpose: a
    /// second "getting started" page would be a second set of instructions to fall
    /// out of step with the first, and the whole reason this row exists is that a
    /// user who skipped the gate still needs it. A `NavigationLink` would have no
    /// place to return to after "Finish setup", which on an already-set-up app
    /// changes nothing the user can see.
    @State private var showSetupGuide = false

    /// The operation history (the port of `apply_history.py` and the desktop
    /// Settings page's *Operation History* card).  Held as loaded records and
    /// re-read whenever the page's filters change or an operation is cleared —
    /// the desktop re-reads the file on every refresh, and nothing else here
    /// watches the file.
    @State private var history: [ApplyHistory.Record] = []
    @State private var historySearch = ""
    @State private var historyMode = "all"
    @State private var historyResult = "all"

    /// Sizes and existence of the two files a report is built from.
    private struct LogSizes: Equatable {
        var appBytes: UInt64 = 0
        var rustBytes: UInt64 = 0
        var rustStatus: String = ""

        var appKB: UInt64 { appBytes / 1024 }
        var rustKB: UInt64 { rustBytes / 1024 }
        var hasApp: Bool { appBytes > 0 }
        var hasRust: Bool { rustBytes > 0 }
    }

    var body: some View {
        Form {
            aboutSection
            creditsSection
            setupSection
            logsSection
            applySection
            historySection
            developmentSection
        }
        .navigationTitle("设置")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showSetupGuide) {
            NavigationStack {
                FirstRunView { showSetupGuide = false }
            }
        }
        .task {
            refreshLogs()
            refreshHistory()
        }
        .onChange(of: devModeOn) { _, _ in DevSettings.applyLoggingPreference() }
        .onChange(of: verboseLog) { _, _ in DevSettings.applyLoggingPreference() }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("关于") {
            VStack(spacing: 12) {
                NativeLogo(size: 88)
                Text("GoldenNugget")
                    .font(.title2.bold())
                Text(Self.versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            // A credit, not a setting: centred and on its own, so it does not
            // read as a row.
            Text("由 GoldenNugget 开发团队用 ❤️ 制作\n")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)

            NativeNote("GoldenNugget 桌面版是本应用所移植的原始版本。"
                + "它使用自己的 Rust 和 Swift 技术栈运行同样的协议，而不是驱动 pymobiledevice3，并且能与 iOS 26 和 27 通信，而不只是与通过有线连接设备通信。"
                + ""
                + "")
        }
    }

    // MARK: - Credits

    /// What the app is built on, and by whom. Every row is a component that is
    /// really in the binary — the two static Rust/C archives are linked into the
    /// executable rather than embedded as frameworks (only `EMProxy.framework`
    /// ships as a dynamic framework in the IPA).
    private var creditsSection: some View {
        Section("致谢") {
            creditRow("GoldenNugget", "桌面版应用 · 本应用是它的移植版",
                      systemImage: "desktopcomputer")
            creditRow("idevice", "Rust 设备与备份技术栈",
                      systemImage: "shippingbox")
            creditRow("libimobiledevice", "C 协议核心",
                      systemImage: "chevron.left.forwardslash.chevron.right")
            creditRow("Minimuxer", "SideStore · 隧道与 usbmux",
                      systemImage: "network")
            creditRow("ZIPFoundation", "归档处理",
                      systemImage: "archivebox")
            NativeNote("这些内置的副本带有本地补丁，每个补丁的原因都列在 Vendor/patches/README.md 中。"
                + "SideStore 的 minimuxer 版权归 © 2026 SideStore 所有。"
                + "")
        }
    }

    private func creditRow(_ title: String, _ role: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Text(role)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Setup

    /// The guide, reachable after the fact.
    ///
    /// Its own section rather than a row under Apply: those rows are switches a run
    /// reads, and this one changes nothing about a run — it opens a screen. It
    /// also sits above them, because it is the answer to "why is nothing
    /// connecting", which is the question a user opens Settings with.
    private var setupSection: some View {
        Section("初始设置") {
            Button {
                showSetupGuide = true
            } label: {
                Label("设置向导", systemImage: "list.number")
            }
            NativeNote("检查本应用在能够连接设备之前所需的两个条件 —— LocalDevVPN 隧道和配对记录 —— 并带你逐一完成。"
                + "这是首次启动时会打开的指南。"
                + "")
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section("日志") {
            // The two halves of a report's evidence: this one is what the host
            // decided, the other is what the protocol did.
            shareRow(title: "goldennugget.log",
                     size: logs.appKB,
                     systemImage: "doc.plaintext",
                     url: GoldenNuggetEngine.appLogURL,
                     available: logs.hasApp)
            shareRow(title: "minimuxer.log",
                     size: logs.rustKB,
                     systemImage: "doc.text.magnifyingglass",
                     url: GoldenNuggetEngine.rustLogURL,
                     available: logs.hasRust)
            if !logs.hasRust, !logs.rustStatus.isEmpty {
                NativeNote(logs.rustStatus)
            }
            NativeNote(logs.hasApp
                ? "一份报告需要两个文件：应用日志说明做出了什么决定，minimuxer.log 说明设备应答了什么。"
                  + ""
                : "尚无应用日志 —— 从本次会话的首次运行开始写入。")
        }
    }

    private func shareRow(title: String, size: UInt64, systemImage: String,
                          url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 12) {
                Label("\(title)（\(size) KB）", systemImage: systemImage)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(available ? Color.primary : Color.secondary)
    }

    // MARK: - Apply

    /// Skip Setup, on its own page rather than behind the Development master: it is
    /// not a switch for working around a bug, it is part of what a run writes.
    private var applySection: some View {
        Section("应用") {
            switchRow("跳过设置",
                      note: skipSetupNote,
                      isOn: Binding(
                          get: { skipSetup.skipSetupEnabled },
                          set: { skipSetup.setSkipSetup($0) }))
        }
    }

    /// What the switch does, in the order the two files are written.
    private var skipSetupNote: String {
        [
            "默认开启，与上游一致。关闭时：应用只会携带调整项。",
            "开启时：应用会在调整项之前添加两个文件，顺序如下 ——",
            "1. SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/CloudConfigurationDetails.plist，\(SkipSetup.panes.count) 个设置面板被标记为已跳过；"
                + ""
                + "",
            "2. ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist，设置已标记为完成。",
            "设备已有的云配置不会被合并进来（读取它需要一个 lockdownd 服务，而此移植版本没有对应的路径），也不会生成密钥包证书。"
                + ""
                + "",
        ].joined(separator: "\n")
    }

    // MARK: - Operation History

    /// The desktop Settings page's *Operation History* card
    /// (`gui/ios/settings.py:741`): the last operations, searchable and
    /// filterable, read from the same `operations.json` the reference writes
    /// (`apply_history.py`).
    ///
    /// The desktop also reaches the preset actions from this page; here they
    /// live on their own **Presets** page, so only the history is duplicated
    /// from the reference's Settings.
    private var historySection: some View {
        Section("Operation History") {
            TextField("搜索历史……", text: $historySearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("Operation", selection: $historyMode) {
                Text("All operations").tag("all")
                Text("应用").tag("apply")
                Text("重置").tag("reset")
            }
            .pickerStyle(.segmented)

            Picker("Result", selection: $historyResult) {
                Text("All results").tag("all")
                Text("Success").tag("success")
                Text("失败").tag("failed")
            }
            .pickerStyle(.segmented)

            Text(historyCountLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(visibleHistory.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(historyRowText(record))
                        .font(.subheadline)
                    if !record.error.isEmpty {
                        Text(record.error)
                            .font(.caption)
                            .foregroundStyle(record.success ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                ApplyHistory.clear()
                refreshHistory()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(history.isEmpty)
        }
    }

    /// Newest-first, filtered and searched exactly as the reference's
    /// `_refresh_history` does (`settings.py:783`).
    private var matchingHistory: [ApplyHistory.Record] {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history.reversed().filter { item in
            if historyMode != "all" && item.mode != historyMode { return false }
            if historyResult == "success" && !item.success { return false }
            if historyResult == "failed" && item.success { return false }
            guard !query.isEmpty else { return true }
            let haystack = [item.timestamp, item.mode, item.device, item.model, item.ios, item.error]
                .joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    /// The reference caps the list at ten rows (`settings.py:804`).
    private var visibleHistory: [ApplyHistory.Record] {
        Array(matchingHistory.prefix(10))
    }

    private var historyCountLine: String {
        let matches = matchingHistory.count
        if matches > visibleHistory.count {
            return "显示 \(matches) 项操作中的 \(visibleHistory.count) 项"
        }
        if matches > 0 {
            return "\(matches) operations found"
        }
        let filtered = !historySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || historyMode != "all" || historyResult != "all"
        return filtered ? "No matching operations" : "No operations recorded yet"
    }

    /// One row's line, in the reference's own vocabulary
    /// (`settings.py:823`): `when • mode • device • iOS version • result`.
    private func historyRowText(_ record: ApplyHistory.Record) -> String {
        let mode = record.mode == "apply" ? "应用" : "重置"
        let result = record.success ? "Success" : "失败"
        let device = record.device.isEmpty ? "Unknown device" : record.device
        let ios = record.ios.isEmpty ? "?" : record.ios
        return "\(Self.displayTimestamp(record.timestamp))  •  \(mode)  •  "
            + "\(device)  •  iOS \(ios)  •  \(result)"
    }

    /// `datetime.fromisoformat(...).strftime("%Y-%m-%d %H:%M")`, falling back to
    /// the stored string when it is not a parseable timestamp.
    private static func displayTimestamp(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func refreshHistory() {
        history = ApplyHistory.load()
    }

    // MARK: - Development

    private var developmentSection: some View {
        Section("开发") {
            Toggle(isOn: $devModeOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开发者模式")
                    NativeNote(devModeOn
                        ? "下面的开关在下次运行时生效。"
                        : "关闭时：运行走正常路径，已存储的开关会被忽略。")
                }
            }

            if devModeOn {
                switchRow("强制部分恢复",
                          note: "即使设备报告的是 iOS 27 或更高版本，也走 iOS 26 分支 —— 即从零构建的局部恢复 —— 并完全跳过保护性备份。"
                              + ""
                              + "",
                          isOn: $forcePartialRestore)

                switchRow("详细日志",
                          note: verboseLog
                            ? "将协议细节记录到 minimuxer.log。"
                              + "关闭后会保留应用日志和运行本身，只丢弃逐帧的记录行。"
                              + ""
                            : "当前未记录协议细节。应用日志仍在记录。",
                          isOn: $verboseLog)

                switchRow("跳过 AFC 媒体",
                          note: "一次运行通常会在备份与清理之间复制相机胶卷中的媒体。"
                              + "此项会将其排除在外，而在相机胶卷很满时，这就是数分钟与数秒之差。"
                              + "",
                          isOn: $skipAfcMedia)

                Button("重置开关", systemImage: "arrow.counterclockwise") {
                    DevSettings.resetSwitches()
                    DevSettings.applyLoggingPreference()
                }

                NativeSafetyNote("这些是开关，不是修复。"
                    + "对真正的 iOS 27 设备强制使用局部恢复，预计会在恢复步骤失败，因为合成出来的清单不带有域注册信息。"
                    + "")
            }
        }
    }

    // MARK: - Rows

    /// A labelled switch with the explanation underneath it.
    private func switchRow(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                NativeNote(note)
            }
        }
    }

    private func refreshLogs() {
        logs = LogSizes(appBytes: GoldenNuggetEngine.appLogSize(),
                        rustBytes: GoldenNuggetEngine.rustLogSize(),
                        rustStatus: GoldenNuggetEngine.rustLogStatus())
    }

    // MARK: - Bundle facts

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private static var versionText: String {
        "\(info("CFBundleShortVersionString"))（\(info("CFBundleVersion")))"
    }
}
