import SwiftUI

/// The page picker behind the home page's "Reset Tweaks" button.
///
/// A port of `src/gui/dialogs/reset_dialog.py` — the reference's `ResetDialog`:
/// a title, "Select the pages you would like to reset.", one switch per
/// resettable page, and OK/Cancel. Its `accept` runs the reset **only** when at
/// least one page is checked (`if len(self.selected_pages) > 0`), which is why
/// the button here is disabled rather than a no-op on tap.
///
/// Two departures from the desktop dialog, both forced by the platform:
///
/// * a checkbox row is a `Toggle` here, since a desktop checkbox is a tap target
///   the size of a word and a phone row is a switch;
/// * the file list is on screen before the reset runs. The reference's dialog
///   says nothing about what a page reset *writes*, and on a phone the decision
///   and the consequence land in the same place — the user can scroll the note
///   before the button, but not after the restore.
///
/// The page list is `ResetPage.allCases` — the reference's `get_resettable_pages`
/// plus `StatusBar` on iOS 27, which the reference's dialog hides but this port
/// can still reset through `StatusBarArchive` (see `ResetPage`).
struct ResetPagesSheet: View {
    /// The device's iOS version, for the note that says which procedure runs.
    let deviceVersion: String
    let isRunning: Bool
    let onReset: (Set<ResetPage>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<ResetPage> = []

    /// The plan for what is ticked *so far*, so the file list updates as the
    /// switches move. `ios27` is the same predicate `procedureSection` uses, and
    /// it changes the bytes a nulled file is written as — so the list under the
    /// switches has to be built with the same branch the run will take.
    private var plan: TweakReset.Plan { TweakReset.plan(pages: selection, ios27: isIOS27) }

    var body: some View {
        NavigationStack {
            List {
                pageSection
                whatItTouches
                procedureSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("重置页面调整项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        selection.removeAll()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重置", role: .destructive) {
                        let pages = selection
                        // Dismiss first: the run reports into the home page's
                        // status line, and a sheet over it would hide the
                        // progress the user is waiting on.
                        dismiss()
                        onReset(pages)
                    }
                    // The reference's `if len(selected_pages) > 0`, made a
                    // property of the button instead of a branch after the tap.
                    .disabled(selection.isEmpty || isRunning)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One switch row per page, with the count of files behind it, right-aligned
    /// in the row.
    private var pageSection: some View {
        Section("请选择要重置的页面。") {
            ForEach(ResetPage.allCases) { page in
                Toggle(isOn: binding(for: page)) {
                    HStack {
                        Text(page.title)
                        Spacer()
                        Text(fileCount(page)).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }
        }
    }

    /// The paths the reset would write, named before it runs.
    ///
    /// Last path components rather than the absolute paths: the directories are
    /// the same handful for every file here (`/var/Managed Preferences/mobile/`,
    /// `/var/mobile/Library/Preferences/`, `/var/mobile/Library/SpringBoard/`,
    /// `/var/db/com.apple.xpc.launchd/`) and printing them nine times says less
    /// than the file names do. The directory *is* in the run log, which is where
    /// a full path belongs.
    @ViewBuilder
    private var whatItTouches: some View {
        if plan.targets.isEmpty {
            Section { NativeNote("尚未选择任何内容。") }
        } else {
            Section("将向设备写入 \(plan.targets.count) 个文件：") {
                ForEach(plan.targets) { target in
                    Text("\(shortPath(target.path)) · \(target.kind.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Which of the two nulls this device gets, and what the reset does *not*
    /// do.
    ///
    /// The iOS 27 wording is a safety note, not decoration: the difference
    /// between the branches is whether a nulled file is 0 bytes or a valid empty
    /// plist, and the reason is that a 0-byte plist is a *truncated* plist on the
    /// newer releases, which is a SpringBoard boot loop. The user has to be able
    /// to read that before the button, not in a failure afterwards.
    private var procedureSection: some View {
        Section {
            if isIOS27 {
                NativeSafetyNote("iOS \(deviceVersion)：每个被置空的文件都写为有效的空 plist，而不是 0 字节。"
                    + "在此版本上，0 字节的 plist 是损坏的 plist，会在启动时让 SpringBoard 崩溃。"
                    + "空 plist 可以解析，系统会回退到自己的默认值。"
                    + "")
            } else {
                NativeNote("每个被置空的文件都写为 0 字节，这会使读取它的守护进程回退到自己的默认值。"
                    + "")
            }
            NativeNote("不会先从设备读回任何内容：不会捕获任何原始值，因此在应用之前就已经自定义过的文件会被恢复为默认值，而不是它原来的内容。"
                + "守护进程列表是个例外 —— 它按一台原厂设备所带有的六个条目写入。"
                + "本应用中的选择不受影响；再次应用会把调整项写回去。"
                + ""
                + "")
            NativeNote("状态栏重置是这里唯一一个整体写入、而非置空的文件：一份全新的、全部为默认值的 "
                + ""
                + (isIOS27 ? "StatusBarOverrides.archive，不包含任何蜂窝条目，SpringBoard 会将其解码为 \"no overrides\"。"
                    + ""
                    : "statusBarOverrides 结构，因此每一项覆盖都读作关闭。")
                + " 它走的是「状态栏」页面所应用的同一套机制。")
        }
    }

    private var isIOS27: Bool {
        let major = Int(deviceVersion.split(separator: ".").first ?? "0") ?? 0
        return major >= 27 && !DevSettings.effective.forcePartialRestore
    }

    private func fileCount(_ page: ResetPage) -> String {
        let count = page.locations.count
        return count == 1 ? "1 个文件" : "\(count) 个文件"
    }

    /// The file name, not the path. Every location here sits in one of a few
    /// directories and the same prefix nine times says less than the name does;
    /// the full path is one tap away in the run log.
    private func shortPath(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func binding(for page: ResetPage) -> Binding<Bool> {
        Binding(
            get: { selection.contains(page) },
            set: { on in
                if on { selection.insert(page) } else { selection.remove(page) }
            })
    }
}
