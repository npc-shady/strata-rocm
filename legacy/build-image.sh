#!/usr/bin/env bash
# Build the Strata ROCm image, then print the lines that say whether it came out
# right (ROCm version, Strata commit, hipBLASLt tuning table).
#
#   ./build-image.sh                    # finds the card(s) in this PC
#   ./build-image.sh --gpu 9070xt       # r9700, 9070xt, 9060xt, 7900xtx, 7900xt, ... or gfx1201
#   ./build-image.sh --gpu all          # one image for RDNA3 and RDNA4 (slower build)
#   ./build-image.sh --rocm 7.2.1-complete
#   STRATA_REF=<commit> ./build-image.sh   # pin Strata to a commit (default: main)
#
# Tags the result strata-rocm:<rocm>-<gpu> and strata-rocm:local (what compose.yaml runs).
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/gpu.sh

gpu=auto
rocm_tag=7.2.1-complete
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)  gpu="${2:?--gpu needs a value}"; shift 2 ;;
    --rocm) rocm_tag="${2:?--rocm needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

case "$gpu" in
  auto)
    archs=$(list_amd_gpus | awk '{print $1}' | sort -u | while read -r a; do
      case " $SUPPORTED_ARCHS " in *" $a "*) echo "$a" ;; esac
    done | paste -sd, -)
    if [ -z "$archs" ]; then
      echo "No supported AMD card found (looked for: $SUPPORTED_ARCHS)." >&2
      echo "Found: $(list_amd_gpus | awk '{print $1}' | paste -sd' ' - || true)" >&2
      echo "Name the card instead, e.g. ./build-image.sh --gpu 9070xt" >&2
      exit 1
    fi
    label=${archs//,/-} ;;
  all)
    archs=gfx1100,gfx1101,gfx1200,gfx1201; label=all ;;
  *)
    archs=""
    for g in ${gpu//,/ }; do
      a=$(gpu_name_to_arch "$g") || { echo "unknown card: $g" >&2; exit 2; }
      case " $SUPPORTED_ARCHS " in *" $a "*) ;; *) echo "note: $a is not one this repo was written for; trying anyway" >&2 ;; esac
      archs="${archs:+$archs,}$a"
    done
    label=${archs//,/-} ;;
esac

ref="${STRATA_REF:-main}"
image="strata-rocm:${rocm_tag%%-*}-${label}"
log="build-${rocm_tag%%-*}-${label}.log"

echo "Building $image (also tagged strata-rocm:local)"
echo "  base  rocm/dev-ubuntu-24.04:$rocm_tag"
echo "  GPU   $archs"
echo "  Strata $ref"
echo "  log   $log"
docker build --progress=plain -t "$image" -t strata-rocm:local \
  --build-arg ROCM_TAG="$rocm_tag" \
  --build-arg STRATA_REF="$ref" \
  --build-arg HIP_ARCHS="$archs" \
  . 2>&1 | tee "$log"

echo
echo "== Check these =="
grep -E "ROCm in /opt/rocm|Strata [0-9a-f]{40}|hipBLASLt tuning table|no hipBLASLt" "$log" || true
docker image ls strata-rocm
