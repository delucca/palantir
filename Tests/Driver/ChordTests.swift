import CoreGraphics
import Testing

@testable import PalantirDriver

struct ChordTests {
  @Test func aChordIsModifiersAndOneKey() throws {
    #expect(try Chord("cmd+shift+g") == Chord(key: 5, flags: [.maskCommand, .maskShift]))
    #expect(try Chord("a") == Chord(key: 0, flags: []))
    #expect(try Chord("Return") == Chord(key: 36, flags: []))
  }

  @Test func arrowsAndPageKeysAreFunctionKeys() throws {
    #expect(try Chord("down").flags == [.maskSecondaryFn, .maskNumericPad])
    #expect(try Chord("shift+pagedown").flags == [.maskShift, .maskSecondaryFn, .maskNumericPad])
  }

  @Test(arguments: ["", "cmd", "cmd+hyper+a", "a+b", "f13"])
  func aChordWithoutExactlyOneKnownKeyIsAnError(text: String) {
    #expect(throws: DriverError.self) { try Chord(text) }
  }

  @Test func goToFolderIsCommandShiftG() throws {
    #expect(try Chord("cmd+shift+g") == Chord.goToFolder)
  }

  @Test(arguments: ["cmd+shift+g", "cmd+q", "cmd+w", "cmd+h", "opt+cmd+h", "cmd+m", "cmd+a"])
  func theSystemStreamCarriesNoCommandKey(text: String) throws {
    let chord = try Chord(text)
    #expect(throws: DriverError.self) { try Input.checkSystemStream(chord, forPanel: false) }
  }

  @Test func onlyAnOpenPanelsInputSendsCommandShiftGAndNoOtherCommandKey() throws {
    #expect(throws: Never.self) { try Input.checkSystemStream(Chord.goToFolder, forPanel: true) }
    #expect(throws: DriverError.self) {
      try Input.checkSystemStream(try Chord("cmd+q"), forPanel: true)
    }
    for text in ["return", "escape", "a", "shift+left"] {
      #expect(throws: Never.self) { try Input.checkSystemStream(try Chord(text), forPanel: false) }
    }
  }

  @Test func aMenuPathIsItsTitles() {
    #expect(MenuBar.titles("View > Fold All") == ["View", "Fold All"])
    #expect(MenuBar.titles("File > Open…") == ["File", "Open…"])
  }
}
