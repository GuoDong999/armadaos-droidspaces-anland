# ArmadaOS Freedom for Droidspaces

[English](README.md) | 简体中文

本项目将 ArmadaOS Freedom 的 Fedora 44 ARM64 用户空间打包为 Droidspaces rootfs，替换为支持 Anland 的 KWin/Xwayland，并加入 Droidspaces 容器配置。它不是可直接启动的 Android/Linux 镜像。

Droidspaces 使用 Android 宿主机内核，所以 ArmadaOS 的设备内核、设备树、启动镜像及直接硬件控制不会在容器内运行。Anland 显示依赖兼容的 GPU render node、Android 端 Anland 应用以及目标设备的 Droidspaces 内核支持。

## GitHub Release 下载

当前已发布的旧版 [v0.1.0-anland.1](https://github.com/GuoDong999/armadaos-droidspaces-anland/releases/tag/v0.1.0-anland.1) 使用的 Linux 用户名是 `z`。该版本密码锁定；首次启动后以 root 运行 `passwd z` 设置密码。

恢复上游账户 `armada` 的新版会以 `v0.1.0-anland.2` 发布。rootfs 超过 GitHub Release 单个附件的 2 GiB 限制，因此分成多个 `.part-*` 分卷。下载所有 rootfs 分卷、两份 SHA-256 清单、`.source` 来源记录以及 `assemble-rootfs-release.sh`，放在同一目录后运行：

```bash
chmod +x assemble-rootfs-release.sh
./assemble-rootfs-release.sh . ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz
```

脚本会先校验每个分卷，再按顺序重组并校验完整 rootfs SHA-256。

## 在 Droidspaces 中启动

1. Android 端安装 Droidspaces 支持的 Anland 5.x APK，授予 root 权限并完成 Anland 首次设置。
2. 在容器设置中启用 **GPU Access** 和 **Anland Display**，关闭 **Configure Termux:X11**。Anland 与 Termux:X11 使用不同显示路径，不要同时开启。
3. 从 Droidspaces RootFS 管理界面导入重组后的 `.tar.xz` 并启动容器。
4. 新版默认使用上游 `armada` 账户，密码锁定。以 root 进入容器后运行 `passwd armada` 设置密码。
5. 打开容器的 Anland 启动入口；在容器终端以 `armada` 执行 `start-desktop-session`，启动 `startplasma-wayland`。

镜像默认启用 NAT、Anland 显示、GPU Access 和 user namespaces；Termux:X11 关闭。允许 user namespaces 可能降低容器隔离强度，请只对可信容器启用。

## Anland 黑屏排查

参考项目的 ArmadaOS 维护记录指出，独立 Plasma 会话至少需要两项：KWin 必须收到 Anland producer 环境变量（`ANLAND`、`ANLAND_SOCKET`、render node 和 KGSL Mesa 选择），并且 Plasma 必须在 D-Bus session 中启动。只执行裸 `startplasma-wayland` 可能使 KWin 回退到容器内不存在的 DRM/KMS 设备，或使 Plasma 因没有 session bus 而立即退出。

本项目的 `start-desktop-session` 已改为检查 `/run/display.sock`，导出 Anland 环境并通过 `dbus-run-session` 启动 Plasma。如果提示 socket 不存在，先在 Droidspaces 打开容器的 Anland Display。新构建仍需在目标设备上实测画面，确认 GPU 和宿主 Anland 服务兼容后才能视为验证通过。

## 本地构建

要求：Docker Engine、Docker Buildx、支持 ARM64 执行的构建环境（原生 ARM64 或 QEMU/binfmt）、`curl`、`tar` 和 `xz`。还需将固定提交的 [Droidspaces rootfs builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder) 检出到 `source/droidspaces-rootfs-builder`。GitHub Actions 会自动检出它。

```bash
./build-rootfs.sh
```

默认构建上游 `armada` 账户并锁定密码，不使用此前提供的本机密码。首次启动后以 root 运行 `passwd armada` 设置密码。构建成功后产物位于 `dist/ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz`，旁边还有 SHA-256 与来源记录。

使用合成 rootfs 验证归档封装：

```bash
./tests/package-rootfs-smoke.sh
```

该测试只验证 Droidspaces 配置前缀、XZ 归档和摘要流程，不代表真实设备启动测试。

## GitHub Actions 构建

公开仓库提供手动 workflow：在 **Actions** 页面运行 **Build ArmadaOS Freedom Anland RootFS**。workflow 使用 ARM64 runner，检查可用磁盘空间，先扁平化 ArmadaOS OCI 多层镜像，再安装 Droidspaces 兼容配置和 Fedora 44 Anland KDE 包。成功后上传 `.tar.xz`、SHA-256 与 provenance，artifact 保留一天。GitHub 构建不会设置密码，生成的 `armada` 账户密码锁定。

## 已知限制

- 这是派生的容器 rootfs，不是官方 ArmadaOS Release 或已支持的 ArmadaOS 安装目标。
- Anland patched KWin/Xwayland 会替换 Armada Freedom 定制的 KWin，Freedom 专属 KWin 行为可能不再保留。
- ArmadaOS 的启动、更新、安装及硬件控制工具尚未验证可在容器内使用，不要用它们修改 Android 宿主。
- 是否能在目标设备上使用 Anland GPU 显示，取决于 Android 内核和 GPU render node；仍需目标设备实测。

## 上游项目

- [ArmadaOS Freedom](https://github.com/ArmadaOS-Freedom/armadaos-freedom)
- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)
- [Droidspaces RootFS builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder)
- [Droidspaces Anland 软件包](https://github.com/Goldzxcbug/droidspaces-package)

上游项目保留各自许可证和版权。本仓库只提供适配配置及构建脚本，不重新分发上游源码。
