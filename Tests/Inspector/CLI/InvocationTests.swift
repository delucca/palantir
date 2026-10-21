import Foundation
import PalantirInspector
import Testing

@testable import PalantirInspectorCLI

struct InvocationTests {
  @Test func eachCommandReadsItsOptions() throws {
    #expect(try Invocation(["state"]) == Invocation(pid: nil, command: .state))
    #expect(try Invocation(["--pid", "42", "list"]) == Invocation(pid: 42, command: .list))
    #expect(
      try Invocation(["wait"]).command == .wait(timeout: Settling.defaultTimeout))
    #expect(try Invocation(["wait", "--timeout", "2.5"]).command == .wait(timeout: 2.5))
    #expect(
      try Invocation(["screenshot", "out.png", "--rect", "0,0,100,50", "--pid", "7"])
        == Invocation(
          pid: 7,
          command: .screenshot(
            path: "out.png", rect: Rect(x: 0, y: 0, width: 100, height: 50),
            timeout: Settling.defaultTimeout)))
  }

  @Test(arguments: [
    [], ["click"], ["state", "extra"], ["wait", "--timeout", "0"], ["screenshot"],
    ["screenshot", "a.png", "--rect", "1,2,3"], ["--pid", "x", "state"], ["--pid"],
    ["wait", "--timeout", "inf"], ["wait", "--timeout", "nan"], ["wait", "--timeout", "601"],
    ["screenshot", "a.png", "--timeout", "1e9"],
  ])
  func aBadCommandLineIsAUsageError(arguments: [String]) {
    #expect(throws: Invocation.Usage.self) { try Invocation(arguments) }
  }

  @Test func aScreenshotIsWrittenToItsFileAndDescribed() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let path = FileManager.default.temporaryDirectory.appending(
      path: "shot-\(UUID().uuidString).png"
    ).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let printed = try saveScreenshot(
      ScreenshotResult(png: png, width: 20, height: 10, scale: 2), to: path)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
    #expect(printed["path"] as? String == path)
    #expect(printed["width"] as? Int == 20 && printed["height"] as? Int == 10)
    #expect(printed["scale"] as? Double == 2)
  }
}
