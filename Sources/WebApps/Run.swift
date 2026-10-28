import Foundation

/// Runs a tool to completion and returns its status with stdout and stderr together.
func run(_ path: String, _ args: [String], env: [String: String] = [:]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    if !env.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
