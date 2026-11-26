#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# piBrick CM5 Drivers - Uninstaller
#

set -euo pipefail

PACKAGE_NAME="pibrick-drivers"
PACKAGE_VERSION="${PIBRICK_DKMS_VERSION:-1.0.0}"

DKMS_NAME="${PACKAGE_NAME}"
DKMS_VERSION="${PACKAGE_VERSION}"
DKMS_SOURCE_DIR="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/platform.sh
source "${SCRIPT_DIR}/platform.sh"

BOOT_FIRMWARE_DIR="${BOOT_FIRMWARE_DIR:-$(default_boot_dir)}"
OVERLAY_FILE="${BOOT_FIRMWARE_DIR}/overlays/pibrick.dtbo"


# piBrick Plymouth splash
PLYMOUTH_THEME_DIR="/usr/share/plymouth/themes/pix"
PLYMOUTH_SPLASH="${PLYMOUTH_THEME_DIR}/splash.png"
SPLASH_BACKUP_DIR="/var/lib/pibrick-drivers/plymouth"
SPLASH_BACKUP="${SPLASH_BACKUP_DIR}/original-splash.png"
SPLASH_MARKER="${SPLASH_BACKUP_DIR}/installed"

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This uninstaller requires root privileges."
        echo "Requesting sudo..."
        exec sudo -E bash "$0" "$@"
    fi
}

info()
{
    echo
    echo "==> $*"
}

die()
{
    echo "Error: $*" >&2
    exit 1
}

stop_button_service()
{
    info "Stopping pibrick-button-service"

    systemctl disable \
        --now \
        pibrick-button-service.service \
        2>/dev/null || true

    rm -f \
        /etc/systemd/system/pibrick-button-service.service

    rm -rf \
        /etc/pibrick

    systemctl daemon-reload
}

remove_userspace()
{
    info "Removing piBrick userspace applications"

    rm -f \
        /usr/sbin/pibrick-button-service \
        /usr/local/bin/pibrick-button-service \
        /usr/local/bin/pibrick-kbd
}

remove_dkms()
{
    info "Removing piBrick DKMS modules"

    if command -v dkms >/dev/null 2>&1; then
        if [[ -d "/var/lib/dkms/${DKMS_NAME}/${DKMS_VERSION}" ]] ||
            dkms status "${DKMS_NAME}/${DKMS_VERSION}" \
            2>/dev/null | grep -F "${DKMS_NAME}/${DKMS_VERSION}" >/dev/null
        then
            dkms remove \
                "${DKMS_NAME}/${DKMS_VERSION}" \
                --all
        else
            echo "No piBrick DKMS registration found."
        fi
    else
        echo "DKMS is not installed."
    fi

    rm -rf "${DKMS_SOURCE_DIR}"

    depmod -a "$(uname -r)"
}

restore_pibrick_splash() {
    if [[ ! -f "$SPLASH_BACKUP" ]]; then
        echo "No piBrick splash backup found; nothing to restore."
        return 0
    fi

    # Restore the original Raspberry Pi OS splash.
    install -m 0644 "$SPLASH_BACKUP" "$PLYMOUTH_SPLASH"

    rm -f "$SPLASH_MARKER"
    rm -f "$SPLASH_BACKUP"
    rmdir "$SPLASH_BACKUP_DIR" 2>/dev/null || true

    echo "Restored original Raspberry Pi OS splash."

    rebuild_splash_initramfs
}

remove_dtbo()
{
    info "Removing piBrick device-tree overlay"

    rm -f "${OVERLAY_FILE}"
}

show_status()
{
    echo
    echo "========================================"
    echo " piBrick CM5 Driver Uninstall Complete"
    echo "========================================"
    echo
    echo "Removed:"
    echo "  - DKMS kernel modules"
    echo "  - /usr/src/${DKMS_NAME}-${DKMS_VERSION}"
    echo "  - pibrick.dtbo"
    echo "  - pibrick-button-service"
    echo "  - pibrick-kbd"
    echo
    echo "The source tree was not modified."
    echo
    echo "Reboot is recommended."
}

remove_config()
{
    local config="$1"

    if [[ ! -f "${config}" ]]; then
        info "config.txt not found, skipping overlay configuration removal"
        return
    fi

    if grep -qE '^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*pibrick([,[:space:]]|$)' "${config}"; then
        info "Removing piBrick device-tree overlay from config.txt"

        local normalized
        normalized="$(mktemp)"
        if ! awk '
            /^[[:space:]]*\[/ { pibrick = 0 }
            /^[[:space:]]*dtoverlay[[:space:]]*=/ {
                pibrick = ($0 ~ /^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*pibrick([,[:space:]]|$)/)
                if (pibrick)
                    next
            }
            pibrick && /^[[:space:]]*dtparam[[:space:]]*=[[:space:]]*(battery_capacity|battery_nominal_voltage_uv|battery_max_voltage_uv|charge_current_ma)=/ { next }
            { print }
        ' "$config" > "$normalized"; then
            rm -f "$normalized"
            die "Could not remove piBrick overlay configuration"
        fi
        cat "$normalized" > "$config"
        rm -f "$normalized"

        # Remove the comment added by install_config(), but only
        # when it is immediately associated with the piBrick overlay.
        sed -i \
            '/^[[:space:]]*#[[:space:]]*piBrick CM5 drivers[[:space:]]*$/d' \
            "${config}"
    else
        info "piBrick device-tree overlay is not enabled in config.txt"
    fi
}

main()
{
    [[ "${PACKAGE_VERSION}" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]] ||
        die "Invalid DKMS version: ${PACKAGE_VERSION}"
    require_root "$@"

    echo "========================================"
    echo " piBrick CM5 Driver Uninstaller"
    echo "========================================"
    echo
    echo "Version : ${PACKAGE_VERSION}"

    stop_button_service
    remove_userspace
    remove_dkms
    remove_config "${BOOT_FIRMWARE_DIR}/config.txt"
    remove_dtbo
    rm -f /etc/udev/rules.d/61-pibrick-accelerometer.rules

    restore_pibrick_splash

    rm -f /etc/modules-load.d/pibrick.conf

    show_status
}

main "$@"
