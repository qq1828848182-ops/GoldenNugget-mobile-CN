import Foundation
import Minimuxer

/// The failure dump, and the device preconditions that gate a run.
///
/// Every line answers one question the layers below cannot: which layer stopped
/// first.  Order matters — each line is a strictly deeper layer than the previous
/// one, and the Rust evidence is snapshotted BEFORE the probes below (those
/// probes drive their own RSD + lockdown traffic into the very same log, which is
/// what made the first dump contain nothing but the probe's own lines).
enum Diagnostics {
    /// One-block snapshot of every layer a channel drop can come from, so the app
    /// log alone tells us where the failure lives.
    static func report() async -> String {
        let minimuxer = Minimuxer.shared()
        var lines: [String] = ["── 诊断 ──"]

        // Snapshot the Rust evidence FIRST.
        let logStatus = RustLog.status()
        let excerpt = RustLog.excerpt()
        let tail = RustLog.tail(30, since: RustLog.mark)

        lines.append("  隧道：\(Tunnel.describe())")
        // The one field a user gets wrong, with the value that fixes it.  A dump
        // that says "tunnel not detected" and nothing else sends the reader to
        // the VPN app, where the rejection they get back ("only allows a prefix
        // length from 0 to 32") does not name the field or the expected value.
        lines.append("  隧道要求：\(Tunnel.requirements)")
        // What the library itself resolved, when it said anything: the app's
        // probe and the Rust connection manager have to be looking at the same
        // pair of addresses, and before this was recorded nothing in a dump
        // could show whether they were.
        if let resolved = Tunnel.reported.line {
            lines.append("  \(resolved)")
        }
        lines.append("  对端 \(Tunnel.peerIP):\(Tunnel.servicePort) 可达性：\(Tunnel.probePeer())")
        if let gw = minimuxer.ideviceGateway {
            lines.append("  网关端点 IP：\(gw.deviceEndpointIp ?? "nil")")
        } else {
            lines.append("  网关：不是 IdeviceGateway")
        }
        lines.append("  配对类型：\(minimuxer.core.getPairingFileType())")
        // Proves whether RSD itself survived: if this works while mobilebackup2
        // keeps dying, the drop is mobilebackup2-specific (device side), not
        // the tunnel.
        let udid = try? await minimuxer.core.fetchUDID()
        lines.append("  lockdown fetchUDID：\(udid.flatMap { $0 } ?? "FAILED")")
        switch await minimuxer.core.isReady(withNetworkCheck: true) {
        case .success(let ready):
            lines.append("  isReady：\(ready)")
        case .failure(let error):
            lines.append("  isReady: 失败 — \(minimuxer.core.describeError(error))")
        }
        lines.append("  Rust 日志：\(logStatus)")
        // Wire liveness: how many DeviceLink messages this run actually moved.
        // A run that "hung at N %" is one number away from being diagnosable —
        // zero messages means the device never engaged, thousands means it was
        // working and the silence came later.
        lines.append("  wire: \(WireCensus.healthLine())")
        let encrypt = await backupEncryptionEnabled()
        lines.append("  备份加密（com.apple.mobile.backup/WillEncrypt）："
            + (encrypt.map { $0 ? "开启 —— 前提被破坏（Manifest.db 已加密）" : "off" } ?? "unknown"))
        // Keyword slice first (the actual evidence), raw tail last (proves the
        // sink is live and shows an unclassified failure).  Both were captured
        // before the probes above wrote a single line.
        lines.append(excerpt)
        lines.append("  Rust 日志原始末尾（最后 30 行）：\n\(tail)")
        // The host-side half of the story only exists in the app log: which
        // files the filter kept, the commit/move accounting, the staging-tree
        // verdict.  Without it a shared diagnostics.txt cannot distinguish "the
        // device refused" from "we refused the device".
        let memory = AppLog.shared.memory
        lines.append("  应用日志末尾（共 \(memory.count) 行中的最后 80 行，完整文件：goldennugget.log）：\n"
            + memory.tail(80))
        lines.append("── 诊断结束 ──")

        let block = lines.joined(separator: "\n")
        // Persist next to the log so it can be shared as a FILE (AirDrop / Save
        // to Files) instead of hand-selecting text in the app's log list.
        try? block.write(to: AppPaths.diagnostics, atomically: true, encoding: .utf8)
        return block
    }

    /// Out-of-band liveness check, used while a DeviceLink stream has gone quiet.
    ///
    /// Answers the one question the stream itself cannot: is the device (and the
    /// tunnel) still there?  A wedged mobilebackup2 daemon still answers
    /// lockdown — that is precisely why this is worth asking: "quiet but alive"
    /// deserves patience, "quiet and gone" does not.
    ///
    /// Two constraints shaped this:
    ///   - it must not use the gateway's ordinary service path, because a failed
    ///     connect there calls `invalidateConnection()` and frees the RSD adapter
    ///     the parked mobilebackup2 call is still using (see
    ///     `IdeviceGateway.probeLockdownAlive()`);
    ///   - it must never hang the guard, hence the deadline and the "inconclusive
    ///     means alive" default: nobody should lose a live run because a probe
    ///     could not answer.
    static func deviceLivenessProbe() async -> (alive: Bool, detail: String) {
        guard let gateway = Minimuxer.shared().ideviceGateway else {
            return (true, "没有可用于探测的网关 —— 将设备视为在线")
        }
        let answer: Bool? = await AsyncRacing.withDeadline(seconds: 8, fallback: { nil }) {
            await Task.detached(priority: .utility) { gateway.probeLockdownAlive() }.value
        }
        switch answer {
        case .some(true):
            return (true, "lockdown 在现有 RSD 会话上已应答 —— 设备与隧道均在线")
        case .some(false):
            return (false, "lockdown 未在现有 RSD 会话上应答 —— 设备或隧道已断开")
        case .none:
            return (true, "lockdown 探测在 8 秒内没有应答 —— 结果不确定，因此本次运行继续保留")
        }
    }

    // MARK: - Backup-encryption precondition

    /// Reads `com.apple.mobile.backup / WillEncrypt` from the device.
    ///
    /// This is the one precondition that silently breaks the whole app and the
    /// one we could not read before: the gateway's `getLockdownValue(key:)`
    /// passes a NULL domain (so this domain-scoped key is invisible) and reads
    /// through `plist_get_string_val` (a no-op on a boolean node).  Hence
    /// `getLockdownBool(key:domain:)`.
    ///
    /// With "Encrypted Local Backup" enabled the device hands the host an
    /// ENCRYPTED Manifest.db, while the prune and the inject rewrite it with bare
    /// sqlite3 — pymobiledevice3's path decrypts with the password, prunes, then
    /// re-encrypts.  There is no encrypt/keybag handling anywhere in the vendored
    /// Rust lib either, so the premise breaks at both ends.
    ///
    /// - Returns: `true`/`false`, or `nil` when the device could not be asked.
    static func backupEncryptionEnabled() async -> Bool? {
        guard let gateway = Minimuxer.shared().ideviceGateway else { return nil }
        return try? await gateway.getLockdownBool(key: "WillEncrypt",
                                                 domain: "com.apple.mobile.backup")
    }

    /// Fail fast when the device would hand us an encrypted Manifest.db.
    static func preflightBackupEncryption() async throws {
        switch await backupEncryptionEnabled() {
        case .some(true):
            throw GoldenNuggetError("""
                This device has "Encrypt local backup" turned on (lockdown \
                com.apple.mobile.backup / WillEncrypt = true).
                GoldenNugget's premise is a plaintext Manifest.db: prune and inject rewrite it \
                through bare sqlite3, and the vendored Rust library has no encrypt/keybag handling \
                at all (pymobiledevice3's path decrypts first, prunes, then re-encrypts).
                Turn "Encrypt local backup" off in Settings → [your name] → iCloud → Device \
                Backup, or clear it on the device page in Finder/iTunes, then run again.
                """)
        case .some(false):
            AppLog.write("预检：本地备份加密 = 关闭（Manifest.db 为明文，前提成立）"
                         + "")
        case .none:
            AppLog.write("预检：无法读取 WillEncrypt（域／键不可用）—— 继续执行，但请注意加密备份会破坏清理／注入流程"
                         + "")
        }
    }
}
