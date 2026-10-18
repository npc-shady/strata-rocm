# strata-rocm

Run [Strata](https://github.com/Niko1221/Strata) in Docker on an AMD Radeon card,
on Linux, with ROCm 7.2.

Strata runs Qwen3.8-Flash-Next, a large mixture-of-experts model, on one consumer
GPU by keeping the experts the card uses most in VRAM and the rest in RAM or on
the SSD. Upstream ships a Docker image for NVIDIA cards only; this repo is the
AMD version: a Dockerfile that compiles Strata's HIP engine against ROCm 7.2,
a compose file, and a script that sets it up for your card.

This repo holds no model and no prebuilt image. You build the image on your own
PC (the engine is compiled for its CPU and GPU), and the model downloads on the
first start.

## Cards

| Card | VRAM | Arch | Status |
|---|---|---|---|
| Radeon AI PRO R9700 | 32 GB | gfx1201 | tested here (numbers below) |
| RX 9070 XT / RX 9070 | 16 GB | gfx1201 | same engine as the R9700; not tested here |
| RX 9060 XT 16 GB | 16 GB | gfx1200 | builds for it; not tested here |
| RX 7900 XTX | 24 GB | gfx1100 | builds for it; not tested here |
| RX 7900 XT / 7900 GRE | 20 / 16 GB | gfx1100 | builds for it; not tested here |
| RX 7800 XT / 7700 XT | 16 / 12 GB | gfx1101 | builds for it; not tested here |

Strata itself supports all of these on Linux. ROCm 7.2.x is used because Strata
ships hipBLASLt tuning tables for that version (hipBLASLt 1.2.2) for gfx1100,
gfx1200 and gfx1201, which make prompt reading faster. For gfx1101 there is no
table, so prompts use plain hipBLAS. Integrated Radeon graphics are not
supported. The 8 GB RX 9060 XT is below Strata's 12 GB minimum.

If you run it on one of the untested cards, an issue with your numbers is very
welcome.

## What you need

- **Linux** with the kernel's `amdgpu` driver. ROCm does not need to be
  installed on the host; it is in the image.
- **Docker** with the compose plugin (`docker compose version`).
- **A CPU with AVX2** (any Ryzen; Intel from Haswell on).
- **RAM:** 32 GB at least, 64 GB recommended. Less RAM means more of the model
  is read from the SSD while it runs, which is slower.
- **Disk:** about 30 GB for the image, plus 70 to 130 GB per model. Put the model
  folder (`STRATA_DATA`) on an NVMe SSD.
- Internet on the first start: the model comes from Hugging Face.

## Quick start

```bash
git clone https://github.com/<you>/strata-rocm.git
cd strata-rocm
./configure.sh                 # finds your card, writes .env with a new API key
./build-image.sh               # 20-40 min: pulls ROCm, compiles the engine for your card
docker compose up -d
docker compose logs -f         # first start: download and set-up, then "loaded"
```

`configure.sh` reads the card, VRAM and RAM from the kernel and picks a starting
model and context (see below). `build-image.sh` finds the card the same way; to
choose it yourself, use `--gpu 9070xt` (or `r9700`, `9060xt`, `7900xtx`, `7900xt`,
`gfx1100`, ...), or `--gpu all` for one image that runs on all of them, which
takes longer to build.

Check that the build found everything: it ends with lines like

```
ROCm in /opt/rocm: <version, 7.2.x>
Strata <commit> (<date>)
hipBLASLt tuning table: gfx1201-hipblaslt-100202.txt (faster prompts)
```

The table's name matches your card (`gfx1100-...` for an RX 7900, `gfx1200-...`
for an RX 9060 XT). A line saying `no hipBLASLt tuning table` instead means
prompts will be slower but everything else works.

## Use it

Strata speaks the OpenAI API (and Anthropic's) on port 8081, with your API key:

```bash
KEY=$(grep '^STRATA_API_KEY=' .env | cut -d= -f2-)
curl -s http://127.0.0.1:8081/v1/models -H "Authorization: Bearer $KEY"
curl -s http://127.0.0.1:8081/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next-iq3_xxs","messages":[{"role":"user","content":"Hello"}]}'
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
| 32 GB | 262144 (measured) | R9700 |
| 20-24 GB | 131072 | RX 7900 XT, RX 7900 XTX |
| 16 GB | 65536 | RX 9060 XT 16 GB, RX 9070 XT, RX 9070, RX 7900 GRE |

| RAM | Starting `STRATA_MODEL` |
|---|---|
| 64 GB or more | IQ3_XXS |
| 32-48 GB | IQ2_XS |

Only the R9700 row has been measured; the others are cautious starting points.
Raise the context if the logs show room, lower it if the start fails or speed is
poor. A 16 GB card that also drives your desktop has less free VRAM than it
says; start lower.

To change the context, KV cache or LOW_RAM of a model that is already set up,
set `STRATA_REINSTALL=1` in `.env`, run `docker compose up -d`, wait for the
start, then set it back to 0. Switching `STRATA_MODEL` to another size needs no
reinstall; it downloads that one on the next start.

All settings are explained in [`.env.example`](.env.example).

## Measured: Radeon AI PRO R9700, 64 GB RAM

Strata in this image, ROCm 7.2.1, `LOW_RAM=on`, KV cache int8, MTP on, with
a media server, game servers and other containers running on the same PC.

| | IQ2_XS, 64K | IQ3_XXS, 64K | IQ3_XXS, 256K |
|---|---|---|---|
| Experts in VRAM | 19,721 (~74%) | 15,712 (~62%) | 13,972 (~55%) |
| Writing speed | 67-83 t/s, peaks 100+ | 74-81 t/s | 74-81 t/s |
| Prompt reading, short prompt | 120-151 t/s | 96 t/s | not measured |
| VRAM hit rate | 98-99% | 92-99% | 98.6-99% |
| Container RAM (anon) | not measured | ~22 GiB | not measured |

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

Unsloth's 4-bit files (UD-*) are not tested here on AMD, and Strata's docs
disagree with each other on whether they run on AMD cards; check upstream first.

## Good to know

- **Build on the PC that runs it.** The engine is compiled for the CPU and GPU
  of the machine that builds the image. Do not push the built image to a
  registry for others; share this repo instead.
- **The first start takes a while**: 70-80 GB to download, then Strata packs
  the model for your card. Later starts take 1-3 minutes. `docker compose logs -f`
  shows progress. The container's health check allows 15 minutes before the
  first check counts.
- **Strata holds the card the whole time it runs.** It cannot unload and keep
  listening. [`extras/`](extras/README.md) has an idle stop and a wake-on-request
  proxy so the card can sleep when nothing is using it.
- **Run compose from this folder**, so it finds `.env`. Without it, even
  `docker compose down` refuses to run, because the API key is required.
- **Memory limits:** with `LOW_RAM=on`, a Docker memory limit is safe, because
  the experts the card can't hold are read from the model files rather than
  copied into RAM. Measure the container's `anon` memory under load first
  (`memory.stat` in its cgroup) and leave headroom.
- **Several cards:** `STRATA_GPUS=0,1` (or `all`) shares one model across cards,
  and `STRATA_GPU=1` uses one card only. Not tested here; see Strata's
  docs/MULTI_GPU.md.
- **Pin Strata for a repeatable build:** `STRATA_REF=<commit> ./build-image.sh`.
  The default follows Strata's `main`.
- **Pictures** (vision) are turned off in this setup.

## Files

| File | What it is |
|---|---|
| `Dockerfile` | ROCm 7.2.1 image; compiles Strata's HIP engine for `HIP_ARCHS` |
| `build-image.sh` | finds the card, builds, prints the lines to check |
| `configure.sh` | writes `.env` for this PC |
| `compose.yaml` | the service: GPU devices, groups, memlock, `/data` volume |
| `.env.example` | every setting, explained |
| `lib/gpu.sh` | card detection from sysfs, shared by the two scripts |
| `extras/` | optional idle stop and wake-on-request proxy (systemd) |

## Credit and licence

[Strata](https://github.com/Niko1221/Strata) is by Niko1221 and contributors,
under the MIT licence; this repo only packages it, and the image's container
start uses Strata's own `docker-entrypoint.sh`. The model weights come with
their own licence. This repo is MIT too: see [LICENSE](LICENSE).
