/*
 * Pipe-to-PTY bridge for a GUI-owned child. Input is never copied to a log.
 * Keep stdin open while the child runs. EOF requests bounded shutdown.
 * The GUI must hide and avoid retaining submitted password text itself.
 */
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <util.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t requested_signal;

static void request_shutdown(int signum) { requested_signal = signum; }

static int termination_grace_seconds(void) {
    const char *value = getenv("CLAMAV_PTY_TERMINATION_GRACE_SECONDS");
    if (!value) return 3;
    if (!*value) return -1;
    unsigned int seconds = 0;
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (*p < '0' || *p > '9') return -1;
        seconds = seconds * 10 + (unsigned int)(*p - '0');
        /* Check each digit, before a later iteration could overflow. */
        if (seconds > 120) return -1;
    }
    return seconds ? (int)seconds : -1;
}

static double monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return 0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void signal_child(pid_t child, int signum) {
    /* forkpty creates the child's session and process group. The fallback
     * also covers a signal arriving before that setup is complete. */
    if (kill(-child, signum) < 0 && errno == ESRCH) (void)kill(child, signum);
}

static int terminal_echo(int master) {
    struct termios attributes;
    if (tcgetattr(master, &attributes) < 0) return -1;
    return (attributes.c_lflag & ECHO) ? 1 : 0;
}

static int only_newlines(const unsigned char *buffer, size_t length) {
    for (size_t i = 0; i < length; ++i)
        if (buffer[i] != '\n' && buffer[i] != '\r') return 0;
    return 1;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return flags;
}

static void consume(unsigned char *buffer, size_t *length, size_t count) {
    *length -= count;
    if (*length) memmove(buffer, buffer + count, *length);
}

static void reject_input(void) {
    fputs("CLAMAV_PTY_INPUT_REJECTED\n", stderr);
    fflush(stderr);
}

/* GUI-only line frames: P<password>\n, R\n, Y\n, N\n. Public answers
 * can never be confused with a one-character password. No frame contents
 * are logged. Legacy raw input remains available to non-GUI callers. */
enum input_type { RAW_INPUT, PASSWORD_INPUT, RETURN_INPUT, PUBLIC_INPUT };
static int decode_frame(unsigned char *frames, size_t *frames_len,
                        unsigned char *input, size_t *input_len,
                        enum input_type *type, int *discarding) {
    unsigned char *newline = memchr(frames, '\n', *frames_len);
    if (!newline) {
        if (*frames_len >= 8192) {
            memset(frames, 0, *frames_len);
            *frames_len = 0;
            if (!*discarding) reject_input();
            *discarding = 1;
        }
        return 0;
    }
    size_t length = (size_t)(newline - frames);
    int accepted = 0;
    if (*discarding) { *discarding = 0; }
    else if (length == 1 && (frames[0] == 'R' || frames[0] == 'Y' || frames[0] == 'N')) {
        *type = frames[0] == 'R' ? RETURN_INPUT : PUBLIC_INPUT;
        if (*type == PUBLIC_INPUT) input[(*input_len)++] = frames[0] == 'Y' ? 'y' : 'n';
        input[(*input_len)++] = '\n';
        accepted = 1;
    } else if (length >= 2 && length <= 4097 && frames[0] == 'P') {
        accepted = 1;
        for (size_t i = 1; i < length; ++i)
            if (frames[i] < 32 || frames[i] == 127) accepted = 0;
        if (accepted) {
            *type = PASSWORD_INPUT;
            memcpy(input, frames + 1, length - 1);
            input[length - 1] = '\n';
            *input_len = length;
        }
    }
    if (!accepted && !*discarding) reject_input();
    consume(frames, frames_len, length + 1);
    memset(frames + *frames_len, 0, length + 1);
    return 1;
}

int main(int argc, char **argv) {
    const int gui_input = argc >= 2 && strcmp(argv[1], "--gui-input") == 0;
    const int program_index = gui_input ? 2 : 1;
    if (argc <= program_index) {
        fprintf(stderr, "Usage: pty-bridge [--gui-input] PROGRAM [ARGUMENT ...]\n");
        return 64;
    }
    const int termination_grace = termination_grace_seconds();
    if (termination_grace < 0) {
        fputs("pty-bridge: CLAMAV_PTY_TERMINATION_GRACE_SECONDS must be an integer from 1 to 120\n", stderr);
        return 64;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = request_shutdown;
    sigemptyset(&action.sa_mask);
    const int termination_signals[] = {SIGTERM, SIGINT, SIGHUP, SIGQUIT};
    for (size_t i = 0; i < sizeof(termination_signals)/sizeof(int); ++i)
        if (sigaction(termination_signals[i], &action, NULL) < 0) {
            perror("pty-bridge: sigaction");
            return 125;
        }

    int master;
    struct winsize size = {40, 100, 0, 0};
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) {
        perror("pty-bridge: forkpty");
        return 125;
    }
    if (child == 0) {
        for (size_t i = 0; i < sizeof(termination_signals)/sizeof(int); ++i)
            (void)signal(termination_signals[i], SIG_DFL);
        (void)signal(SIGPIPE, SIG_DFL);
        if (!getenv("TERM")) (void)setenv("TERM", "dumb", 1);
        execvp(argv[program_index], &argv[program_index]);
        int saved_errno = errno;
        perror("pty-bridge: exec");
        _exit(saved_errno == ENOENT ? 127 : 126);
    }

    (void)signal(SIGPIPE, SIG_IGN);
    (void)fcntl(master, F_SETFD, FD_CLOEXEC);
    int in_flags = set_nonblocking(STDIN_FILENO);
    int out_flags = set_nonblocking(STDOUT_FILENO);
    int master_flags = set_nonblocking(master);
    if (in_flags < 0 || out_flags < 0 || master_flags < 0) {
        perror("pty-bridge: nonblocking I/O");
        signal_child(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        close(master);
        if (in_flags >= 0) (void)fcntl(STDIN_FILENO, F_SETFL, in_flags);
        if (out_flags >= 0) (void)fcntl(STDOUT_FILENO, F_SETFL, out_flags);
        return 125;
    }

    unsigned char input[16384], frames[16384], output[65536];
    size_t input_len = 0, frames_len = 0, output_len = 0;
    enum input_type input_type = RAW_INPUT;
    int discarding_frame = 0;
    int stdin_eof = 0, master_eof = 0, stdout_failed = 0;
    int reaped = 0, status = 0, internal_failure = 0;
    int reported_echo = -1;
    double eof_deadline = 0, kill_deadline = 0, drain_deadline = 0;

    for (;;) {
        double now = monotonic_seconds();
        int echo = terminal_echo(master);
        if (echo != reported_echo && echo >= 0) {
            fprintf(stderr, "CLAMAV_PTY_ECHO=%d\n", echo);
            fflush(stderr);
            reported_echo = echo;
        }
        int signum = requested_signal;
        if (signum) {
            requested_signal = 0;
            if (reaped) (void)kill(-child, signum);
            else signal_child(child, signum);
            if (!kill_deadline) kill_deadline = now + termination_grace;
            stdin_eof = 1;
            memset(input, 0, input_len); memset(frames, 0, frames_len);
            frames_len = 0;
            input_len = 0;
        }
        if (!reaped) {
            pid_t waited = waitpid(child, &status, WNOHANG);
            if (waited == child) {
                reaped = 1;
                stdin_eof = 1;
                memset(input, 0, input_len); memset(frames, 0, frames_len);
                frames_len = 0;
                input_len = 0;
                drain_deadline = now + 2.0;
            } else if (waited < 0 && errno != EINTR) {
                internal_failure = 1;
                reaped = 1;
                drain_deadline = now + 2.0;
            }
        }
        if (!reaped && eof_deadline && now >= eof_deadline && !kill_deadline) {
            signal_child(child, SIGHUP);
            kill_deadline = now + termination_grace;
            input_len = 0;
        }
        if (kill_deadline && now >= kill_deadline) {
            if (reaped) (void)kill(-child, SIGKILL);
            else signal_child(child, SIGKILL);
            kill_deadline = 0;
            eof_deadline = 0;
        }
        if (reaped && master_eof && output_len == 0) break;
        if (reaped && drain_deadline && now >= drain_deadline) {
            /* Descendants must not keep a GUI operation alive indefinitely. */
            (void)kill(-child, SIGHUP);
            if (kill_deadline) (void)kill(-child, SIGKILL);
            break;
        }

        if (gui_input && !input_len && !stdin_eof)
            while (!input_len && decode_frame(frames, &frames_len, input, &input_len,
                                             &input_type, &discarding_frame)) {}

        struct pollfd fds[3] = {
            {STDIN_FILENO, 0, 0}, {master, 0, 0}, {STDOUT_FILENO, 0, 0}
        };
        if (!stdin_eof && !reaped && (gui_input ? frames_len < sizeof(frames) : input_len < sizeof(input)))
            fds[0].events = POLLIN;
        if (!master_eof && output_len < sizeof(output)) fds[1].events |= POLLIN;
        if (!master_eof && input_len) fds[1].events |= POLLOUT;
        if (!stdout_failed && output_len) fds[2].events = POLLOUT;
        /* POLLHUP is reported even when events == 0. Remove inactive fds
         * entirely so a closed stdin cannot make the shutdown loop spin. */
        for (size_t i = 0; i < 3; ++i)
            if (fds[i].events == 0) fds[i].fd = -1;
        int ready = poll(fds, 3, 100);
        if (ready < 0) {
            if (errno == EINTR) continue;
            internal_failure = 1;
            signal_child(child, SIGKILL);
            break;
        }

        if (fds[0].events && (fds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            unsigned char *target = gui_input ? frames : input;
            size_t *length = gui_input ? &frames_len : &input_len;
            ssize_t count = read(STDIN_FILENO, target + *length, sizeof(input) - *length);
            if (count > 0) *length += (size_t)count;
            else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
                stdin_eof = 1;
                eof_deadline = monotonic_seconds() + 3.0;
            }
        }
        if (input_len && (fds[1].revents & POLLOUT)) {
            /* Fail closed if terminal state is unavailable or ECHO is enabled.
             * stderr is a status channel, never a copy of submitted input. */
            struct termios current_attributes;
            const int attributes_available = tcgetattr(master, &current_attributes) == 0;
            const int current_echo = attributes_available ?
                ((current_attributes.c_lflag & ECHO) ? 1 : 0) : -1;
            const int reject = gui_input ?
                (current_echo < 0 || (input_type == PASSWORD_INPUT && current_echo != 0)) :
                (!only_newlines(input, input_len) && current_echo != 0);
            if (reject) {
                memset(input, 0, input_len);
                input_len = 0;
                reject_input();
            } else {
                /* Ruby IO#getch (used by Homebrew) consumes one character
                 * in noncanonical mode. A trailing newline would remain
                 * queued and could answer the following question by itself.
                 * Line-oriented prompts still need their newline. Inspect
                 * ICANON immediately before writing, not when decoding. */
                if (gui_input && input_type == PUBLIC_INPUT &&
                    !(current_attributes.c_lflag & ICANON)) {
                    if (input_len == 2) {
                        input[1] = 0;
                        input_len = 1;
                    } else if (input_len == 1 && input[0] == '\n') {
                        input[0] = 0;
                        input_len = 0;
                    }
                }
                ssize_t count = write(master, input, input_len);
                if (count > 0) {
                    consume(input, &input_len, (size_t)count);
                    memset(input + input_len, 0, (size_t)count);
                } else if (count < 0 && errno != EAGAIN && errno != EINTR) {
                    memset(input, 0, input_len);
                    input_len = 0;
                }
            }
        }
        if (!master_eof && output_len < sizeof(output) &&
            (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t count = read(master, output + output_len, sizeof(output) - output_len);
            if (count > 0) output_len += (size_t)count;
            else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
                master_eof = 1;
                input_len = 0;
            }
        }
        if (!stdout_failed && output_len && (fds[2].revents & (POLLOUT | POLLHUP | POLLERR))) {
            ssize_t count = write(STDOUT_FILENO, output, output_len);
            if (count > 0) consume(output, &output_len, (size_t)count);
            else if (count < 0 && errno != EAGAIN && errno != EINTR) {
                stdout_failed = 1;
                signal_child(child, SIGHUP);
                if (!kill_deadline) kill_deadline = monotonic_seconds() + termination_grace;
            }
        }
        if (stdout_failed) output_len = 0;
    }

    close(master);
    memset(input, 0, sizeof(input));
    memset(frames, 0, sizeof(frames));
    if (!reaped) {
        signal_child(child, SIGKILL);
        pid_t waited;
        do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
        if (waited != child) internal_failure = 1;
    }
    /* A cancellation applies to every process in the child's group, including
     * a grandchild which ignored the original termination signal. */
    if (stdin_eof && kill_deadline) (void)kill(-child, SIGKILL);
    (void)fcntl(STDIN_FILENO, F_SETFL, in_flags);
    (void)fcntl(STDOUT_FILENO, F_SETFL, out_flags);
    if (internal_failure) return 125;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}
