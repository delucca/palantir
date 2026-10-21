#if DEBUG
  package import AppKit

  /// A feature's part of the inspector's state.
  @MainActor package protocol StateSection {
    /// The section's key in the state: the feature's name in lowercase, such as "notebook".
    var name: String { get }
    /// The feature's state as its layout probes measure it, read without changing anything.
    func state() throws -> any Encodable
  }

  /// Answers requests about one window: its state, whether its layout has settled, and renderings
  /// of its content. It never drives the app.
  @MainActor package final class Inspector {
    private let window: @MainActor () -> NSWindow?
    package let sections: [any StateSection]

    package init(window: @escaping @MainActor () -> NSWindow?, sections: [any StateSection]) {
      self.window = window
      self.sections = sections
    }

    /// The response line to a request line, without the newline.
    package func respond(to line: Data) async -> Data {
      let envelope: Envelope
      do {
        envelope = try JSONDecoder().decode(Envelope.self, from: line)
      } catch {
        // JSON that is not a request, such as a number where the method belongs, is not a parse error.
        let isJSON =
          (try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed)) != nil
        return Self.encode(
          InspectorResponse<NoParams>(
            id: nil, result: nil,
            error: isJSON ? .invalidRequest("not a JSON-RPC 2.0 request") : .parse("\(error)")))
      }
      let id = envelope.id
      func failure(_ error: InspectorError) -> Data {
        Self.encode(InspectorResponse<NoParams>(id: id, result: nil, error: error))
      }
      guard envelope.jsonrpc == "2.0", let name = envelope.method else {
        return failure(.invalidRequest("not a JSON-RPC 2.0 request"))
      }
      guard let method = InspectorMethod(rawValue: name) else {
        return failure(.methodNotFound(name))
      }
      do {
        switch method {
        case .state:
          return Self.encode(InspectorResponse(id: id, result: try state(), error: nil))
        case .wait:
          let params = try Self.params(WaitParams.self, in: line)
          let result = try await waitForSettledLayout(timeout: params?.timeout)
          return Self.encode(InspectorResponse(id: id, result: result, error: nil))
        case .screenshot:
          let params = try Self.params(ScreenshotParams.self, in: line)
          let result = try await screenshot(of: params?.rect, timeout: params?.timeout)
          return Self.encode(InspectorResponse(id: id, result: result, error: nil))
        }
      } catch let error as InspectorError {
        return failure(error)
      } catch {
        return failure(.stateUnavailable("\(error)"))
      }
    }

    /// The window and every section's state.
    package func state() throws -> InspectorState {
      guard let window = window() else { throw InspectorError.noWindow }
      var states: [String: any Encodable] = [:]
      for section in sections { states[section.name] = try section.state() }
      return InspectorState(window: WindowState(window), sections: states)
    }

    /// Answers once the window has no layout or display pending and what layout decides has stayed
    /// the same for `Settling.quietLooks` looks in a row.
    package func waitForSettledLayout(timeout: Double?) async throws -> WaitResult {
      let timeout = timeout ?? Settling.defaultTimeout
      guard Settling.takes(timeout) else {
        throw InspectorError.invalidParams(
          "timeout \(timeout) is not above 0 and at most \(Settling.maximumTimeout) seconds")
      }
      let clock = ContinuousClock()
      let start = clock.now
      var last: Data?
      var quiet = 0
      var looks = 0
      var unsettled = ""
      while true {
        guard let window = window() else { throw InspectorError.noWindow }
        looks += 1
        if let pending = Settling.pending(window) {
          // Off the screen no display cycle does the work, so it would never settle by itself.
          guard window.isVisible, !window.isMiniaturized else {
            throw InspectorError.unavailable(
              "the window is \(window.isMiniaturized ? "minimized" : "hidden") and \(pending)")
          }
          quiet = 0
          last = nil
          unsettled = pending
        } else {
          let now = try layout()
          quiet = now == last ? quiet + 1 : 1
          last = now
          unsettled = "the state is still changing"
          if quiet >= Settling.quietLooks {
            return WaitResult(waited: (clock.now - start) / .seconds(1), looks: looks)
          }
        }
        guard clock.now - start < .seconds(timeout) else {
          throw InspectorError.notSettled(after: timeout, unsettled)
        }
        try await Task.sleep(for: Settling.interval)
      }
    }

    /// What layout decides: the window's frame and each section's state. Which window is key and
    /// whether palantir is active change with focus, not with layout.
    private func layout() throws -> Data {
      let state = try state()
      var layout = Self.encode(state.window.frame) + Self.encode(state.window.content)
      for name in state.sections.keys.sorted() {
        if let section = state.sections[name] { layout += Self.encode(section) }
      }
      return layout
    }

    /// The window's content, or the part of it in `rect`, rendered at the display's resolution
    /// once layout has settled.
    package func screenshot(of rect: Rect?, timeout: Double?) async throws -> ScreenshotResult {
      _ = try await waitForSettledLayout(timeout: timeout)
      guard let window = window() else { throw InspectorError.noWindow }
      return try Screenshot.render(window, rect)
    }

    private struct Envelope: Decodable {
      var jsonrpc: String?
      var id: RequestID?
      var method: String?
    }

    private static func params<Params: Codable & Sendable>(
      _ type: Params.Type, in line: Data
    ) throws -> Params? {
      do {
        return try JSONDecoder().decode(InspectorRequest<Params>.self, from: line).params
      } catch {
        throw InspectorError.invalidParams("\(error)")
      }
    }

    static func encode(_ value: some Encodable) -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      // Every value the inspector encodes is plain data: strings, numbers and arrays of them.
      return try! encoder.encode(value)
    }
  }

  /// How the inspector decides that layout has settled.
  package enum Settling {
    /// The time between two looks at the window, about a frame at 60 Hz.
    static let interval = Duration.milliseconds(16)
    /// How many looks in a row must find nothing pending and the same state.
    static let quietLooks = 4
    /// Seconds `wait` and `screenshot` wait for settled layout when the request names none.
    package static let defaultTimeout = 5.0
    /// The longest timeout `wait` and `screenshot` take, and the CLI accepts.
    package static let maximumTimeout = 600.0

    /// Whether `seconds` is a timeout the inspector takes: finite, above 0, at most the maximum.
    package static func takes(_ seconds: Double) -> Bool {
      seconds.isFinite && seconds > 0 && seconds <= maximumTimeout
    }

    /// The layout or display the window still has to do, such as "NSClipView needs display", or
    /// nil.
    @MainActor static func pending(_ window: NSWindow) -> String? {
      if let view = window.contentView, let work = work(view) { return work }
      return window.viewsNeedDisplay ? "the window needs display" : nil
    }

    @MainActor private static func work(_ view: NSView) -> String? {
      let name = String(describing: type(of: view))
      if view.needsUpdateConstraints { return "\(name) needs constraints" }
      if view.needsLayout { return "\(name) needs layout" }
      if view.needsDisplay { return "\(name) needs display" }
      return view.subviews.lazy.compactMap(work).first
    }
  }

  extension WindowState {
    @MainActor init(_ window: NSWindow) {
      let screenTop = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
      let frame = window.frame
      self.init(
        frame: Rect(
          x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height),
        content: Size(
          width: window.contentLayoutRect.width, height: window.contentLayoutRect.height),
        scale: window.backingScaleFactor,
        isKey: window.isKeyWindow,
        isVisible: window.isVisible,
        isMiniaturized: window.isMiniaturized,
        isActive: NSApp.isActive)
    }
  }
#endif
