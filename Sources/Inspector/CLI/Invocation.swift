#if DEBUG
  import Darwin
  import Foundation
  import PalantirInspector

  /// A command line: the palantir to read, by pid or the only one listening, and what to ask.
  struct Invocation: Equatable {
    enum Command: Equatable {
      case state
      case wait(timeout: Double)
      case screenshot(path: String, rect: Rect?, timeout: Double)
      case list
    }

    var pid: pid_t?
    var command: Command

    struct Usage: Error, Equatable {
      let message: String

      init(_ message: String) { self.message = message }
    }

    init(pid: pid_t?, command: Command) {
      self.pid = pid
      self.command = command
    }

    init(_ arguments: [String]) throws {
      var arguments = arguments
      func option(_ name: String) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count else { throw Usage("\(name) needs a value") }
        defer { arguments.removeSubrange(index...(index + 1)) }
        return arguments[index + 1]
      }
      func seconds() throws -> Double {
        guard let text = try option("--timeout") else { return Settling.defaultTimeout }
        guard let value = Double(text), Settling.takes(value) else {
          throw Usage("--timeout \(text): above 0 and at most \(Settling.maximumTimeout) seconds")
        }
        return value
      }
      pid = try option("--pid").map {
        guard let pid = pid_t($0), pid > 0 else { throw Usage("--pid \($0)") }
        return pid
      }
      guard let name = arguments.first else { throw Usage("no command") }
      arguments.removeFirst()
      switch name {
      case "state":
        command = .state
      case "wait":
        command = .wait(timeout: try seconds())
      case "screenshot":
        let rect = try option("--rect").map(Self.rect)
        let timeout = try seconds()
        guard let path = arguments.first else { throw Usage("screenshot needs a file") }
        arguments.removeFirst()
        command = .screenshot(path: path, rect: rect, timeout: timeout)
      case "list":
        command = .list
      default:
        throw Usage("no command \(name)")
      }
      if let extra = arguments.first { throw Usage("unexpected \(extra)") }
    }

    /// A rect written as x,y,width,height in window points.
    static func rect(_ text: String) throws -> Rect {
      let numbers = text.split(separator: ",").map { Double($0) }
      guard numbers.count == 4, let x = numbers[0], let y = numbers[1], let width = numbers[2],
        let height = numbers[3]
      else { throw Usage("--rect \(text)") }
      return Rect(x: x, y: y, width: width, height: height)
    }
  }

  /// Writes a screenshot's PNG to `path` and answers what the CLI prints about it.
  func saveScreenshot(_ result: ScreenshotResult, to path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    try result.png.write(to: url)
    return [
      "path": url.path, "width": result.width, "height": result.height, "scale": result.scale,
    ]
  }
#endif
