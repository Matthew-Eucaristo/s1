#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import s1

// Thin entry point: all logic lives in `CLIMain` (library target), which
// keeps the CLI itself testable off-macOS.
exit(CLIMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
