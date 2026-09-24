#!/usr/bin/env bash
set -Eeuo pipefail

source_directory="${1:?usage: prepare-openwrt-prebuilt.sh SOURCE_DIRECTORY}"
base_url="${OPENWRT_PREBUILT_BASE_URL:-https://downloads.openwrt.org/snapshots/targets/mediatek/filogic}"
prebuilt_root="${OPENWRT_PREBUILT_ROOT:-/opt/openwrt-prebuilt}"
download_root="${RUNNER_TEMP:-/tmp}/openwrt-prebuilt-${GITHUB_RUN_ID:-local}"

if [[ ! -d "$source_directory" ]]; then
    echo "Source directory does not exist: $source_directory" >&2
    exit 1
fi
if [[ "$prebuilt_root" != '/opt/openwrt-prebuilt' ]]; then
    echo 'OPENWRT_PREBUILT_ROOT must remain /opt/openwrt-prebuilt.' >&2
    exit 1
fi

for command in curl sha256sum tar grep awk find sudo; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is missing: $command" >&2
        exit 1
    fi
done

base_url="${base_url%/}"
mkdir -p -- "$download_root"

echo "Reading profiles: $base_url/profiles.json"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 \
    --silent --show-error \
    --output "$download_root/profiles.json" \
    "$base_url/profiles.json"

echo "Reading checksums: $base_url/sha256sums"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 \
    --silent --show-error \
    --output "$download_root/sha256sums" \
    "$base_url/sha256sums"

# profiles.json no longer advertises the prebuilt archives, so discover them
# from sha256sums, which lists every file published in the target directory.
find_archive() {
    local description="$1"
    local pattern="$2"
    local -a matches

    mapfile -t matches < <(
        awk -v pattern="$pattern" '
            substr($2, 1, 1) == "*" && substr($2, 2) ~ pattern { print substr($2, 2) }
        ' "$download_root/sha256sums"
    )
    if (( ${#matches[@]} != 1 )); then
        echo "Expected one x86_64 $description archive in sha256sums, found ${#matches[@]}." >&2
        printf '%s\n' "${matches[@]}" >&2
        exit 1
    fi
    printf '%s\n' "${matches[0]}"
}

llvm_filename="$(find_archive LLVM-BPF '^llvm-bpf-[^/]+[.]Linux-x86_64[.]tar[.]zst$')"
toolchain_filename="$(find_archive toolchain '^openwrt-toolchain-mediatek-filogic_[^/]+[.]Linux-x86_64[.]tar[.]zst$')"
printf 'LLVM-BPF archive: %s\n' "$llvm_filename"
printf 'Toolchain archive: %s\n' "$toolchain_filename"

checksum_for() {
    local filename="$1"
    local record

    if ! record="$(awk -v expected="*$filename" '$2 == expected { print; count++ } END { if (count != 1) exit 1 }' "$download_root/sha256sums")"; then
        echo "No unique SHA-256 entry found for $filename." >&2
        exit 1
    fi
    printf '%s\n' "${record%% *}"
}

download_verified() {
    local filename="$1"
    local expected_hash="$2"
    local archive_path="$download_root/$filename"
    local actual_hash

    echo "Downloading $filename" >&2
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 \
        --silent --show-error \
        --output "$archive_path" \
        "$base_url/$filename"

    actual_hash="$(sha256sum "$archive_path")"
    actual_hash="${actual_hash%% *}"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "SHA-256 mismatch for $filename." >&2
        echo "Expected: $expected_hash" >&2
        echo "Actual:   $actual_hash" >&2
        exit 1
    fi
    printf '%s\n' "$archive_path"
}

llvm_hash="$(checksum_for "$llvm_filename")"
toolchain_hash="$(checksum_for "$toolchain_filename")"
llvm_archive="$(download_verified "$llvm_filename" "$llvm_hash")"
toolchain_archive="$(download_verified "$toolchain_filename" "$toolchain_hash")"

sudo rm -rf -- "$prebuilt_root"
sudo install -d -m 0755 "$prebuilt_root"
sudo chown "$(id -u):$(id -g)" "$prebuilt_root"

tar --zstd -xf "$llvm_archive" --directory "$prebuilt_root"
tar --zstd -xf "$toolchain_archive" --directory "$prebuilt_root"

llvm_root="$prebuilt_root/llvm-bpf"
toolchain_bundle="$prebuilt_root/${toolchain_filename%.tar.zst}"
if [[ ! -f "$llvm_root/.llvm-version" ]]; then
    echo "LLVM-BPF extraction did not produce $llvm_root/.llvm-version." >&2
    exit 1
fi
if [[ ! -d "$toolchain_bundle" ]]; then
    echo "Toolchain extraction did not produce $toolchain_bundle." >&2
    exit 1
fi

mapfile -t toolchain_roots < <(
    find "$toolchain_bundle" -mindepth 1 -maxdepth 1 -type d -name 'toolchain-*' -print
)
if (( ${#toolchain_roots[@]} != 1 )); then
    echo "Expected one toolchain root below $toolchain_bundle." >&2
    printf '%s\n' "${toolchain_roots[@]}"
    exit 1
fi

toolchain_root="${toolchain_roots[0]}"
toolchain_link="$prebuilt_root/toolchain"
ln -s "$toolchain_root" "$toolchain_link"
if [[ ! -f "$toolchain_link/info.mk" ]]; then
    echo "Toolchain extraction did not produce $toolchain_link/info.mk." >&2
    exit 1
fi

shopt -s nullglob
gcc_wrappers=("$toolchain_link"/bin/*-openwrt-linux-musl-gcc)
if (( ${#gcc_wrappers[@]} != 1 )); then
    echo "Expected one musl GCC wrapper below $toolchain_link/bin." >&2
    printf '%s\n' "${gcc_wrappers[@]}"
    exit 1
fi
toolchain_prefix="${gcc_wrappers[0]##*/}"
toolchain_prefix="${toolchain_prefix%gcc}"
toolchain_target="${toolchain_prefix%-}"
toolchain_gcc_version="$(awk -F '[:=]' '$1 == "GCC_VERSION" { value=$NF; gsub(/[[:space:]]/, "", value); print value; exit }' "$toolchain_link/info.mk")"
if [[ -z "$toolchain_gcc_version" ]]; then
    echo "Could not read GCC_VERSION from $toolchain_link/info.mk." >&2
    exit 1
fi

if [[ -e "$source_directory/llvm-bpf" || -L "$source_directory/llvm-bpf" ]]; then
    echo "The source tree already contains source/llvm-bpf; refusing to replace it." >&2
    exit 1
fi
ln -s "$llvm_root" "$source_directory/llvm-bpf"

if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        printf 'OPENWRT_PREBUILT_PROFILES=%s\n' "$download_root/profiles.json"
        printf 'OPENWRT_PREBUILT_CHECKSUMS=%s\n' "$download_root/sha256sums"
        printf 'OPENWRT_LLVM_BPF_ROOT=%s\n' "$llvm_root"
        printf 'OPENWRT_LLVM_BPF_ARCHIVE=%s\n' "$llvm_filename"
        printf 'OPENWRT_LLVM_BPF_SHA256=%s\n' "$llvm_hash"
        printf 'OPENWRT_TOOLCHAIN_ROOT=%s\n' "$toolchain_link"
        printf 'OPENWRT_TOOLCHAIN_ARCHIVE=%s\n' "$toolchain_filename"
        printf 'OPENWRT_TOOLCHAIN_SHA256=%s\n' "$toolchain_hash"
        printf 'OPENWRT_TOOLCHAIN_PREFIX=%s\n' "$toolchain_prefix"
        printf 'OPENWRT_TOOLCHAIN_TARGET=%s\n' "$toolchain_target"
        printf 'OPENWRT_TOOLCHAIN_GCC_VERSION=%s\n' "$toolchain_gcc_version"
    } >> "$GITHUB_ENV"
fi

printf 'LLVM-BPF root: %s\n' "$llvm_root"
printf 'Toolchain root: %s\n' "$toolchain_link"
printf 'Toolchain prefix: %s\n' "$toolchain_prefix"
printf 'Toolchain GCC version: %s\n' "$toolchain_gcc_version"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo '### Prebuilt OpenWrt toolchains'
        printf -- '- LLVM-BPF archive: \`%s\`\n' "$llvm_filename"
        printf -- '- LLVM-BPF extracted path: \`%s\`\n' "$llvm_root"
        printf -- '- Toolchain archive: \`%s\`\n' "$toolchain_filename"
        printf -- '- Toolchain extracted path: \`%s\`\n' "$toolchain_link"
        printf -- '- Toolchain prefix: \`%s\`\n' "$toolchain_prefix"
        printf -- '- Toolchain GCC version: \`%s\`\n' "$toolchain_gcc_version"
    } >> "$GITHUB_STEP_SUMMARY"
fi
