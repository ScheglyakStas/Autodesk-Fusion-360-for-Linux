#!/usr/bin/env bash

#############################################################################
# Name:         Autodesk Fusion 360 - Launcher (Linux)                      #
# Description:  With this file you run Autodesk Fusion 360 on your system.  #
# Author:       Steve Zabka                                                 #
# Author URI:   https://cryinkfly.com                                       #
# License:      MIT                                                         #
# Copyright (c) 2020-2026                                                   #
# Time/Date:    08:00/20.06.2026                                            #
# Version:      2.1.6-Alpha                                                 #
#############################################################################

# Path: SELECTED__INSTALLATION_PATH/bin/autodesk_fusion_launcher.sh

#################################
# Open Autodesk Fusion 360 now! #
#################################

###############################################################################################################################################################
# ALL FUNCTIONS ARE ARRANGED HERE:                                                                                                                            #
###############################################################################################################################################################

# Check in which directory the autodesk_fusion_launcher.sh file is located.
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# Make AUTODESK_ROOT_DIRECTORY absolute (one level up from the script dir)
AUTODESK_ROOT_DIRECTORY="$(cd "$SCRIPT_DIR/.." && pwd)"
WINEPREFIX_LOG_FILE="$AUTODESK_ROOT_DIRECTORY/logs/wineprefixes.log"
if [ ! -f "$WINEPREFIX_LOG_FILE" ]; then
    echo "wineprefixes.log not found at $WINEPREFIX_LOG_FILE. Exiting..."
    exit 1
fi
LOG_AUTODESK_ROOT_DIRECTORY=$(awk 'NR == 2' "$WINEPREFIX_LOG_FILE")
if [ "$AUTODESK_ROOT_DIRECTORY" != "$LOG_AUTODESK_ROOT_DIRECTORY" ]; then
    echo "Error: AUTODESK_ROOT_DIRECTORY does not match wineprefixes.log (line 2). Exiting..."
    exit 1
fi
WINE_PFX=$(awk 'NR == 3' "$WINEPREFIX_LOG_FILE")
PROTON_VERSION=$(awk 'NR == 4' "$WINEPREFIX_LOG_FILE")

REPO_URL="https://raw.githubusercontent.com/ScheglyakStas/Autodesk-Fusion-360-for-Linux/main"

# This feature will check if there is a new version of Autodesk Fusion 360.
function check_autodesk_fusion_online_versions() {
    curl -o "$AUTODESK_ROOT_DIRECTORY/logs/version.txt" -L "$REPO_URL/files/setup/data/build-versions.txt"
    ONLINE_BUILD_VERSION=$(awk 'NR == 1' "$AUTODESK_ROOT_DIRECTORY/logs/version.txt")
    ONLINE_INSIDER_BUILD_VERSION=$(awk 'NR == 2' "$AUTODESK_ROOT_DIRECTORY/logs/version.txt")
    echo "Online Build-Version: $ONLINE_BUILD_VERSION"
    echo "Online Insider-Build-Version: $ONLINE_INSIDER_BUILD_VERSION"
    #check_versions #Update function not work correctly at the moment!!!
    run_autodesk_fusion
}

function check_version_file() {
    # Find the newest version.txt file from the Autodesk Fusion 360 installation.
    AUTODESK_FUSION_API_VERSION=$(find "$WINE_PFX" -name fusion_version.txt -printf "%T+ %p\n" | sort -r 2>&1 | head -n 1 | sed -r 's/.+0000000000 (.+)/\1/')
    if [ -f "$AUTODESK_FUSION_API_VERSION" ]; then
        echo "The version.txt file exists!"
        check_versions
    else
        echo "The version.txt file does not exist!"
        run_autodesk_fusion
    fi
}

function check_versions() {
    # Get the string from the version.txt file from FUSION360_API_VERSION
    SYSTEM_BUILD_VERSION=$(cat "$AUTODESK_FUSION_API_VERSION")
    echo "System Build-Version: $SYSTEM_BUILD_VERSION"
    if [ "$ONLINE_BUILD_VERSION" = "$SYSTEM_BUILD_VERSION" ] || [ "$ONLINE_INSIDER_BUILD_VERSION" = "$SYSTEM_BUILD_VERSION" ]; then
        echo "Do nothing!"
        run_autodesk_fusion
    else
        backup_old_version
        update
    fi
}

function backup_old_version() {
    # Backup the old version of the Autodesk Fusion 360
    echo "Backup the old version of the Autodesk Fusion 360!"
    # Copy $wineprefix to $wineprefix-backup-$SYSTEM_BUILD_VERSION
    cp -r "$WINE_PFX" "$WINE_PFX-backup-$SYSTEM_BUILD_VERSION"
}

function update() {
    echo "Update the Autodesk Fusion 360 version!"
    # Download the newest version of the Autodesk Fusion 360
    AUTODESK_FUSION_INSTALLER="$AUTODESK_ROOT_DIRECTORY/downloads/Fusion360ClientInstaller.exe"
    fusion360_installer_url="https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Client%20Downloader.exe"
    curl -L "$fusion360_installer_url" -o $AUTODESK_FUSION_INSTALLER
    cp "$AUTODESK_ROOT_DIRECTORY/downloads/Fusion360ClientInstaller.exe" "$SELECTED_DIRECTORY/wineprefixes/default/drive_c/users/$USER/Downloads"
    # Install the newest version of the Autodesk Fusion 360
    WINEPREFIX="$WINE_PFX" timeout -k 2m 1m wine "$WINE_PFX/drive_c/users/$USER/Downloads/Fusion360installer.exe" --quiet
    WINEPREFIX="$WINE_PFX" timeout -k 2m 1m wine "$WINE_PFX/drive_c/users/$USER/Downloads/Fusion360installer.exe" --quiet
    run_autodesk_fusion
}

# Window classes the patched winex11.drv should manage instead of leaving override-redirect.
WINE_X11_MANAGED_CLASSES="${WINE_X11_MANAGED_CLASSES-Qt683QWindowToolSaveBits,Qt683QWindowToolSaveBitsOwnDC,Qt683QWindow,Qt683QWindowOwnDCIcon}"
export WINE_X11_MANAGED_CLASSES

# Use the Microsoft shader compiler bundled with Fusion. Wine's builtin one (vkd3d 2.1)
# lays out effect constant buffers wrongly and the 3D viewport stops clearing.
WINEDLLOVERRIDES="d3dcompiler_47,d3dcompiler_43=n,b${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
export WINEDLLOVERRIDES

# Preloaded shim (see lib/wine_sndbuf_fix.c): raises Wine's fixed 64 KB TCP send
# buffer that capped cloud uploads at ~90 KB/s, makes SwitchToThread cheaper, and
# shows the right-click Marking Menu on top instead of behind the main window.
SNDBUF_FIX="$AUTODESK_ROOT_DIRECTORY/lib/wine_sndbuf_fix.so"
if [ -f "$SNDBUF_FIX" ]; then
    export LD_PRELOAD="$SNDBUF_FIX${LD_PRELOAD:+:$LD_PRELOAD}"
fi

function run_autodesk_fusion() {
    if [ "$PROTON_VERSION" == "Wine" ]; then
        run_autodesk_fusion_wine
    elif [ "$PROTON_VERSION" == "Wine-fix" ]; then
        run_autodesk_fusion_wine_fix
    else
        run_autodesk_fusion_proton
    fi
}

function run_autodesk_fusion_wine() {
    LAUNCHER="$(find "$WINE_PFX" -name Fusion360.exe -printf "%T+ %p\n" | sort -r 2>&1 | head -n 1 | cut -d' ' -f2-)"

    echo $LAUNCHER

    DXVK_LOG_LEVEL=none \
    WINEPREFIX="$WINE_PFX" \
    WINEDEBUG=-all,+err \
    wine "$LAUNCHER" &

    WINEPID=$!
    wait "$WINEPID"

    WINEPREFIX="$WINE_PFX" wineserver -k
}

function run_autodesk_fusion_wine_fix() {
    LAUNCHER="$(find "$WINE_PFX" -name Fusion360.exe -printf "%T+ %p\n" | sort -r 2>&1 | head -n 1 | cut -d' ' -f2-)"

    WINE_BUILD_DIR="$HOME/fusion-wine-build/bin"

    echo $LAUNCHER

    DXVK_LOG_LEVEL=none \
    WINEPREFIX="$WINE_PFX" \
    WINESERVER="$WINE_BUILD_DIR/wineserver" \
    WINEDEBUG=-all,+err \
    $WINE_BUILD_DIR/wine "$LAUNCHER" &

    WINEPID=$!
    wait "$WINEPID"

    WINEPREFIX="$WINE_PFX" "$WINE_BUILD_DIR/wineserver" -k
}

function run_autodesk_fusion_proton() {
    LAUNCHER="$(find "$WINE_PFX" -name Fusion360.exe -printf "%T+ %p\n" | sort -r 2>&1 | head -n 1 | cut -d' ' -f2-)"
    STEAM_DIRECTORY="$HOME/.local/share/Steam"
    PROTON_DIRECTORY="$STEAM_DIRECTORY/compatibilitytools.d/$PROTON_VERSION"
    
    if ! pgrep -x steam >/dev/null 2>&1; then
        echo -e "$(gettext "${YELLOW}Starting Steam (background, no window)...${NOCOLOR}")"
        # Start Steam in a separate user scope to avoid a parent-child link.
        if command -v systemd-run >/dev/null 2>&1; then
            setsid -f systemd-run --user --scope --quiet steam -silent </dev/null >/dev/null 2>&1
        else
            # Fallback if systemd-run is not available; Steam is linked to Fusion, so it can look like Fusion never exited.
            setsid -f steam -silent </dev/null >/dev/null 2>&1
        fi
        sleep 5
    fi

    PROTON_LOG=0 \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIRECTORY" \
    STEAM_COMPAT_DATA_PATH="$AUTODESK_ROOT_DIRECTORY/protonprefix" \
    "$PROTON_DIRECTORY/proton" run "$LAUNCHER" &

    WINEPID=$!
    wait $WINEPID

    WINEPREFIX="$WINE_PFX" "$PROTON_DIRECTORY/files/bin/wineserver" -k
}

###############################################################################################################################################################
# THE PROGRAM IS STARTED HERE:                                                                                                                                #
###############################################################################################################################################################

check_autodesk_fusion_online_versions