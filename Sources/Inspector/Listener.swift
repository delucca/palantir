#if DEBUG
  import Darwin
  package import Foundation

  /// Serves an inspector on a Unix socket in `SocketDirectory`, one JSON-RPC message per line, and
  /// keeps App Nap away from palantir while it listens.
  @MainActor package final class InspectorListener {
    /// The launch flag that makes a debug build listen.
    nonisolated package static let launchFlag = "--inspector"
    /// The most request bytes a connection may have unanswered, its line included, before it is
    /// dropped.
    nonisolated static let maximumRequest = 1 << 20
    /// How many clients may be connected at once; one more is closed at once.
    nonisolated static let maximumConnections = 4
    /// Seconds a response may wait for a client that stopped reading before it is dropped.
    nonisolated static let sendTimeout = 5.0
    /// Seconds a connection may sit with nothing to answer and nothing sent before it is closed.
    nonisolated static let idleTimeout = 30.0

    package let socket: URL
    private let descriptor: Int32
    private let source: any DispatchSourceRead
    private let connections: Connections
    private let activity: any NSObjectProtocol
    private var stopped = false

    package init(
      serving inspector: Inspector, in directory: URL = SocketDirectory.url,
      sendTimeout: Double = InspectorListener.sendTimeout,
      idleTimeout: Double = InspectorListener.idleTimeout
    ) throws {
      try SocketDirectory.prepare(directory)
      let socket = SocketDirectory.socket(for: getpid(), in: directory)
      guard var address = socketAddress(socket) else {
        throw SocketError.pathTooLong(socket.path)
      }
      unlink(socket.path)
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, chmod(socket.path, 0o600) == 0, listen(descriptor, 8) == 0 else {
        let code = errno
        close(descriptor)
        unlink(socket.path)
        throw SocketError.system("listen on \(socket.path)", code)
      }
      let (source, connections) = Self.accepting(
        on: descriptor, for: inspector, sendTimeout: sendTimeout, idleTimeout: idleTimeout)
      source.resume()
      self.socket = socket
      self.descriptor = descriptor
      self.source = source
      self.connections = connections
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "The palantir inspector is listening.")
    }

    /// Accepts each client on a queue of its own, off the main actor, up to
    /// `maximumConnections` at once. The descriptor closes in the source's cancel handler, once no
    /// handler can still be using it.
    nonisolated private static func accepting(
      on descriptor: Int32, for inspector: Inspector, sendTimeout: Double, idleTimeout: Double
    ) -> (source: any DispatchSourceRead, connections: Connections) {
      let connections = Connections()
      let source = DispatchSource.makeReadSource(
        fileDescriptor: descriptor, queue: connections.queue)
      source.setEventHandler {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        guard connections.open.count < maximumConnections else {
          close(client)
          return
        }
        let connection = Connection(
          descriptor: client, inspector: inspector, sendTimeout: sendTimeout,
          idleTimeout: idleTimeout,
          closed: { id in connections.queue.async { connections.open[id] = nil } })
        connections.open[ObjectIdentifier(connection)] = connection
        connection.start()
      }
      source.setCancelHandler { close(descriptor) }
      return (source, connections)
    }

    /// Stops listening, closes every connection and removes the socket.
    package func stop() {
      guard !stopped else { return }
      stopped = true
      source.cancel()
      connections.queue.async {
        for connection in self.connections.open.values { connection.shutDown() }
      }
      unlink(socket.path)
      ProcessInfo.processInfo.endActivity(activity)
    }
  }

  /// The clients connected, kept on the listener's queue only.
  private final class Connections: @unchecked Sendable {
    let queue = DispatchQueue(label: "palantir.inspector")
    var open: [ObjectIdentifier: Connection] = [:]
  }

  /// One client: reads request lines and answers them one at a time, in order.
  private final class Connection: @unchecked Sendable {
    // Everything below is touched on `queue` only.
    private let descriptor: Int32
    private let inspector: Inspector
    private let idleTimeout: Double
    private let closed: @Sendable (ObjectIdentifier) -> Void
    private let queue = DispatchQueue(label: "palantir.inspector.connection")
    private var source: (any DispatchSourceRead)?
    private var reading = false
    private var idle: DispatchWorkItem?
    private var buffer = Data()
    private var answering = false
    private var ended = false
    private var cancelled = false
    private var shut = false

    init(
      descriptor: Int32, inspector: Inspector, sendTimeout: Double, idleTimeout: Double,
      closed: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
      self.descriptor = descriptor
      self.inspector = inspector
      self.idleTimeout = idleTimeout
      self.closed = closed
      var on: Int32 = 1
      // A client that leaves before its answer must not kill palantir with SIGPIPE.
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var limit = timeval(
        tv_sec: Int(sendTimeout), tv_usec: Int32((sendTimeout - sendTimeout.rounded(.down)) * 1e6))
      setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    func start() {
      queue.async {
        let source = DispatchSource.makeReadSource(
          fileDescriptor: self.descriptor, queue: self.queue)
        source.setEventHandler { self.read() }
        // The descriptor closes here, once no handler can still be reading it.
        source.setCancelHandler {
          self.cancelled = true
          self.closeIfDone()
        }
        self.source = source
        source.resume()
        self.reading = true
        self.armIdle()
      }
    }

    /// Closes the connection, from the listener stopping.
    func shutDown() { queue.async { self.drop() } }

    /// Reading goes on only while no complete line waits for its answer.
    private func pauseReading() {
      guard reading else { return }
      source?.suspend()
      reading = false
    }

    private func resumeReading() {
      guard !reading else { return }
      source?.resume()
      reading = true
    }

    private func armIdle() {
      idle?.cancel()
      let item = DispatchWorkItem { [weak self] in self?.drop() }
      idle = item
      queue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func disarmIdle() {
      idle?.cancel()
      idle = nil
    }

    private func read() {
      var chunk = [UInt8](repeating: 0, count: 65_536)
      let count = Darwin.read(descriptor, &chunk, chunk.count)
      if count < 0, errno == EINTR || errno == EAGAIN { return }
      guard count > 0 else { return end() }
      buffer.append(contentsOf: chunk.prefix(count))
      // The limit holds for what is unanswered, a complete line included, before any dispatch.
      guard buffer.count <= InspectorListener.maximumRequest else { return drop() }
      armIdle()
      answerNext()
    }

    /// Answers the next complete line unless one is being answered; the next waits for its reply.
    private func answerNext() {
      guard !answering else { return }
      // Blank lines go in one step, however many there are.
      buffer.removeSubrange(
        buffer.startIndex..<(buffer.firstIndex { $0 != 0x0A } ?? buffer.endIndex))
      guard let newline = buffer.firstIndex(of: 0x0A) else {
        resumeReading()
        return closeIfDone()
      }
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      answering = true
      pauseReading()
      disarmIdle()
      let inspector = inspector
      Task { @MainActor in
        let reply = await inspector.respond(to: line)
        self.queue.async { self.write(reply + [0x0A]) }
      }
    }

    private func write(_ data: Data) {
      let sent = data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          // A client that stopped reading makes the write time out after `sendTimeout`.
          guard written > 0 else { return false }
          offset += written
        }
        return true
      }
      answering = false
      if sent {
        armIdle()
        answerNext()
      } else {
        drop()
      }
    }

    /// The client is done writing: the lines it sent are answered, then the connection closes.
    private func end() {
      ended = true
      disarmIdle()
      if let source {
        resumeReading()
        source.cancel()
        self.source = nil
      }
      answerNext()
    }

    /// Closes the connection without answering what is left.
    private func drop() {
      buffer.removeAll()
      end()
    }

    private func closeIfDone() {
      guard ended, cancelled, !answering, !shut else { return }
      shut = true
      close(descriptor)
      closed(ObjectIdentifier(self))
    }
  }
#endif
