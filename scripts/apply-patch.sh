#!/usr/bin/env bash
set -Eeuo pipefail

source_directory="${1:-}"
patch_path="${2:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/patches/0001-mediatek-add-ruijie-rg-x60-ubootmod.patch}"

if [[ -z "$source_directory" ]]; then
    echo "Usage: $0 <immortalwrt-source-directory> [patch-path]" >&2
    exit 2
fi

source_root="$(cd -- "$source_directory" && pwd -P)"
patch_file="$(realpath -- "$patch_path")"

if [[ ! -d "$source_root/.git" ]]; then
    echo "Source directory is not a Git checkout: $source_root" >&2
    exit 1
fi

contains_marker() {
    local file="$1"
    local marker="$2"

    [[ -f "$file" ]] && grep -Fq -- "$marker" "$file"
}

has_uboot_config_support() {
    local patch_directory="$source_root/package/boot/uboot-mediatek/patches"

    [[ -d "$patch_directory" ]] &&
        grep -RFl --include='*.patch' -- 'configs/mt7986_ruijie_rg-x60_defconfig' "$patch_directory" >/dev/null 2>&1
}

declare -a feature_keys=(
    LinuxDts
    UbootTarget
    UbootSource
    ImageRecipe
    NetworkSetup
    WifiMacFix
    UpgradeSupport
)
declare -A feature_state=()

refresh_feature_state() {
    local upgrade_file="$source_root/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
    local upgrade_count=0

    if [[ -f "$upgrade_file" ]]; then
        upgrade_count="$(awk 'index($0, "ruijie,rg-x60-ubootmod") { count++ } END { print count + 0 }' "$upgrade_file")"
    fi

    feature_state[LinuxDts]=false
    feature_state[UbootTarget]=false
    feature_state[UbootSource]=false
    feature_state[ImageRecipe]=false
    feature_state[NetworkSetup]=false
    feature_state[WifiMacFix]=false
    feature_state[UpgradeSupport]=false

    [[ -f "$source_root/target/linux/mediatek/dts/mt7986a-ruijie-rg-x60-ubootmod.dts" ]] && feature_state[LinuxDts]=true
    contains_marker "$source_root/package/boot/uboot-mediatek/Makefile" 'define U-Boot/mt7986_ruijie_rg-x60' && feature_state[UbootTarget]=true
    has_uboot_config_support && feature_state[UbootSource]=true
    contains_marker "$source_root/target/linux/mediatek/image/filogic.mk" 'define Device/ruijie_rg-x60-ubootmod' && feature_state[ImageRecipe]=true
    contains_marker "$source_root/target/linux/mediatek/filogic/base-files/etc/board.d/02_network" 'ruijie,rg-x60-ubootmod' && feature_state[NetworkSetup]=true
    contains_marker "$source_root/target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac" 'ruijie,rg-x60-ubootmod' && feature_state[WifiMacFix]=true
    (( upgrade_count >= 2 )) && feature_state[UpgradeSupport]=true

    return 0
}

feature_is_complete() {
    local key

    for key in "${feature_keys[@]}"; do
        [[ "${feature_state[$key]}" == true ]] || return 1
    done
}

refresh_feature_state

if feature_is_complete; then
    echo 'Ruijie RG-X60 U-BootMod support is already complete; patch application skipped.'
    exit 0
fi

present_parts=()
for key in "${feature_keys[@]}"; do
    [[ "${feature_state[$key]}" == true ]] && present_parts+=("$key")
done

if (( ${#present_parts[@]} > 0 )); then
    printf 'Partial RG-X60 U-BootMod support detected; refusing to apply an incomplete overlay: %s\n' "$(IFS=', '; echo "${present_parts[*]}")" >&2
    exit 1
fi

if git -C "$source_root" apply --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    echo 'Applying RG-X60 patch directly.'
    git -C "$source_root" apply --index --whitespace=nowarn "$patch_file"
else
    echo 'Direct application did not match; trying a three-way Git merge.'
    git -C "$source_root" apply --index --3way --whitespace=nowarn "$patch_file"
fi

git -C "$source_root" diff --cached --check
refresh_feature_state

missing_parts=()
for key in "${feature_keys[@]}"; do
    [[ "${feature_state[$key]}" == true ]] || missing_parts+=("$key")
done

if (( ${#missing_parts[@]} > 0 )); then
    printf 'Patch application completed but required parts are missing: %s\n' "$(IFS=', '; echo "${missing_parts[*]}")" >&2
    exit 1
fi

echo 'Ruijie RG-X60 U-BootMod patch applied and verified.'
git -C "$source_root" diff --cached --stat
