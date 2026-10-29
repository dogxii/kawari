import Foundation

/// 一个额度窗口（5 小时或 7 天）
struct Window: Equatable, Sendable {
    var used: Double  // 0–100
    var resets: Date

    /// 过了重置时间，窗口一定已经清零。闲置的账号不用联网也能知道它恢复了
    func used(at now: Date) -> Double { now >= resets ? 0 : used }
}

/// Claude Code 交给 status line 的额度（官方字段 rate_limits），只有 Pro / Max 账号才有
struct Limits: Equatable, Sendable {
    /// nil 表示 Claude Code 没给这个窗口：它在重置后会去掉该窗口，所以按 0 处理
    var fiveHour: Window?
    var sevenDay: Window?

    static func parse(_ data: Data) -> Limits? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any]
        else { return nil }
        func window(_ key: String) -> Window? {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (window["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(used: min(max(used, 0), 100), resets: Date(timeIntervalSince1970: resets))
        }
        return Limits(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    }

    /// 下一次有窗口重置的时间，界面到点刷新
    func nextReset(after now: Date) -> Date? {
        [fiveHour, sevenDay].compactMap { $0?.resets }.filter { $0 > now }.min()
    }
}

/// 本地会话记录（~/.claude/projects 下的 jsonl）里的 token 用量。
/// 只看最近 14 天，在后台按文件增量解析：第一次全量扫一遍，之后只读新增的部分。
final class Ledger: @unchecked Sendable {
    static let days = 14

    struct Totals: Equatable, Sendable {
        /// 最早 → 今天
        var daily = [Int](repeating: 0, count: Ledger.days)
        var loaded = false

        var today: Int { daily.last ?? 0 }
        var week: Int { daily.suffix(7).reduce(0, +) }
    }

    private let root: URL
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "kawari.ledger", qos: .utility)
    // 以下只在 queue 上访问
    private var offsets: [String: (file: Int?, offset: UInt64)] = [:]  // 文件 → inode 与已读到的位置
    private var seen = Set<Int>()  // 已计入的消息：同一条消息会按内容块写成多行
    private var tokens: [Date: Int] = [:]  // 哪天 → token
    private let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    func refresh(now: Date, _ done: @escaping @Sendable (Totals) -> Void) {
        queue.async { [self] in
            scan(now: now)
            done(summarize(now: now))
        }
    }

    /// 同步版本，供测试使用
    func totals(now: Date) -> Totals {
        queue.sync {
            scan(now: now)
            return summarize(now: now)
        }
    }

    private func cutoff(_ now: Date) -> Date {
        calendar.date(byAdding: .day, value: 1 - Self.days, to: calendar.startOfDay(for: now))!
    }

    private func scan(now: Date) {
        let cutoff = cutoff(now)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, modified >= cutoff,
                  let size = values.fileSize.map(UInt64.init)
            else { continue }
            // 会话记录可能被裁剪（CLAUDE_CODE_TRANSCRIPT_LOCAL_GC）或整个替换：从头再读，已计入的消息靠 seen 去重
            let file = (values.allValues[.fileResourceIdentifierKey] as? NSObject)?.hash
            var offset = offsets[url.path].flatMap { $0.file == file ? $0.offset : nil } ?? 0
            if size < offset { offset = 0 }
            guard size > offset else { continue }
            offsets[url.path] = (file, autoreleasepool { read(url, from: offset, cutoff: cutoff) })
        }
        tokens = tokens.filter { $0.key >= cutoff }
    }

    private static let usageNeedle = Array(#""usage""#.utf8)

    /// 分块读到文件末尾，只处理完整的行；返回下次开始的位置
    private func read(_ url: URL, from start: UInt64, cutoff: Date) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return start }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil else { return start }
        var offset = start
        var buffer = Data()
        // 读出的数据块与 JSON 解析的临时对象都是自动释放的，每块清一次，否则首次全量扫描会占用数百 MB
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: 1 << 22), !chunk.isEmpty else { return false }
            buffer.append(chunk)
            let consumed = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var position = 0
                while position < raw.count, let newline = memchr(base + position, 0x0A, raw.count - position) {
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    let length = end - position
                    // 绝大多数行不含 usage，先用字节查找筛掉，再交给 JSON 解析
                    if memmem(base + position, length, Self.usageNeedle, Self.usageNeedle.count) != nil {
                        record(Data(bytes: base + position, count: length), cutoff: cutoff)
                    }
                    position = end + 1
                }
                return position
            }
            offset += UInt64(consumed)
            buffer = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
            return true
        }) {}
        return offset
    }

    private func record(_ line: Data, cutoff: Date) {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              entry["type"] as? String == "assistant",
              let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String ?? entry["uuid"] as? String,
              !seen.contains(id.hashValue)
        else { return }
        let count = Self.tokens(usage)
        guard count > 0 else { return }  // 流式过程中的占位，等后面带数字的那一行
        seen.insert(id.hashValue)
        guard let stamp = entry["timestamp"] as? String, let date = dates.date(from: stamp), date >= cutoff
        else { return }
        tokens[calendar.startOfDay(for: date), default: 0] += count
    }

    /// 全部 token，含缓存读写（与 ccusage 的口径一致）。顶层为 0 时以 iterations 为准
    static func tokens(_ usage: [String: Any]) -> Int {
        func sum(_ usage: [String: Any]) -> Int {
            ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        }
        let total = sum(usage)
        if total > 0 { return total }
        return (usage["iterations"] as? [[String: Any]])?.reduce(0) { $0 + sum($1) } ?? 0
    }

    private func summarize(now: Date) -> Totals {
        let today = calendar.startOfDay(for: now)
        var totals = Totals(loaded: true)
        for (day, count) in tokens {
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day,
                  (0..<Self.days).contains(ago)
            else { continue }
            totals.daily[Self.days - 1 - ago] += count
        }
        return totals
    }
}

enum Format {
    /// 1234 → 1.2K，12345678 → 12M
    static func tokens(_ count: Int) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        let value = Double(count)
        for (size, unit) in units where value >= size {
            let scaled = value / size
            return (scaled < 10 ? String(format: "%.1f", scaled) : String(Int(scaled.rounded()))) + unit
        }
        return "\(count)"
    }

    /// 距离重置：45m、1h 20m、3d 4h
    static func until(_ date: Date, now: Date) -> String {
        let minutes = max(Int((date.timeIntervalSince(now) / 60).rounded(.up)), 0)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }
}
