import StarCoreC

// Test helper, not shipped: installs the fatal-signal handler, then dies of SIGSEGV so
// CrashHandlerBacktraceTests can read what the handler writes to stderr.
//
// argv[1], when given, is the crash-note path (the handler writes the signal name there).
let notePath: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
if let notePath {
    _ = star_install_crash_handlers(notePath, nil)
} else {
    _ = star_install_crash_handlers(nil, nil)
}

// A store through a small unmapped address (never 0: a nil pointer would trap in Swift with
// SIGILL/SIGTRAP, not SIGSEGV). Derived from the arguments' count so the optimizer cannot
// see the address and delete the store.
let target = UnsafeMutablePointer<Int>(bitPattern: 8 * CommandLine.arguments.count)
target!.pointee = 1
