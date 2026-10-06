# Swift toolchain notes

Notes from fixing `swift test`, SourceKit-LSP, and XCTest in the nixpkgs Swift toolchain (Swift 6.2.4), and from porting
the fixes to Swift 6.3 and 6.4. They explain why the patches exist and how to debug the toolchain.

## How the toolchain is assembled

Upstream ships one toolchain directory. nixpkgs splits it into separate packages and assembles them again:

| Package | Contents |
|---|---|
| `swiftc` | Compiler, SourceKit (`sourcekitd`), Swift Syntax for the compiler. Built three times (see below). |
| `stdlib` | Standard library. `swiftc` built with only the stdlib components. |
| `swift` | Wrapper that merges `swiftc`, `stdlib`, Foundation, XCTest, Swift Testing, LLDB, and the driver with `symlinkJoin`, then copies the files that resolve paths relative to themselves (`swift-frontend`, `swift-driver`, and on Darwin the SourceKit framework and XPC service). |
| `swiftpm` | SwiftPM, built with CMake. |
| `sourcekit-lsp` | SourceKit-LSP, built with SwiftPM. It vendors its own copy of SwiftPM and applies `swiftpm.patches` to it. |

The compiler bootstraps in stages: stage 0 is C++ only (`swiftc-cxx_bootstrap`), stage 1 enables Swift in the compiler
(`swiftc-bootstrap`), stage 2 is the final compiler (`swiftc`). Each stage has its own `swift` wrapper, so changing the
wrapper or `swiftc` rebuilds every stage. Swift 6.3 bootstraps through a full 6.2 toolchain first.

Many tools find other parts of the toolchain relative to their own location *after resolving symlinks*. Because
`swift` is mostly symlinks into `swiftc`, such tools see `swiftc` (which has no stdlib) instead of the merged toolchain.
That is the root cause of several bugs below.

## Bugs found and fixed

### SwiftPM (`swift test`)

- **CMake build is only for bootstrapping on macOS.** Upstream builds the distributed SwiftPM with SwiftPM itself
  ([swift-package-manager#10600](https://github.com/swiftlang/swift-package-manager/issues/10600)). The CMake build
  misses things the SwiftPM build does:
  - `swiftpm-testing-helper` is not built. It loads Darwin test *bundles* to run Swift Testing. Not needed in nixpkgs,
    see the next point.
  - Executables get no rpaths to back-deployed libraries (`lib/swift-5.5`, `lib/swift-6.2`). SwiftPM crashed on macOS
    15 because `libswiftCompatibilitySpan.dylib` (only part of macOS 26+) was not found. Fixed by mirroring
    `ProductBuildDescription.swift` in CMake (`0012-add-back-deployment-rpaths-with-cmake.patch`). The `swift` setup
    hook then rewrites `$swift/lib/…` rpaths to `$stdlib/lib/…`, where the back-deployment libraries live.
- **XCTest on Darwin.** nixpkgs uses swift-corelibs-xctest on Darwin because Xcode’s XCTest is unavailable. Upstream
  SwiftPM builds Darwin tests as loadable bundles run by Xcode’s `xctest` (XCTest) or `swiftpm-testing-helper` (Swift
  Testing). swift-corelibs-xctest needs Linux-style tests: an executable with a generated entry point and a generated
  test list. `0013-build-and-run-tests-like-on-linux-on-darwin.patch` does that on Darwin, which makes XCTest work and
  makes the helper unnecessary. It also disables generated XCTest observation code that uses APIs only Xcode’s XCTest
  has (`XCTIssue`, `XCTAttachment`, …).
- **Deployment target.** SwiftPM defaults to macOS 10.13 for packages that don’t declare platforms, and uses
  `XCTest.framework` from Xcode for test targets. Both are wrong in nixpkgs (Swift Testing needs 10.15+, nixpkgs
  libraries target `$MACOSX_DEPLOYMENT_TARGET`). `postPatch` sets the oldest supported macOS version to
  `$MACOSX_DEPLOYMENT_TARGET` on Darwin.
- **Swift Testing macro plugin built for the build machine’s macOS.** swift-testing builds `TestingMacros` as a CMake
  external project, which does not inherit `CMAKE_Swift_COMPILER_TARGET`, so `swiftc` targeted the running OS (macOS 26
  on Hydra) and `@Test` failed on macOS 15. `swift-testing` patch 0002 adds `SwiftTesting_MACRO_Swift_COMPILER_TARGET`.

### SourceKit-LSP

All four problems made SourceKit-LSP useless for SwiftPM packages without workarounds (merged toolchain via
`symlinkJoin` and `SOURCEKIT_TOOLCHAIN_PATH=…/bin`):

1. **`cannotDetermineHostToolchain`.** SourceKit-LSP requires `clang`, `clangd`, `sourcekitd`, `swift`, and `swiftc` in
   one toolchain directory. `swift` now links `clangd`. The vendored SwiftPM never substituted `@out@`, so it could not
   find `PackageDescription`; sourcekit-lsp now runs `swiftpm.postPatch` on it with `out` set to `swiftpm`.
2. **Toolchain path had to end in `bin`.** The IndexStore patch set `foundAny` for a path that always exists, so the
   search stopped at the first candidate. Fixed in sourcekit-lsp patch 0002.
3. **SourceKit plugins not found.** They are installed with SourceKit-LSP, not the toolchain. sourcekit-lsp patch 0003
   falls back to its own store path.
4. **Hover, completion, and diagnostics silently broken for anything using Foundation.** The compiler patch that reads
   libc flags from the wrapped clang found `clang` next to `getMainExecutable()`. In SourceKit, the main executable is
   `sourcekit-lsp`, so no libc flags were found, `SwiftGlibc` failed to load, and everything depending on Foundation
   (including cross-module types) failed. Diagnostics were *empty*, not wrong. `swiftc` patch 0011 uses
   `ClangImporterOpts.clangPath`, which the invocation derives from the toolchain path. Only affects Linux in practice
   (libc comes from the SDK on Darwin).

On Darwin, SourceKit runs as an XPC service:

- The service and framework were symlinks into `swiftc`, so SourceKit found the toolchain there and failed with
  “Loading the standard library failed” (also on master). The `swift` wrapper copies them on Darwin.
- With only `sourcekit-xpc-service` installed, `SourceKitService` links SourceKit statically and exports only `_main`,
  so the SourceKit plugin crashed looking up the service API. Installing `sourcekit-inproc` as well (like swift.org
  toolchains) makes the service link `sourcekitdInProc`, which exports it.
- The XPC service cannot be launched from a Nix build (“Service is invalid”), so the SourceKit-LSP test is broken on
  Darwin in the sandbox. It works outside the sandbox.

## Debugging techniques

- **LSP client:** a ~100-line Python client (see `sourcekit-lsp/tests/semantic-functionality/test.py`) that starts
  `sourcekit-lsp`, opens a file, waits with `workspace/synchronize` (needs
  `--experimental-feature synchronize-for-build-system-updates`), and checks diagnostics, hover, and completion.
- **SourceKit-LSP logs:** `SOURCEKIT_LSP_LOG_LEVEL=debug SOURCEKIT_LSP_LOG_PRIVACY_LEVEL=sensitive`, written to
  `~/.sourcekit-lsp/logs` on Linux (OSLog on Darwin). They contain every sourcekitd request with its compiler arguments.
- **Replaying sourcekitd requests:** a small C program that `dlopen`s `libsourcekitdInProc.so` and sends the logged
  requests with `sourcekitd_request_create_from_yaml`. Moving the program next to a `clang` symlink proved bug 4.
- **Darwin crash reports:** `~/Library/Logs/DiagnosticReports/*.ips` and `log show --predicate 'process == "…"'` on CI
  runners.

## CI on the fork

`.github/workflows/swift.yml` builds the toolchain in stages because a full build exceeds GitHub’s 6-hour job limit:

- Each stage builds one derivation (by name) from the closure of the tests. A post-build hook records the paths it
  built, which are exported with `nix-store --export` (a `file://` binary cache refuses paths whose references it does
  not contain) and passed on as artifacts. Later stages fetch the references from cache.nixos.org and import the
  exports in order.
- `workflow_dispatch` takes `reuse-run-ids`, so later runs can reuse the paths built by earlier runs instead of building
  the toolchain again.
- The test jobs run the passthru tests (in the sandbox), `swift test` and the SourceKit-LSP test outside the sandbox,
  and build and test an external package ([Archivist](https://github.com/tothambrus11/Archivist), XCTest and macros).
- Gotchas: macOS runners use Bash 3.2 (no `mapfile`) and have no `timeout`; `nix-shell` needs `NIX_PATH` for
  `bashInteractive`; GitHub artifact downloads occasionally fail with HTTP 504.

Approximate build times on GitHub runners (Linux 4 cores, macOS 3 cores):

| Stage | Linux | macOS |
|---|---|---|
| stage 0 compiler | 1h10m | 45m–1h20m |
| stage 1 compiler | 1h30m | 1h |
| final compiler | 4h15m | 2h45m–3h45m |
| stdlib, LLDB, tests | ~1h | ~1h–3h |

## Swift 6.3 and 6.4

### Upstream work

[nixpkgs#565702](https://github.com/NixOS/nixpkgs/pull/565702) (reckenrode) updates Swift 6.2.4 → 6.3.3. It adds
bootstrapping through a full 6.2 toolchain, per-version patch sets (`patchesForVersion`), `update.sh`, and
`prefetch-swiftpm-deps`, and targets staging. 6.4.0 is planned as a follow-up, and SDKs/cross-compilation after that.

The PR branch is based on staging, which is not built for Darwin, and it vendors the LLVM TextAPI patch, which changes
every LLVM in nixpkgs. Testing it on GitHub runners would mean building the Darwin stdenv. The fork’s `swift-6.3` and
`swift-6.4` branches instead cherry-pick the PR onto master, replace the TextAPI vendoring with a filter in
`swiftPackages.llvmPackages` (only the fork needs it dropped), and add the changes from this document.

### Porting the changes to 6.3

The bootstrap chain becomes: Swift’s LLVM 17 fork → 6.2.4 stage 0, stage 1, final compiler, stdlib → Swift’s LLVM 21
fork → 6.3.3 stage 1, final compiler, stdlib → LLDB 21. None of it is cached, so CI builds the LLVM forks in their own
stages.

- `swiftc` patch 0011 goes into the 6.2 patch set and is shared with 6.3.
- SwiftPM patch 0013 needs rebasing (`SwiftSDK.swift` and `BuildParameters.swift` moved code around). `patch` reports
  the rejected hunks, so always apply the full patch list to the new sources before building.
- **Bootstrapping race on Linux.** The stage 1 compiler builds its own stdlib. Its RPATH points to the stdlib in the
  build folder (`$ORIGIN/../lib/swift/linux`), so while that stdlib is being built, Swift sets `LD_LIBRARY_PATH` to the
  runtime of the bootstrap compiler, which it expects in `<bootstrap swift>/lib/swift/linux`. nixpkgs installs the
  stdlib’s libraries in `lib` instead, so the compiler loaded the half-built new runtime and failed whenever a library
  was not there yet (`libswift_Builtin_float.so: cannot open shared object file`). It depends on the build order, so it
  may not happen on every machine. `swiftc` substitutes the bootstrap stdlib’s `lib` in `cmake/modules/SwiftUtils.cmake`
  (only for non-Darwin builds that build a stdlib, so the 6.2.4 derivations stay unchanged). The `swift` wrapper exposes
  its `stdlib` in `passthru` for this.

Result: everything passes on Linux, macOS 15, and macOS 26 (SwiftPM with XCTest and Swift Testing, SourceKit-LSP,
Archivist).

### Updating to 6.4.0

1. Run `update.sh 6.4.0 <swift-docc-render rev> <swift-tools-protocols version>`. For 6.4.0, `update-checkout` uses the
   `release/6.4.0` branches; swift-docc-render only has `release/6.4.x` (`d45c3ac`), and swift-tools-protocols is tagged
   `swift-6.4.0-RELEASE`. The script only needs `swift` for `swift package resolve`, so a cached older toolchain works.
2. Add `6.4.0` to the version table in `swiftPackages.llvmPackages`. 6.4 uses the same LLVM as 6.3 (`21.0.0`, based on
   21.1.6), but the fork already has nixpkgs’ Darwin triple parsing backport (empty patch in `patches/6.4`).
3. Add `patches/6.4` for packages that use `patchesForVersion` (`swiftc`, `swift-foundation`,
   `swift-corelibs-libdispatch`, `swift-llbuild`).
4. Check every package’s patches against the new sources before building:
   - `swiftc`: 0001 and 0006 rebased; the `swift repl` null-terminator fix is upstream.
   - `swiftpm`: 0002, 0009, and 0013 rebased; the `swift-package-collection` patch is upstream. 6.4 adds a test
     debugging mode with its own Darwin-only test runner paths, which 0013 also has to switch to the Linux paths.
     6.4 raises the default oldest supported macOS to 12.0, so the `postPatch` substitution matches any version.
   - `swift-foundation` 0002, `swift-build` 0001 and 0002, `swift-docc`’s test patch: context changes only.
   - `swift-foundation` 0003 (missing `_FoundationCShims` imports after Glibc 2.44) still applies with fuzz, but in
     6.4 `URL_Swift.swift` is only used for the Foundation framework and the `stat` code moved to `URL_Impl.swift`, so
     the import ended up inside `#if FOUNDATION_FRAMEWORK`. 6.4 has its own version of the patch. Watch out for patches
     that apply with fuzz.
   - sourcekit-lsp’s vendored SwiftPM tracks `release/6.4.x`, which differs from the tag; the SwiftPM patches still
     apply to it.
5. On Darwin, the Runtime module fails to build with strict availability (which nixpkgs enables for the final compiler)
   and a deployment target older than macOS 26: 6.4 then defines `BacktracingDT 6.2` as macOS 26.0, but
   `DefaultSymbolLocator` uses declarations annotated with it without availability checks (`'ElfImageCache' is only
   available in macOS 26.0 or newer`). Upstream `main` has the same code. `swiftc` patch 0012 (6.4, Darwin only) keeps
   it at the deployment target, like without strict availability.

### Swift Build (the default build system in SwiftPM 6.4)

SwiftPM 6.4 uses Swift Build by default on all platforms (6.3 still defaults to the native build system), so
`swift build`, `swift test`, and `swiftpmHook` builds go through it. The native build system still works with
`--build-system native` (it is marked deprecated). Problems found so far:

- **Toolchain layout.** SwiftPM derives the toolchain directory it gives Swift Build by resolving the compiler’s
  symlinks and removing `usr/bin`; for nixpkgs this resulted in `/nix/store`. Swift Build looks for tools in
  `<toolchain>/usr/bin` and the Swift Testing macro plugin in `<toolchain>/usr/lib`. nixpkgs toolchains have `bin` and
  `lib` at the top level, so Swift Build fell back to running `swiftc` relative to the package
  (`/build/src/swiftc is not an executable file`). SwiftPM patch 0014 and swift-build patch 0005 handle toolchains
  without `usr`.
- **`llvm-ar`.** Swift Build uses `llvm-ar` on Linux, which the nixpkgs toolchain does not include. SwiftPM patch 0014
  passes the librarian of the native build system (`$AR`) instead.
- **libIndexStore** (for XCTest discovery) is looked up in the toolchain; swift-build patch 0004 falls back to
  libclang’s.
- **Tests on Darwin.** Swift Build builds Darwin tests as `.xctest` bundles linking `XCTest.framework`, and its Darwin
  specs skip the SwiftPM test runner. swift-build patch 0004 builds them like on Linux (a dylib and a test runner with
  a generated entry point, without the Xcode-only XCTest APIs), and SwiftPM patch 0013 runs the runner.
- **`DEVELOPER_DIR` on Darwin.** Swift Build sets `DEVELOPER_DIR` to the toolchain directory, and the driver ran
  `xcrun` with it (`invalid DEVELOPER_DIR path`). Still being investigated.

## CI notes for version branches

- The `platforms` input of `swift.yml` (`linux`, `darwin`, or both) builds one platform, and runs for different
  platforms don’t cancel each other (the concurrency group includes it). Pushing starts a run for both platforms; cancel
  it and dispatch with `reuse-run-ids` to reuse earlier runs.
- macOS runners run out of disk space while building the compiler. The stage workflow deletes unused Xcodes, simulator
  runtimes, Android, and .NET, and removes each export after importing it.
- Jobs sometimes fail with “The job was not acquired by Runner of type hosted even after multiple attempts”. Rerun the
  failed jobs.
