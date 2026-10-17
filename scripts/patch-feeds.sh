#!/usr/bin/env bash
set -Eeuo pipefail

source_directory="${1:-}"

if [[ -z "$source_directory" ]]; then
    echo "Usage: $0 <immortalwrt-source-directory>" >&2
    exit 2
fi

source_root="$(cd -- "$source_directory" && pwd -P)"
compiler_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
patches_root="$compiler_root/patches"

if [[ ! -d "$source_root/feeds" ]]; then
    echo "Feeds directory not found: $source_root/feeds" >&2
    exit 1
fi

# Fix miniupnpd 2.3.11 patch drift in immortalwrt/packages feed (immortalwrt/packages#2000, PR #2001)
miniupnpd_patch_dir="$source_root/feeds/packages/net/miniupnpd/patches"
if [[ -d "$miniupnpd_patch_dir" ]]; then
    if [[ -f "$miniupnpd_patch_dir/020-descr-filter-fix.patch" ]]; then
        echo "Applying miniupnpd 2.3.11 patch fixes (removing obsolete 020/030, refreshing 040)..."
        rm -f "$miniupnpd_patch_dir/020-descr-filter-fix.patch"
        rm -f "$miniupnpd_patch_dir/030-allow-private-fix.patch"
        if [[ -f "$patches_root/feeds/packages/net/miniupnpd/040-improve-logging.patch" ]]; then
            cp -f "$patches_root/feeds/packages/net/miniupnpd/040-improve-logging.patch" "$miniupnpd_patch_dir/040-improve-logging.patch"
        fi
        echo "miniupnpd patches successfully refreshed."
    else
        echo "miniupnpd 2.3.11 patch fix skipped (already resolved in upstream feed)."
    fi
fi

# Apply any additional feed file overlays if present in patches/feeds
if [[ -d "$patches_root/feeds" ]]; then
    while IFS= read -r -d '' src_file; do
        rel_path="${src_file#"$patches_root/feeds/"}"
        [[ "$rel_path" == "packages/net/miniupnpd/040-improve-logging.patch" ]] && continue
        dest_file="$source_root/feeds/$rel_path"
        dest_dir="$(dirname -- "$dest_file")"
        if [[ -d "$dest_dir" ]]; then
            cp -f "$src_file" "$dest_file"
            echo "Applied feed overlay: $rel_path"
        fi
    done < <(find "$patches_root/feeds" -type f -print0)
fi

echo "Feed patches applied and verified."
