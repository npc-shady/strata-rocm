# syntax=docker/dockerfile:1
#
# Strata (https://github.com/Niko1221/Strata) for AMD GPUs on Linux, ROCm 7.2.x.
#
# Upstream ships one Dockerfile; this is the AMD/HIP version. The HIP engine is
# compiled during `docker build` against the base image's own ROCm (setup.py uses
# /opt/rocm when it is ROCm 7+ with the HIP dev files), so a container start only
# sets up the model and serves. Upstream's docker-entrypoint.sh is reused as-is:
# it reads MODEL, CONTEXT, LOW_RAM, API_KEY, ... and keeps everything on /data.
#
# Why ROCm 7.2.x: Strata ships hipBLASLt tuning tables (faster prompt reading)
# for hipBLASLt 1.2.2, which is ROCm 7.2.x, for all three card families here:
# tools/hip/gfx1100-, gfx1200- and gfx1201-hipblaslt-100202.txt. Without a table
# for the card's arch and the installed hipBLASLt, prompts fall back to plain
# hipBLAS. On an R9700, 7.2.1-complete logs "hipBLASLt tuning table:
# gfx1201-hipblaslt-100202.txt (faster prompts)".
#
# Build with ./build-image.sh (see README); it finds the card and sets HIP_ARCHS.
# The engine is compiled on, and for, the machine that builds it: build on the PC
# that will run it rather than sharing a built image.
#
#   HIP_ARCHS   GPU target(s), comma-separated:
#                 gfx1201  RX 9070 / 9070 XT, Radeon AI PRO R9700
#                 gfx1200  RX 9060 XT
#                 gfx1100  RX 7900 XT / XTX / GRE
#                 gfx1101  RX 7800 XT / 7700 XT
#   ROCM_TAG    rocm/dev-ubuntu-24.04 tag (7.x tags end in -complete).
#   STRATA_REF  Strata commit or branch (default main).

ARG ROCM_TAG=7.2.1-complete
FROM rocm/dev-ubuntu-24.04:${ROCM_TAG}

# STRATA_EXECV=1: setup.py replaces itself with the server, so the server is
# PID 1 and docker stop's SIGTERM reaches it (as in upstream's image).
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8 STRATA_EXECV=1 \
    ROCM_PATH=/opt/rocm HIP_PATH=/opt/rocm LD_LIBRARY_PATH=/opt/rocm/lib

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libatomic1 libgomp1 \
        python3 python3-pip python3-venv unzip \
    && rm -rf /var/lib/apt/lists/*

# Strata's source. Pin STRATA_REF to a commit for a reproducible build; the
# default follows main. An empty value (a failed $(git rev-parse ...) in the
# build command) also falls back to main rather than failing the clone.
ARG STRATA_REPO=https://github.com/Niko1221/Strata.git
ARG STRATA_REF=main
RUN git clone "$STRATA_REPO" /opt/strata \
    && git -C /opt/strata checkout --detach "${STRATA_REF:-main}" \
    && git -C /opt/strata log -1 --format='Strata %H (%cd)' \
    && rm -rf /opt/strata/.git

WORKDIR /opt/strata

RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt \
    && chmod +x setup.sh docker-entrypoint.sh

# The engine, built by setup.py's own HIP build (build_engine_hip): same cmake
# flags as a normal Linux install, against /opt/rocm. It writes engine/BUILD.json,
# which is what setup.py checks at start: a matching source hash, backend and
# arch means the container reuses this engine instead of recompiling.
# docker build has no GPU, so the architecture is given here, not detected.
ARG HIP_ARCHS=gfx1201
RUN .venv/bin/python - <<'PYEOF'
import os, sys
import setup

archs = [a for a in os.environ["HIP_ARCHS"].replace(",", ";").split(";") if a]
ver = setup.rocm_version("/opt/rocm")
print(f"ROCm in /opt/rocm: {ver}", flush=True)
if ver is None or ver < setup.ROCM_SYSTEM_MIN:
    sys.exit(f"the base image's ROCm ({ver}) is older than Strata's minimum {setup.ROCM_SYSTEM_MIN}")

llama = setup.get_llama_cpp()
eng = setup.build_engine_hip({"arch": archs[0], "archs": archs}, llama, "none")

meta = (eng / "BUILD.json").read_text()
if '"/opt/rocm/lib"' not in meta:
    sys.exit("the engine was not built against /opt/rocm (setup.py fell back to its own ROCm wheels):\n" + meta)
for a in archs:
    setup.hipblaslt_table(a, ["/opt/rocm/lib"])
PYEOF

# the cmake tree is build-time only; engine/ holds what the container runs
RUN rm -rf build-hip

VOLUME ["/data"]
EXPOSE 8080

# /health answers before the API-key gate. The port opens only after the model
# loads (minutes; much longer on a first setup), hence the long start period.
HEALTHCHECK --interval=30s --timeout=5s --start-period=900s --retries=3 \
  CMD curl -fs "http://127.0.0.1:${PORT:-8080}/health" || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
