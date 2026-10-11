import Foundation
import Darwin

// No ClamAV, Homebrew, elevated privileges or user configuration are touched.
// Only a Bash child of the real PTY bridge is used.
let args = CommandLine.arguments
guard args.count == 3, ["foundation", "live"].contains(args[1]) else {
    fputs("usage: test-reader foundation|live /path/to/pty-bridge\n", stderr)
    exit(64)
}
let foundation = args[1] == "foundation"
let child = Process()
let input = Pipe(), output = Pipe(), control = Pipe()
child.executableURL = URL(fileURLWithPath: args[2])
child.arguments = ["/bin/bash", "-c", "printf 'STAGE ONE\\n'; stty -echo; printf 'Password: '; IFS= read -r answer; printf '\\nACK length=%s\\n' \"${#answer}\"; stty echo; printf '%9000s' 'tail'; exit 7"]
child.standardInput = input
child.standardOutput = output
child.standardError = control
var environment = ProcessInfo.processInfo.environment
environment["CLAMAV_PTY_TERMINATION_GRACE_SECONDS"] = "1"
environment.removeValue(forKey: "BASH_ENV")
environment.removeValue(forKey: "ENV")
child.environment = environment

let lock = NSLock()
let promptSeen = DispatchSemaphore(value: 0)
let hiddenInputSeen = DispatchSemaphore(value: 0)
let done = DispatchGroup()
var transcript = Data(), status = Data()
var outputChunkSizes = [Int]()
var outputEOF = false, controlEOF = false
var errors = [String]()
let started = Date()
try child.run()

func startReading(_ handle: FileHandle, isControl: Bool) {
    done.enter()
    DispatchQueue.global().async {
        defer { done.leave() }
        var signaled = false
        do {
            while let bytes = try (foundation ? handle.read(upToCount: 4096) : LivePipeReader.readChunk(from: handle)), !bytes.isEmpty {
                lock.lock()
                if isControl { status.append(bytes) }
                else { transcript.append(bytes); outputChunkSizes.append(bytes.count) }
                let text = String(decoding: isControl ? status : transcript, as: UTF8.self)
                let ready = text.contains(isControl ? "CLAMAV_PTY_ECHO=0\n" : "Password: ")
                lock.unlock()
                if ready && !signaled {
                    signaled = true
                    (isControl ? hiddenInputSeen : promptSeen).signal()
                }
            }
            lock.lock()
            if isControl { controlEOF = true } else { outputEOF = true }
            lock.unlock()
        } catch {
            lock.lock(); errors.append(error.localizedDescription); lock.unlock()
        }
    }
}
startReading(output.fileHandleForReading, isControl: false)
startReading(control.fileHandleForReading, isControl: true)
let deadline = DispatchTime.now() + .seconds(2)
let livePrompt = promptSeen.wait(timeout: deadline) == .success
let liveControl = hiddenInputSeen.wait(timeout: deadline) == .success
let childRunningBeforeResponse = child.isRunning
let promptDelay = Date().timeIntervalSince(started)
let secret = "synthetic-live-reader-secret"
if livePrompt && liveControl {
    try input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
} else {
    child.terminate()
}
guard done.wait(timeout: .now() + .seconds(5)) == .success else {
    child.terminate()
    fputs("FAIL: pipe readers did not reach EOF within bounded cleanup time\n", stderr)
    exit(2)
}
child.waitUntilExit()
try? input.fileHandleForWriting.close()
lock.lock()
let finalText = String(decoding: transcript, as: UTF8.self)
let finalControl = String(decoding: status, as: UTF8.self)
let finalSizes = outputChunkSizes
let eof = outputEOF && controlEOF
let finalErrors = errors
lock.unlock()
let results: [String: Any] = [
    "mode": args[1],
    "prompt_visible_before_response": livePrompt,
    "secure_input_visible_before_response": liveControl,
    "child_running_before_response": childRunningBeforeResponse,
    "observation_seconds": promptDelay,
    "prompt_eventually_read": finalText.contains("Password: "),
    "secure_input_eventually_read": finalControl.contains("CLAMAV_PTY_ECHO=0\n"),
    "both_pipes_reached_EOF": eof,
    "secret_echoed": finalText.contains(secret) || finalControl.contains(secret),
    "received_response": finalText.contains("ACK length=\(secret.count)"),
    "received_tail": finalText.hasSuffix("tail"),
    "largest_output_chunk": finalSizes.max() ?? 0,
    "output_chunks": finalSizes.count,
    "child_exit": child.terminationStatus,
    "read_errors": finalErrors
]
let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
print()
if foundation {
    // This test succeeds when it reproduces the defect: both short streams are
    // withheld until termination even though the child is waiting for input.
    guard !livePrompt, !liveControl, childRunningBeforeResponse,
          finalText.contains("Password: "), finalControl.contains("CLAMAV_PTY_ECHO=0\n"), eof else { exit(1) }
} else {
    guard livePrompt, liveControl, childRunningBeforeResponse, promptDelay < 2,
          eof, finalErrors.isEmpty, !finalText.contains(secret), !finalControl.contains(secret),
          finalText.contains("ACK length=\(secret.count)"), finalText.hasSuffix("tail"),
          finalSizes.allSatisfy({ $0 <= LivePipeReader.maximumChunkSize }),
          finalSizes.count >= 3, child.terminationStatus == 7 else { exit(1) }
}
