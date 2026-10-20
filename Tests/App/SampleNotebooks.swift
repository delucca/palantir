import Foundation
import PalantirNotebookUI

@MainActor
func temporaryNotebook(_ data: Data) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: "notebook.md")
  try data.write(to: url)
  return url
}

@MainActor
func temporaryNotebook(_ text: String) throws -> URL {
  try temporaryNotebook(Data(text.utf8))
}

@MainActor
func removeTemporaryNotebook(_ url: URL) {
  try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@MainActor
func openNotebook(_ text: String) throws -> NotebookWindowController {
  let controller = NotebookWindowController()
  let url = try temporaryNotebook(text)
  defer { removeTemporaryNotebook(url) }
  try controller.open(url)
  return controller
}

@MainActor
func longNotebook(before: Int, owned: Int, after: Int) -> String {
  (1...before).map { "Filler line \($0).\n" }.joined() + "# Tasks\n## Fix the reaper\n"
    + (1...owned).map { "It leaks, line \($0).\n" }.joined() + "# Notes\n"
    + (1...after).map { "Filler line \($0).\n" }.joined()
}

@MainActor
func sectionsNotebook() -> String {
  "Intro.\n"
    + (1...10).map { section in
      "# Section \(section)\n" + (1...100).map { "Body \(section).\($0)\n" }.joined()
    }.joined()
}

@MainActor
func wrappingSectionsNotebook() -> String {
  let words = String(repeating: "word ", count: 30)
  return "Intro.\n"
    + (1...10).map { section in
      "# Section \(section)\n" + (1...60).map { "Body \(section).\($0) \(words)\n" }.joined()
    }.joined()
}

@MainActor
func wrappingPartsNotebook() -> String {
  let words = String(repeating: "word ", count: 30)
  return "Intro.\n"
    + (1...12).map { part in
      "# Part \(part)\n"
        + (1...4).map { item in
          "## Item \(part).\(item)\n"
            + (1...6).map { "Body \(part).\(item).\($0) \(words)\n" }.joined()
        }.joined()
    }.joined()
}

extension String {
  /// The text with each range removed; a range inside another goes with it.
  func removing(_ ranges: [NSRange]) -> String {
    let result = NSMutableString(string: self)
    let outer = ranges.filter { range in
      !ranges.contains { $0 != range && NSLocationInRange(range.location, $0) }
    }
    for range in outer.sorted(by: { $0.location > $1.location }) {
      result.deleteCharacters(in: range)
    }
    return result as String
  }
}
