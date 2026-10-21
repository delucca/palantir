#if DEBUG
  import AppKit
  package import PalantirInspector
  import PalantirNotebook
  package import PalantirNotebookUI

  /// The notebook's section of the inspector's state, measured by the layout probes from what
  /// the last viewport layout drew, without laying anything out. Rects are in window points from
  /// the content's top-left corner, the coordinates of a screenshot's crop.
  package struct NotebookState: Codable, Equatable, Sendable {
    /// A folded heading: the offset of its first character and its first line.
    package struct Heading: Codable, Equatable, Sendable {
      package var offset: Int
      package var line: String
    }

    /// A paragraph drawn in the window: its first character's offset, its text and its rect.
    package struct Line: Codable, Equatable, Sendable {
      package var offset: Int
      package var text: String
      package var rect: Rect
    }

    /// Two drawn paragraphs with space between them, negative where they overlap.
    package struct Gap: Codable, Equatable, Sendable {
      package var after: Int
      package var before: Int
      package var height: Double
    }

    /// The marker of a folded heading on screen.
    package struct Marker: Codable, Equatable, Sendable {
      package var heading: Int
      package var label: String?
      package var rect: Rect
    }

    package struct Selection: Codable, Equatable, Sendable {
      package var location: Int
      package var length: Int
    }

    /// How far the text is scrolled, in points: the top of the window in the text, the window's
    /// height and the height of the scrollable text.
    package struct Scroll: Codable, Equatable, Sendable {
      package var y: Double
      package var height: Double
      package var documentHeight: Double
    }

    /// The text's length in UTF-16 code units, the unit of every offset.
    package var length: Int
    package var folded: [Heading]
    package var drawn: [Line]
    package var gaps: [Gap]
    package var markers: [Marker]
    package var selection: Selection
    package var scroll: Scroll

    package init(_ view: NotebookTextView) throws {
      let text = view.string as NSString
      let clip = try required(view.enclosingScrollView?.contentView, "no clip view")
      let content = try required(view.window?.contentView, "no window")
      func windowRect(_ rect: CGRect) -> Rect {
        let converted = view.convert(rect, to: content)
        return Rect(
          content.isFlipped
            ? converted
            : CGRect(
              x: converted.minX, y: content.bounds.height - converted.maxY,
              width: converted.width, height: converted.height))
      }
      length = text.length
      folded = view.folds.foldedHeadings.map {
        let line = text.substring(
          with: text.lineRange(for: NSRange(location: $0.range.location, length: 0)))
        return Heading(offset: $0.range.location, line: line.trimmingCharacters(in: .newlines))
      }
      drawn = try view.drawnParagraphs().map {
        let paragraph = text.substring(
          with: text.paragraphRange(for: NSRange(location: $0.offset, length: 0)))
        return Line(
          offset: $0.offset, text: paragraph.trimmingCharacters(in: .newlines),
          rect: windowRect($0.frame.offsetBy(dx: view.textContainerOrigin.x, dy: 0)))
      }
      gaps = try view.drawnGaps().map { Gap(after: $0.after, before: $0.before, height: $0.height) }
      markers = view.foldedMarkers.sorted { $0.key < $1.key }.map {
        Marker(
          heading: $0.key, label: $0.value.accessibilityLabel(),
          rect: windowRect($0.value.frame))
      }
      let selected = view.selectedRange()
      selection = Selection(location: selected.location, length: selected.length)
      scroll = Scroll(
        y: clip.bounds.minY, height: clip.bounds.height, documentHeight: view.frame.height)
    }
  }

  /// The notebook's state section.
  struct NotebookStateSection: StateSection {
    let view: NotebookTextView

    var name: String { "notebook" }

    func state() throws -> any Encodable { try NotebookState(view) }
  }

  extension NotebookWindowController {
    /// The notebook's section of the inspector's state, for the app to wire in.
    package func makeStateSection() -> any StateSection {
      NotebookStateSection(view: textView)
    }
  }
#endif
