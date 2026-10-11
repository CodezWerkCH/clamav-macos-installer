// Unprivileged, lossless recovery of unregistered Homebrew ClamAV kegs.
import Foundation
import CryptoKit
import Darwin

struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ ok: Bool, _ text: String) throws { if !ok { throw Failure(description: text) } }
func info(_ path: String) throws -> stat {
    var s = stat()
    guard lstat(path, &s) == 0 else { throw Failure(description: "Cannot inspect: \(path) (\(errno))") }
    return s
}
func exists(_ p: String) -> Bool { var s = stat(); return lstat(p, &s) == 0 }
func directory(_ p: String) throws {
    let s = try info(p)
    try require(s.st_mode & S_IFMT == S_IFDIR, "Not a plain directory: \(p)")
}
func children(_ p: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: p).sorted() }
func hash(_ p: String) throws -> String {
    let fd = open(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    try require(fd >= 0, "Cannot read: \(p)")
    let f = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var s = stat(); try require(fstat(fd, &s) == 0 && s.st_mode & S_IFMT == S_IFREG, "Changed file: \(p)")
    var h = SHA256()
    while let data = try f.read(upToCount: 1024 * 1024), !data.isEmpty { h.update(data: data) }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}
struct Entry: Codable, Equatable {
    let path: String, mode: UInt16, uid: UInt32, gid: UInt32, inode: UInt64
    let value: String
}
func manifest(_ root: String) throws -> [Entry] {
    var result = [Entry]()
    func visit(_ rel: String) throws {
        let p = rel.isEmpty ? root : root + "/" + rel
        let s = try info(p); let kind = s.st_mode & S_IFMT
        var value = ""
        switch kind {
        case S_IFDIR: break
        case S_IFREG: value = "\(s.st_size):\(try hash(p))"
        case S_IFLNK: value = try FileManager.default.destinationOfSymbolicLink(atPath: p)
        default: throw Failure(description: "Unexpected special file: \(p)")
        }
        result.append(Entry(path: rel, mode: s.st_mode, uid: s.st_uid, gid: s.st_gid, inode: s.st_ino, value: value))
        if kind == S_IFDIR {
            for name in try children(p) { try visit(rel.isEmpty ? name : rel + "/" + name) }
        }
    }
    try visit(""); return result
}
func noReferences(_ prefix: String, _ keg: String) throws {
    func visit(_ p: String) throws {
        let s = try info(p)
        if s.st_mode & S_IFMT == S_IFLNK {
            let target = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardized.path
            try require(target != keg && !target.hasPrefix(keg + "/"), "Package is still linked: \(p)")
        } else if s.st_mode & S_IFMT == S_IFDIR {
            for name in try children(p) { try visit(p + "/" + name) }
        }
    }
    for rel in ["bin", "sbin", "lib", "include", "share", "opt", "var/homebrew/linked"] {
        let p = prefix + "/" + rel
        if exists(p) { try directory(p); try visit(p) }
    }
}
func run() throws {
    try require(getuid() != 0, "Must run without administrator privileges")
    let prefix: String, home: String
    #if ARCHIVE_TEST
    try require(CommandLine.arguments.count == 3, "Test fixture paths required")
    prefix = CommandLine.arguments[1]; home = CommandLine.arguments[2]
    #else
    try require(CommandLine.arguments.count == 1, "No arguments supported")
    prefix = "/opt/homebrew"
    guard let account = getpwuid(getuid()) else { throw Failure(description: "Unknown account") }
    home = String(cString: account.pointee.pw_dir)
    #endif
    let rack = prefix + "/Cellar/clamav"
    try directory(prefix); try directory(prefix + "/Cellar")
    if !exists(rack) { return }
    try directory(rack)
    let versions = try children(rack)
    // Validate every remaining keg before moving any of them. Valid receipts
    // stay Homebrew's responsibility; this is not a forced uninstall fallback.
    for version in versions {
        try require(version.count <= 64 && version.range(of: "^[0-9]+(\\.[0-9]+){1,3}(_[0-9]+)?$", options: .regularExpression) != nil, "Unexpected version entry")
        let keg = rack + "/" + version
        try directory(keg)
        try require(try info(keg).st_uid == getuid(), "Package has a different owner")
        try require(!exists(keg + "/INSTALL_RECEIPT.json"), "Registered package remains; normal removal required")
        try directory(keg + "/.brew")
        try require(try info(keg + "/.brew/clamav.rb").st_mode & S_IFMT == S_IFREG, "ClamAV package identity missing")
        try noReferences(prefix, keg)
    }
    if versions.isEmpty { try require(rmdir(rack) == 0, "Cannot remove empty package directory"); return }
    let archives = home + "/.clamav-automatik-archiv"
    if !exists(archives) { try require(mkdir(archives, 0o700) == 0, "Cannot create archive directory") }
    try directory(archives)
    let a = try info(archives)
    try require(a.st_uid == getuid() && a.st_mode & 0o077 == 0, "Archive directory is not private")
    for version in versions {
        let keg = rack + "/" + version
        print("Verifying ClamAV package remainder \(version) …"); fflush(stdout)
        let before = try manifest(keg)
        try noReferences(prefix, keg)
        try require(!exists(keg + "/INSTALL_RECEIPT.json"), "Package registration changed")
        var template = Array((archives + "/paketrest-" + version + "-XXXXXX").utf8CString)
        guard let dir = mkdtemp(&template) else { throw Failure(description: "Cannot create unique archive") }
        let archive = String(cString: dir), target = archive + "/clamav-" + version
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(before).write(to: URL(fileURLWithPath: archive + "/manifest.json"), options: .atomic)
        // Atomic same-volume rename preserves all metadata, xattrs and hard links.
        // EXDEV or any permission error fails without copying/deleting originals.
        try require(renamex_np(keg, target, UInt32(RENAME_EXCL)) == 0, "Cannot archive atomically; original retained (\(errno))")
        #if ARCHIVE_TEST
        if ProcessInfo.processInfo.environment["ARCHIVE_TEST_CHANGE"] == "1" {
            try Data("simulated concurrent change".utf8).write(to: URL(fileURLWithPath: target + "/changed-during-move"))
        }
        #endif
        do {
            try require(try manifest(target) == before, "Archive verification failed")
        } catch {
            let restored = renamex_np(target, keg, UInt32(RENAME_EXCL)) == 0
            throw Failure(description: "\(error); restored=\(restored); recovery archive: \(archive)")
        }
        try "ClamAV \(version): unregistered package archived without deletion. Original: \(keg)\nSHA-256, metadata and symlinks verified against manifest.json.\n".write(toFile: archive + "/README.txt", atomically: true, encoding: .utf8)
        print("@@CLAMAV:ARCHIVE:\(archive)")
        print("Verified package archive: \(archive) (\(before.count) entries)"); fflush(stdout)
    }
    try require(rmdir(rack) == 0, "Unexpected package remainder; inspect archive")
}
do { try run() } catch { fputs("Package archive: \(error)\n", stderr); exit(2) }
