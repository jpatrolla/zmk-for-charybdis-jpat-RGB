#!/usr/bin/env bash
set -euo pipefail

# Flash script for Charybdis split keyboard (Nice Nano v2)
# Usage:
#   ./flash.sh              # Build and flash both sides
#   ./flash.sh --reset      # Flash settings_reset to each side before flashing firmware
#   ./flash.sh left         # Flash left side only
#   ./flash.sh right        # Flash right side only
#   ./flash.sh --reset left # Reset + flash left side only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZMK_DIR="$SCRIPT_DIR/.zmk"
ZMK_REPO="https://github.com/zmkfirmware/zmk.git"
ZMK_BRANCH="main"
BUILD_DIR="$SCRIPT_DIR/build"
VOLUME_NAME="NICENANO"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
ZEPHYR_SDK_DIR="$HOME/zephyr-sdk-0.17.0"

LEFT_FW="$BUILD_DIR/left/zephyr/zmk.uf2"
RIGHT_FW="$BUILD_DIR/right/zephyr/zmk.uf2"
RESET_FW="$BUILD_DIR/reset/zephyr/zmk.uf2"

RESET_MODE=false
SIDES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset|-r)
            RESET_MODE=true
            shift
            ;;
        left|right)
            SIDES+=("$1")
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--reset|-r] [left|right]"
            echo ""
            echo "Flash ZMK firmware to the Charybdis split keyboard."
            echo ""
            echo "Options:"
            echo "  --reset, -r   Flash settings_reset firmware before flashing,"
            echo "                useful for pairing issues or major config changes"
            echo "  left          Flash left side only"
            echo "  right         Flash right side only"
            echo "  -h, --help    Show this help message"
            echo ""
            echo "With no side specified, both sides are flashed (left first)."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Default to both sides
if [[ ${#SIDES[@]} -eq 0 ]]; then
    SIDES=(left right)
fi

# ── Environment ────────────────────────────────────────────────
export ZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_DIR"

# ── Clone/update ZMK ──────────────────────────────────────────
if [[ ! -d "$ZMK_DIR" ]]; then
    echo "Cloning ZMK ($ZMK_BRANCH) into $ZMK_DIR..."
    git clone --branch "$ZMK_BRANCH" --depth 1 "$ZMK_REPO" "$ZMK_DIR"
    echo "Running west init/update (this takes a few minutes the first time)..."
    cd "$ZMK_DIR"
    west init -l app/
    west update
    cd "$SCRIPT_DIR"
else
    echo "ZMK already at $ZMK_DIR"
fi

# Activate Zephyr environment
source "$ZMK_DIR/zephyr/zephyr-env.sh"

# ── Build functions ────────────────────────────────────────────
build_side() {
    local side="$1"
    echo "Building $side firmware..."
    west build -d "$BUILD_DIR/$side" -b nice_nano/nrf52840/zmk \
        -s "$ZMK_DIR/app" -p auto \
        -- -DSHIELD="charybdis_$side" \
           -DZMK_CONFIG="$SCRIPT_DIR/config"
}

build_reset() {
    if [[ ! -f "$RESET_FW" ]]; then
        echo "Building settings_reset firmware..."
        west build -d "$BUILD_DIR/reset" -b nice_nano/nrf52840/zmk \
            -s "$ZMK_DIR/app" -p auto \
            -- -DSHIELD="settings_reset" \
               -DZMK_CONFIG="$SCRIPT_DIR/config"
    fi
}

# ── Flash functions ────────────────────────────────────────────
wait_for_volume() {
    local label="$1"
    echo ""
    echo ">>> $label"
    echo "    Double-tap the reset button on the Nice Nano..."

    while [[ ! -d "$MOUNT_POINT" ]]; do
        sleep 0.5
    done
    # Give the volume a moment to fully mount
    sleep 1
    echo "    Found $VOLUME_NAME!"
}

flash_uf2() {
    local uf2="$1"
    local label="$2"

    if [[ ! -f "$uf2" ]]; then
        echo "ERROR: Firmware not found: $uf2"
        exit 1
    fi

    echo "    Copying $(basename "$uf2") ($label)..."
    cp "$uf2" "$MOUNT_POINT/"

    # Wait for the volume to unmount (board reboots after flash)
    while [[ -d "$MOUNT_POINT" ]]; do
        sleep 0.5
    done
    echo "    Flashed successfully!"
    sleep 2
}

get_fw_path() {
    case "$1" in
        left)  echo "$LEFT_FW" ;;
        right) echo "$RIGHT_FW" ;;
    esac
}

# ── Main ───────────────────────────────────────────────────────

echo "=== Charybdis Keyboard Flash Tool ==="
echo ""

# Build phase
if $RESET_MODE; then
    build_reset
fi
for side in "${SIDES[@]}"; do
    build_side "$side"
done

echo ""
echo "Build complete. Starting flash process..."

# Flash phase
for side in "${SIDES[@]}"; do
    fw="$(get_fw_path "$side")"

    if $RESET_MODE; then
        wait_for_volume "Reset $side side"
        flash_uf2 "$RESET_FW" "settings_reset"

        wait_for_volume "Flash $side side (after reset)"
        flash_uf2 "$fw" "$side firmware"
    else
        wait_for_volume "Flash $side side"
        flash_uf2 "$fw" "$side firmware"
    fi
done

echo ""
echo "=== All done! ==="
