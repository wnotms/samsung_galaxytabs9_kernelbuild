# Galaxy Tab S9 SM-X710 Kernel Build

用于通过 GitHub Actions 编译 Samsung Galaxy Tab S9 Wi-Fi（SM-X710 / Snapdragon 8 Gen 2 / SM8550 / Kalama）内核。

## 当前构建目标

- Device: Samsung Galaxy Tab S9 Wi-Fi
- Model: SM-X710
- Platform: Qualcomm SM8550 / Kalama
- Kernel: Linux 5.15.153
- Android KMI: android13-5.15
- Defconfig: `kalama_gki_defconfig`
- Toolchain: `clang-r450784e`
- Output: Kernel `Image` + AnyKernel3 ZIP + `.config`

## GitHub Actions

进入：

`Actions -> Build Galaxy Tab S9 SM-X710 Kernel -> Run workflow`

参数：

- `lto`: `thin` 推荐；`full` 用于实验。
- `jobs`: GitHub Hosted Runner 推荐 `2`，避免编译阶段内存压力过大。
- `build_number`: 默认 `X710ZCU5CYH4`，用于产物命名。

## Droidspaces

当前 SM-X710 defconfig 已包含 Droidspaces/容器环境需要的大部分功能，包括：

- System V IPC / POSIX message queue
- PID / UTS / IPC / USER / NET namespaces
- seccomp
- cgroups
- devtmpfs
- overlayfs
- veth / bridge
- netfilter / NAT

Actions 构建脚本会再次显式启用这些配置，并在编译后检查关键配置是否真正进入 `out/.config`。

## 构建产物

成功后在 Actions Artifacts 下载：

- `SM-X710_...zip`：AnyKernel3 刷机包
- `Image`：原始 arm64 kernel image
- `.config`：本次实际编译配置

## 注意

这是自定义内核构建项目。刷写前请确保已经备份原始 boot/init_boot/vendor_boot 以及重要数据，并确认刷机包与当前 SM-X710 固件兼容。

## License

本仓库中由本项目原创的构建脚本、GitHub Actions 工作流及其他项目专用文件，除非文件中另有声明，采用 **GNU General Public License v2.0 only (GPL-2.0-only)** 授权，详见根目录 `LICENSE`。

Linux 内核源码及其衍生内容保留原有许可证。请参阅 `common/COPYING`、`common/LICENSES/` 以及各源文件中的 SPDX 标识。

`prebuilts/`、工具链、固件及其他第三方组件不因根目录许可证而重新授权，继续遵循各自上游或权利人的许可证条款。
