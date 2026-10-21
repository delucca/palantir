#if DEBUG
  import Darwin
  import Foundation
  import PalantirInspector

  let usage = """
    usage: palantir-inspect [--pid <pid>] <command>

    Reads a debug palantir started with --inspector. It never drives the app.

      state                     the window and every feature's state, as JSON
      wait [--timeout <s>]      answers once layout has settled
      screenshot <out.png> [--rect <x,y,width,height>] [--timeout <s>]
                                the window's content at full resolution once layout has
                                settled; the rect is in window points from the content's
                                top-left corner
      list                      the pid and socket of every palantir listening

    Without --pid it reads the only palantir listening.
    """

  func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("palantir-inspect: \(message)\n".utf8))
    exit(code)
  }

  func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
  }

  /// Prints a response's result, or fails with its error.
  func printResult(_ response: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      fail("not a JSON-RPC response", 1)
    }
    if let error = object["error"] as? [String: Any] {
      fail("\(error["message"] ?? "") (\(error["code"] ?? ""))", 1)
    }
    try printJSON(object["result"] ?? NSNull())
  }

  /// Calls `body` once a palantir answers, retrying one still launching for up to `timeout`
  /// seconds; `body` gets the seconds left.
  func untilListening(
    _ pid: pid_t?, timeout: Double, _ body: (InspectorClient, Double) throws -> Data
  ) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      do {
        return try body(InspectorClient(pid: pid), max(0.1, deadline.timeIntervalSinceNow))
      } catch let error as SocketError {
        switch error {
        case .noInspector, .system: guard Date() < deadline else { throw error }
        default: throw error
        }
        usleep(100_000)
      }
    }
  }

  do {
    let invocation = try Invocation(Array(CommandLine.arguments.dropFirst()))
    switch invocation.command {
    case .state:
      try printResult(InspectorClient(pid: invocation.pid).call(.state, NoParams(), timeout: 10))
    case .wait(let timeout):
      try printResult(
        untilListening(invocation.pid, timeout: timeout) {
          try $0.call(.wait, WaitParams(timeout: $1), timeout: $1 + 5)
        })
    case .screenshot(let path, let rect, let timeout):
      let result = try InspectorClient(pid: invocation.pid).call(
        .screenshot, ScreenshotParams(rect: rect, timeout: timeout), timeout: timeout + 5,
        as: ScreenshotResult.self)
      try printJSON(saveScreenshot(result, to: path))
    case .list:
      for (pid, url) in SocketDirectory.sockets() { print("\(pid)\t\(url.path)") }
    }
  } catch let error as Invocation.Usage {
    fail("\(error.message)\n\n\(usage)", 64)
  } catch let error as SocketError {
    fail("\(error)", 2)
  } catch {
    fail("\(error)", 1)
  }
#else
  import Foundation

  FileHandle.standardError.write(
    Data("palantir-inspect: the inspector is in debug builds only\n".utf8))
  exit(64)
#endif
