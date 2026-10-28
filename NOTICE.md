# NOTICE / 来源与授权

## 代码来源

`src/` 和 `kext/` 中的 `IntelBTPatcher` 代码派生自：

- [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware) — **GPL-2.0**
- 其中 LE PHY / Data Length 事件的 3 阶段补丁来自上游 **PR #515**（作者 `htthinh1999`，其说明中标注该补丁由 Claude 协助编写），以及 `if-lensman` 在 issue #514 中公开的排查成果
- 编译基座包含 [lshbluesky/IntelBluetoothFirmware](https://github.com/lshbluesky/IntelBluetoothFirmware) 的 Tahoe 支持代码

因此 `src/`、`kext/` 整体以 **GPL-2.0** 分发。若你分发本仓库的 kext 二进制，请一并保留 `src/` 源码与本 NOTICE。

## 本仓库原创部分

- `README.md`、`docs/`、`patches/0002-*.patch`、`scripts/`、`logs/` — **MIT**（见 LICENSE）
- 其中 `patches/0002` 的三处移植改动（`bmAttributes` 取传输类型、静态池替代 new/delete、新增 `kmod_info.cpp`）为本仓库原创，同样以 GPL-2.0 提供给 kext 部分使用。

## 商标

Logitech、Logi、K251 为 Logitech 的商标；Intel、OpenCore、macOS 分别为 Intel、Acidanthera、Apple 的商标或产品名。本仓库与上述公司无隶属关系。

## 免责

内核扩展属于高风险改动。本仓库的 kext 未签名，仅供黑苹果（OpenCore 注入）使用；修改 EFI 前请务必备份整个 `OC` 目录。因使用本仓库内容造成的任何损失由使用者自行承担。
