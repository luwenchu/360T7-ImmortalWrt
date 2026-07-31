#!/bin/sh
set -eu

die() {
	echo "ERROR: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<'EOF'
Usage:
  recover-fit-ubi.sh --yes-rebuild-ubi /tmp/firmware.itb

This command erases and rebuilds only the fixed-layout "ubi" partition.
Run it only from the Qihoo 360T7 initramfs recovery system.
EOF
	exit 2
}

[ "$#" -eq 2 ] || usage
[ "$1" = "--yes-rebuild-ubi" ] || usage
image="$2"

for command_name in \
	ubus jsonfilter sysupgrade sha256sum stat head \
	ubiblock ubidetach ubiformat ubiattach ubimkvol ubiupdatevol ubinfo; do
	command -v "$command_name" >/dev/null 2>&1 ||
		die "Required recovery command is unavailable: $command_name"
done

board="$(ubus call system board | jsonfilter -e '@.board_name')"
rootfs_type="$(ubus call system board | jsonfilter -e '@.rootfs_type')"
[ "$board" = "qihoo,360t7" ] ||
	die "Unsupported board: $board"
[ "$rootfs_type" = "initramfs" ] ||
	die "This must run from initramfs recovery, not the installed system."

mtd_line="$(awk '$1 == "mtd4:" && $2 == "06c00000" && $4 == "\"ubi\"" { print }' /proc/mtd)"
[ -n "$mtd_line" ] ||
	die "Expected fixed layout mtd4 (108 MiB, name ubi) was not found."
[ -f "$image" ] || die "Firmware image does not exist: $image"

image_size="$(stat -c %s "$image")"
[ "$image_size" -gt 0 ] || die "Firmware image is empty."
sysupgrade -T "$image" ||
	die "Firmware failed the platform compatibility check."

expected_sha256="$(sha256sum "$image" | awk '{ print $1 }')"
ecc_before="$(cat /sys/class/mtd/mtd4/ecc_failures)"
echo "Board: $board"
echo "Target partition: mtd4 (ubi)"
echo "Firmware size: $image_size"
echo "Firmware SHA-256: $expected_sha256"
echo "ECC failures before rebuild: $ecc_before"

if [ -e /dev/fit0 ]; then
	fitblk /dev/fit0
fi

if [ -x /etc/init.d/ubihealthd ]; then
	/etc/init.d/ubihealthd stop || true
else
	killall ubihealthd 2>/dev/null || true
fi

for volume in /sys/class/ubi/ubi0_*; do
	[ -d "$volume" ] || continue
	name="$(cat "$volume/name")"
	volume_id="${volume##*_}"
	if [ -e "/dev/ubiblock0_${volume_id}" ]; then
		ubiblock -r "/dev/ubi0_${volume_id}"
	fi
	echo "Removing old UBI mapping: $name"
done

ubidetach -m 4
ubiformat /dev/mtd4 -y
ubiattach -m 4

ubimkvol /dev/ubi0 -N fit -s "$image_size"
ubiupdatevol /dev/ubi0_0 -s "$image_size" "$image"
ubimkvol /dev/ubi0 -N rootfs_data -m
sync

actual_sha256="$(head -c "$image_size" /dev/ubi0_0 | sha256sum | awk '{ print $1 }')"
[ "$actual_sha256" = "$expected_sha256" ] ||
	die "FIT readback checksum mismatch: $actual_sha256"

ecc_after="$(cat /sys/class/mtd/mtd4/ecc_failures)"
[ "$ecc_after" -eq "$ecc_before" ] ||
	die "ECC failures increased during rebuild: $ecc_before -> $ecc_after"

ubinfo -a
echo "FIT readback SHA-256: $actual_sha256"
echo "ECC failures after rebuild: $ecc_after (no increase)"
echo "UBI rebuild completed. Run: reboot -f"
