#!/usr/bin/env bash
# Write .env for this PC: finds the AMD card and its VRAM, the RAM, the video and
# render group IDs, picks upstream's image flavour for the card, a starting model
# and context, and makes an API key.
#
#   ./configure.sh           # will not replace an existing .env
#   ./configure.sh --force   # replace it (the old one is kept as .env.bak)
#
# The picks are starting points; edit .env afterwards. See README "Settings by card".
set -euo pipefail
cd "$(dirname "$0")"
. lib/gpu.sh

if [ -e .env ]; then
  [ "${1:-}" = --force ] || { echo ".env already exists. ./configure.sh --force replaces it." >&2; exit 1; }
  cp -p .env .env.bak
fi

read -r arch vram_mib < <(best_amd_gpu) || true
if [ -z "${arch:-}" ]; then
  echo "No supported AMD card found (looked for: $SUPPORTED_ARCHS). Is the amdgpu driver loaded?" >&2
  exit 1
fi
vram_gib=$(( (vram_mib + 512) / 1024 ))
ram_gib=$(awk '/^MemTotal/ {printf "%d", $2/1048576 + 0.5}' /proc/meminfo)

# Context: what the card can keep next to a useful expert cache. Only the 32 GB
# row has been measured (R9700, see README); the others are conservative guesses.
if   [ "$vram_gib" -ge 30 ]; then ctx=256k
elif [ "$vram_gib" -ge 20 ]; then ctx=128k
elif [ "$vram_gib" -ge 14 ]; then ctx=64k
else                              ctx=32k
fi
flavor=$(arch_to_flavor "$arch")
# Model: IQ3_XXS wants ~43 GB of RAM for the experts the card can't hold;
# below ~56 GB of RAM start with the smaller IQ2_XS (~36 GB).
if [ "$ram_gib" -ge 56 ]; then model=IQ3_XXS; else model=IQ2_XS; fi

# The groups that own the GPU device files (what the container must be in), else
# the usual group names. Compose refuses the same ID twice, so if both are one
# group, the second becomes 0: the container runs as root, so that adds nothing.
gid() { getent group "$1" | cut -d: -f3 || true; }
dev_gid() { stat -c %g "$1" 2>/dev/null || true; }
render_gid=""
for n in /dev/dri/renderD*; do [ -e "$n" ] && { render_gid=$(dev_gid "$n"); break; }; done
[ -n "$render_gid" ] || render_gid=$(gid render)
video_gid=$(dev_gid /dev/kfd)
[ -n "$video_gid" ] || video_gid=$(gid video)
[ -n "$render_gid" ] || render_gid=$video_gid
[ -n "$video_gid" ] || video_gid=$render_gid
[ -n "$render_gid" ] || { echo "Cannot find the GPU's groups (no /dev/kfd, /dev/dri, render or video group)." >&2; exit 1; }
if [ "$video_gid" = "$render_gid" ]; then
  v=$(gid video); if [ -n "$v" ] && [ "$v" != "$render_gid" ]; then video_gid=$v; else video_gid=0; fi
fi
[ -e /dev/kfd ] || echo "Note: /dev/kfd is missing: is the amdgpu driver loaded? (lsmod | grep amdgpu)" >&2

key=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')

umask 077
cat > .env <<ENV
# Written by configure.sh on $(date -u +%Y-%m-%d) for: $arch, ${vram_gib} GB VRAM, ${ram_gib} GB RAM.
# Holds your API key: keep it out of git. Settings explained in .env.example.
STRATA_API_KEY=$key
VIDEO_GID=$video_gid
RENDER_GID=$render_gid

STRATA_IMAGE=ghcr.io/niko1221/strata:latest-$flavor

STRATA_FAMILY=qwen
STRATA_MODEL=$model
STRATA_CONTEXT=$ctx
STRATA_KV=
STRATA_DRAFTING=
STRATA_PARALLEL=
STRATA_VISION=off
STRATA_TUNE=skip
STRATA_RETUNE=0
STRATA_SET=

STRATA_DATA=./strata-data
STRATA_BIND=127.0.0.1
STRATA_PORT=8081
ENV

echo "Wrote .env: $arch, ${vram_gib} GB VRAM, ${ram_gib} GB RAM -> image $flavor, MODEL=$model CONTEXT=$ctx"
[ "$ram_gib" -lt 40 ] && echo "Note: under 40 GB of RAM Strata reads more of the model from disk; use an NVMe SSD for STRATA_DATA."
echo "API key: in .env (STRATA_API_KEY). Next: docker compose pull && docker compose up -d"
