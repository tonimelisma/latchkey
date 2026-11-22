// Latchkey's test launcher (spec 004 FR-335; Toni, 2026-11-21: "Test step outside fence").
//
// A Shell command runs inside Latchkey's fence (macOS's sandbox). When xcodebuild runs an app's
// tests, LaunchServices opens the test app, and an app opened for a sandboxed program gets none
// of Xcode's test settings (DYLD_INSERT_LIBRARIES, XCTestSessionIdentifier): it starts as a
// plain app and never connects ("The test runner hung before establishing connection"). The
// fence lets this one program, inside Latchkey's own app where a command can't change it, start
// outside the sandbox, and only when the command declared `open`, which already starts what it
// opens outside the fence. It runs Apple's xcodebuild for the test step and nothing else: the
// build stays inside the fence (the job's xcodebuild runs build-for-testing there first).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    argv[0] = (char *)xcodebuild;
    execve(xcodebuild, argv, env);
    perror("LatchkeyXcodeTests: xcodebuild");
    return 127;
}
