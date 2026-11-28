// Latchkey's test launcher (spec 004 FR-335; decided 2026-11-21: "Test step outside fence").
//
// A Shell command runs inside Latchkey's fence (macOS's sandbox). When xcodebuild runs an app's
// tests, LaunchServices opens the test app, and an app opened for a sandboxed program gets none
// of Xcode's test settings (DYLD_INSERT_LIBRARIES, XCTestSessionIdentifier): it starts as a
// plain app and never connects ("The test runner hung before establishing connection"). The
// fence lets this one program, inside Latchkey's own app where a command can't change it, start
// outside the sandbox, and only when the command declared `open`, which already starts what it
// opens outside the fence. It runs Apple's xcodebuild for the test step and nothing else: the
// build stays inside the fence (the job's xcodebuild runs build-for-testing there first).
//
// xcodebuild is started as responsible for itself (security review 2026-11-21): a program
// Latchkey starts is otherwise counted as Latchkey's by macOS's privacy checks, and outside the
// fence it would have Latchkey's permissions (Full Disk Access, Apple Events) to write and send
// with. Disclaimed, it has what a program started in Terminal has, as an opened app does. When
// macOS offers no way to disclaim, nothing runs.
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const char *xcodebuild = "/usr/bin/xcodebuild";

// Every other action, and the options that make xcodebuild do something else.
static const char *refused[] = {
    "build", "build-for-testing", "test", "analyze", "archive", "install", "installsrc", "clean",
    "docbuild", "-exportArchive", "-exportNotarizedApp", "-exportLocalizations", "-importLocalizations",
    "-create-xcframework", "-downloadPlatform", "-downloadAllPlatforms", "-importPlatform",
    "-runFirstLaunch", "-license", "-resolvePackageDependencies", NULL,
};

// Settings that would pick another xcodebuild or load other code into it.
static int dropped(const char *entry) {
    return strncmp(entry, "DYLD_", 5) == 0 || strncmp(entry, "DEVELOPER_DIR=", 14) == 0
        || strncmp(entry, "TOOLCHAINS=", 11) == 0 || strncmp(entry, "XCODE_XCCONFIG_FILE=", 20) == 0;
}

static pid_t child = 0;

// Stopping the job reaches xcodebuild too (it shares the job's process group); a signal sent to
// this program alone is passed on.
static void pass(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    int tests = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "test-without-building") == 0) tests++;
        for (const char **r = refused; *r; r++) {
            if (strcmp(argv[i], *r) == 0) {
                fprintf(stderr, "LatchkeyXcodeTests runs only xcodebuild test-without-building, not %s.\n", argv[i]);
                return 64;
            }
        }
    }
    if (tests != 1) {
        fprintf(stderr, "LatchkeyXcodeTests runs only xcodebuild test-without-building.\n");
        return 64;
    }
    size_t n = 0;
    for (char **e = environ; *e; e++) n++;
    char **env = calloc(n + 1, sizeof(char *));
    if (env == NULL) return 71;
    size_t k = 0;
    for (char **e = environ; *e; e++) {
        if (!dropped(*e)) env[k++] = *e;
    }

    // libsystem's responsibility call, the one macOS's own launchers use (no public header).
    int (*disclaim)(posix_spawnattr_t *, int) =
        (int (*)(posix_spawnattr_t *, int))dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    posix_spawnattr_t attr;
    if (disclaim == NULL || posix_spawnattr_init(&attr) != 0 || disclaim(&attr, 1) != 0) {
        fprintf(stderr, "LatchkeyXcodeTests: macOS offers no way to run the tests apart from Latchkey's permissions.\n");
        return 71;
    }
    argv[0] = (char *)xcodebuild;
    int err = posix_spawn(&child, xcodebuild, NULL, &attr, argv, env);
    posix_spawnattr_destroy(&attr);
    if (err != 0) {
        fprintf(stderr, "LatchkeyXcodeTests: xcodebuild: %s\n", strerror(err));
        return 127;
    }
    int sigs[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) signal(sigs[i], pass);
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 127;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-335
