#if DEBUG
  import Darwin
  package import Foundation

  /// Where inspectors listen: one socket per palantir process, named by its pid, in a directory
  /// only the user can open.
  package enum SocketDirectory {
    /// `palantir-inspector` in the user's own temporary directory.
    package static var url: URL {
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
      let temporary =
        length > 0
        ? String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        : NSTemporaryDirectory()
      return URL(fileURLWithPath: temporary, isDirectory: true).appending(
        path: "palantir-inspector", directoryHint: .isDirectory)
    }

    package static func socket(for pid: pid_t, in directory: URL = url) -> URL {
      directory.appending(path: "\(pid).sock")
    }

    /// The sockets of the palantir processes still running that take a connection, by pid. A pid
    /// the system gave to another process after a crash is running, but its socket is dead.
    package static func sockets(in directory: URL = url) -> [(pid: pid_t, url: URL)] {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      return names.compactMap { name in
        guard name.hasSuffix(".sock"), let pid = pid_t(name.dropLast(5)), isRunning(pid),
          accepts(directory.appending(path: name))
        else {
          return nil
        }
        return (pid, directory.appending(path: name))
      }
      .sorted { $0.pid < $1.pid }
    }

    /// Whether something is listening on the socket at `url`.
    static func accepts(_ url: URL) -> Bool {
      guard var address = socketAddress(url) else { return false }
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { return false }
      defer { close(descriptor) }
      return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      } == 0
    }

    package static func isRunning(_ pid: pid_t) -> Bool {
      kill(pid, 0) == 0 || errno == EPERM
    }

    /// Creates the directory with mode 0700, or checks that the one there is a real directory the
    /// user owns and only the user can open, and removes the sockets of processes that are gone.
    static func prepare(_ directory: URL) throws {
      if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
        throw SocketError.system("mkdir \(directory.path)", errno)
      }
      var info = stat()
      guard lstat(directory.path, &info) == 0 else {
        throw SocketError.system("lstat \(directory.path)", errno)
      }
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0
      else {
        throw SocketError.unsafeDirectory(directory.path)
      }
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in names where name.hasSuffix(".sock") {
        if let pid = pid_t(name.dropLast(5)), !isRunning(pid) {
          unlink(directory.appending(path: name).path)
        }
      }
    }
  }

  package enum SocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case unsafeDirectory(String)
    case pathTooLong(String)
    case noInspector
    case severalInspectors([pid_t])
    case closed

    package var description: String {
      switch self {
      case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
      case .unsafeDirectory(let path):
        "\(path) is not a directory that only this user owns and opens"
      case .pathTooLong(let path): "socket path longer than sun_path allows: \(path)"
      case .noInspector: "no palantir is listening; launch a debug build with --inspector"
      case .severalInspectors(let pids):
        "several palantirs are listening (pids \(pids.map(String.init).joined(separator: ", "))); pass --pid"
      case .closed: "the inspector closed the connection"
      }
    }
  }

  /// A `sockaddr_un` for `url`, or nil when its path does not fit in `sun_path`.
  func socketAddress(_ url: URL) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(url.path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { path in
      path.copyBytes(from: bytes)
      path[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }
#endif
