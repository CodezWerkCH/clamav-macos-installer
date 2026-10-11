import Foundation

struct ScanSnapshot {
    let status: String
    let running: Bool
    let report: URL?
    let started: Date?
    let finished: Date?
    let logText: String
    let truncated: Bool
    let findings: Int
    let errors: Int
    let warnings: Int

    init(status: String, logs: URL) {
        self.status = status
        running = status.contains("LAEUFT:")
        var candidate: URL?
        if let range = status.range(of: logs.path + "/scan-", options: .backwards) {
            let path = String(status[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: path)
            if url.deletingLastPathComponent().standardizedFileURL.path == logs.standardizedFileURL.path,
               url.lastPathComponent.hasPrefix("scan-") { candidate = url }
        }
        report = candidate
        let attributes = candidate.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        started = attributes?[.creationDate] as? Date
        finished = (try? FileManager.default.attributesOfItem(atPath: logs.appendingPathComponent("last-scan.txt").path)[.modificationDate]) as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        truncated = size > 1_000_000
        var text = ""
        if let url = candidate, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            do {
                if size > 1_000_000 { try handle.seek(toOffset: size - 1_000_000) }
                text = String(decoding: try handle.read(upToCount: 1_000_000) ?? Data(), as: UTF8.self)
            } catch { text = "" }
        }
        logText = text
        let lines = text.components(separatedBy: .newlines)
        warnings = lines.filter { $0.range(of: #"\bWARNING\b"#, options: [.regularExpression, .caseInsensitive]) != nil }.count
        findings = lines.filter { $0.hasSuffix(" FOUND") }.count
        errors = lines.filter {
            let v = $0.lowercased()
            return v.range(of: #"\berror\b"#, options: .regularExpression) != nil || v.hasPrefix("fehler:") || v.contains("permission denied") || v.contains("operation not permitted")
        }.count
    }

    func elapsed(at now: Date) -> String? {
        guard let start = started else { return nil }
        let end = running ? now : (finished ?? now)
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    static func jobRunning(_ output: String, exitCode: Int32) -> Bool? {
        if exitCode == 113 { return false }
        guard exitCode == 0 else { return nil }
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("state = running") { return true }
        if lines.contains("state = not running") || lines.contains("state = waiting") { return false }
        return nil
    }
}
