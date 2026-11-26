#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

is_arch() (
    ID=
    . /etc/os-release
    [[ "$ID" == archarm || "$ID" == arch ]]
)

default_boot_dir()
{
    if is_arch; then
        printf '%s\n' /boot
    else
        printf '%s\n' /boot/firmware
    fi
}

rebuild_splash_initramfs()
{
    compgen -G "${BOOT_FIRMWARE_DIR}/initramfs*" >/dev/null || return 0

    if is_arch; then
        mkinitcpio -P ||
            echo "WARNING: Could not rebuild initramfs automatically."
    elif command -v plymouth-set-default-theme >/dev/null 2>&1; then
        plymouth-set-default-theme --rebuild-initrd pix ||
            echo "WARNING: Could not rebuild initramfs automatically."
    elif command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k all ||
            echo "WARNING: Could not rebuild initramfs automatically."
    fi
}
