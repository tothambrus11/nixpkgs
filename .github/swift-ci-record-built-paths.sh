#!/bin/sh
# Nix post-build hook for the Swift CI workflow: records the paths built by the current job, so they can be passed on
# to the jobs that need them.
set -eu
echo $OUT_PATHS >> /tmp/nix-built-paths
