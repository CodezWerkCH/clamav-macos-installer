/*
 * Undo only Homebrew services' root ownership of a ClamAV keg's bin/sbin.
 * No deletion, recursion, child processes, or caller-supplied filesystem path.
 * Build the fixture-path override only into an unprivileged test executable.
 */
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef CLAMAV_REPAIR_TEST_PREFIX
#define CLAMAV_REPAIR_PREFIX "/opt/homebrew/Cellar/clamav"
#else
#define CLAMAV_REPAIR_PREFIX CLAMAV_REPAIR_TEST_PREFIX
#endif

#define FORBIDDEN_FLAGS (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)

static int fail(const char *message) {
    fprintf(stderr, "ClamAV package permissions: %s\n", message);
    return 1;
}

static int version_valid(const char *version) {
    size_t length = strlen(version);
    if (!length || length > 64 || version[0] < '0' || version[0] > '9') return 0;
    const unsigned char *p = (const unsigned char *)version;
    unsigned int dots = 0;
    while (*p >= '0' && *p <= '9') ++p;
    while (*p == '.') {
        ++dots;
        if (dots > 3) return 0;
        ++p;
        if (*p < '0' || *p > '9') return 0;
        while (*p >= '0' && *p <= '9') ++p;
    }
    if (!dots) return 0;
    if (*p == '_') {
        ++p;
        if (*p < '0' || *p > '9') return 0;
        while (*p >= '0' && *p <= '9') ++p;
    }
    return *p == '\0';
}

static int invoking_uid(uid_t *uid) {
    const char *value = getenv("SUDO_UID");
    uintmax_t number = 0;
    if (!value || !*value) return 0;
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
        unsigned int digit = (unsigned int)(*p - '0');
        if (number > ((uintmax_t)(uid_t)-1 - digit) / 10) return 0;
        number = number * 10 + digit;
    }
    if (!number || number >= (uintmax_t)(uid_t)-1) return 0;
    *uid = (uid_t)number;
    return 1;
}

/* Every component is opened relative to a held descriptor. O_NOFOLLOW rejects
 * links even in ancestors; no subsequent mutation resolves a pathname. */
static int open_prefix(void) {
    char path[] = CLAMAV_REPAIR_PREFIX;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    char *cursor = path;
    while (*cursor == '/') ++cursor;
    while (*cursor) {
        char *end = strchr(cursor, '/');
        if (end) *end = '\0';
        int next = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        int saved_errno = errno;
        close(fd);
        if (next < 0) { errno = saved_errno; return -1; }
        fd = next;
        if (!end) break;
        cursor = end + 1;
    }
    return fd;
}

static int safe_directory(const struct stat *info, uid_t uid, int is_keg) {
    if (!S_ISDIR(info->st_mode) || (info->st_flags & FORBIDDEN_FLAGS)) return 0;
    mode_t permissions = info->st_mode & 07777;
    if (is_keg)
        return info->st_uid == uid && (permissions == 0755 || permissions == 01755);
    if (info->st_uid == uid)
        return permissions == 0755 || permissions == 01755;
    return info->st_uid == 0 && permissions == 01755;
}

static int unchanged(const struct stat *first, const struct stat *now) {
    return first->st_dev == now->st_dev && first->st_ino == now->st_ino &&
           first->st_uid == now->st_uid && first->st_gid == now->st_gid &&
           first->st_mode == now->st_mode && first->st_flags == now->st_flags;
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "--check") && strcmp(argv[1], "--repair")) ||
        !version_valid(argv[2])) {
        fputs("Usage: clamav-package-repair --check|--repair VERSION\n", stderr);
        return 64;
    }
    int repair = !strcmp(argv[1], "--repair");
    uid_t uid = getuid();
    if (repair && (geteuid() != 0 || !invoking_uid(&uid)))
        return fail("repair requires sudo with the original non-root user's SUDO_UID.");
    if (!repair && (geteuid() == 0 || uid == 0))
        return fail("run the read-only check as the Homebrew user, without sudo.");

    int parent = open_prefix();
    if (parent < 0) {
        if (errno == ENOENT) { puts("REPAIR:NOT_NEEDED"); return 0; }
        return fail("the fixed Homebrew path is inaccessible, not a directory, or contains a symbolic link.");
    }
    int keg = openat(parent, argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int saved_errno = errno;
    close(parent);
    if (keg < 0) {
        if (saved_errno == ENOENT) { puts("REPAIR:NOT_NEEDED"); return 0; }
        return fail("the ClamAV version directory is inaccessible or is a symbolic link.");
    }

    const char *names[] = {"bin", "sbin"};
    int fd[] = {-1, -1};
    struct stat info[2], keg_info;
    int result = 1, needed = 0;
    if (fstat(keg, &keg_info) < 0 || !safe_directory(&keg_info, uid, 1)) {
        fail("unexpected version-directory ownership, permissions, type, or immutable flags; nothing changed.");
        goto done;
    }
    for (int i = 0; i < 2; ++i) {
        fd[i] = openat(keg, names[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (fd[i] < 0) {
            if (errno == ENOENT) continue; /* An earlier uninstall may have removed it. */
            fail("bin/sbin is inaccessible, not a directory, or is a symbolic link; nothing changed.");
            goto done;
        }
        if (fstat(fd[i], &info[i]) < 0 || !safe_directory(&info[i], uid, 0)) {
            fail("unexpected bin/sbin ownership, permissions, type, or immutable flags; nothing changed.");
            goto done;
        }
        if (info[i].st_uid == 0) ++needed;
    }
    if (!needed || !repair) {
        puts(needed ? "REPAIR:NEEDED" : "REPAIR:NOT_NEEDED");
        result = 0;
        goto done;
    }
    /* Validate every held inode again before the first change. A later rename
     * cannot redirect fchown to a symlink target or replacement directory. */
    struct stat current;
    if (fstat(keg, &current) < 0 || !unchanged(&keg_info, &current)) {
        fail("the version directory changed during validation; nothing changed.");
        goto done;
    }
    for (int i = 0; i < 2; ++i) {
        if (fd[i] >= 0 && (fstat(fd[i], &current) < 0 || !unchanged(&info[i], &current))) {
            fail("bin/sbin changed during validation; nothing changed.");
            goto done;
        }
    }
    for (int i = 0; i < 2; ++i) {
        if (fd[i] < 0 || info[i].st_uid != 0) continue;
        if (fchown(fd[i], uid, (gid_t)-1) < 0) {
            fail("could not restore directory ownership; retry or inspect the remaining package. No files were deleted.");
            goto done;
        }
        if (fstat(fd[i], &current) < 0 || current.st_uid != uid ||
            current.st_gid != info[i].st_gid || current.st_mode != info[i].st_mode ||
            current.st_flags != info[i].st_flags) {
            fail("directory verification failed after ownership repair; no files were deleted.");
            goto done;
        }
        printf("Restored ownership of ClamAV %s/%s only.\n", argv[2], names[i]);
    }
    puts("REPAIR:NOT_NEEDED");
    result = 0;
done:
    for (int i = 0; i < 2; ++i) if (fd[i] >= 0) close(fd[i]);
    close(keg);
    return result;
}
