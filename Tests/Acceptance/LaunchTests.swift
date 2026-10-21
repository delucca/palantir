import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.integration), .serialized)
struct LaunchTests {
  @Test func aDebugLaunchWithTheFlagIsWaitedForThroughTheInspector() throws {
    let world = try FakeWorld()
    let pid = try world.launcher.launch(build: .debug, inspector: true)
    #expect(
      world.calls(to: Settings.inspectorName).first == [
        "--pid", "\(pid)", "wait", "--timeout", "3",
      ])
    let open = try #require(world.calls.first { $0.program == Settings.open })
    #expect(open.arguments.suffix(2) == ["--args", "--inspector"])
    #expect(open.arguments.starts(with: ["-g", "-n"]))
  }

  @Test func aReleaseLaunchWithTheFlagIsWaitedForThroughMenusNeverTheInspector() throws {
    let world = try FakeWorld()
    world.dropsArguments = false
    let pid = try world.launcher.launch(build: .release, inspector: true)
    #expect(world.calls(to: Settings.inspectorName).isEmpty)
    #expect(world.calls(to: Settings.driverName).contains(["--pid", "\(pid)", "menus"]))
  }

  @Test func aLaunchWithoutTheFlagPassesNoArgsAndIsWaitedForThroughMenus() throws {
    let world = try FakeWorld()
    _ = try world.launcher.launch(build: .debug, inspector: false)
    let open = try #require(world.calls.first { $0.program == Settings.open })
    #expect(!open.arguments.contains("--args"))
    #expect(world.calls(to: Settings.inspectorName).isEmpty)
  }

  @Test func aLaunchThatNeverAnswersIsQuitAndFails() throws {
    let world = try FakeWorld()
    world.inspect = { _ in Output(exit: 1, stdout: "", stderr: "no inspector") }
    let error = #expect(throws: NoVerdict.self) {
      _ = try world.launcher.launch(build: .debug, inspector: true)
    }
    #expect(error?.kind == .launch)
    #expect(error?.message.contains("did not answer") == true)
    #expect(world.palantirPids().isEmpty)
  }

  @Test func aMissingBundleIsALaunchError() throws {
    let world = try FakeWorld()
    var launcher = world.launcher
    launcher = Launcher(
      runner: world, processes: world, bin: world.bin,
      apps: [.debug: world.root.appending(path: "no.app")])
    let error = #expect(throws: NoVerdict.self) {
      _ = try launcher.launch(build: .debug, inspector: true)
    }
    #expect(error?.kind == .launch)
  }

  @Test func quitPressesTheQuitMenuItemAndReportsATerminationAsFalse() throws {
    let world = try FakeWorld()
    let pid = try world.launcher.launch(build: .debug, inspector: false)
    #expect(world.launcher.quit(pid))
    #expect(
      world.calls(to: Settings.driverName).contains([
        "--pid", "\(pid)", "menu", "palantir > Quit palantir",
      ]))
    world.ignoresQuit = true
    let stuck = try world.launcher.launch(build: .debug, inspector: false)
    #expect(!world.launcher.quit(stuck))
    #expect(!world.isRunning(stuck))
  }
}

@Suite(.layer(.unit))
struct ProcessArgumentsTests {
  /// A `KERN_PROCARGS2` buffer: argc, the path, NUL padding, the arguments.
  static func buffer(argc: Int32, path: String, padding: Int, arguments: [String]) -> Data {
    var data = withUnsafeBytes(of: argc) { Data($0) }
    data += Data(path.utf8) + Data(repeating: 0, count: padding)
    for argument in arguments { data += Data(argument.utf8) + Data([0]) }
    data += Data("HOME=/x".utf8) + Data([0])
    return data
  }

  @Test func theArgumentsFollowThePathAndStopAtArgc() {
    let data = Self.buffer(
      argc: 2, path: "/a/palantir", padding: 3, arguments: ["/a/palantir", "--inspector"])
    #expect(ProcessArguments.parse(data) == ["/a/palantir", "/a/palantir", "--inspector"])
  }

  @Test func aProcessLaunchedWithoutArgumentsHasOnlyItsProgramName() {
    let data = Self.buffer(argc: 1, path: "/a/palantir", padding: 1, arguments: ["/a/palantir"])
    #expect(ProcessArguments.parse(data) == ["/a/palantir", "/a/palantir"])
  }

  @Test func aShortBufferIsNil() {
    #expect(ProcessArguments.parse(Data([1, 0])) == nil)
  }
}

@Suite(.layer(.unit))
struct OutputsTests {
  @Test func menuRowsKeepAnEmptyTitleAndTheKeyColumn() {
    let items = Outputs.menus("Edit > \tdisabled\tpress\t-\nEdit > Copy\tdisabled\tpress\tcmd+c\n")
    #expect(items.count == 2)
    #expect(items[0]["path"] as? String == "Edit > ")
    #expect(items[1]["key"] as? String == "cmd+c")
    #expect(items[1]["enabled"] as? Bool == false)
  }

  @Test func aMenuRowFromBeforeTheKeyColumnHasNoKey() {
    let items = Outputs.menus("File\tenabled\tpress\n")
    #expect(items[0]["key"] == nil)
    #expect(items[0]["press"] as? Bool == true)
  }

  @Test func treeLinesCarryDepthRoleLabelFrameAndActions() {
    let elements = Outputs.tree(
      "AXWindow title=\"w\" frame=-3,4,50,60 actions=AXRaise,AXPress\n    AXButton\n")
    #expect(elements[0]["frame"] as? [Int] == [-3, 4, 50, 60])
    #expect(elements[0]["actions"] as? [String] == ["AXRaise", "AXPress"])
    #expect(elements[1]["depth"] as? Int == 2)
    #expect(elements[1]["role"] as? String == "AXButton")
  }

  @Test func socketRowsAreAPidAndAPath() {
    let sockets = Outputs.sockets("12\t/tmp/x\n34\t/tmp/y\n")
    #expect(sockets.map { $0["pid"] as? Int } == [12, 34])
  }
}
