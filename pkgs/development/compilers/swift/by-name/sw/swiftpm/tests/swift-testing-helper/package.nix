{
  lib,
  stdenv,
  swift,
  swiftpm,
}:

# On Darwin, `swift test` runs Swift Testing tests using `swiftpm-testing-helper`.
# See https://github.com/swiftlang/swift-package-manager/issues/10600.
stdenv.mkDerivation {
  name = "test-swiftpm-swift-testing-helper";

  src = ./src;

  strictDeps = true;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;

  checkPhase = ''
    runHook preCheck

  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    test -x "${swiftpm}/libexec/swift/pm/swiftpm-testing-helper"

  ''
  + ''
    TERM=dumb swift test --disable-xctest 2>&1 | tee test.log
    grep -q 'Test run with 1 test .*passed' test.log

    runHook postCheck
  '';

  installPhase = ''
    touch "$out"
  '';

  __structuredAttrs = true;
}
