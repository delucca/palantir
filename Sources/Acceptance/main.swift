import Foundation

do {
  try run(Array(CommandLine.arguments.dropFirst()))
} catch let error as Usage {
  FileHandle.standardError.write(Data("palantir-accept: \(error.message)\n\n\(usage)\n".utf8))
  exit(64)
} catch let error as NoVerdict {
  FileHandle.standardError.write(Data("palantir-accept: \(error.kind.rawValue): \(error)\n".utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data("palantir-accept: \(error)\n".utf8))
  exit(2)
}
