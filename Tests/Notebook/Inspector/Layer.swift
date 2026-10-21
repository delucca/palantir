import Foundation
import Testing

/// The test layers.
///
/// `PALANTIR_TEST_LAYERS` names the ones to run, comma-separated; without it, every layer but e2e
/// runs. Every suite carries one, and every test target declares the same.
enum Layer: String {
  /// Pure logic: no window, socket or process.
  case unit
  /// Real AppKit windows and views, or real sockets, inside the test process.
  case integration
  /// Palantir launched as a process of its own, which can take the front.
  case e2e
  /// A release build of palantir, checked for what it holds.
  case release

  /// Returns the layers `PALANTIR_TEST_LAYERS` names, or every layer but e2e when it is unset.
  ///
  /// - Throws: `UnknownLayer` when a name is no layer or the value names none.
  static func selected(
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Set<Layer> {
    guard let value = environment["PALANTIR_TEST_LAYERS"] else {
      return [.unit, .integration, .release]
    }
    let layers = try value.split(separator: ",").map { name in
      guard let layer = Layer(rawValue: String(name)) else { throw UnknownLayer(name: name) }
      return layer
    }
    // An empty value would otherwise skip every test and pass.
    guard !layers.isEmpty else { throw UnknownLayer(name: Substring(value)) }
    return Set(layers)
  }
}

/// A `PALANTIR_TEST_LAYERS` value that names something other than a layer.
struct UnknownLayer: Error, CustomStringConvertible {
  /// The name that matched no layer, or the whole value when it names none.
  let name: Substring
  var description: String { "PALANTIR_TEST_LAYERS names \"\(name)\", which is no layer" }
}

extension Trait where Self == ConditionTrait {
  /// Returns a condition that enables a suite or test only when `environment` selects its layer.
  static func layer(
    _ layer: Layer, in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    .enabled("its layer is not selected") { try Layer.selected(in: environment).contains(layer) }
  }
}
