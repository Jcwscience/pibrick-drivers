#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# piBrick CM5 Drivers - Installer Redirect
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/scripts/install.sh" "$@"
