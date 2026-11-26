#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# piBrick CM5 Drivers - Installer
#

set -euo pipefail

PACKAGE_NAME="pibrick-drivers"
PACKAGE_VERSION="${PIBRICK_DKMS_VERSION:-1.0.0}"
DKMS_NAME="${PACKAGE_NAME}"
DKMS_VERSION="${PACKAGE_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/platform.sh
source "${SCRIPT_DIR}/platform.sh"

KERNEL_VERSION="$(uname -r)"
KERNEL_MODULE_DIR="/lib/modules/${KERNEL_VERSION}"
KERNEL_BUILD_DIR="${KERNEL_MODULE_DIR}/build"

DKMS_SOURCE_DIR="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

BOOT_FIRMWARE_DIR="${BOOT_FIRMWARE_DIR:-$(default_boot_dir)}"
OVERLAY_DIR="${BOOT_FIRMWARE_DIR}/overlays"
OVERLAY_FILE="${OVERLAY_DIR}/pibrick.dtbo"

MODULES_LOAD_CONF="/etc/modules-load.d/pibrick.conf"

BUTTON_APP_DIR="${ROOT_DIR}/app/pibrick-button-service"
KEYBOARD_APP_DIR="${ROOT_DIR}/app/pibrick-kbd"

# piBrick Plymouth splash
SPLASH_SOURCE="${ROOT_DIR}/app/splash/pibrick-splash.png"
PLYMOUTH_THEME_DIR="/usr/share/plymouth/themes/pix"
PLYMOUTH_SPLASH="${PLYMOUTH_THEME_DIR}/splash.png"
SPLASH_BACKUP_DIR="/var/lib/pibrick-drivers/plymouth"
SPLASH_BACKUP="${SPLASH_BACKUP_DIR}/original-splash.png"
SPLASH_MARKER="${SPLASH_BACKUP_DIR}/installed"

die()
{
    echo
    echo "Error: $*" >&2
    exit 1
}

info()
{
    echo
    echo "==> $*"
}

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This installer requires root privileges."
        echo "Requesting sudo..."
        exec sudo -E bash "$0" "$@"
    fi
}

check_source_tree()
{
    local required

    for required in \
        "${ROOT_DIR}/Makefile" \
        "${ROOT_DIR}/dkms/dkms.conf" \
        "${ROOT_DIR}/panel" \
        "${ROOT_DIR}/power" \
        "${ROOT_DIR}/accel" \
        "${ROOT_DIR}/touch/hyn_ts/Makefile"
    do
        [[ -e "${required}" ]] || \
            die "Required source is missing: ${required}"
    done
}

install_arch_dependencies()
{
    [[ "$(uname -m)" == aarch64 ]] ||
        die "Arch Linux installation requires an AArch64 kernel."
    command -v pacman >/dev/null 2>&1 ||
        die "pacman is required on Arch Linux."

    local -a packages=(dkms gcc make)
    local kernel_package
    if [[ "$1" == full ]]; then
        packages+=(dtc)
    fi

    if [[ ! -f "${KERNEL_BUILD_DIR}/Makefile" ]]; then
        [[ -r "${KERNEL_MODULE_DIR}/pkgbase" ]] ||
            die "Running kernel ${KERNEL_VERSION} is missing its package metadata. Reboot into the installed Raspberry Pi kernel and rerun the installer."
        kernel_package="$(<"${KERNEL_MODULE_DIR}/pkgbase")"
        case "${kernel_package}" in
            linux-rpi|linux-rpi-16k)
                packages+=("${kernel_package}-headers")
                ;;
            *)
                die "Install headers for the running kernel (${kernel_package}, ${KERNEL_VERSION}) and rerun the installer."
                ;;
        esac
    fi

    if ! pacman -Qq "${packages[@]}" >/dev/null 2>&1; then
        pacman -S --needed "${packages[@]}"
    fi
}

install_dependencies()
{
    info "Installing build dependencies"

    if is_arch; then
        install_arch_dependencies "$1"
        return
    fi

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    local header_package

    case "${KERNEL_VERSION}" in
        *rpt-rpi-v8)
            header_package="linux-headers-rpi-v8"
            ;;
        *rpt-rpi-v7)
            header_package="linux-headers-rpi-v7"
            ;;
        *rpt-rpi-v7l)
            header_package="linux-headers-rpi-v7l"
            ;;
        *rpt-rpi-v6)
            header_package="linux-headers-rpi-v6"
            ;;
        *)
            header_package="linux-headers-${KERNEL_VERSION}"
            ;;
    esac

    local -a packages=(dkms build-essential)
    if [[ "$1" == full ]]; then
        packages+=(device-tree-compiler)
    fi
    if [[ ! -f "${KERNEL_BUILD_DIR}/Makefile" ]]; then
        packages+=("${header_package}")
    fi
    apt-get install -y "${packages[@]}"
}

check_kernel_build_tree()
{
    if [[ ! -f "${KERNEL_BUILD_DIR}/Makefile" ]]; then
        if is_arch; then
            die "Headers for the running kernel ${KERNEL_VERSION} are unavailable. If the kernel was upgraded, reboot into the installed kernel before retrying."
        fi
        die "Kernel build directory not found: ${KERNEL_BUILD_DIR}"
    fi
}

build_dtbo()
{
    info "Building device-tree overlay"

    make \
        -C "${ROOT_DIR}" \
        dtbo \
        DTC=dtc

    [[ -f "${ROOT_DIR}/dts/pibrick.dtbo" ]] || \
        die "Device-tree overlay was not generated."
}

prepare_dkms_source()
{
    info "Preparing DKMS source"

    rm -rf "${DKMS_SOURCE_DIR}"

    mkdir -p "${DKMS_SOURCE_DIR}"

    install -m 0644 \
        "${ROOT_DIR}/Makefile" \
        "${DKMS_SOURCE_DIR}/Makefile"

    if [[ -f "${ROOT_DIR}/Kconfig" ]]; then
        install -m 0644 \
            "${ROOT_DIR}/Kconfig" \
            "${DKMS_SOURCE_DIR}/Kconfig"
    fi

    install -m 0644 \
        "${ROOT_DIR}/dkms/dkms.conf" \
        "${DKMS_SOURCE_DIR}/dkms.conf"
    sed -i "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${DKMS_VERSION}\"/" \
        "${DKMS_SOURCE_DIR}/dkms.conf"

    cp -a \
        "${ROOT_DIR}/panel" \
        "${DKMS_SOURCE_DIR}/panel"

    cp -a \
        "${ROOT_DIR}/power" \
        "${DKMS_SOURCE_DIR}/power"

    cp -a \
        "${ROOT_DIR}/accel" \
        "${DKMS_SOURCE_DIR}/accel"

    mkdir -p "${DKMS_SOURCE_DIR}/touch"

    cp -a \
        "${ROOT_DIR}/touch/hyn_ts" \
        "${DKMS_SOURCE_DIR}/touch/hyn_ts"

    echo "DKMS source:"
    echo "  ${DKMS_SOURCE_DIR}"
}

remove_existing_dkms()
{
    if ! command -v dkms >/dev/null 2>&1; then
        return
    fi

    if [[ -d "/var/lib/dkms/${DKMS_NAME}/${DKMS_VERSION}" ]] ||
        dkms status "${DKMS_NAME}/${DKMS_VERSION}" \
        2>/dev/null | grep -F "${DKMS_NAME}/${DKMS_VERSION}" >/dev/null
    then
        info "Removing existing DKMS registration"

        dkms remove \
            "${DKMS_NAME}/${DKMS_VERSION}" \
            --all
    fi
}

install_dkms()
{
    info "Installing kernel modules with DKMS"

    remove_existing_dkms

    prepare_dkms_source

    dkms add \
        "${DKMS_NAME}/${DKMS_VERSION}"

    dkms build \
        "${DKMS_NAME}/${DKMS_VERSION}" \
        -k "${KERNEL_VERSION}"

    dkms install \
        "${DKMS_NAME}/${DKMS_VERSION}" \
        -k "${KERNEL_VERSION}"

    depmod -a "${KERNEL_VERSION}"
}

install_dtbo()
{
    info "Installing device-tree overlay"

    mkdir -p "${OVERLAY_DIR}"

    install -m 0644 \
        "${ROOT_DIR}/dts/pibrick.dtbo" \
        "${OVERLAY_FILE}"
}

install_button_service()
{
    [[ -d "${BUTTON_APP_DIR}" ]] || return 0

    info "Installing pibrick-button-service"

    make -C "${BUTTON_APP_DIR}" install
}

install_keyboard_application()
{
    [[ -d "${KEYBOARD_APP_DIR}" ]] || return 0

    info "Installing pibrick-kbd"

    make -C "${KEYBOARD_APP_DIR}" install
}

install_pibrick_splash() {
    if [[ ! -f "$SPLASH_SOURCE" ]]; then
        echo "WARNING: piBrick splash image not found: $SPLASH_SOURCE"
        echo "Skipping splash installation."
        return 0
    fi

    if [[ ! -f "$PLYMOUTH_SPLASH" ]]; then
        echo "Skipping Plymouth splash installation because the pix theme is unavailable."
        return 0
    fi

    local active_theme=""
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        active_theme="$(plymouth-set-default-theme 2>/dev/null || true)"
    fi

    if [[ "$active_theme" != "pix" ]]; then
        echo "WARNING: Active Plymouth theme is '${active_theme:-unknown}', not pix."
        echo "Skipping splash replacement to avoid modifying the wrong theme."
        return 0
    fi

    # Preserve the original image on the first installation only.
    if [[ ! -f "$SPLASH_BACKUP" ]]; then
        mkdir -p "$SPLASH_BACKUP_DIR"
        cp -a "$PLYMOUTH_SPLASH" "$SPLASH_BACKUP"
    fi

    install -m 0644 "$SPLASH_SOURCE" "$PLYMOUTH_SPLASH"

    touch "$SPLASH_MARKER"
    echo "Installed piBrick Plymouth splash."

    rebuild_splash_initramfs
}

show_status()
{
    info "Installation complete"

    echo
    echo "DKMS:"
    dkms status "${DKMS_NAME}/${DKMS_VERSION}" || true

    echo
    echo "Kernel modules:"

    for module in \
        panel-pibrick \
        pibrick-battery \
        pibrick-stc3115 \
        pibrick-charger \
        pibrick-mma8451 \
        hyn_ts
    do
        if modinfo -k "${KERNEL_VERSION}" "${module}" >/dev/null 2>&1; then
            echo "  ${module}: installed"
        else
            echo "  ${module}: NOT FOUND"
        fi
    done

    echo
    echo "Device-tree overlay:"

    if [[ -f "${OVERLAY_FILE}" ]]; then
        echo "  ${OVERLAY_FILE}"
    else
        echo "  NOT FOUND"
    fi

    echo
    echo "Userspace:"
    echo "  pibrick-button-service:"
    if systemctl list-unit-files --type=service 2>/dev/null |
        grep '^pibrick-button-service\.service' >/dev/null; then

        if systemctl is-active --quiet pibrick-button-service.service; then
            echo "    installed, running"
        else
            echo "    installed, not running"
        fi
    else
        echo "    not installed"
    fi

    echo "  pibrick-kbd:"
    if [[ -x /usr/local/bin/pibrick-kbd ]]; then
        echo "    installed"
    else
        echo "    not installed"
    fi

    echo
    echo "Reboot is recommended."
}

install_config()
{
    local config="$1"
    local normalized

    # Firmware truncates config.txt entries after 98 characters. Keep overlay
    # parameters on separate lines, even when preserving an existing setup.
    normalized="$(mktemp)"
    if ! awk '
        /^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*pibrick,/ {
            count = split($0, fields, ",")
            print fields[1]
            for (i = 2; i <= count; i++)
                print "dtparam=" fields[i]
            next
        }
        { print }
    ' "$config" > "$normalized"; then
        rm -f "$normalized"
        die "Could not normalize piBrick overlay configuration"
    fi
    cat "$normalized" > "$config"
    rm -f "$normalized"

    if ! grep -qE '^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*pibrick([,[:space:]]|$)' "$config"; then
        info "Enabling piBrick device-tree overlay"
        local last_section
        last_section="$(awk '/^[[:space:]]*\[/ { section = $0 } END { print section }' "$config")"
        if [[ -n "$last_section" && ! "$last_section" =~ ^[[:space:]]*\[all\][[:space:]]*$ ]]; then
            printf '\n[all]\n' >> "$config"
        fi
        printf '\n# piBrick CM5 drivers\ndtoverlay=pibrick\n' >> "$config"
    else
        info "piBrick device-tree overlay already enabled"
    fi
}

install_module_autoload()
{
    echo "==> Configuring piBrick module autoload"

    cat > "$MODULES_LOAD_CONF" <<'EOF'
panel-pibrick
pibrick-charger
pibrick-battery
pibrick-stc3115
pibrick-mma8451
hyn_ts
EOF
}

main()
{
    local mode=full
    case "${1:-}" in
        "") ;;
        --modules-only) mode=modules ;;
        *) die "Usage: bash scripts/install.sh [--modules-only]" ;;
    esac
    [[ $# -le 1 ]] || die "Usage: bash scripts/install.sh [--modules-only]"
    [[ "${PACKAGE_VERSION}" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]] ||
        die "Invalid DKMS version: ${PACKAGE_VERSION}"

    require_root "$@"

    echo "========================================"
    echo " piBrick CM5 Driver Installer"
    echo "========================================"
    echo
    echo "Version : ${PACKAGE_VERSION}"
    echo "Kernel  : ${KERNEL_VERSION}"
    echo "Source  : ${ROOT_DIR}"

    check_source_tree
    if [[ "$mode" == full ]]; then
        [[ -f "${BOOT_FIRMWARE_DIR}/config.txt" ]] ||
            die "Firmware config not found at ${BOOT_FIRMWARE_DIR}/config.txt. Mount the Raspberry Pi boot partition before continuing."
    fi
    install_dependencies "$mode"
    check_kernel_build_tree

    if [[ "$mode" == modules ]]; then
        install_dkms
        dkms status "${DKMS_NAME}/${DKMS_VERSION}"
        return
    fi

    # The root Makefile builds the DTBO.
    # Kernel modules are built only once by DKMS.
    build_dtbo

    # DKMS owns kernel module compilation and installation.
    install_dkms
    install_module_autoload

    # The DTBO is installed separately because it is not a kernel module.
    install_dtbo
    install -D -m 0644 \
        "${ROOT_DIR}/accel/61-pibrick-accelerometer.rules" \
        /etc/udev/rules.d/61-pibrick-accelerometer.rules
    install_config "${BOOT_FIRMWARE_DIR}/config.txt"

    # Userspace applications are built independently.
    install_button_service
    install_keyboard_application

    install_pibrick_splash

    show_status
}

main "$@"
