#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "Usage: $0 IMAGEBUILDER_DIR SYSUPGRADE_ITB OUTPUT_BIN KERNEL_VERSION METADATA_JSON" >&2
  exit 1
fi

imagebuilder_dir="$(realpath "$1")"
sysupgrade_itb="$(realpath "$2")"
output_bin="$3"
kernel_version="$4"
metadata_json="$(realpath "$5")"

host_bin="${imagebuilder_dir}/staging_dir/host/bin"
mkits="${imagebuilder_dir}/scripts/mkits.sh"
sysupgrade_tar="${imagebuilder_dir}/scripts/sysupgrade-tar.sh"

resolve_tool() {
  local tool_name="$1"
  local bundled_tool="${host_bin}/${tool_name}"
  if [[ -x "${bundled_tool}" ]]; then
    printf '%s\n' "${bundled_tool}"
    return
  fi
  command -v "${tool_name}"
}

dumpimage="$(resolve_tool dumpimage)"
fdtget="$(resolve_tool fdtget)"
fdtput="$(resolve_tool fdtput)"
fwtool="$(resolve_tool fwtool)"
mkimage="$(resolve_tool mkimage)"

for tool in "${dumpimage}" "${fdtget}" "${fdtput}" "${fwtool}" \
  "${mkimage}" "${mkits}" "${sysupgrade_tar}"; do
  if [[ ! -x "${tool}" ]]; then
    echo "Required ImageBuilder tool is unavailable: ${tool}" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

fit_listing="${work_dir}/fit-listing.txt"
"${dumpimage}" -l "${sysupgrade_itb}" | tee "${fit_listing}"

image_index() {
  local image_name="$1"
  local index
  index="$(
    awk -v image_name="(${image_name})" '
      $1 == "Image" && $3 == image_name {
        print $2
      }
    ' "${fit_listing}"
  )"
  if [[ ! "${index}" =~ ^[0-9]+$ ]]; then
    echo "Could not find a unique ${image_name} component in the sysupgrade FIT." >&2
    exit 1
  fi
  printf '%s\n' "${index}"
}

kernel_index="$(image_index kernel-1)"
fdt_index="$(image_index fdt-1)"
rootfs_index="$(image_index rootfs-1)"
kernel_load="0x$("${fdtget}" -t x "${sysupgrade_itb}" /images/kernel-1 load)"
kernel_entry="0x$("${fdtget}" -t x "${sysupgrade_itb}" /images/kernel-1 entry)"
if [[ ! "${kernel_load}" =~ ^0x[0-9a-fA-F]+$ ||
      ! "${kernel_entry}" =~ ^0x[0-9a-fA-F]+$ ]]; then
  echo "Could not read the kernel load and entry addresses from the FIT." >&2
  exit 1
fi

kernel_gz="${work_dir}/kernel.bin.gz"
legacy_dtb="${work_dir}/qihoo-360t7-legacy.dtb"
rootfs="${work_dir}/rootfs.squashfs"

"${dumpimage}" -T flat_dt -p "${kernel_index}" -o "${kernel_gz}" "${sysupgrade_itb}"
"${dumpimage}" -T flat_dt -p "${fdt_index}" -o "${legacy_dtb}" "${sysupgrade_itb}"
"${dumpimage}" -T flat_dt -p "${rootfs_index}" -o "${rootfs}" "${sysupgrade_itb}"

if [[ "$(od -An -tx1 -N4 "${rootfs}" | tr -d ' \n')" != "68737173" ]]; then
  echo "The extracted rootfs is not a little-endian squashfs image." >&2
  exit 1
fi

# The upstream image binds this DTB to a combined FIT UBI volume. This U-Boot
# updater instead writes separate kernel and rootfs volumes.
"${fdtput}" -d "${legacy_dtb}" /chosen bootargs-append
"${fdtput}" -d "${legacy_dtb}" /chosen rootdisk

if "${fdtget}" "${legacy_dtb}" /chosen bootargs-append >/dev/null 2>&1 ||
   "${fdtget}" "${legacy_dtb}" /chosen rootdisk >/dev/null 2>&1; then
  echo "The legacy DTB still forces the combined FIT root disk." >&2
  exit 1
fi

legacy_its="${work_dir}/kernel-legacy.its"
legacy_kernel="${work_dir}/kernel-legacy.itb"
"${mkits}" \
  -A arm64 \
  -C gzip \
  -a "${kernel_load}" \
  -e "${kernel_entry}" \
  -v "${kernel_version}" \
  -k "${kernel_gz}" \
  -D qihoo_360t7 \
  -d "${legacy_dtb}" \
  -c config-1 \
  -o "${legacy_its}"
"${mkimage}" -f "${legacy_its}" "${legacy_kernel}"

legacy_kernel_listing="${work_dir}/legacy-kernel-listing.txt"
"${dumpimage}" -l "${legacy_kernel}" | tee "${legacy_kernel_listing}"
grep -Fq "Image 0 (kernel-1)" "${legacy_kernel_listing}"
grep -Fq "Image 1 (fdt-1)" "${legacy_kernel_listing}"
if grep -Fq "(rootfs-1)" "${legacy_kernel_listing}"; then
  echo "The legacy kernel FIT unexpectedly contains the rootfs." >&2
  exit 1
fi

mkdir -p "$(dirname "${output_bin}")"
TOPDIR="${imagebuilder_dir}" \
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
  sh "${sysupgrade_tar}" \
    --board qihoo_360t7 \
    --kernel "${legacy_kernel}" \
    --rootfs "${rootfs}" \
    "${output_bin}"

"${fwtool}" -I "${metadata_json}" "${output_bin}"

expected_members="$(
  printf '%s\n' \
    "sysupgrade-qihoo_360t7/" \
    "sysupgrade-qihoo_360t7/CONTROL" \
    "sysupgrade-qihoo_360t7/kernel" \
    "sysupgrade-qihoo_360t7/root"
)"
actual_members="$(tar -tf "${output_bin}")"
if [[ "${actual_members}" != "${expected_members}" ]]; then
  echo "The U-Boot Web image has an unexpected tar layout:" >&2
  printf '%s\n' "${actual_members}" >&2
  exit 1
fi

if [[ "$(tar -xOf "${output_bin}" sysupgrade-qihoo_360t7/CONTROL)" != \
      "BOARD=qihoo_360t7" ]]; then
  echo "The U-Boot Web image has an unexpected board identifier." >&2
  exit 1
fi

verified_metadata="${work_dir}/verified-metadata.json"
"${fwtool}" -i "${verified_metadata}" "${output_bin}"
jq -e '
  .supported_devices | index("qihoo,360t7") != null
' "${verified_metadata}" >/dev/null

echo "Created verified 360T7 U-Boot Web image: ${output_bin}"
