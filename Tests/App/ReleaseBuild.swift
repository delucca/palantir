import Foundation
import Testing

/// Release palantir, built for the tests that check it or launch it.
enum ReleaseBuild {
  /// Runs `executable` and returns its standard output, failing on a non-zero exit.
  static func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "\(executable) \(arguments) failed")
    return String(decoding: data, as: UTF8.self)
  }

  /// Builds release palantir and returns its executable. A build of its own, in a scratch path of
  /// its own, so it does not wait on the lock of the build that runs the tests.
  static func executable() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let scratch = root.appending(path: ".build/release-check")
    _ = try run(
      "/usr/bin/xcrun",
      [
        "swift", "build", "-c", "release", "--product", "palantir", "--package-path", root.path,
        "--scratch-path", scratch.path, "--only-use-versions-from-resolved-file",
      ])
    return scratch.appending(path: "release/palantir")
  }
}
