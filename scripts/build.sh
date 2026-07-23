#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-"${ROOT_DIR}/work"}"
DIST_DIR="${DIST_DIR:-"${ROOT_DIR}/dist"}"
PROFILE="qihoo_360t7"
ARCH="aarch64_cortex-a53"
IMMORTALWRT_ROOT="${IMMORTALWRT_ROOT:-https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/targets/mediatek/filogic}"
DAED_REPOSITORY="${DAED_REPOSITORY:-kenzok8/openwrt-daede}"
IMAGEBUILDER_FILE="immortalwrt-imagebuilder-24.10-SNAPSHOT-mediatek-filogic.Linux-x86_64.tar.zst"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 1
  }
}

for command_name in curl jq sha256sum tar zstd make find; do
  require_command "${command_name}"
done

rm -rf "${WORK_DIR}" "${DIST_DIR}"
mkdir -p "${WORK_DIR}/downloads" "${WORK_DIR}/external-packages" "${DIST_DIR}"

download() {
  local url="$1"
  local output="$2"
  local curl_args=(
    --fail --location --retry 4 --retry-all-errors
    --connect-timeout 20 --max-time 1800
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${curl_args[@]}" --output "${output}" "${url}"
}

echo "Reading the current 24.10-SNAPSHOT profile metadata..."
curl --fail --location --retry 4 \
  --output "${WORK_DIR}/profiles.json" "${IMMORTALWRT_ROOT}/profiles.json"
curl --fail --location --retry 4 \
  --output "${WORK_DIR}/sha256sums" "${IMMORTALWRT_ROOT}/sha256sums"

target="$(jq -r '.target' "${WORK_DIR}/profiles.json")"
ib_version="$(jq -r '.version_number' "${WORK_DIR}/profiles.json")"
ib_revision="$(jq -r '.version_code' "${WORK_DIR}/profiles.json")"
kernel_version="$(jq -r '.linux_kernel.version' "${WORK_DIR}/profiles.json")"
arch_packages="$(jq -r '.arch_packages' "${WORK_DIR}/profiles.json")"
supported_device="$(jq -r --arg profile "${PROFILE}" \
  '.profiles[$profile].supported_devices[] | select(. == "qihoo,360t7")' \
  "${WORK_DIR}/profiles.json")"

if [[ "${target}" != "mediatek/filogic" ||
      "${ib_version}" != "24.10-SNAPSHOT" ||
      "${arch_packages}" != "${ARCH}" ||
      "${supported_device}" != "qihoo,360t7" ]]; then
  echo "ImageBuilder metadata does not match the dedicated 360T7 target." >&2
  exit 1
fi

expected_ib_sha256="$(
  awk -v file="${IMAGEBUILDER_FILE}" '$2 == "*" file { print $1 }' \
    "${WORK_DIR}/sha256sums"
)"
if [[ ! "${expected_ib_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ImageBuilder checksum was not found in upstream sha256sums." >&2
  exit 1
fi

echo "Downloading ${IMAGEBUILDER_FILE}..."
curl --fail --location --retry 4 --retry-all-errors \
  --connect-timeout 20 --max-time 3600 \
  --output "${WORK_DIR}/downloads/${IMAGEBUILDER_FILE}" \
  "${IMMORTALWRT_ROOT}/${IMAGEBUILDER_FILE}"
echo "${expected_ib_sha256}  ${WORK_DIR}/downloads/${IMAGEBUILDER_FILE}" |
  sha256sum --check -

tar --use-compress-program=unzstd \
  --extract --file "${WORK_DIR}/downloads/${IMAGEBUILDER_FILE}" \
  --directory "${WORK_DIR}"
imagebuilder_dir="$(
  find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d \
    -name 'immortalwrt-imagebuilder-*' -print -quit
)"
if [[ -z "${imagebuilder_dir}" ]]; then
  echo "Extracted ImageBuilder directory was not found." >&2
  exit 1
fi

echo "Resolving the current daed Release..."
release_api="https://api.github.com/repos/${DAED_REPOSITORY}/releases/latest"
curl_args=(
  --fail --location --retry 4
  --header "Accept: application/vnd.github+json"
  --header "X-GitHub-Api-Version: 2022-11-28"
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi
curl "${curl_args[@]}" --output "${WORK_DIR}/daed-release.json" "${release_api}"
daed_tag="$(jq -r '.tag_name' "${WORK_DIR}/daed-release.json")"

select_asset() {
  local jq_filter="$1"
  local description="$2"
  local count
  count="$(jq --arg arch "${ARCH}" --arg kernel "${kernel_version}" \
    "[.assets[] | select(${jq_filter})] | length" \
    "${WORK_DIR}/daed-release.json")"
  if [[ "${count}" != "1" ]]; then
    echo "Expected exactly one ${description}; found ${count} in ${daed_tag}." >&2
    exit 1
  fi
  jq -r --arg arch "${ARCH}" --arg kernel "${kernel_version}" \
    ".assets[] | select(${jq_filter}) | .name" \
    "${WORK_DIR}/daed-release.json"
}

# jq variables are intentionally expanded by jq, not by this shell.
# shellcheck disable=SC2016
daed_asset="$(select_asset \
  '(.name | startswith("daed_") and endswith("_" + $arch + ".ipk"))' \
  "daed IPK for ${ARCH}")"
luci_asset="$(select_asset \
  '(.name | startswith("luci-app-daede_") and endswith("_all.ipk"))' \
  "luci-app-daede IPK")"
# shellcheck disable=SC2016
btf_asset="$(select_asset \
  '(.name | startswith("vmlinux-btf_" + $kernel + "-") and endswith("_" + $arch + ".ipk"))' \
  "BTF IPK for kernel ${kernel_version} and ${ARCH}")"

for asset in "${daed_asset}" "${luci_asset}" "${btf_asset}"; do
  asset_url="$(jq -r --arg name "${asset}" \
    '.assets[] | select(.name == $name) | .browser_download_url' \
    "${WORK_DIR}/daed-release.json")"
  asset_digest="$(jq -r --arg name "${asset}" \
    '.assets[] | select(.name == $name) | (.digest // "")' \
    "${WORK_DIR}/daed-release.json")"
  destination="${WORK_DIR}/external-packages/${asset}"
  echo "Downloading ${asset}..."
  download "${asset_url}" "${destination}"
  if [[ "${asset_digest}" == sha256:* ]]; then
    echo "${asset_digest#sha256:}  ${destination}" | sha256sum --check -
  fi
done

(
  cd "${WORK_DIR}/external-packages"
  sha256sum -- *.ipk >"${DIST_DIR}/external-packages.sha256"
)

patched_packages="${WORK_DIR}/patched-packages"
repack_dir="${WORK_DIR}/daed-repack"
mkdir -p "${patched_packages}" "${repack_dir}/outer" "${repack_dir}/data"
cp "${WORK_DIR}/external-packages/${luci_asset}" "${patched_packages}/"
cp "${WORK_DIR}/external-packages/${btf_asset}" "${patched_packages}/"

# During ImageBuilder finalization, init scripts run from the target rootfs but
# outside chroot. The upstream daed init script sources an absolute target path,
# which resolves against the Ubuntu runner and makes ImageBuilder return 1.
# Repack the already verified IPK with a relative-root fallback for build time.
tar --extract \
  --file "${WORK_DIR}/external-packages/${daed_asset}" \
  --directory "${repack_dir}/outer"
tar --extract --gzip \
  --file "${repack_dir}/outer/data.tar.gz" \
  --directory "${repack_dir}/data"
daed_init="${repack_dir}/data/etc/init.d/daed"
if [[ "$(grep -c '^\. /usr/share/daed/cleanup\.sh$' "${daed_init}")" != "1" ]]; then
  echo "The daed init script has an unexpected cleanup helper declaration." >&2
  exit 1
fi

awk '
  $0 == ". /usr/share/daed/cleanup.sh" {
    print "DAED_CLEANUP=/usr/share/daed/cleanup.sh"
    print "[ -r \"$DAED_CLEANUP\" ] || DAED_CLEANUP=./usr/share/daed/cleanup.sh"
    print ". \"$DAED_CLEANUP\""
    next
  }
  { print }
' "${daed_init}" >"${daed_init}.patched"
mv "${daed_init}.patched" "${daed_init}"
chmod 0755 "${daed_init}"

tar --create --gzip \
  --owner=0 --group=0 --numeric-owner \
  --file "${repack_dir}/outer/data.tar.gz" \
  --directory "${repack_dir}/data" .
tar --create \
  --owner=0 --group=0 --numeric-owner \
  --file "${patched_packages}/${daed_asset}" \
  --directory "${repack_dir}/outer" \
  ./debian-binary ./control.tar.gz ./data.tar.gz

cp "${patched_packages}"/*.ipk "${imagebuilder_dir}/packages/"

echo "Building the dedicated ${PROFILE} image..."
if make -C "${imagebuilder_dir}" image \
    PROFILE="${PROFILE}" \
    PACKAGES="daed luci-app-daede vmlinux-btf" \
    DISABLED_SERVICES="daed" \
    FILES="${ROOT_DIR}/files"; then
  imagebuilder_status=0
else
  imagebuilder_status=$?
fi
echo "ImageBuilder command status: ${imagebuilder_status}"
if [[ "${imagebuilder_status}" -ne 0 ]]; then
  echo "ImageBuilder returned ${imagebuilder_status}; validating generated output before deciding failure."
fi

echo "Locating the dedicated 360T7 sysupgrade image..."
find "${imagebuilder_dir}/bin/targets/mediatek/filogic" \
  -maxdepth 1 -type f -printf 'Generated: %f\n'
mapfile -t sysupgrade_images < <(
  find "${imagebuilder_dir}/bin/targets/mediatek/filogic" \
    -maxdepth 1 -type f \
    -name '*qihoo_360t7*squashfs-sysupgrade.itb' -print
) || true
if [[ "${#sysupgrade_images[@]}" -ne 1 ]]; then
  echo "Expected exactly one qihoo_360t7 sysupgrade image; found ${#sysupgrade_images[@]}." >&2
  exit 1
fi
sysupgrade_image="${sysupgrade_images[0]}"

if find "${imagebuilder_dir}/bin/targets/mediatek/filogic" \
  -maxdepth 1 -type f -name '*sysupgrade*' ! -name '*qihoo_360t7*' |
  grep -q .; then
  echo "A sysupgrade image for another device was unexpectedly generated." >&2
  exit 1
fi

firmware_name="immortalwrt-${ib_version,,}-${ib_revision}-mediatek-filogic-qihoo_360t7-daed-${daed_tag#v}-squashfs-sysupgrade.itb"
cp "${sysupgrade_image}" "${DIST_DIR}/${firmware_name}"

manifest="$(
  find "${imagebuilder_dir}/bin/targets/mediatek/filogic" \
    -maxdepth 1 -type f -name '*qihoo_360t7*.manifest' -print -quit
)"
if [[ -z "${manifest}" ]]; then
  echo "The 360T7 package manifest was not generated." >&2
  exit 1
fi
cp "${manifest}" "${DIST_DIR}/${firmware_name%.itb}.manifest"

for required_package in daed luci-app-daede vmlinux-btf; do
  if ! grep -qE "^${required_package} -" "${DIST_DIR}/${firmware_name%.itb}.manifest"; then
    echo "${required_package} is absent from the generated image manifest." >&2
    exit 1
  fi
done

metadata_file="${DIST_DIR}/${firmware_name%.itb}.metadata.json"
fwtool="${imagebuilder_dir}/staging_dir/host/bin/fwtool"
if [[ -x "${fwtool}" ]]; then
  "${fwtool}" -I "${metadata_file}" "${DIST_DIR}/${firmware_name}"
  jq -e '
    .supported_devices | index("qihoo,360t7") != null
  ' "${metadata_file}" >/dev/null
else
  jq --arg warning "fwtool was unavailable; profile validation was performed before the build." \
    '{warning: $warning}' >"${metadata_file}"
fi

(
  cd "${DIST_DIR}"
  sha256sum -- "${firmware_name}" >"${firmware_name}.sha256"
)

cat >"${DIST_DIR}/RELEASE_NOTES.md" <<EOF
## 360T7 dedicated ImageBuilder firmware

- Device: Qihoo 360T7 only (\`qihoo_360t7\`, supported device \`qihoo,360t7\`)
- ImmortalWrt: \`${ib_version}\` / \`${ib_revision}\`
- Target: \`${target}\`
- Architecture: \`${ARCH}\`
- Kernel: \`${kernel_version}\`
- daed Release: \`${daed_tag}\`
- Integrated packages: \`${daed_asset}\`, \`${luci_asset}\`, \`${btf_asset}\`
- Default LAN address on a clean installation: \`192.168.233.1\`

The build fails instead of publishing when the daed Release does not contain a
BTF package matching both the ImageBuilder kernel version and package architecture.
Do not flash this image on any model other than Qihoo 360T7.
EOF

release_tag="360t7-${ib_revision}-daed-${daed_tag#v}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "release_tag=${release_tag}"
    echo "firmware=${firmware_name}"
    echo "ib_revision=${ib_revision}"
    echo "kernel_version=${kernel_version}"
    echo "daed_tag=${daed_tag}"
  } >>"${GITHUB_OUTPUT}"
fi

echo "Build completed: ${DIST_DIR}/${firmware_name}"
