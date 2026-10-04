{
  stdenv,
  swift,
  swiftpm,
}:

# Tests that `swift test` runs both XCTest and Swift Testing tests.
stdenv.mkDerivation {
  name = "test-swiftpm-swift-test";

  src = ./src;

  strictDeps = true;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    TERM=dumb swift test 2>&1 | tee test.log
    grep -q 'Executed 1 test, with 0 failures' test.log
    grep -q 'Test run with 1 test .*passed' test.log

    runHook postCheck
  '';

  installPhase = ''
    touch "$out"
  '';

  __structuredAttrs = true;
}
