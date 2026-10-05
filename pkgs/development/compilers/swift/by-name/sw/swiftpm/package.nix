{
  lib,
  callPackage,
  cmake,
  fetchFromGitHub,
  fetchpatch2,
  llvmPackages,
  ninja,
  replaceVars,
  sqlite,
  stdenv,
  swift,
  swift-argument-parser,
  swift-asn1,
  swift-build,
  swift-certificates,
  swift-collections,
  swift-crypto,
  swift-driver,
  swift-llbuild,
  swift-syntax,
  swift-system,
  swift-tools-protocols,
  swift-tools-support-core,
  swiftpmHook,
  swift_release,
  swift_sources,
}:

let
  swift-syntax-no-toolchain = swift-syntax.override { useToolchainLibraries = false; };

  rpaths = lib.makeLibraryPath [
    sqlite
    swift-argument-parser
    swift-asn1
    swift-build
    swift-certificates
    swift-collections
    swift-crypto
    swift-driver
    swift-llbuild
    swift-syntax-no-toolchain
    swift-system
    swift-tools-protocols
    swift-tools-support-core
  ];
in

stdenv.mkDerivation (finalAttrs: {
  pname = "swiftpm";
  version = swift_release;

  outputs = [
    "out"
    "dev"
  ];

  src = fetchFromGitHub {
    owner = "swiftlang";
    repo = "swift-package-manager";
    tag = "swift-${finalAttrs.version}-RELEASE";
    inherit (swift_sources.swift-package-manager) hash;
  };

  patches = [
    ./patches/0001-gnu-install-dirs.patch
    # Use swift-corelibs-xctest even on Darwin (because XCTest.framework is not available in nixpkgs).
    ./patches/0002-darwin-swift-corelibs-xctest.patch
    # SwiftPM tries to use `sandbox-exec` for sandboxing, which will fail when it is run in the Nix sandbox.
    ./patches/0003-disable-sandbox.patch
    # SwiftPM falls back to looking for manifests and plugins in the Swift compiler location. Find them in $out.
    ./patches/0005-fix-manifest-path.patch
    # Silence warnings about not finding the cache folder when building packages by moving it to $NIX_BUILD_TOP.
    ./patches/0006-nix-build-caches.patch
    # SwiftPM does its own `.pc` parsing, so it avoids the `pkg-config` wrapper used in nixpkgs to support
    # cross-compilation. This patch adds support for `"PKG_CONFIG_PATH_FOR_TARGET` to SwiftPM.
    ./patches/0007-nix-pkgconfig-vars.patch
    # SwiftPM assumes that you are using Apple Clang on macOS, but nixpkgs builds Clang from upstream LLVM.
    # This effectively disables using `-index-store-path`, which isn’t supported by LLVM’s Clang.
    ./patches/0008-set-compiler-vendor.patch
    # A couple of required libraries are missing from the `CMakeLists.txt` files.
    ./patches/0009-add-missing-libraries.patch
    # SwiftPM tries to load IndexStoreDB from the toolchain, but load it from the store instead.
    (replaceVars ./patches/0010-Load-IndexStore-from-the-store.patch {
      libclang = lib.getLib llvmPackages.libclang;
    })
    # SwiftPM tries to find Clang via `CC`, but that can be GCC on Linux, which doesn’t actually work with SwiftPM.
    ./patches/0011-Always-find-Clang-in-the-toolchain.patch
    # The CMake build doesn’t add rpaths to the back-deployed libraries (such as `libswiftCompatibilitySpan.dylib`)
    # to executables like SwiftPM does when building itself, so SwiftPM fails to run on macOS 15 and older.
    ./patches/0012-add-back-deployment-rpaths-with-cmake.patch
    # swift-corelibs-xctest requires test products to be executables, so build and run them like on Linux on Darwin.
    # This makes XCTest work on Darwin. Swift Testing uses the same executables, so `swiftpm-testing-helper` (which
    # loads test bundles) isn’t needed.
    ./patches/0013-build-and-run-tests-like-on-linux-on-darwin.patch
    # Swift Build assumes the toolchain has its tools in `usr/bin` and includes `llvm-ar` on Linux.
    ./patches/0014-support-nixpkgs-toolchains-with-swift-build.patch
  ];

  postPatch = ''
    # Need to reference $out, so this can’t be substituted by `replaceVars`.
    substituteInPlace Sources/PackageModel/UserToolchain.swift \
      --replace-fail '@out@' "$out"

    # Replace hardcoded references to `xcrun` with `PATH`-based references.
    find Sources -name '*.swift' -exec sed -i '{}' -e 's|/usr/bin/xcrun|xcrun|g' \;

    # Set the deployment target when building package manifests to one supported in nixpkgs.
    substituteInPlace Sources/PackageLoading/ManifestLoader.swift \
      --replace-fail '.tripleString(forPlatformVersion: version)' ".tripleString(forPlatformVersion: \"$MACOSX_DEPLOYMENT_TARGET\")"
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    # Use the nixpkgs deployment target as the oldest supported version of macOS, which is the deployment target of
    # packages (and test targets, which use the deployment target of XCTest.framework from Xcode otherwise) that don’t
    # require a newer one. The default (e.g., macOS 12.0 in Swift 6.4) is too old for the libraries in nixpkgs.
    sed -i -E 's/(name: "macos", oldestSupportedVersion: )"[0-9.]+"/\1"'"$MACOSX_DEPLOYMENT_TARGET"'"/' \
      Sources/PackageModel/Platform.swift
    grep -qF "name: \"macos\", oldestSupportedVersion: \"$MACOSX_DEPLOYMENT_TARGET\"" Sources/PackageModel/Platform.swift
  '';

  strictDeps = true;

  # Needed for rpath fixups to work on Darwin.
  env.NIX_LDFLAGS = lib.optionalString stdenv.hostPlatform.isDarwin "-headerpad_max_install_names";

  preConfigure = ''
    appendToVar cmakeFlags -DCMAKE_Swift_COMPILER_TARGET=${stdenv.hostPlatform.swift.triple}
    appendToVar cmakeFlags -DCMAKE_Swift_FLAGS=-module-cache-path\ "$NIX_BUILD_TOP/module-cache"
  '';

  nativeBuildInputs = [
    cmake
    ninja
    swift
  ];

  propagatedBuildInputs = [ swiftpmHook ];

  buildInputs = [
    sqlite
    swift-argument-parser
    swift-asn1
    swift-build
    swift-certificates
    swift-collections
    swift-crypto
    swift-driver
    swift-llbuild
    swift-syntax-no-toolchain
    swift-system
    swift-tools-protocols
    swift-tools-support-core
  ];

  postInstall =
    lib.optionalString stdenv.hostPlatform.isDarwin ''
      # Replace `@rpath` with absolute paths on Darwin. For some reason, this isn’t always done during installation.
      # `fixDarwinDylibNames` doesn’t work either.
      IFS= readarray -d "" dylibs < <(find "$out" -type f -and -name '*.dylib' -print0)
      declare -a mappings

      for dylib in "''${dylibs[@]}"; do
        mappings+=(-change "@rpath/$(basename "$dylib")" "$dylib")
      done

      for dylib in "''${dylibs[@]}"; do
        install_name_tool "$dylib" ''${mappings[@]}
      done
    ''
    + lib.optionalString stdenv.hostPlatform.isElf ''
      for output in "''${outputs[@]}"; do
        while IFS= read -d "" f; do
          if isELF "$f"; then
            patchelf --add-rpath ${lib.escapeShellArg rpaths} "$f"
          fi
        done < <(find "$output" -type f -print0)
      done
    '';

  passthru.tests = lib.packagesFromDirectoryRecursive {
    inherit callPackage;
    directory = ./tests;
  };

  __structuredAttrs = true;

  meta = {
    description = "Package Manager for the Swift Programming Language";
    homepage = "https://github.com/swiftlang/swift-package-manager";
    inherit (swift.meta) badPlatforms platforms;
    license = lib.licenses.asl20;
    maintainers = lib.teams.swift.members;
  };
})
