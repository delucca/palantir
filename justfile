set shell := ["bash", "-euo", "pipefail", "-c"]

app := ".build/palantir.app"

build:
    swift build

test:
    swift test

fmt:
    swift format --in-place --recursive --parallel Package.swift Sources Tests

lint:
    swift format lint --strict --recursive --parallel Package.swift Sources Tests

# Assemble an ad-hoc signed palantir.app from a SwiftPM build.
bundle config="debug":
    swift build -c {{config}}
    rm -rf {{app}}
    mkdir -p {{app}}/Contents/MacOS
    cp "$(swift build -c {{config}} --show-bin-path)/palantir" {{app}}/Contents/MacOS/
    cp Sources/Palantir/Info.plist {{app}}/Contents/
    codesign --force --sign - {{app}}

run: bundle
    {{app}}/Contents/MacOS/palantir
