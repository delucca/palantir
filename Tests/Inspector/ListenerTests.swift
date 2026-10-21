import AppKit
import Darwin
import Foundation
import Testing

@testable import PalantirInspector

@MainActor
struct ListenerTests {
  /// A fresh directory for sockets, short enough for `sun_path`.
  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
      path: "pi-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    return url
  }

  private func mode(_ url: URL) -> mode_t {
    var info = stat()
    lstat(url.path, &info)
    return info.st_mode
  }

  private func call(_ client: InspectorClient, _ method: InspectorMethod) async throws -> Data {
    try await Task.detached { try client.call(method, NoParams(), timeout: 5) }.value
  }

  // [utest->req~inspector.debug-only~1]
  @Test func theListenerAnswersOnASocketOnlyTheUserCanOpen() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: []), in: directory)
    defer { listener.stop() }
    #expect(mode(directory) & S_IFMT == S_IFDIR)
    #expect(mode(directory) & 0o777 == 0o700)
    #expect(mode(listener.socket) & S_IFMT == S_IFSOCK)
    #expect(mode(listener.socket) & 0o777 == 0o600)
    #expect(listener.socket.lastPathComponent == "\(getpid()).sock")

    let client = try InspectorClient(pid: nil, directory: directory)
    #expect(client.pid == getpid())
    let response = try JSONSerialization.jsonObject(with: try await call(client, .state))
    let result = try #require((response as? [String: Any])?["result"] as? [String: Any])
    #expect(result["window"] != nil && result["sections"] != nil)

    listener.stop()
    #expect(!FileManager.default.fileExists(atPath: listener.socket.path))
  }

  // [utest->req~inspector.debug-only~1]
  @Test(arguments: [0o755, 0o750, 0o701] as [mode_t])
  func theListenerRefusesADirectoryOthersCanOpen(mode: mode_t) throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(mkdir(directory.path, mode) == 0 && chmod(directory.path, mode) == 0)
    #expect(throws: SocketError.self) {
      try InspectorListener(serving: Inspector(window: { nil }, sections: []), in: directory)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: SocketDirectory.socket(for: getpid(), in: directory).path))
  }

  // [utest->req~inspector.debug-only~1]
  @Test func theListenerRefusesASymlinkedDirectory() throws {
    let target = try directory()
    let link = try directory()
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: target)
    }
    try #require(mkdir(target.path, 0o700) == 0 && symlink(target.path, link.path) == 0)
    #expect(throws: SocketError.self) {
      try InspectorListener(serving: Inspector(window: { nil }, sections: []), in: link)
    }
  }

  @Test func aSocketPathLongerThanSunPathIsAnError() throws {
    let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 100), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: long) }
    #expect(throws: SocketError.self) {
      try InspectorListener(serving: Inspector(window: { nil }, sections: []), in: long)
    }
  }

  @Test func theUsersSocketDirectoryFitsSunPath() {
    let path = SocketDirectory.socket(for: 99_999, in: SocketDirectory.url).path
    #expect(path.utf8.count < 104)
    #expect(
      path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        || path.hasPrefix("/var/folders/"))
  }

  /// A client on its own socket, off the main actor, where the inspector answers.
  private final class RawClient: @unchecked Sendable {
    private let descriptor: Int32

    init(_ socket: URL) throws {
      descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      var on: Int32 = 1
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var limit = timeval(tv_sec: 3, tv_usec: 0)
      setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
      var address = try #require(socketAddress(socket))
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      try #require(connected == 0)
    }

    deinit { close(descriptor) }

    /// Writes `request`, as much as the inspector takes before it closes the connection.
    func send(_ request: Data) {
      request.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          guard written > 0 else { return }
          offset += written
        }
      }
    }

    /// What comes back until `lines` lines arrived, the connection closed, or 3 s passed.
    func receive(lines: Int) -> (data: Data, closed: Bool) {
      var data = Data()
      var chunk = [UInt8](repeating: 0, count: 65_536)
      while data.count(where: { $0 == 0x0A }) < lines {
        let count = Darwin.read(descriptor, &chunk, chunk.count)
        if count == 0 { return (data, true) }
        if count < 0 { return (data, errno != EAGAIN) }
        data.append(contentsOf: chunk.prefix(count))
      }
      return (data, false)
    }
  }

  private func request(_ id: Int, _ method: String, _ params: String = "{}") -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#.utf8) + [0x0A]
  }

  /// A window on the screen, transparent, so its layout settles.
  private func shownWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFront(nil)
    return window
  }

  @Test func aRequestOverTheLimitDropsTheConnectionUnanswered() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let listener = try InspectorListener(
      serving: Inspector(window: { nil }, sections: []), in: directory)
    defer { listener.stop() }
    let client = try RawClient(listener.socket)
    let line = Data(repeating: 0x78, count: InspectorListener.maximumRequest + 1) + [0x0A]
    let answer = await Task.detached {
      client.send(line)
      return client.receive(lines: 1)
    }.value
    #expect(answer.data.isEmpty && answer.closed)
  }

  @Test func requestsOnOneConnectionAreAnsweredOneAtATimeInOrder() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = shownWindow()
    defer { window.orderOut(nil) }
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: []), in: directory)
    defer { listener.stop() }
    let client = try RawClient(listener.socket)
    // A wait takes several looks; the state alone would answer at once.
    let requests = request(1, "wait") + request(2, "state")
    let answer = await Task.detached {
      client.send(requests)
      return client.receive(lines: 2)
    }.value
    let ids = String(decoding: answer.data, as: UTF8.self).split(separator: "\n").map {
      try? JSONDecoder().decode(InspectorResponse<NoParams>.self, from: Data($0.utf8)).id
    }
    #expect(ids == [.number(1), .number(2)])
  }

  @Test func aRequestAfterManyBlankLinesIsAnswered() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: []), in: directory)
    defer { listener.stop() }
    let client = try RawClient(listener.socket)
    let lines = Data(repeating: 0x0A, count: 200_000) + request(1, "state")
    let answer = await Task.detached {
      client.send(lines)
      return client.receive(lines: 1)
    }.value
    let response = try JSONDecoder().decode(
      InspectorResponse<NoParams>.self, from: Data(answer.data.prefix { $0 != 0x0A }))
    #expect(response.id == .number(1) && response.error == nil)
  }

  /// A section with a state far larger than a socket's buffer.
  private struct LargeSection: StateSection {
    var name: String { "large" }
    func state() throws -> any Encodable { String(repeating: "x", count: 4 << 20) }
  }

  @Test func aClientThatStopsReadingIsDroppedAfterTheSendTimeout() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: [LargeSection()]), in: directory,
      sendTimeout: 0.2)
    defer { listener.stop() }
    let client = try RawClient(listener.socket)
    let line = request(1, "state")
    let answer = await Task.detached {
      client.send(line)
      usleep(1_000_000)
      return client.receive(lines: 1)
    }.value
    #expect(!answer.data.contains(0x0A) && answer.closed)
  }

  @Test func aConnectionOverTheLimitIsClosedAtOnce() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: []), in: directory)
    defer { listener.stop() }
    var open = try (0..<InspectorListener.maximumConnections).map { _ in
      try RawClient(listener.socket)
    }
    let extra = try RawClient(listener.socket)
    let line = request(1, "state")
    let refused = await Task.detached {
      extra.send(line)
      return extra.receive(lines: 1)
    }.value
    #expect(refused.data.isEmpty && refused.closed)

    open.removeAll()
    var answered = false
    for _ in 0..<40 where !answered {
      let client = try RawClient(listener.socket)
      answered = await Task.detached {
        client.send(line)
        return client.receive(lines: 1).data.contains(0x0A)
      }.value
      if !answered { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(answered, "a closed connection must free its place")
  }

  @Test(arguments: [0, -1, 1e9, 601])
  func aTimeoutOutOfBoundsIsABadParameter(timeout: Double) async throws {
    let window = shownWindow()
    defer { window.orderOut(nil) }
    let inspector = Inspector(window: { window }, sections: [])
    for method in ["wait", "screenshot"] {
      let line = request(1, method, #"{"timeout":\#(timeout)}"#).dropLast()
      let response = try JSONDecoder().decode(
        InspectorResponse<NoParams>.self, from: await inspector.respond(to: Data(line)))
      #expect(response.error?.code == -32_602, "\(method) with timeout \(timeout)")
    }
  }

  @Test func anUnknownMethodAndABadLineAreJSONRPCErrors() async throws {
    let inspector = Inspector(window: { nil }, sections: [])
    let unknown = try JSONDecoder().decode(
      InspectorResponse<NoParams>.self,
      from: await inspector.respond(to: Data(#"{"jsonrpc":"2.0","id":7,"method":"click"}"#.utf8)))
    #expect(unknown.id == .number(7) && unknown.error?.code == -32_601)
    let bad = try JSONDecoder().decode(
      InspectorResponse<NoParams>.self, from: await inspector.respond(to: Data("not json".utf8)))
    #expect(bad.id == nil && bad.error?.code == -32_700)
    let noWindow = try JSONDecoder().decode(
      InspectorResponse<NoParams>.self,
      from: await inspector.respond(to: Data(#"{"jsonrpc":"2.0","id":"a","method":"state"}"#.utf8)))
    #expect(noWindow.id == .string("a") && noWindow.error == .noWindow)
  }

  @Test func jsonThatIsNotARequestIsAnInvalidRequestNotAParseError() async throws {
    let inspector = Inspector(window: { nil }, sections: [])
    for line in [#"{"jsonrpc":"2.0","id":1,"method":5}"#, "[1]", "7"] {
      let response = try JSONDecoder().decode(
        InspectorResponse<NoParams>.self, from: await inspector.respond(to: Data(line.utf8)))
      #expect(response.error?.code == -32_600, "\(line)")
    }
  }

  /// A section whose state differs at every look.
  private final class ChangingSection: StateSection {
    var name: String { "changing" }
    private var looks = 0
    func state() throws -> any Encodable {
      looks += 1
      return looks
    }
  }

  // [utest->req~inspector.settled-layout~1]
  @Test func aStateThatKeepsChangingNeverSettlesAndTimesOut() async throws {
    let window = shownWindow()
    defer { window.orderOut(nil) }
    let inspector = Inspector(window: { window }, sections: [ChangingSection()])
    do {
      _ = try await inspector.waitForSettledLayout(timeout: 0.3)
      Issue.record("the wait answered although the state kept changing")
    } catch let error as InspectorError {
      #expect(error.code == -32_001)
    }
  }

  @Test func aClientThatSendsNothingIsClosedAfterTheIdleTimeout() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = shownWindow()
    defer { window.orderOut(nil) }
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: []), in: directory, idleTimeout: 0.3)
    defer { listener.stop() }
    let client = try RawClient(listener.socket)
    let answer = await Task.detached { client.receive(lines: 1) }.value
    #expect(answer.data.isEmpty && answer.closed)
  }

  @Test func stoppingTheListenerClosesItsConnections() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = shownWindow()
    defer { window.orderOut(nil) }
    let listener = try InspectorListener(
      serving: Inspector(window: { window }, sections: []), in: directory)
    let client = try RawClient(listener.socket)
    try await Task.sleep(for: .milliseconds(200))
    listener.stop()
    let answer = await Task.detached { client.receive(lines: 1) }.value
    #expect(answer.closed)
  }

  @Test func aSocketNobodyListensOnIsNotDiscoveredEvenWhenItsPidIsRunning() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = SocketDirectory.socket(for: getpid(), in: directory)
    var address = try #require(socketAddress(socket))
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(descriptor) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(bound == 0)
    #expect(SocketDirectory.sockets(in: directory).isEmpty)
  }
}
