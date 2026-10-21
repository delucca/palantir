import Testing

@testable import PalantirDriver

struct ArgumentsTests {
  @Test(arguments: ["-2147483648", "2147483647", "1001", "-1001", "x", ""])
  func aScrollOutOfBoundsIsAUsageError(text: String) {
    #expect(throws: Usage.self) { try Arguments.scrollLines(text) }
  }

  @Test func aScrollWithinBoundsIsTaken() throws {
    #expect(try Arguments.scrollLines("-1000") == -1000)
    #expect(try Arguments.scrollLines("5") == 5)
  }

  @Test(arguments: ["0", "-1", "x"])
  func aPidIsPositive(text: String) {
    #expect(throws: Usage.self) { try Arguments.pid(text, option: "--pid") }
  }

  @Test func leftoverArgumentsAreAUsageError() throws {
    #expect(throws: Usage.self) { try Arguments.noneLeft(["123"], for: "restore") }
    try Arguments.noneLeft([], for: "restore")
  }
}
