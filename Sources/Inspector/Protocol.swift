#if DEBUG
  package import CoreGraphics
  package import Foundation

  /// A method the inspector answers. Each one only reads: none clicks, types, scrolls or runs a
  /// command.
  package enum InspectorMethod: String, CaseIterable, Codable, Sendable {
    /// The window and one section per wired feature: `InspectorState`.
    case state
    /// Answers once the window has no layout or display pending and its state has stopped
    /// changing: `WaitParams`, `WaitResult`.
    case wait
    /// A PNG of the window's content at the display's resolution, whole or cropped, rendered once
    /// layout has settled: `ScreenshotParams`, `ScreenshotResult`.
    case screenshot
  }

  /// A JSON-RPC 2.0 request id, a number or a string.
  package enum RequestID: Codable, Equatable, Sendable {
    case number(Int)
    case string(String)

    package init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Int.self) {
        self = .number(number)
      } else {
        self = .string(try container.decode(String.self))
      }
    }

    package func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .number(let number): try container.encode(number)
      case .string(let string): try container.encode(string)
      }
    }
  }

  /// A JSON-RPC 2.0 request, sent as one line.
  package struct InspectorRequest<Params: Codable & Sendable>: Codable, Sendable {
    package var jsonrpc = "2.0"
    package var id: RequestID?
    package var method: String
    package var params: Params?

    package init(id: Int, method: InspectorMethod, params: Params?) {
      self.id = .number(id)
      self.method = method.rawValue
      self.params = params
    }
  }

  /// A JSON-RPC 2.0 response, sent as one line: a result or an error.
  package struct InspectorResponse<Result> {
    package var jsonrpc = "2.0"
    package var id: RequestID?
    package var result: Result?
    package var error: InspectorError?

    package init(id: RequestID?, result: Result?, error: InspectorError?) {
      self.id = id
      self.result = result
      self.error = error
    }
  }

  extension InspectorResponse: Sendable where Result: Sendable {}
  extension InspectorResponse: Encodable where Result: Encodable {}
  extension InspectorResponse: Decodable where Result: Decodable {}

  /// A JSON-RPC 2.0 error.
  package struct InspectorError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    package var code: Int
    package var message: String

    package init(code: Int, message: String) {
      self.code = code
      self.message = message
    }

    package var description: String { "\(message) (\(code))" }

    package static func parse(_ message: String) -> Self { Self(code: -32_700, message: message) }
    package static func invalidRequest(_ message: String) -> Self {
      Self(code: -32_600, message: message)
    }
    package static func methodNotFound(_ method: String) -> Self {
      Self(code: -32_601, message: "no method \(method)")
    }
    package static func invalidParams(_ message: String) -> Self {
      Self(code: -32_602, message: message)
    }
    package static let noWindow = Self(code: -32_000, message: "no window to inspect")
    package static func notSettled(after seconds: Double, _ reason: String) -> Self {
      Self(code: -32_001, message: "layout did not settle within \(seconds) seconds: \(reason)")
    }
    package static func stateUnavailable(_ message: String) -> Self {
      Self(code: -32_002, message: message)
    }
    package static func unavailable(_ reason: String) -> Self {
      Self(code: -32_003, message: "layout cannot settle: \(reason)")
    }
  }

  /// Parameters a method does not take.
  package struct NoParams: Codable, Sendable {
    package init() {}
  }

  /// `wait`'s parameters.
  package struct WaitParams: Codable, Sendable {
    /// Seconds to wait before answering with an error; `Settling.defaultTimeout` if absent.
    package var timeout: Double?

    package init(timeout: Double? = nil) { self.timeout = timeout }
  }

  /// `wait`'s result.
  package struct WaitResult: Codable, Equatable, Sendable {
    /// Seconds from the request to the answer.
    package var waited: Double
    /// How many times the inspector looked at the window.
    package var looks: Int

    package init(waited: Double, looks: Int) {
      self.waited = waited
      self.looks = looks
    }
  }

  /// `screenshot`'s parameters.
  package struct ScreenshotParams: Codable, Sendable {
    /// The part of the content to render, in window points; the whole content if absent.
    package var rect: Rect?
    /// Seconds to wait for settled layout before answering with an error; `Settling.defaultTimeout`
    /// if absent.
    package var timeout: Double?

    package init(rect: Rect? = nil, timeout: Double? = nil) {
      self.rect = rect
      self.timeout = timeout
    }
  }

  /// `screenshot`'s result.
  package struct ScreenshotResult: Codable, Sendable {
    /// The PNG, base64 in JSON.
    package var png: Data
    package var width: Int
    package var height: Int
    /// Pixels per point of the window's display.
    package var scale: Double

    package init(png: Data, width: Int, height: Int, scale: Double) {
      self.png = png
      self.width = width
      self.height = height
      self.scale = scale
    }
  }

  /// What `state` answers: the window, and each wired feature's section under its name.
  package struct InspectorState: Encodable {
    package var window: WindowState
    package var sections: [String: any Encodable]

    private enum CodingKeys: String, CodingKey { case window, sections }

    package func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(window, forKey: .window)
      var nested = container.nestedContainer(keyedBy: SectionKey.self, forKey: .sections)
      for (name, section) in sections {
        try nested.encode(section, forKey: SectionKey(stringValue: name))
      }
    }

    private struct SectionKey: CodingKey {
      var stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }
  }

  /// The window palantir shows.
  package struct WindowState: Codable, Equatable, Sendable {
    /// The window's frame in screen points, from the top-left of the main display, as the
    /// accessibility tree reports it.
    package var frame: Rect
    /// The content's size in window points.
    package var content: Size
    /// Pixels per point of the window's display.
    package var scale: Double
    package var isKey: Bool
    package var isVisible: Bool
    package var isMiniaturized: Bool
    /// Whether palantir is the active app, the one that gets the keys.
    package var isActive: Bool

    package init(
      frame: Rect, content: Size, scale: Double, isKey: Bool, isVisible: Bool,
      isMiniaturized: Bool, isActive: Bool
    ) {
      self.frame = frame
      self.content = content
      self.scale = scale
      self.isKey = isKey
      self.isVisible = isVisible
      self.isMiniaturized = isMiniaturized
      self.isActive = isActive
    }
  }

  /// A rectangle in points, its origin at the top-left, y growing down.
  package struct Rect: Codable, Equatable, Sendable {
    package var x: Double
    package var y: Double
    package var width: Double
    package var height: Double

    package init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }

    package init(_ rect: CGRect) {
      self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    package var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  }

  package struct Size: Codable, Equatable, Sendable {
    package var width: Double
    package var height: Double

    package init(width: Double, height: Double) {
      self.width = width
      self.height = height
    }
  }
#endif
