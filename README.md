# ImmortalWrt Ruijie RG-X60 U-BootMod 编译器

这个目录是一套可独立成仓的编译配置：GitHub Actions 每次直接检出官方 `immortalwrt/immortalwrt`，应用本目录中的补丁，再只编译锐捷 RG-X60 的 OpenWrt U-Boot 布局固件。因此不需要长期维护 ImmortalWrt fork。

## 使用方法

GitHub 只识别仓库根目录下的 `.github/workflows`。请把 `immortalwrt-compiler` 目录中的内容作为一个新仓库的根目录提交，并把完整的固件编译配置保存为仓库根目录下的 `xg-x60-config`，然后在 Actions 页面运行 **Build Ruijie RG-X60 U-BootMod**。

工作流会直接把 `xg-x60-config` 复制为 ImmortalWrt 源码树的 `.config`，再执行 `make defconfig`。因此可以直接使用通过 `make menuconfig` 和 `make defconfig` 生成的完整配置，不需要维护本项目原先提供的最小设备配置。

## 预编译 LLVM-BPF 和 Toolchain

工作流会从 [OpenWrt Filogic snapshot](https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/) 自动下载 `profiles.json` 和 `sha256sums`，从 `profiles.json` 的 `x86_64` artifact 字段取得当前的 `llvm-bpf` 与 `toolchain` 文件名，再下载并校验对应的两个 `.tar.zst`。因此版本号更新时不需要修改工作流，也不依赖仓库中本地的压缩包。

解压后的固定路径如下：

- LLVM-BPF：`/opt/openwrt-prebuilt/llvm-bpf`。工作流还会在源码树创建 `source/llvm-bpf` 链接，这是 ImmortalWrt 检测预编译 LLVM 的位置。
- Toolchain：`/opt/openwrt-prebuilt/toolchain`。这是指向压缩包内部 `toolchain-aarch64_cortex-a53_gcc-<version>_musl` 目录的稳定链接。

`xg-x60-config` 需要启用外部 Toolchain 和预编译 BPF Toolchain，例如：

```text
CONFIG_EXTERNAL_TOOLCHAIN=y
CONFIG_BPF_TOOLCHAIN_PREBUILT=y
CONFIG_EXTERNAL_TOOLCHAIN_LIBC_USE_MUSL=y
```

工作流会根据下载包中的 `info.mk` 自动写入 `CONFIG_TARGET_NAME`、`CONFIG_TOOLCHAIN_PREFIX`、`CONFIG_TOOLCHAIN_ROOT` 和 `CONFIG_EXTERNAL_GCC_VERSION`。当前包对应的值为 `aarch64-openwrt-linux-musl`、`aarch64-openwrt-linux-musl-`、`/opt/openwrt-prebuilt/toolchain` 和 `14.4.0`；如果需要在配置中手工调整，使用上述固定路径即可。

## 第三方 feeds

需要引入第三方 feed 时，只需编辑仓库根目录下的 [`custom-feeds.conf`](custom-feeds.conf)，每行使用 OpenWrt 标准的 `src-git` 等 feeds 配置格式。工作流会先从当前 ImmortalWrt 源码复制 `feeds.conf.default`，再追加这里的内容，因此不需要复制或长期维护上游默认 feeds 列表。

```text
src-git myfeed https://github.com/owner/openwrt-feed.git;main
```

第三方 feed 的名称不要与上游 feed 重复。为了让构建结果可复现，建议固定到标签或提交；如果跟随分支，分支更新后构建内容也会变化。该文件会随构建输入一起保存到 Artifact。

手动运行时可以填写：

- `source_repository`：默认 `immortalwrt/immortalwrt`。
- `source_ref`：默认 `master`，也可以填写分支、标签或提交 SHA。

成功构建的产物会同时上传为 GitHub Actions Artifact 并发布到 GitHub Release，包括：

- `*-initramfs-recovery.itb`
- `*-squashfs-sysupgrade.itb`
- `*-preloader.bin`
- `*-bl31-uboot.fip`
- 构建信息和 SHA-256 校验文件

工作流还会按计划每周五 03:00（UTC）运行。计划运行会先查询 `SOURCE_REPOSITORY@SOURCE_REF` 的最新提交，并与最近一次成功构建 Release 的 `BUILD-MANIFEST.txt` 中记录的提交比较；如果提交没有变化，就只保留检查记录并跳过编译和发布。查询失败或找不到历史构建记录时会继续编译，以避免遗漏更新。手动运行不受此检查影响。

由本工作流发布的 Release 仅保留最近 3 个成功构建版本。Release 清理只匹配 `rg-x60-ubootmod-build-` 标签前缀，不会删除手工发布或其他工作流生成的 Release。

Workflow Runs 使用另一套策略：编译、产物检查或上传失败时不会执行发布任务，因此失败记录和完整日志会保留下来；下一次构建成功后，发布任务会删除当前 `build.yml` 此前所有已经结束的运行记录。当前成功运行无法删除自身，仍在执行或排队的并发任务也不会被删除。

## 长效补丁策略

[`patches/0001-mediatek-add-ruijie-rg-x60-ubootmod.patch`](patches/0001-mediatek-add-ruijie-rg-x60-ubootmod.patch) 基于 ImmortalWrt `fbef452572985e2cdb5a8843845f767b3bf4883d`（2026-08-18）重基，带完整 Git blob 索引。

[`scripts/apply-patch.sh`](scripts/apply-patch.sh) 会：

1. 检查上游是否已经完整包含该设备，完整包含时直接跳过；
2. 优先普通应用补丁；
3. 上下文发生变化时自动使用 Git 三方合并；
4. 对部分合入或无法合并的状态立即报错，避免编出不完整固件。

本地已有 ImmortalWrt 源码时也可以运行：

```bash
bash ./scripts/apply-patch.sh ../immortalwrt
```

## 重要提示

该固件使用无 NMBM、112 MiB UBI 的 U-BootMod 分区布局，与原厂布局不同。不要把 U-BootMod sysupgrade 固件直接刷到仍使用原厂引导和原厂分区的设备。修改引导区前应完整备份 `factory`、`product_info`、原厂 BL2/FIP，并确认已有串口或其他恢复手段。

如果未来上游重构相关文件，工作流会在“应用长期补丁”步骤失败并给出冲突，而不会继续编译。此时以新的上游提交重新生成补丁即可；设备 DTS、U-Boot 配置和默认环境都集中在这一份 patch 中。
