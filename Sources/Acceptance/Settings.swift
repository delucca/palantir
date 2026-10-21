import Foundation

/// The layer's tunables.
enum Settings {
  /// The version of the check format `check.json` declares.
  static let checkFormat = 1
  /// The longest `sleep` action, in seconds.
  static let sleepLimit = 5.0
  /// The rounds a `repeat` action runs when it names no `max`, and the most it may name.
  static let repeatDefault = 50
  static let repeatLimit = 200
  /// The rules the layer gives no check: the inspector's report of the notebook's state, which only
  /// restates what every other check reads, and the layer's own rules.
  static let uncheckedRules: Set<String> = ["inspector.notebook-state"]
  static let uncheckedFeatures: Set<String> = ["acceptance"]

  /// How long a launched palantir has to answer, in seconds, from `open` to its first answer.
  static let launchDeadline = 15.0
  /// How long one subprocess may run, in seconds.
  static let subprocessTimeout = 60.0
  /// How long one replay may run, in seconds.
  static let replayDeadline = 180.0
  /// How long a palantir has to exit after its Quit menu item, in seconds.
  static let quitGrace = 5.0
  /// The timeout, in seconds, of one readiness probe while a launch waits.
  static let probeTimeout = 8.0

  /// The programs the runner starts, by absolute path. Anything else is a programming error.
  static let open = "/usr/bin/open"
  static let lsappinfo = "/usr/bin/lsappinfo"
  static let jq = "/usr/bin/jq"
  static let nm = "/usr/bin/nm"
  static let driverName = "palantir-drive"
  static let inspectorName = "palantir-inspect"

  /// The folder for run folders, mutant builds and the release bundle.
  static var cache: String {
    ProcessInfo.processInfo.environment["PALANTIR_ACCEPT_CACHE"] ?? ".build/acceptance"
  }

  /// The models of the layer, by role. Never a Fable model.
  static let generatorModel = "claude-opus-5-5"
  static let judgeModel = "gpt-6-astra"
  static let mutantModel = "gpt-6.1-sol"
  static let triageModel = "gpt-6-astra"
  static let codexEffort = "high"
  /// Turn limits of a Claude run, and its budget in US dollars.
  static let generatorTurns = 30
  static let explorerTurns = 60
  static let claudeBudget = 3
  /// Time limits of a model run, in seconds.
  static let draftTime = 1200.0
  static let judgeTime = 900.0
  static let mutantTime = 1200.0
  static let exploreTime = 1500.0
  static let triageTime = 900.0

  /// The only thing a generator learns when a build that breaks its rule passes its check.
  static let gateSignal =
    "a build of palantir that breaks this rule passed this check; read the rule again and make the check fail any build that breaks it"
  /// The rounds generation allows before a rule ends ungated.
  static let replayRevisions = 3
  static let judgeRounds = 3
  static let mutantWriters = 2
  static let signalRevisions = 1
  /// The free disk space below which no mutant build or run clone starts, in bytes.
  static let diskFloor: Int64 = 20 * 1024 * 1024 * 1024
  /// The path of a command that wraps each replay generation starts, such as the one that takes the
  /// desktop lock; unset, replays run directly.
  static var replayWrapper: [String] {
    (ProcessInfo.processInfo.environment["PALANTIR_ACCEPT_REPLAY_WRAPPER"] ?? "")
      .split(separator: " ").map(String.init)
  }

  /// The prepared VM that every run clone is cut from, and where the guest keeps the layer.
  static let preparedVM = "palantir-acceptance"
  static let guestRoot = "/Users/admin/acceptance"
  /// How long a run clone has to answer `tart exec` after it boots, and how long a replay in it
  /// may take, in seconds.
  static let vmBootTimeout = 180.0
  static let vmRunTimeout = 1800.0
}
