#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    echo 'apt-get was not found; this script expects a Debian/Ubuntu runner.' >&2
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo 'sudo was not found.' >&2
    exit 1
fi

packages=(
    build-essential
    clang
    flex
    bison
    g++
    gawk
    gcc-multilib
    g++-multilib
    gettext
    git
    libncurses-dev
    libssl-dev
    libelf-dev
    libyaml-dev
    python3
    python3-setuptools
    python3-pyelftools
    rsync
    swig
    unzip
    zlib1g-dev
    file
    wget
    curl
    device-tree-compiler
    qemu-utils
    squashfs-tools
    zstd
)

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install --yes --no-install-recommends "${packages[@]}"
