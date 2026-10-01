import Foundation

/// Starts the voice program as its own "responsible process". By default macOS credits a child
/// to the app that started it, so a program run by VoiceAI would use VoiceAI's Accessibility and
/// microphone permissions — and its path sits in preferences any process of this user can write
/// (audit 2026-10-01, P1-01). Disclaimed, the program gets its own permission checks, as a
/// program run from Terminal does: a speech engine needs none.
///
/// `responsibility_spawnattrs_setdisclaim` is not in the public headers; Terminal, Chromium and
/// LLDB call it the same way. Without it nothing is started at all — the system voice reads.
/// Foundation only, so the headless check covers it.
enum DisclaimedSpawn {
    struct Child {
        let pid: pid_t
        /// The program's standard input.
        let input: FileHandle
        /// The program's standard output.
        let output: FileHandle
    }

    enum SpawnError: Error {
        case disclaimUnavailable
        case failed(Int32)
    }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let setDisclaim: SetDisclaim? = {
        // RTLD_DEFAULT: look the symbol up in everything already loaded.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    static var available: Bool { setDisclaim != nil }

    /// Runs `path` with no arguments; standard error goes to /dev/null. The caller reaps the
    /// child with `waitpid` once it ends.
    static func start(_ path: String) throws -> Child {
        guard let setDisclaim else { throw SpawnError.disclaimUnavailable }
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0 else { throw SpawnError.failed(errno) }
        guard pipe(&fromChild) == 0 else {
            close(toChild[0]); close(toChild[1])
            throw SpawnError.failed(errno)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors below reach the program, nothing else VoiceAI has open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard setDisclaim(&attributes, 1) == 0 else { throw SpawnError.disclaimUnavailable }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let status = path.withCString { program -> Int32 in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(program), nil]
            defer { free(argv[0]) }
            return posix_spawn(&pid, program, &actions, &attributes, &argv, environ)
        }
        // The program's ends now live in the child; ours stay here.
        close(toChild[0])
        close(fromChild[1])
        guard status == 0 else {
            close(toChild[1]); close(fromChild[0])
            throw SpawnError.failed(status)
        }
        return Child(pid: pid,
                     input: FileHandle(fileDescriptor: toChild[1], closeOnDealloc: true),
                     output: FileHandle(fileDescriptor: fromChild[0], closeOnDealloc: true))
    }
}
