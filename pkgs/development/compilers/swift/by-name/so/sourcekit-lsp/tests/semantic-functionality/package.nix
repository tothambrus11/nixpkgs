{
  lib,
  python3,
  sourcekit-lsp,
  stdenv,
  swift,
  swiftpm,
}:

# Tests that SourceKit-LSP provides semantic functionality without any additional configuration. This requires that it
# finds a complete toolchain, the SourceKit plugins, and `PackageDescription`, and that SourceKit can load Foundation.
stdenv.mkDerivation {
  name = "test-sourcekit-lsp-semantic-functionality";

  src = ./src;

  strictDeps = true;

  nativeBuildInputs = [
    python3
    sourcekit-lsp
    swift
    swiftpm
  ];

  dontUseSwiftpmBuild = true;
  dontUseSwiftpmInstall = true;

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR

    echo "Using the toolchain found by SourceKit-LSP"
    python3 ${./test.py} .

    # SourceKit-LSP should also find the toolchain when given its root instead of its `bin` folder.
    echo "Using SOURCEKIT_TOOLCHAIN_PATH=${swift}"
    rm -rf .build
    SOURCEKIT_TOOLCHAIN_PATH=${swift} python3 ${./test.py} .

    runHook postBuild
  '';

  installPhase = ''
    touch "$out"
  '';

  __structuredAttrs = true;

  meta.timeout = 3600;
}
