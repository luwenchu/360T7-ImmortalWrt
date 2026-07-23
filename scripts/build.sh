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

for command_name in curl jq sha256sum tar zstd make find realpath od; do
  require_command "${command_name}"
done

mkdir -p "${WORK_DIR}/downloads"
find "${WORK_DIR}" -mindepth 1 -maxdepth 1 \
  ! -name downloads -exec rm -rf -- {} +
rm -rf "${DIST_DIR}"
mkdir -p "${WORK_DIR}/external-packages" "${DIST_DIR}"

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
recovery_name="$(jq -r --arg profile "${PROFILE}" '
  .profiles[$profile].images[]
  | select(.type == "kernel" and .filesystem == "initramfs")
  | .name
' "${WORK_DIR}/profiles.json")"
recovery_sha256="$(jq -r --arg profile "${PROFILE}" '
  .profiles[$profile].images[]
  | select(.type == "kernel" and .filesystem == "initramfs")
  | .sha256
' "${WORK_DIR}/profiles.json")"

if [[ "${target}" != "mediatek/filogic" ||
      "${ib_version}" != "24.10-SNAPSHOT" ||
      "${arch_packages}" != "${ARCH}" ||
      "${supported_device}" != "qihoo,360t7" ||
      ! "${recovery_sha256}" =~ ^[0-9a-f]{64}$ ||
      "${recovery_name}" != *qihoo_360t7*initramfs-recovery.itb ]]; then
  echo "ImageBuilder metadata does not match the dedicated 360T7 target." >&2
  exit 1
fi

echo "Downloading the matching 360T7 initramfs recovery image..."
recovery_path="${DIST_DIR}/${recovery_name}"
curl --fail --location --retry 4 --retry-all-errors \
  --connect-timeout 20 --max-time 600 \
  --output "${recovery_path}" \
  "${IMMORTALWRT_ROOT}/${recovery_name}"
echo "${recovery_sha256}  ${recovery_path}" | sha256sum --check -

expected_ib_sha256="$(
  awk -v file="${IMAGEBUILDER_FILE}" '$2 == "*" file { print $1 }' \
    "${WORK_DIR}/sha256sums"
)"
if [[ ! "${expected_ib_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ImageBuilder checksum was not found in upstream sha256sums." >&2
  exit 1
fi

echo "Downloading ${IMAGEBUILDER_FILE}..."
imagebuilder_archive="${WORK_DIR}/downloads/${IMAGEBUILDER_FILE}"
if echo "${expected_ib_sha256}  ${imagebuilder_archive}" |
  sha256sum --check --status - 2>/dev/null; then
  echo "Using the cached, checksum-verified ImageBuilder archive."
else
  rm -f "${imagebuilder_archive}"
  curl --fail --location --retry 4 --retry-all-errors \
    --connect-timeout 20 --max-time 3600 \
    --output "${imagebuilder_archive}" \
    "${IMMORTALWRT_ROOT}/${IMAGEBUILDER_FILE}"
fi
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

package_version() {
  local package_file="$1"
  tar --extract --to-stdout --file "${package_file}" ./control.tar.gz |
    tar --extract --gzip --to-stdout --file - ./control |
    awk -F ': ' '$1 == "Version" { print $2; exit }'
}

daed_version="$(
  package_version "${WORK_DIR}/external-packages/${daed_asset}"
)"
luci_version="$(
  package_version "${WORK_DIR}/external-packages/${luci_asset}"
)"
btf_version="$(
  package_version "${WORK_DIR}/external-packages/${btf_asset}"
)"
for version in "${daed_version}" "${luci_version}" "${btf_version}"; do
  if [[ -z "${version}" ]]; then
    echo "Could not read an exact package version from the Release IPKs." >&2
    exit 1
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
tar --create --gzip \
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
shopt -s nullglob
sysupgrade_images=(
  "${imagebuilder_dir}"/bin/targets/mediatek/filogic/*qihoo_360t7*squashfs-sysupgrade.itb
)
shopt -u nullglob
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

declare -A required_versions=(
  [daed]="${daed_version}"
  [luci-app-daede]="${luci_version}"
  [vmlinux-btf]="${btf_version}"
)
for required_package in daed luci-app-daede vmlinux-btf; do
  expected_manifest_line="${required_package} - ${required_versions[$required_package]}"
  if ! grep -Fxq "${expected_manifest_line}" \
    "${DIST_DIR}/${firmware_name%.itb}.manifest"; then
    echo "Expected '${expected_manifest_line}' in the generated image manifest." >&2
    exit 1
  fi
done

metadata_file="${DIST_DIR}/${firmware_name%.itb}.metadata.json"
fwtool="${imagebuilder_dir}/staging_dir/host/bin/fwtool"
if [[ -x "${fwtool}" ]]; then
  echo "Extracting and validating firmware metadata..."
  "${fwtool}" -i "${metadata_file}" "${DIST_DIR}/${firmware_name}"
  jq -e '
    .supported_devices | index("qihoo,360t7") != null
  ' "${metadata_file}" >/dev/null
else
  echo "fwtool is required to validate both sysupgrade formats." >&2
  exit 1
fi

(
  cd "${DIST_DIR}"
  sha256sum -- "${firmware_name}" >"${firmware_name}.sha256"
)

echo "Preparing the legacy kernel/rootfs upgrade logic for the U-Boot Web image..."
legacy_files="${WORK_DIR}/legacy-files"
cp -a "${ROOT_DIR}/files" "${legacy_files}"
legacy_platform_source="${imagebuilder_dir}/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
legacy_platform="${legacy_files}/lib/upgrade/platform.sh"
if [[ ! -f "${legacy_platform_source}" ]]; then
  legacy_platform_source="${WORK_DIR}/platform.sh"
  curl --fail --location --retry 4 --retry-all-errors \
    --connect-timeout 20 --max-time 300 \
    --output "${legacy_platform_source}" \
    "https://raw.githubusercontent.com/immortalwrt/immortalwrt/openwrt-24.10/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
fi
mkdir -p "$(dirname "${legacy_platform}")"

awk '
  $0 == "platform_do_upgrade() {" {
    in_upgrade = 1
  }
  in_upgrade && !inserted && $0 ~ /^[[:space:]]*case "\$board" in$/ {
    print
    print "\tqihoo,360t7)"
    print "\t\tCI_UBIPART=\"ubi\""
    print "\t\tCI_KERNPART=\"kernel\""
    print "\t\tCI_ROOTPART=\"rootfs\""
    print "\t\tnand_do_upgrade \"$1\""
    print "\t\t;;"
    inserted = 1
    next
  }
  in_upgrade && $0 ~ /^[[:space:]]*qihoo,360t7\|\\$/ {
    removed = 1
    next
  }
  { print }
  END {
    if (!inserted || !removed) {
      exit 1
    }
  }
' "${legacy_platform_source}" >"${legacy_platform}"

grep -Fq $'\tqihoo,360t7)' "${legacy_platform}"
if grep -Fq $'\tqihoo,360t7|\\' "${legacy_platform}"; then
  echo "The FIT-volume 360T7 upgrade branch was not removed." >&2
  exit 1
fi

echo "Building the rootfs variant dedicated to the legacy U-Boot layout..."
if make -C "${imagebuilder_dir}" image \
    PROFILE="${PROFILE}" \
    PACKAGES="daed luci-app-daede vmlinux-btf" \
    DISABLED_SERVICES="daed" \
    FILES="${legacy_files}"; then
  legacy_imagebuilder_status=0
else
  legacy_imagebuilder_status=$?
fi
echo "Legacy-layout ImageBuilder command status: ${legacy_imagebuilder_status}"
if [[ "${legacy_imagebuilder_status}" -ne 0 ]]; then
  echo "ImageBuilder returned ${legacy_imagebuilder_status}; validating the generated legacy-layout source image."
fi

shopt -s nullglob
legacy_source_images=(
  "${imagebuilder_dir}"/bin/targets/mediatek/filogic/*qihoo_360t7*squashfs-sysupgrade.itb
)
shopt -u nullglob
if [[ "${#legacy_source_images[@]}" -ne 1 ]]; then
  echo "Expected one temporary 360T7 FIT for U-Boot Web conversion." >&2
  exit 1
fi

uboot_web_name="${firmware_name%.itb}-uboot-web.bin"
echo "Converting ${legacy_source_images[0]} to ${uboot_web_name}..."
bash "${ROOT_DIR}/scripts/make-uboot-web.sh" \
  "${imagebuilder_dir}" \
  "${legacy_source_images[0]}" \
  "${DIST_DIR}/${uboot_web_name}" \
  "${kernel_version}" \
  "${metadata_file}"
(
  cd "${DIST_DIR}"
  sha256sum -- "${uboot_web_name}" >"${uboot_web_name}.sha256"
)

cat >"${DIST_DIR}/RELEASE_NOTES.md" <<EOF
## 360T7 dedicated ImageBuilder firmware

- Device: Qihoo 360T7 only (\`qihoo_360t7\`, supported device \`qihoo,360t7\`)
- ImmortalWrt: \`${ib_version}\` / \`${ib_revision}\`
- Target: \`${target}\`
- Architecture: \`${ARCH}\`
- Kernel: \`${kernel_version}\`
- daed Release: \`${daed_tag}\`
- Integrated packages: \`${daed_asset}\` (\`${daed_version}\`),
  \`${luci_asset}\` (\`${luci_version}\`), \`${btf_asset}\` (\`${btf_version}\`)
- Default LAN address on a clean installation: \`192.168.233.1\`

The initramfs recovery image is the checksum-verified upstream image matching
this ImageBuilder revision. It runs from RAM and intentionally does not contain
daed. Boot it first when recovering through U-Boot, then flash the dedicated
sysupgrade image from the recovery system.

The \`*-uboot-web.bin\` asset is only for the Qihoo 360T7 U-Boot Web updater
that accepts a sysupgrade tar containing separate \`kernel\` and \`root\`
members. It is generated from the same ImageBuilder kernel and rootfs as this
Release, but uses the legacy 360T7 UBI volume layout expected by that updater.
Do not rename or upload the combined \`.itb\` file to the U-Boot Web page.

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
