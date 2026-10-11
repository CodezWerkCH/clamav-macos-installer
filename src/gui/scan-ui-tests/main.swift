import Foundation
let fm = FileManager.default
let logs = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clamav-snapshot-test-" + UUID().uuidString)
try fm.createDirectory(at: logs, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: logs) }
let report = logs.appendingPathComponent("scan-test.log")
let statusURL = logs.appendingPathComponent("last-scan.txt")
func snapshot(_ content: String, status: String? = nil) throws -> ScanSnapshot {
    try content.write(to: report, atomically: false, encoding: .utf8)
    let value = status ?? "2026-10-11 23:14:47 CEST | LAEUFT: \(report.path)"
    try value.write(to: statusURL, atomically: false, encoding: .utf8)
    return ScanSnapshot(status: value, logs: logs)
}
var checks = 0
func check(_ value: Bool) { checks += 1; precondition(value, "Check \(checks) failed") }
let running = try snapshot("Beginn: now\nQuarantaene: /temporary/payload\n")
check(running.running); check(running.report?.path == report.path)
check(running.elapsed(at: running.started!.addingTimeInterval(3661)) == "01:01:01")
check(running.findings == 0 && running.errors == 0)
let found = try snapshot("a: Eicar-Test-Signature FOUND\nb: Permission denied ERROR\nTotal errors: 0\n")
check(found.findings == 1); check(found.errors == 1)
let clean = try snapshot("Infected files: 0\nTotal errors: 0\n", status: "now | OK: keine Bedrohung; \(report.path)")
check(!clean.running); check(clean.errors == 0)
let outside = ScanSnapshot(status: "LAEUFT: /private/etc/passwd", logs: logs)
check(outside.report == nil && outside.logText.isEmpty)
let traversal = ScanSnapshot(status: "LAEUFT: \(logs.path)/scan-x/../../passwd", logs: logs)
check(traversal.report == nil)
let huge = try snapshot(String(repeating: "x", count: 1_100_000))
check(huge.truncated && huge.logText.utf8.count == 1_000_000)
check(ScanSnapshot.jobRunning("state = running\n", exitCode: 0) == true)
check(ScanSnapshot.jobRunning("state = not running\n", exitCode: 0) == false)
check(ScanSnapshot.jobRunning("state = active\n", exitCode: 0) == nil)
check(ScanSnapshot.jobRunning("", exitCode: 113) == false)
check(ScanSnapshot.jobRunning("", exitCode: 1) == nil)
let warning = try snapshot("WARNING: pipe: Not supported file type\n")
check(warning.warnings == 1 && warning.errors == 0 && warning.findings == 0)
print("PASS: \(checks) scan snapshot checks")
