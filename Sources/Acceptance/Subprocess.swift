import Foundation

/// What a subprocess printed and how it ended.
struct Output: Equatable {
  var exit: Int32
  var stdout: String
  var stderr: String
}

/// A subprocess that ran past its time limit, and was killed.
struct TimedOut: Error, CustomStringConvertible {
  let command: String
  let seconds: Double

  var description: String { "\(command) ran over \(Int(seconds)) s" }
}

/// Starts programs. The runner reaches palantir, jq and the system only through one of these.
protocol Runner {
  /// Runs `program` to its end.
  ///
  /// - Throws: `TimedOut` after `timeout` seconds, the program killed.
  func run(_ program: String, _ arguments: [String], stdin: Data?, timeout: Double) throws -> Output
}

extension Runner {
  func run(_ program: String, _ arguments: [String], timeout: Double = Settings.subprocessTimeout)
    throws -> Output
  { try run(program, arguments, stdin: nil, timeout: timeout) }
}

/// The real runner. It records every program it started, for `replay.json`.
final class SystemRunner: Runner, @unchecked Sendable {
  private static let spawn = NSLock()
  private let lock = NSLock()
  private var started: Set<String> = []

  /// The programs started so far, sorted.
  var programs: [String] {
    lock.withLock { started.sorted() }
  }

  func run(_ program: String, _ arguments: [String], stdin: Data?, timeout: Double) throws -> Output
  {
    lock.withLock { _ = started.insert(program) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = arguments
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    // A process started while another one's pipe ends are open inherits them, and then neither
    // sees its input end: the pipes live only inside this lock.
    Self.spawn.lock()
    let out = Pipe()
    let err = Pipe()
    let input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = input
    do { try process.run() } catch {
      Self.spawn.unlock()
      throw error
    }
    try? out.fileHandleForWriting.close()
    try? err.fileHandleForWriting.close()
    try? input.fileHandleForReading.close()
    let stdout = Capture(out.fileHandleForReading)
    let stderr = Capture(err.fileHandleForReading)
    if let stdin { try? input.fileHandleForWriting.write(contentsOf: stdin) }
    try? input.fileHandleForWriting.close()
    Self.spawn.unlock()
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
      }
      throw TimedOut(
        command: ([program] + arguments).joined(separator: " "), seconds: timeout)
    }
    return Output(
      exit: process.terminationStatus, stdout: stdout.text, stderr: stderr.text)
  }
}

/// Reads a pipe to its end on another thread.
private final class Capture: @unchecked Sendable {
  private let done = DispatchSemaphore(value: 0)
  private var data = Data()

  /// Dispatch's pool is not used: a caller blocked on it from a busy pool would starve the read.
  init(_ handle: FileHandle) {
    let reader = Thread { [self] in
      data = (try? handle.readToEnd()) ?? Data()
      done.signal()
    }
    reader.start()
  }

  var text: String {
    done.wait()
    return String(decoding: data, as: UTF8.self)
  }
}
