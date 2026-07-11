import Foundation

// Entry point. When re-exec'd with `--vd-helper`, this same universal binary runs the
// headless virtual-display helper instead of the SwiftUI app (see VirtualDisplayHelper).
if CommandLine.arguments.contains("--vd-helper") {
    VirtualDisplayHelper.run() // never returns
} else {
    SidewireApp.main()
}
