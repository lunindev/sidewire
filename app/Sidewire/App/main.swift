import Foundation

// Entry point. When re-exec'd with `--vd-helper`, this same universal binary runs the
// headless virtual-display helper instead of the SwiftUI app (see VirtualDisplayHelper).
//
// The flag must be the FIRST argument, not merely present somewhere in argv. `contains` would also
// match a stray occurrence — a file path, a document opened by Launch Services, an argument the OS
// appends — and silently start a headless helper where the user expected the app. VirtualDisplayManager
// always passes it first, so this is strictly more precise with no behavioural change.
//
// Note this is a correctness fix, not a privilege boundary: the helper runs as the same user with
// the same rights as the app, creates the same virtual display, and is driven over a private pipe.
// Anyone able to invoke this binary with arguments can already run the app itself, so there is no
// elevation to defend against here.
if CommandLine.arguments.dropFirst().first == "--vd-helper" {
    VirtualDisplayHelper.run() // never returns
} else {
    SidewireApp.main()
}
