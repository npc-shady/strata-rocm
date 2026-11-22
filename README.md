# strata-rocm

Run [Strata](https://github.com/Niko1221/Strata) in Docker on an AMD Radeon card,
on Linux, set up for your card in one step.

Strata runs Qwen3.8-Flash-Next, a large mixture-of-experts model, on one consumer
GPU by keeping the experts the card uses most in VRAM and the rest in RAM or on
the SSD.

> **Since November 2026 this repo uses upstream's own AMD image**
> (`ghcr.io/niko1221/strata:<version>-rocm-gfx120x` / `-rocm-gfx110x`), which
> carries the engine and its ROCm runtime. Nothing is compiled here any more.
> What this repo adds on top: `configure.sh` (finds your card and writes the
> settings), a compose file, starting points per card, measured numbers on an
> R9700, and [`extras/`](extras/README.md) to let the card sleep when Strata is
> idle. Coming from the old self-built image? See
> [Upgrading from the self-built image](#upgrading-from-the-self-built-image).

This repo holds no model and no image of its own. The image comes from
upstream's registry, and the model downloads on the first start.

## Cards

| Card | VRAM | Arch | Image flavour | Status |
|---|---|---|---|---|
| Radeon AI PRO R9700 | 32 GB | gfx1201 | `rocm-gfx120x` | tested here (numbers below) |
| RX 9070 XT / RX 9070 | 16 GB | gfx1201 | `rocm-gfx120x` | same engine as the R9700; not tested here |
| RX 9060 XT 16 GB | 16 GB | gfx1200 | `rocm-gfx120x` | not tested here |
| RX 7900 XTX | 24 GB | gfx1100 | `rocm-gfx110x` | not tested here |
| RX 7900 XT / 7900 GRE | 20 / 16 GB | gfx1100 | `rocm-gfx110x` | not tested here |
| RX 7800 XT / 7700 XT | 16 / 12 GB | gfx1101 | `rocm-gfx110x` | not tested here |
| RX 7600 XT | 16 GB | gfx1102 | `rocm-gfx110x` | reported working upstream; not tested here |

Integrated Radeon graphics are not covered here (Strix Halo has its own upstream
image, `rocm-gfx1151`). The 8 GB RX 9060 XT is below Strata's 12 GB minimum.

If you run it on one of the untested cards, an issue with your numbers is very
welcome.

## What you need

- **Linux** with the kernel's `amdgpu` driver (Linux 6.8+ for RDNA 4). ROCm does
  not need to be installed on the host; it is in the image.
- **Docker** with the compose plugin (`docker compose version`).
- **A CPU with AVX2** (any Ryzen; Intel from Haswell on).
- **RAM:** 32 GB at least, 64 GB recommended. Less RAM means more of the model
  is read from the SSD while it runs, which is slower.
- **Disk:** about 3 GB for the image, plus 70 to 130 GB per model. Put the model
  folder (`STRATA_DATA`) on an NVMe SSD.
- Internet on the first start: the image from ghcr.io, the model from Hugging Face.

## Quick start

```bash
git clone https://github.com/npc-shady/strata-rocm.git
cd strata-rocm
./configure.sh                 # finds your card, writes .env with a new API key
docker compose pull            # upstream's image for your card, ~0.8 GB
docker compose up -d
docker compose logs -f         # first start: download and set-up, then "loaded"
```

`configure.sh` reads the card, VRAM and RAM from the kernel, picks the image
flavour for the card, a starting model and context (see below), and the
video/render group numbers the container needs.

**Pin the version.** `configure.sh` writes `latest-<flavour>`, which follows
upstream. To update only when you choose, set `STRATA_IMAGE` in `.env` to an
explicit tag, e.g. `ghcr.io/niko1221/strata:0.2.19-rocm-gfx120x`. The version of
an image you have is in its label:

```bash
docker image inspect "$(grep '^STRATA_IMAGE=' .env | cut -d= -f2-)" \
  -f '{{ index .Config.Labels "org.opencontainers.image.version" }}'
```

## Use it

Strata speaks the OpenAI API (and Anthropic's) on port 8081, with your API key:

```bash
KEY=$(grep '^STRATA_API_KEY=' .env | cut -d= -f2-)
curl -s http://127.0.0.1:8081/v1/models -H "Authorization: Bearer $KEY"
curl -s http://127.0.0.1:8081/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"strata","messages":[{"role":"user","content":"Hello"}]}'
```

Use the model name `/v1/models` gives you. In OpenCode, Continue, Open WebUI and
the like, add an OpenAI-compatible provider with base URL
`http://<host>:8081/v1` and the key. Strata's dashboard is on the same port in a
browser.

The port is bound to `127.0.0.1` (this PC only) by default. Set
`STRATA_BIND=0.0.0.0` in `.env` to serve your LAN; the key is still required.

## Settings by card

Strata fills the VRAM left over after the context's KV cache with experts, so a
longer context means fewer experts on the card and a little less speed. RAM
decides which model sizes fit comfortably.

| VRAM | Starting `STRATA_CONTEXT` | Cards |
|---|---|---|
| 32 GB | 256k (measured) | R9700 |
| 20-24 GB | 128k | RX 7900 XT, RX 7900 XTX |
| 16 GB | 64k | RX 9060 XT 16 GB, RX 9070 XT, RX 9070, RX 7900 GRE, RX 7600 XT |

| RAM | Starting `STRATA_MODEL` |
|---|---|
| 64 GB or more | IQ3_XXS (IQ3_S if it fits: closer to the full model) |
| 32-48 GB | IQ2_XS |

Only the R9700 row has been measured; the others are cautious starting points.
Leave `STRATA_MODEL` or `STRATA_CONTEXT` empty and Strata picks for your card and
says what it chose in the log. A 16 GB card that also drives your desktop has
less free VRAM than it says; start lower.

To change a setting, edit `.env` and run `docker compose up -d`. The model, the
prepared pack and any tuning stay in `STRATA_DATA`; switching `STRATA_MODEL` to
another size downloads that one on the next start. After an image update you can
re-tune once with `STRATA_TUNE=quick` and `STRATA_RETUNE=1` (then set it back to 0).

All settings are explained in [`.env.example`](.env.example); the full list is in
upstream's [docs/DOCKER.md](https://github.com/Niko1221/Strata/blob/main/docs/DOCKER.md).

## Measured: Radeon AI PRO R9700, 64 GB RAM

On the self-built image (Strata 0.1.x, ROCm 7.2.1), `LOW_RAM=on`, KV cache int8,
MTP on, with a media server, game servers and other containers running on the
same PC. Numbers for the official image will follow.

| | IQ2_XS, 64K | IQ3_XXS, 64K | IQ3_XXS, 256K | IQ3_S, 256K |
|---|---|---|---|---|
| Experts in VRAM | 19,721 (~74%) | 15,712 (~62%) | 13,972 (~55%) | ~11,750 |
| Writing speed | 67-83 t/s, peaks 100+ | 74-81 t/s | 74-81 t/s | 70-94 t/s at 12-24K context, 65-81 t/s at 55-84K |
| Prompt reading | 120-151 t/s (short prompt) | 96 t/s (short prompt) | not measured | 620-860 t/s (3-10K new tokens, warm) |
| VRAM hit rate | 98-99% | 92-99% | 98.6-99% | 93-97% |
| Container RAM (anon) | not measured | ~22 GiB | not measured | not measured |

The IQ3_S column is from a real coding-agent session (OpenCode with an Orca
lead), so its context grows request by request. The card's power cap made no
difference to it: 220 W and 260 W gave the same speeds (70.9 vs 72.7 t/s over
the whole session), so on this card Strata looks limited by memory and the
experts in system RAM rather than by the GPU's power.

For comparison, the same card runs a dense 27B model at Q4 with MTP at about
30-45 t/s. In an agent setup (OpenCode, 8 graded tasks of 26K to 229K tokens of
context), IQ3_XXS at 256K graded 6 A and 2 B with no factual errors.

Quality of the sizes against the full Q8_0 model, from Strata's own tables
(higher "same top token" and lower KL are closer to the original):

| Model | Same top token | Mean KL |
|---|---|---|
| IQ3_XXS | 84.5% | 0.202 |
| IQ3_S | 87.7% | 0.144 |
| UD-IQ4_XS | 88.9% | 0.101 |
| UD-Q4_K_XL | 93.1% | 0.056 |

## Good to know

- **The first start takes a while**: 70-80 GB to download, then Strata prepares
  the model for your card. Later starts take 1-3 minutes. `docker compose logs -f`
  shows progress; `docker ps` says `starting` until the model is loaded.
- **Strata holds the card the whole time it runs.** It cannot unload and keep
  listening. [`extras/`](extras/README.md) has an idle stop and a wake-on-request
  proxy so the card can sleep when nothing is using it.
- **Run compose from this folder**, so it finds `.env`. Without it, even
  `docker compose down` refuses to run, because the API key is required.
- **No memory limit.** Strata plans from the host's RAM; a container memory
  limit gets it killed while the model loads.
- **Parallel requests.** One request alone gets MTP drafting (the fastest single
  stream). Requests that share the card are batched and decode without drafts.
  `STRATA_PARALLEL=1` keeps it to one at a time.
- **Several cards:** `STRATA_GPUS=0,1` (or `all`) shares one model across cards,
  and `STRATA_GPU=1` uses one card only. Not tested here; see Strata's
  docs/MULTI_GPU.md.
- **Pictures** (vision) are off by default: `STRATA_VISION=on` turns them on.

## Upgrading from the self-built image

The old image of this repo (compiled here, Strata 0.1.x) can't build current
Strata. To move an existing install to the official image, keeping the model:

```bash
git pull
docker compose down
cp .env .env.old
./configure.sh --force         # new .env; copy your STRATA_API_KEY, MODEL and CONTEXT back from .env.old
docker compose pull && docker compose up -d && docker compose logs -f
```

The first start of the official image moves `models/`, `packs/` and `mtp/` in
your `STRATA_DATA` folder into `STRATA_DATA/Strata-data/`: a rename, nothing is
downloaded again, and the prepared pack is kept. `LOW_RAM`, `REINSTALL`,
`KV_STREAMING` and `HOST` are retired (the image ignores them with a warning).
The old build is in [`legacy/`](legacy/README.md), with how to go back.

## Files

| File | What it is |
|---|---|
| `configure.sh` | writes `.env` for this PC: image flavour, model, context, groups, API key |
| `compose.yaml` | the service: upstream's image, GPU devices, groups, memlock, `/data` volume |
| `.env.example` | every setting, explained |
| `lib/gpu.sh` | card detection from sysfs |
| `extras/` | optional idle stop and wake-on-request proxy (systemd) |
| `legacy/` | the old self-built 0.1.x image, for rollback only |

## Credit and licence

[Strata](https://github.com/Niko1221/Strata) is by Niko1221 and contributors,
under the MIT licence; the image is theirs, built and published from their
signed release packages. This repo only sets it up. The model weights come with
their own licence. This repo is MIT too: see [LICENSE](LICENSE).
