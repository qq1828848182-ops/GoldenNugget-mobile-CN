import SwiftUI
import UniformTypeIdentifiers

/// The PosterBoard page: wallpaper packs, a video wallpaper, and the resets.
///
/// The reference's own page has three tabs — Tendies, Templates, Video — plus a
/// reset dialog.  Templates is **not** here, and its absence is now a routing
/// decision rather than a gap: a `.batter` template is not necessarily a
/// wallpaper.  Only one whose `domain` is PosterBoard's rides along with the
/// wallpapers below, and any other restores into some other app's container —
/// putting those under a page called PosterBoard would say something false
/// about them.  Since 2026-10-18 it has its own page (**Templates**), with its
/// own options engine; see `docs/template-port.md`.  What *is* here covers
/// everything the other two tabs do, including the video method the reset
/// dialog exists to recover from.
///
/// Three things this page says that the reference does not, all of them because
/// this port has to be honest about what has run on a device:
///
///   * **The database card.** A wallpaper is a descriptor directory *plus* three
///     rows in the store's own sqlite, and the database cannot be synthesised —
///     it has to be fetched from the device.  The card says when that happened
///     last, and the fetch is also the first stage of an apply that needs one.
///     It is hidden on AirLift, which has no such stage: that mode writes the
///     descriptors into the container and never touches the rows.
///   * **The unsafe-container warning** is shown on the pack row rather than in
///     a modal that appears on import: it is a property of the pack, and it stays
///     true for as long as the pack is listed.
///   * **The reset section states what it does not undo.** A reset makes the
///     fetched database stale, so the next apply fetches a fresh one; saying so
///     here is cheaper than the puzzle of a store that half-works.
struct PosterBoardView: View {
    /// Everything this page edits, **owned by `RootView`**: the page picks the
    /// wallpapers and the home page's single `Apply` delivers them, so the selection has
    /// to outlive this view — which a `NavigationSplitView` destroys on every sidebar
    /// selection.  The old `@AppStorage` options moved in here for the same reason: two
    /// sources of truth for "was Loop on" is one too many when the second one is the one
    /// that applies.
    @Binding var selection: PosterBoardSelection

    @State private var identity: DeviceIdentity = .unknown
    @State private var databaseSummary = "尚未检查"
    @State private var pickError: String?
    /// Only the database fetch runs from this page — the apply is the home page's.
    @State private var status: String?
    @State private var statusTone: GoldenTone = .secondary
    @State private var running = false
    @State private var runStarted: Date?

    @State private var showPackImporter = false
    @State private var showVideoImporter = false
    @State private var showThumbnailImporter = false

    /// The apply mode, seeded from the setting and written back on change.
    ///
    /// `@AppStorage` would have been the shorter version, and the reason it is not
    /// used is that the mode has to be validated against the device on this page —
    /// AirLift needs iOS 26.2 and a pairing record, and a picker that can hold a mode
    /// the page will later refuse is a worse thing to show than one that cannot be
    /// set here.
    @State private var applyMode: PosterBoardApplyMode = .airlift

    /// The imported pack awaiting a Convert / Install-as-is answer, if any. See
    /// `LegacyConvertPromptModifier` for why the question is a value rather than
    /// an immediate call.
    @State private var legacyPrompt: LegacyConvertPrompt?

    var body: some View {
        List {
            deviceSection
            applyModeSection
            // AirLift writes the descriptors into the container and never looks
            // at the store's sqlite, so on that mode the whole card is about a
            // stage the run will not perform. Leaving it up would be offering a
            // fetch that the apply below ignores.
            if applyMode != .airlift { databaseSection }
            packsSection
            videoSection
            resetSection
            if applyMode == .airlift { airliftApplySection }
            applySection
            if let pickError { errorSection(pickError) }
            if !statusText.isEmpty {
                Section {
                    Text(statusText)
                        .foregroundStyle(statusTone.nativeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RunLogCard()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PosterBoard")
        .navigationBarTitleDisplayMode(.inline)
        // Loading the pack list and the database state is a directory walk and a
        // file stat, so it happens here and not in `body`. `loadFromDisk` is idempotent
        // and does not touch the options: `RootView` already ran it at launch, and this
        // pass is what picks up a pack imported from somewhere else meanwhile.
        .task {
            // The device line is read here and not in `body`, like every other page: it is
            // a lockdown call.  It used to be declared and never set, so the card said
            // "unknown device" for the whole life of this page.
            identity = await DeviceIdentity.read()
            selection.loadFromDisk()
            applyMode = PosterBoardApplyModeSettings.current
            refreshDatabaseSummary()
        }
        .legacyConvertPrompt($legacyPrompt, answer: answerLegacyPrompt)
    }

    // MARK: - The legacy-format answer

    /// Store the Convert / Install-as-is answer and reload the selection, which is
    /// what puts the new answer on the pack the apply reads.
    ///
    /// The reference assigns `auto_convert` on the tendie it just created; the pack
    /// list here is re-read from disk, so the answer goes to
    /// `PosterBoardPreferences.autoConvertAnswers` through
    /// `settingAutoConvert` and the list is rebuilt from it.
    private func answerLegacyPrompt(_ prompt: LegacyConvertPrompt, _ convert: Bool) {
        legacyPrompt = nil
        // `settingAutoConvert` writes the answer straight through, which is what
        // matters here: the pack in the selection is a value read from the archive,
        // and the apply re-reads it too.
        _ = prompt.pack.settingAutoConvert(convert)
        RunLog.shared.append(convert
            ? "PosterBoard：应用时 \(prompt.pack.name) 将转换为新版格式（旧版：\(prompt.families.joined(separator: ", "))）。"
                + ""
            : "PosterBoard：\(prompt.pack.name) 将保持原有的旧版格式（\(prompt.families.joined(separator: ", "))）。"
                + "")
        selection.loadFromDisk()
    }

    // MARK: - Device and database

    private var deviceSection: some View {
        Section {
            Text(identity.describe)
                .font(.headline)
            NativeNote("壁纸以文件形式交付到本应用自己制作的设备备份中，位于 \(PosterBoard.domain) 域 —— 与调整项使用同一通道。"
                + "在应用之前，不会向设备写入任何内容。"
                + "")
        }
    }

    // MARK: - Apply mode

    /// The two ways a selection can reach the device, as a segmented choice.
    ///
    /// A `Picker` rather than a switch: this is a choice between two mechanisms
    /// with different costs, and a switch cannot show what the other option is.
    /// The consequence of picking AirLift is spelled out under it, because
    /// "AirLift" alone says nothing about the version floor or the reboot it
    /// saves.
    private var applyModeSection: some View {
        Section {
            Picker("如何应用", selection: $applyMode) {
                ForEach(PosterBoardApplyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: applyMode) { _, mode in
                PosterBoardApplyModeSettings.current = mode
            }
            NativeNote(applyMode.summary)
            if applyMode == .airlift, !airliftBlocker.isEmpty {
                NativeSafetyNote(airliftBlocker)
            }
            if applyMode == .airlift {
                NativeNote("存储数据库不属于此模式，因此它的卡片被隐藏：注入会把描述符直接写入容器，而记录不会被触碰。"
                    + "自动刷新也会被忽略。"
                    + "")
            }
            if !selection.resetModes.isEmpty, !applyMode.supportsReset {
                NativeSafetyNote("你所选择的重置无法通过 AirLift 完成。"
                    + "请切回保护性备份以保留它。")
            }
        }
    }

    /// Why AirLift is not usable right now, in the page's own words.
    ///
    /// The same check `GoldenNuggetEngine` makes before it starts a run, stated
    /// here so the picker cannot be set to something the apply will refuse.
    private var airliftBlocker: String {
        let reason = Airlift.unsupportedReason(deviceVersion: identity.version)
        if !reason.isEmpty { return reason }
        if !FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) {
            return "AirLift 需要配对记录，但当前未存储任何记录。请在主页导入一份。"
        }
        return ""
    }

    private var databaseSection: some View {
        Section("商店数据库") {
            Toggle("自动刷新", isOn: $selection.autoRefresh)
            Button {
                fetchDatabase()
            } label: {
                HStack {
                    Label("从设备获取数据库", systemImage: "arrow.down.circle")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(running)
            NativeNote(databaseNote)
        }
    }

    private var databaseNote: String {
        var lines = [
            "已获取数据库：\(databaseSummary)",
            "一张壁纸同时存在于两个地方 —— 它的描述符文件，以及存储自身 sqlite 中的三条记录。"
                + "这些记录承载着设备的提供方注册信息以及选择器排序所用的元数据，因此无法凭空构造：应用时会先从设备获取存储，再向它的副本中添加记录。"
                + ""
                + "",
        ]
        if selection.autoRefresh {
            lines.append("自动刷新已开启（上游的默认值）：每次应用还会写入 PBF_RESET_FILE_PROTECTIONS，正是它让 PosterBoard 在启动时重新读取存储。"
                + "关闭它以不触碰设备的偏好设置。"
                + "")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Packs

    private var packsSection: some View {
        Section("壁纸包（\(selection.tendies.count)）") {
            // The desktop build opens the wallpaper downloader from right here
            // (`wallpaper_downloader.py`, reached from this page's own button),
            // and the entry point stayed here when the sidebar row was dropped:
            // the downloader edits this section's own selection, so the row in the
            // packs list is the one place a reader is looking for it.
            NavigationLink(value: AppDestination.wallpaperDownloads) {
                Label("下载壁纸", systemImage: "square.and.arrow.down")
            }
            .disabled(running)
            Button {
                showPackImporter = true
            } label: {
                Label("导入 .tendies 壁纸包", systemImage: "plus.circle")
            }
            .disabled(running)
            // Keep each document picker attached to the control that presents it.
            // Stacking three fileImporter modifiers on the parent List can cause
            // one presentation host to shadow the others on iOS 26.
            .fileImporter(isPresented: $showPackImporter, allowedContentTypes: [.data]) { result in
                importPack(result)
            }
            if selection.tendies.isEmpty {
                NativeNote("尚未导入任何包。"
                    + "`.tendies` 文件是一个 ZIP，内含一张壁纸的描述符；从壁纸合集中导入一个（Cowabunga 和 CaPlayground 都发布这类文件），然后应用。"
                    + "")
            } else {
                ForEach(selection.tendies) { pack in
                    packRow(pack)
                }
                Button(role: .destructive) {
                    selection.tendies.forEach(PosterBoardImports.remove)
                    selection.loadFromDisk()
                } label: {
                    Label("移除所有壁纸包", systemImage: "trash")
                }
                .disabled(running)
                NativeNote("上游将所选内容上限设为 \(PosterBoardImports.descriptorLimit) 个描述符。"
                    + "每个包都会被复制进本应用，因此在这里移除一个只会移除该副本 —— 你导入的文件不受影响。"
                    + ""
                    + "")
            }
            // Upstream's `auto_convert_legacy` checkbox, on by default. It gates
            // both the import dialog and the apply-time rewrite, so it belongs
            // here rather than in the apply card: turning it off is how a user
            // says "push what I imported, as it is" for good.
            Toggle("将旧版壁纸转换为新版格式",
                   isOn: Binding(get: { PosterBoardPreferences.autoConvertLegacy },
                                 set: { PosterBoardPreferences.autoConvertLegacy = $0 }))
            NativeNote(legacyConvertNote)
        }
    }

    private var legacyConvertNote: String {
        var lines = [
            "iOS 27 只为新版（「Clownfish」）布局构建景深效果，因此 iOS 27 之前制作的包在应用时会被改写 —— 否则它虽然能安装，但看起来是平的，没有景深。"
                + "改写会重新标记系列、丢弃外部脚本并重新发布各个平面，而且它是尽力而为的：可能会改变壁纸的外观。"
                + "不包含任何 27 之前内容的包则无论如何都不会被改动。"
                + ""
                + "",
        ]
        if let atLeast27 = PosterBoard.compareVersion(identity.version, "27"), atLeast27 < 0 {
            lines.append("这台设备运行的是 iOS \(identity.version)，它会按原样读取旧版包，因此这里不会转换任何内容，也不会询问任何包。"
                + "")
        }
        if !PosterBoardPreferences.autoConvertLegacy {
            lines.append("转换已关闭，因此旧版壁纸包会连同其原始文件一起推送。")
        }
        return lines.joined(separator: "\n\n")
    }

    private func packRow(_ pack: PosterBoardTendie) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pack.summary)
                        .font(.caption)
                        .foregroundStyle(pack.isUnsafeContainer ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    PosterBoardImports.remove(pack)
                    selection.loadFromDisk()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(running)
            }

            // Which extension this pack is injected under. A bare pack does not
            // carry that, and picking the wrong one is silent: the descriptor
            // lands in a folder the provider never reads and the wallpaper just
            // does not appear. The reference asks at import time
            // (`TendieItem.posterType`); here it is a row control that persists
            // with the pack.
            if !pack.isContainer {
                Picker("目标扩展名", selection: Binding(
                    get: { pack.posterType },
                    set: { chosen in
                        guard let index = selection.tendies.firstIndex(where: { $0.id == pack.id })
                        else { return }
                        selection.tendies[index] = pack.settingPosterType(chosen)
                    }
                )) {
                    ForEach(PosterBoardPosterType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .disabled(running)
            }
        }
    }

    // MARK: - Video

    private var videoSection: some View {
        Section("视频壁纸") {
            Button {
                showVideoImporter = true
            } label: {
                HStack {
                    Label("选择视频", systemImage: "film")
                    if let video = selection.video?.lastPathComponent {
                        Spacer()
                        Text(video).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .disabled(running)
            .fileImporter(isPresented: $showVideoImporter,
                          allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { result in
                importMedia(result, into: PosterBoard.videoDirectory) { selection.video = $0 }
            }
            Toggle("循环（CoreAnimation 帧列表）", isOn: $selection.loop)
            if selection.loop {
                Toggle("循环时倒放", isOn: $selection.reverse)
                Toggle("覆盖时钟", isOn: $selection.foreground)
                calculationModeRow
            } else {
                Button {
                    showThumbnailImporter = true
                } label: {
                    HStack {
                        Label("选择定格帧（.heic）", systemImage: "photo")
                        if let thumbnail = selection.thumbnail?.lastPathComponent {
                            Spacer()
                            Text(thumbnail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .disabled(running)
                .fileImporter(isPresented: $showThumbnailImporter,
                              allowedContentTypes: [.heic, .image]) { result in
                    importMedia(result, into: PosterBoard.thumbnailDirectory) { selection.thumbnail = $0 }
                }
            }
            if selection.video != nil || selection.thumbnail != nil {
                Button(role: .destructive) {
                    PosterBoard.clearFiles(in: PosterBoard.videoDirectory)
                    PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                    selection.video = nil
                    selection.thumbnail = nil
                } label: {
                    Label("清除视频选择", systemImage: "xmark.circle")
                }
            }
            NativeNote(videoNote)
        }
    }

    /// Four options in one row is 288 pt of text at the narrowest window width,
    /// so this is a menu: it keeps its value on screen instead of wrapping.
    private var calculationModeRow: some View {
        Picker("计算模式", selection: $selection.calculationMode) {
            ForEach(PosterBoardCalculationMode.allCases) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
    }

    private var videoNote: String {
        var lines = [String]()
        if selection.loop {
            lines.append("循环播放会把视频解码为 JPEG 帧，并把一个 CoreAnimation 帧列表交给 PosterBoard（最多 \(PosterBoardVideo.frameLimit) 帧，使用视频自身的分辨率）。"
                + "它很慢，而且帧会被写入备份，因此长片段会产生很大的备份 —— 请先裁剪。"
                + ""
                + "")
            lines.append("带有旋转变换的视频会按其存储的方向解码，参考实现的解码器也是如此；这类片段在锁屏上可能会显示为旋转过的。"
                + ""
                + "")
        } else {
            lines.append("实况照片方式会把视频写入照片海报描述符，并且需要一帧定格画面 —— 参考实现在描述符没有缩略图时会直接报错，而不是照样输出。"
                + "视频会被重新封装为 .mov，除非它本身已经是 .mov。"
                + ""
                + "")
        }
        if selection.loop && selection.reverse {
            lines.append("循环时倒放会先正放片段，再倒放。")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section("重置") {
            Toggle("完全重置 —— 抹除所有内容并从空白状态开始", isOn: $selection.fullReset)
            ForEach(PosterBoardResetMode.allCases) { mode in
                Toggle(mode.rawValue, isOn: binding(for: mode))
            }
            if !resetWarning.isEmpty {
                NativeSafetyNote(resetWarning)
            }
        }
    }

    private func binding(for mode: PosterBoardResetMode) -> Binding<Bool> {
        Binding(
            get: { !selection.fullReset && selection.resetModes.contains(mode) },
            set: { isOn in
                if isOn {
                    selection.resetModes.insert(mode)
                } else {
                    selection.resetModes.remove(mode)
                }
            })
    }

    private var resetWarning: String {
        if selection.fullReset {
            return "完全重置：存储的 Extensions、GalleryCache 和 Backups 目录会被置零，并替换为一个空数据库。"
                + "设备上的每一张壁纸都会消失，且在此节点之前获取的数据库也已过期 —— 下一次应用会获取一份新的。"
                + ""
                + ""
        }
        if selection.resetModes.isEmpty { return "" }
        let names = selection.resetModes.map(\.rawValue).sorted().joined(separator: ", ")
        return "已选择：\(names)。"
            + "重置会在该文件夹上写入一个 0 字节文件，参考实现就是这样清除它们的；它运行时不需要存储数据库，因此对于已经出现异常的存储，这是一条恢复途径。"
            + "它不会撤销任何已经应用的内容。"
            + ""
    }

    // MARK: - What the one Apply will carry

    /// **There is no Apply button here**, and that is the point: the reference has one
    /// apply pass for everything (`_apply_tweak_pass`, with a `needs_posterboard` flag),
    /// and so does this app — the button lives on the home page, next to the tweaks, and
    /// it carries this page's selection with them in one backup and one restore.
    ///
    /// A second button would have been two runs of the same four stages over two payload
    /// sets: two backups, two restores, two chances to leave the device half-applied, and
    /// no way for the operator to know which of them carried what.  Upstream's own
    /// sidebar has a single Apply page for the same reason.
    /// The apply that needs no backup, on the page whose contents it delivers.
    ///
    /// It lives here rather than on the home page because the two applies are
    /// not the same run: the home page's Apply couples the wallpapers to the
    /// tweaks and to a protective backup, and this one is the wallpapers alone.
    /// Reached through the home page, a wallpapers-only run looks identical to
    /// one that also takes a backup — the page says otherwise, but the button
    /// to believe is the one that was pressed.
    private var airliftApplySection: some View {
        Section {
            if selection.isActive {
                Text("就绪：\(selection.describe)").foregroundStyle(.tint)
            } else {
                NativeNote("尚未导入任何包 —— 请在上面导入一个 `.tendies` 以通过这种方式应用它。"
                    + "")
            }
            Button {
                applyViaAirlift()
            } label: {
                HStack {
                    Label("通过 AirLift 应用", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(!airliftAvailable)
            if !airliftBlocker.isEmpty {
                NativeSafetyNote(airliftBlocker)
            }
            NativeNote("通过隧道把描述符写入 \(PosterBoard.domain) 并重启界面，因此几秒内即可生效。"
                + "不会进行备份，因为没有任何内容需要交付回设备 —— 但同样出于这个原因，它**只**应用包：调整项需要备份，因此它们仍然要走主页上的**应用**按钮。"
                + ""
                + ""
                + "")
        }
    }

    /// Whether the run can start: not already running, not blocked by the device,
    /// and there is something selected to inject.
    private var airliftAvailable: Bool {
        !running && airliftBlocker.isEmpty && selection.isActive
    }

    private var applySection: some View {
        Section {
            if applyMode == .airlift {
                // The home page's Apply is still a backup-mode run even when this
                // page is set to AirLift: it delivers the tweaks, and the
                // wallpapers ride that same backup. Saying "fetches the database
                // first" here would be true of that run, but the database card
                // above is hidden, so it would read as a reference to nothing.
                NativeNote("主页上的**应用**按钮会交付调整项，而你选中的壁纸会随它们一起通过一次保护性备份送达 —— 无论此页面的设置如何，那都是一次备份模式的运行。"
                    + "若只想应用包、不做备份，请使用上面的**通过 AirLift 应用**。"
                    + ""
                    + "")
            } else if selection.isActive {
                Text("就绪：\(selection.describe)").foregroundStyle(.tint)
                NativeNote("由主页上的**应用**按钮随调整项一起交付。"
                    + "它会先从设备获取存储的数据库，因此那次运行会多一次交互。"
                    + "之后请重启设备 —— 存储在启动时才会被读取。"
                    + "")
            } else {
                NativeNote("尚未选择任何内容。"
                    + "这里选中的任何内容都会由主页上的**应用**按钮随调整项一起交付 —— 一次备份、一次恢复。"
                    + "")
            }
            if applyMode != .airlift {
                NativeNote("数据库本身可以从上面的卡片单独获取 —— 它是唯一一个会因自身原因而失败的阶段（容器是否上传由设备决定），因此能够单独运行它、观察它并重试，值得为它设一个专门的按钮。"
                    + ""
                    + ""
                    + "")
            }
        }
    }

    private var statusText: String { status ?? "" }

    private func errorSection(_ message: String) -> some View {
        Section("导入失败") {
            NativeSafetyNote(message)
        }
    }

    // MARK: - Behaviour

    private func refreshDatabaseSummary() {
        // The cache is keyed by UDID (upstream does the same), but the page has
        // no UDID outside a run — so it shows the newest database in the
        // directory rather than asking the device to render a label. There is
        // one device behind this app at a time.
        let directory = URL.documents.appendingPathComponent("PosterBoard", conformingTo: .data)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasSuffix(".sqlite3") }.sorted()
        guard let name = candidates.last else {
            databaseSummary = "暂时还没有 —— 添加壁纸的应用会获取一个"
            return
        }
        let url = directory.appendingPathComponent(name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int64,
              let date = attributes?[.modificationDate] as? Date else {
            databaseSummary = name
            return
        }
        let when = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        databaseSummary = "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，获取于 \(when)"
            + ""
    }

    private func importPack(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                let existing = selection.tendies.reduce(0) { $0 + $1.descriptorCount }
                let pack = try PosterBoardImports.import(from: url)
                // Upstream's cap (`verify_tendie`): a container pack carries no
                // descriptor and so is never counted, which is also what its
                // code does.
                guard existing + pack.descriptorCount <= PosterBoardImports.descriptorLimit else {
                    PosterBoardImports.remove(pack)
                    throw GoldenNuggetError("\(pack.name) 带有 \(pack.descriptorCount) 个描述符，这会使所选内容达到 \(existing + pack.descriptorCount) 个。"
                        + "超过 \(PosterBoardImports.descriptorLimit) 后 PosterBoard 的选择器将无法使用 —— 请先移除一个包。"
                        + ""
                        + ""
                        + "")
                }
                selection.loadFromDisk()
                pickError = nil
                RunLog.shared.append("PosterBoard：已导入 \(pack.name)（\(pack.summary)）")
                // The reference asks here, once, before the pack joins the
                // selection (`add_tendie` → `_ask_legacy_convert`), so the answer
                // is in place before any apply can read it.
                if let prompt = pack.legacyConvertPrompt(deviceVersion: identity.version) {
                    legacyPrompt = prompt
                }
            } catch {
                pickError = error.localizedDescription
                selection.loadFromDisk()
            }
        }
    }

    private func importMedia(_ result: Result<URL, Error>,
                             into directory: URL,
                             assign: (URL) -> Void) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                assign(try PosterBoard.store(url, in: directory))
                pickError = nil
            } catch {
                pickError = error.localizedDescription
            }
        }
    }

    private func fetchDatabase() {
        guard !running else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "正在获取 PosterBoard 数据库…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.fetchPosterBoardDatabase()
                text = "数据库已获取。"
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ 已被用户停止（\(failure.label)）"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
                refreshDatabaseSummary()
            }
        }
    }

    /// Run the AirLift injection for the packs selected on this page.
    ///
    /// Shaped like `fetchDatabase` on purpose: the page already owns a run slot,
    /// a run log and a status line, and a second apply path that kept its own
    /// would mean the user watching one of them not move.
    private func applyViaAirlift() {
        guard airliftAvailable else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "正在通过 AirLift 注入壁纸包…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.applyPosterBoardViaAirlift(
                    selection, deviceVersion: identity.version)
                text = "已通过 AirLift 应用。设备已重启界面 —— 未创建备份。"
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ 已被用户停止（\(failure.label)）"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
            }
        }
    }
}
