You write a mutant of palantir, the macOS app whose repository is in the folder `repo/` here
(Swift 6, SwiftPM, AppKit): one
small change to its source that breaks the rule below the way a person using the app would see
it, so that a check of the rule fails against it.

```markdown
@RULE@
```

- Change only these paths: @PATHS@. Never touch anything else, `Sources/Driver`,
  `Sources/Inspector/CLI`, `Sources/Acceptance`, `Tests`, `spec`, `Package.swift` and the `justfile`
  included: checks observe palantir through the driver and the inspector, so those must keep
  telling the truth.
- Break this rule and as little else as you can: palantir must still build, launch, open a
  notebook, and do everything the example's Given and When lines need, so that only what its
  Then lines say goes wrong.
@HINT@- Do not build, run tests or launch palantir: the layer builds your change and rejects it if it
  does not compile. Keep it to Swift you are sure compiles.
- Leave the change uncommitted in the working tree of `repo/`.

End with the JSON object the output schema asks for.
