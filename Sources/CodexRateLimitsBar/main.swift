import AppKit
import CodexRateLimitsCore
import Darwin

let commandLineArguments = Array(CommandLine.arguments.dropFirst())
if CodexCommandLine.isCLIInvocation(commandLineArguments) {
    exit(CodexCommandLine.run(arguments: commandLineArguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
