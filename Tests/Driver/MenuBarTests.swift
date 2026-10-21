import Testing

@testable import PalantirDriver

@Suite(.layer(.unit))
struct MenuBarTests {
  @Test func noKeyEquivalentPrintsADash() {
    #expect(KeyEquivalent.text(char: "", virtualKey: nil, modifiers: 0) == "-")
    #expect(KeyEquivalent.text(char: nil, virtualKey: nil, modifiers: 0) == "-")
  }

  @Test func modifierZeroIsCommandAlone() {
    #expect(KeyEquivalent.text(char: "o", virtualKey: nil, modifiers: 0) == "cmd+o")
  }

  @Test func theModifierBitsAddShiftOptionAndControl() {
    #expect(KeyEquivalent.text(char: "g", virtualKey: nil, modifiers: 0b0001) == "cmd+shift+g")
    #expect(KeyEquivalent.text(char: "h", virtualKey: nil, modifiers: 0b0011) == "cmd+shift+opt+h")
    #expect(KeyEquivalent.text(char: "f", virtualKey: nil, modifiers: 0b0100) == "cmd+ctrl+f")
  }

  @Test func bitThreeDropsCommand() {
    #expect(KeyEquivalent.text(char: "a", virtualKey: nil, modifiers: 0b1000) == "a")
    #expect(KeyEquivalent.text(char: "a", virtualKey: nil, modifiers: 0b1010) == "opt+a")
  }

  @Test func aCapitalCharacterIsLowercased() {
    #expect(KeyEquivalent.text(char: "G", virtualKey: nil, modifiers: 1) == "cmd+shift+g")
  }

  @Test func aVirtualKeyNamesAKeyWithNoCharacter() {
    #expect(KeyEquivalent.text(char: "", virtualKey: 125, modifiers: 8) == "down")
    #expect(KeyEquivalent.text(char: nil, virtualKey: 36, modifiers: 0) == "cmd+return")
  }

  @Test func aControlCharacterFallsBackToTheVirtualKey() {
    #expect(KeyEquivalent.text(char: "\u{1b}", virtualKey: 53, modifiers: 2) == "cmd+opt+escape")
    #expect(KeyEquivalent.text(char: "\u{F702}", virtualKey: 123, modifiers: 4) == "cmd+ctrl+left")
    #expect(KeyEquivalent.text(char: "\t", virtualKey: nil, modifiers: 4) == "-")
  }

  @Test func theTextParsesAsAChord() throws {
    let text = KeyEquivalent.text(char: "g", virtualKey: nil, modifiers: 1)
    #expect(try Chord(text) == Chord.goToFolder)
  }

  /// A clock that only moves when the code sleeps.
  final class Clock: @unchecked Sendable {
    var time = 0.0
    var slept = 0
  }

  @Test func anItemThatEnablesAfterADelayIsPressed() {
    let clock = Clock()
    let enabled = MenuBar.becomesEnabled(
      read: { clock.time >= 0.2 }, now: { clock.time },
      sleep: {
        clock.time += $0
        clock.slept += 1
      })
    #expect(enabled)
    #expect(clock.slept == 4)
  }

  @Test func anItemThatNeverEnablesIsRefusedAboutASecondLater() {
    let clock = Clock()
    let enabled = MenuBar.becomesEnabled(
      read: { false }, now: { clock.time },
      sleep: {
        clock.time += $0
        clock.slept += 1
      })
    #expect(!enabled)
    #expect(clock.time >= MenuBar.enableTimeout - 0.001 && clock.time < MenuBar.enableTimeout + 0.1)
  }

  @Test func anItemEnabledAtOnceNeedsNoWaitAtAll() {
    let clock = Clock()
    #expect(
      MenuBar.becomesEnabled(read: { true }, now: { clock.time }, sleep: { clock.time += $0 }))
    #expect(clock.time <= MenuBar.enablePoll + 0.001)
  }
}
