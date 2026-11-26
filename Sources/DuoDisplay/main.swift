import Foundation

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--displaytest") {
    exit(SelfTest.runVirtualDisplay() ? 0 : 1)
}
if CommandLine.arguments.contains("--inputtest") {
    exit(SelfTest.runInputSerialization() ? 0 : 1)
}
if CommandLine.arguments.contains("--edgetest") {
    exit(EdgeSelfTest.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--pairtest") {
    exit(PairingSelfTest.run() ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--piptest") {
    let args = CommandLine.arguments
    PiPSelfTest.run(output: args.indices.contains(i + 1) ? args[i + 1] : nil)
}
if CommandLine.arguments.contains("--transporttest") {
    exit(TransportSelfTest.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--mediatest") {
    exit(MediaSelfTest.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--rendertest") {
    if CommandLine.arguments.contains("--window") { SelfTest.runRenderWindowed() }
    exit(SelfTest.runRender() ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--uisnapshot") {
    let args = CommandLine.arguments
    let dir = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : "build/ui-snapshots"
    UISnapshot.run(output: dir, onscreen: args.contains("--onscreen"))
}
DuoDisplayApp.main()
