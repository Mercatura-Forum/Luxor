#!/usr/bin/env bash
# Emits the --package flags for a build of this tree: the mops dependencies and the Thebes Domain
# Kernel. The kernel is read from the directory in KERNEL, else from vendor/thebes-kernel when its source
# is there, else from a checkout beside this repository (../thebes-kernel); vendor/thebes-kernel/README.md
# names the commit this tree is built against. It is PINNED: deps/KERNEL_PIN names the commit,
# and a kernel checkout at any other commit is refused with both named. A kernel placed from an archive
# rather than a checkout has no commit to compare; KERNEL_PIN_SKIP=1 accepts it as it is.
#
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
if [ -z "${KERNEL:-}" ]; then
  if [ -d "$HERE/vendor/thebes-kernel/src/domain" ]; then KERNEL="$HERE/vendor/thebes-kernel"; else KERNEL="$HERE/../thebes-kernel"; fi
fi
if [ ! -d "$KERNEL/src/domain" ]; then
  echo "packages.sh: no kernel at $KERNEL (expected \$KERNEL/src/domain: clone it beside this repository as thebes-kernel, see vendor/thebes-kernel/README.md)" >&2; exit 1
fi
KERNEL="$(cd "$KERNEL" && pwd -P)"
if [ "${KERNEL_PIN_SKIP:-0}" != "1" ]; then
  WANT="$(head -1 "$HERE/deps/KERNEL_PIN" 2>/dev/null || true)"
  # the kernel must be a checkout of its own: inside this repository's checkout, git would answer with
  # this repository's commit
  TOP="$(git -C "$KERNEL" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$TOP" ] || [ "$(cd "$TOP" && pwd -P)" != "$KERNEL" ]; then
    echo "packages.sh: the kernel at $KERNEL is not a git checkout, so its commit cannot be compared with '$WANT'; set KERNEL_PIN_SKIP=1 to build with it as it is" >&2; exit 1
  fi
  HAVE="$(git -C "$KERNEL" rev-parse HEAD)"
  if [ "$WANT" != "$HAVE" ]; then
    echo "packages.sh: the kernel is at '$HAVE' and this tree is built against '$WANT'" >&2; exit 1
  fi
fi
echo "$(cd "$HERE" && mops sources) --package kernel $KERNEL/src"
