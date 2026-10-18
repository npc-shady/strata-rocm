# shellcheck shell=bash
# Shared by build-image.sh and configure.sh. Reads the AMD cards from the kernel
# (amdgpu + KFD in sysfs), so the host needs no ROCm install.

# Cards this repo is built and documented for. Strata itself also lists gfx1101
# (RX 7800 XT / 7700 XT) and some older cards; see its docs.
SUPPORTED_ARCHS="gfx1100 gfx1101 gfx1200 gfx1201"
SYSFS="${STRATA_SYSFS:-/sys}"     # overridable for testing

# A card name -> its GPU architecture.
gpu_name_to_arch() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')" in
    r9700|aipror9700|9070xt|rx9070xt|9070|rx9070|9070gre|rx9070gre) echo gfx1201 ;;
    9060xt|rx9060xt|9060|rx9060)                                   echo gfx1200 ;;
    7900xtx|rx7900xtx|7900xt|rx7900xt|7900gre|rx7900gre)          echo gfx1100 ;;
    7800xt|rx7800xt|7700xt|rx7700xt)                              echo gfx1101 ;;
    gfx*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# One line per GPU: "<arch> <vram MiB> <render node>". CPU nodes are skipped.
# KFD's gfx_target_version is major*10000 + minor*100 + stepping (stepping in hex
# in the gfx name): 110000 -> gfx1100, 120001 -> gfx1201.
list_amd_gpus() {
  local p v minor arch vram
  for p in "$SYSFS"/class/kfd/kfd/topology/nodes/*/properties; do
    [ -r "$p" ] || continue
    v=$(awk '$1 == "gfx_target_version" {print $2}' "$p")
    [ -n "$v" ] && [ "$v" != 0 ] || continue
    arch=$(printf 'gfx%d%d%x' $((v / 10000)) $((v / 100 % 100)) $((v % 100)))
    minor=$(awk '$1 == "drm_render_minor" {print $2}' "$p")
    vram=0
    if [ -n "$minor" ] && [ -r "$SYSFS/class/drm/renderD$minor/device/mem_info_vram_total" ]; then
      vram=$(( $(cat "$SYSFS/class/drm/renderD$minor/device/mem_info_vram_total") / 1048576 ))
    fi
    echo "$arch $vram renderD${minor:-?}"
  done
}

# The supported card with the most VRAM: "<arch> <vram MiB>", or nothing.
best_amd_gpu() {
  list_amd_gpus | while read -r arch vram _; do
    case " $SUPPORTED_ARCHS " in *" $arch "*) echo "$arch $vram" ;; esac
  done | sort -k2,2nr | head -n1
}
