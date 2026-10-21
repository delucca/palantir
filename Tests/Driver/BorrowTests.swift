import Foundation
import Testing

@testable import PalantirDriver

struct BorrowTests {
  private let previous: pid_t = 4_242

  /// A record in a folder of its own, removed when the test ends.
  private func withRecord(_ body: (FrontRecord) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "borrow-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(FrontRecord(palantir: 1, in: directory))
  }

  @Test func theFrontGoesBackWhenActivatingFailsAfterTakingIt() throws {
    try withRecord { record in
      var recordedFirst = false
      var givenBack: [pid_t] = []
      #expect(throws: DriverError.self) {
        try Borrow.run(
          from: previous, record: record,
          activate: {
            recordedFirst = record.saved == previous
            throw DriverError("palantir took the front but its window never came up")
          },
          input: { Issue.record("the input ran after a failed activation") },
          giveBack: {
            givenBack.append($0)
            return true
          })
      }
      #expect(recordedFirst)
      #expect(givenBack == [previous])
      #expect(record.saved == nil)
    }
  }

  @Test func aFrontThatDidNotGoBackKeepsItsRecord() throws {
    try withRecord { record in
      #expect(throws: DriverError.self) {
        try Borrow.run(
          from: previous, record: record, activate: {}, input: {}, giveBack: { _ in false })
      }
      #expect(record.saved == previous)
      #expect(throws: DriverError.self) {
        try Borrow.restore(record: record, to: nil, giveBack: { _ in false })
      }
      #expect(record.saved == previous)
      try Borrow.restore(record: record, to: nil, giveBack: { $0 == previous })
      #expect(record.saved == nil)
    }
  }

  @Test func aFailedInputAndAFailedGiveBackAreBothReported() throws {
    try withRecord { record in
      do {
        try Borrow.run(
          from: previous, record: record, activate: {},
          input: { throw DriverError("the input failed") }, giveBack: { _ in false })
        Issue.record("the borrow did not fail")
      } catch {
        let message = "\(error)"
        #expect(message.contains("the input failed"))
        #expect(message.contains("palantir-drive restore"))
      }
      #expect(record.saved == previous)
    }
  }

  @Test func onlyPalantirsFrontIsGivenBackAndOnlyAFrontBackClearsTheRecord() {
    let palantir: pid_t = 1
    #expect(Borrow.step(front: previous, palantir: palantir, previous: previous) == .done)
    #expect(Borrow.step(front: palantir, palantir: palantir, previous: previous) == .bringBack)
    // The person moved to a third app: its front stays, and so does the record.
    #expect(Borrow.step(front: 77, palantir: palantir, previous: previous) == .leave)
    #expect(Borrow.step(front: nil, palantir: palantir, previous: previous) == .leave)
  }
}
