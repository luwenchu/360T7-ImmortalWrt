#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "Usage: $0 IMAGEBUILDER_DIR SYSUPGRADE_ITB OUTPUT_BIN METADATA_JSON" >&2
  exit 1
fi

imagebuilder_dir="$(realpath "$1")"
sysupgrade_itb="$(realpath "$2")"
output_bin="$3"
metadata_json="$(realpath "$4")"
host_bin="${imagebuilder_dir}/staging_dir/host/bin"

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
fwtool="$(resolve_tool fwtool)"

if [[ "$(od -An -tx1 -N4 "${sysupgrade_itb}" | tr -d ' \n')" != "d00dfeed" ]]; then
  echo "The Web BIN source is not a raw FIT image." >&2
  exit 1
fi

"${dumpimage}" -l "${sysupgrade_itb}" |
  grep -Fq 'Image 0 (kernel-1)'
"${dumpimage}" -l "${sysupgrade_itb}" |
  grep -Fq '(rootfs-1)'

verified_metadata="$(mktemp)"
trap 'rm -f "${verified_metadata}"' EXIT
"${fwtool}" -i "${verified_metadata}" "${sysupgrade_itb}"
jq -e '
  .supported_devices | index("qihoo,360t7") != null
' "${verified_metadata}" >/dev/null
cmp --silent "${verified_metadata}" "${metadata_json}"

mkdir -p "$(dirname "${output_bin}")"
cp -- "${sysupgrade_itb}" "${output_bin}"
cmp --silent "${sysupgrade_itb}" "${output_bin}"

echo "Created byte-identical raw FIT Web BIN: ${output_bin}"
