# legacy: the self-built 0.1.x image

Until November 2026 this repo compiled Strata's HIP engine inside `docker build`
against ROCm 7.2 (`Dockerfile`, `build-image.sh`). Strata 0.2.x changed how it is
built and started (`setup.py` and `docker-entrypoint.sh` left the repository root,
and the engine no longer uses llama.cpp), so this build **only works for Strata
0.1.x commits**. Upstream now publishes an AMD image itself; the main
[README](../README.md) uses it.

These files are kept for anyone who needs to rebuild an old pinned image, e.g.
to roll back:

```bash
STRATA_REF=<a 0.1.x commit> legacy/build-image.sh --gpu r9700
# then STRATA_IMAGE=strata-rocm:local in .env
```

A volume used by the official image has had its `models/`, `packs/` and `mtp/`
moved into `Strata-data/`. To go back to this image, move them back first:

```bash
cd strata-data && for d in models packs mtp; do [ -d Strata-data/$d ] && mv Strata-data/$d/* $d/; done
```

The 0.1.x image read `LOW_RAM`, `REINSTALL`, `KV_STREAMING` and `HOST`, which the
official image ignores; see the old `.env.example` in git history
(`git show 547d98b:.env.example`).
