#if DEBUG
  import Darwin
  package import Foundation

  /// The CLI's side of the socket: one request line out, one response line back.
  package struct InspectorClient: Sendable {
    package let pid: pid_t
    package let socket: URL

    /// The inspector of `pid`, or of the only palantir listening when `pid` is nil.
    package init(pid: pid_t?, directory: URL = SocketDirectory.url) throws {
      if let pid {
        self.pid = pid
        socket = SocketDirectory.socket(for: pid, in: directory)
        return
      }
      let sockets = SocketDirectory.sockets(in: directory)
      guard let only = sockets.first else { throw SocketError.noInspector }
      guard sockets.count == 1 else { throw SocketError.severalInspectors(sockets.map(\.pid)) }
      self.pid = only.pid
      socket = only.url
    }

    /// The response line to a request for `method`, waiting at most `timeout` seconds for it.
    package func call(
      _ method: InspectorMethod, _ params: some Codable & Sendable, timeout: Double
    ) throws -> Data {
      guard var address = socketAddress(socket) else { throw SocketError.pathTooLong(socket.path) }
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
      defer { close(descriptor) }
      var on: Int32 = 1
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      guard timeout.isFinite, timeout > 0 else {
        throw InspectorError.invalidParams("timeout \(timeout) is not a positive number of seconds")
      }
      var limit = timeval(tv_sec: Int(min(timeout, 86_400).rounded(.up)), tv_usec: 0)
      setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else { throw SocketError.system("connect \(socket.path)", errno) }
      var request = try JSONEncoder().encode(
        InspectorRequest(id: 1, method: method, params: params))
      request.append(0x0A)
      try request.withUnsafeBytes { bytes in
        guard Darwin.write(descriptor, bytes.baseAddress!, bytes.count) == bytes.count else {
          throw SocketError.system("write", errno)
        }
      }
      var response = Data()
      var chunk = [UInt8](repeating: 0, count: 65_536)
      while !response.contains(0x0A) {
        let count = Darwin.read(descriptor, &chunk, chunk.count)
        guard count >= 0 else { throw SocketError.system("read", errno) }
        guard count > 0 else { throw SocketError.closed }
        response.append(contentsOf: chunk.prefix(count))
      }
      return response.prefix { $0 != 0x0A }
    }

    /// The result of `method`, decoded, or the inspector's error.
    package func call<Result: Decodable & Sendable>(
      _ method: InspectorMethod, _ params: some Codable & Sendable, timeout: Double,
      as type: Result.Type
    ) throws -> Result {
      let response = try JSONDecoder().decode(
        InspectorResponse<Result>.self, from: call(method, params, timeout: timeout))
      if let error = response.error { throw error }
      guard let result = response.result else {
        throw InspectorError.invalidRequest("a response with neither a result nor an error")
      }
      return result
    }
  }
#endif
