# 黑苹果 Intel 蓝牙 BLE HID 键盘配对失败 → 不弹授权码（完整修复）

> **一句话**：在 macOS + Intel 蓝牙（`IntelBluetoothFirmware` 驱动）的黑苹果上，BLE 键盘能被发现、能建立连接，但**永远不弹 6 位配对码**，30 秒后自动断开。根因是 Intel 固件从不上报 `LE PHY Update Complete` 事件，`bluetoothd` 的连接状态机卡在 GATT 之前的 `wait-for-features` 阶段，配对流程**从未启动**。
>
> **English**: On hackintoshes using Intel Bluetooth driven by `IntelBluetoothFirmware`, BLE HID keyboards connect at link level but never show the pairing passkey, because the Intel firmware never emits `LE PHY Update Complete`. `bluetoothd` stalls in `wait-for-features` / `PHYReady:no` before GATT and SMP ever start. This repo ships the kernel patch, a prebuilt kext, and the full diagnosis write-up.

---

## 适用范围（先对症状）

| 现象 | 本仓库是否适用 |
|---|---|
| 蓝牙列表里能看到键盘，点「连接」一直转圈，**没有** 6 位数字 | ✅ 适用 |
| 卖家说「把屏幕上的授权码在键盘上敲一下」，但屏幕上根本没有码 | ✅ 适用（码是没生成，不是没显示） |
| 鼠标 / 耳机 / 手机能正常连，只有键盘不行 | ✅ 典型（这些设备不需要 MITM passkey 配对） |
| 键盘点连接后短暂显示「断开连接」再失败 | ✅ 适用 |
| 蓝牙列表里根本看不到键盘 | ❌ 不是本问题（先确认键盘进入配对模式） |
| 用的是 Broadcom 网卡 / 白苹果 | ❌ 不适用（本补丁只作用于 Intel 蓝牙） |

**判定命令**（不需要 root）：

```bash
log show --last 10m --predicate 'process == "bluetoothd"' --style compact \
  | grep -iE "PHYReady|encryptionStatusChangedCb|Accepting pairing request"
```

- 出现 `ready: wait-for-features ... PHYReady:no` 之后日志再无 GATT/SMP 动作 → **命中本问题**
- 出现 `Accepting pairing request with passkey <6位>` → 配对流程正常启动了，装之前先别装

---

## 本机实测环境（Works on my machine）

| 项目 | 值 |
|---|---|
| 机型 (SMBIOS) | `iMac19,1`（OpenCore 黑苹果，EFI 位于磁盘唯一 ESP `disk0s1`） |
| CPU | 6 核 Intel Core i5 |
| 内存 | 16 GB |
| 系统 | **macOS 13.7.8 (22H730)**，Darwin 22.6.0 |
| 无线网卡 | **Intel Wireless-AC 9560**（CNVi，2×2 802.11ac，系统报告 `Card Type: Wi-Fi (0x8086, …)`，无 802.11ax） |
| Wi-Fi 驱动 | `AirportItlwm 2.3.0`（`itlwm fw 46.4e1ceb39`） |
| 蓝牙控制器 | 同一颗 **9560 的蓝牙半边**，USB `8087:0aaa`（idProduct 2730，`IntelBluetoothFirmware_9560` personality），固件 `v256 c256`，`Chipset: THIRD_PARTY_DONGLE`，`Transport: USB` |
| 蓝牙软件栈 | `Lilu 1.7.2` + `BlueToolFixup 2.7.2` + `IntelBluetoothFirmware 2.4.0` + `IntelBTPatcher 2.4.0` → **本仓库替换为 2.5.1（含补丁）** |
| 键盘 | **Logitech K251**（法规型号 **YR0107**，蓝牙名 `Logi K251`），USB `VID 0x046D / PID 0xB397`，固件 `BK101.00_0007` |
| 键盘连接方式 | **仅 BLE**（无 2.4G 接收器；全程不以经典蓝牙 HID 出现，`CnS < BLE >`） |
| 同机已配对设备 | REDMI K90 Pro Max（BLE 手机）——这类不需要 passkey 的设备本来就正常 |

---

## 故障现象（修复前）

1. 系统设置 → 蓝牙 → 附近设备里能看到 `Logi K251`
2. 长按键盘底部配对键 3 秒（LED 快闪）后点「连接」
3. 一直转圈，**不出现任何数字**，约 30 秒后自己断开
4. 键盘侧同样在等一个永远不会到来的码

真实日志（见 [`logs/before-failed-pairing.log`](logs/before-failed-pairing.log)）：

```
22:58:09.521  Outgoing LE Connection complete ... status 0        ← 链路层连接成功
22:58:09.524  Gatt device connected ... status 0
22:58:09.524  encryptionStatusChangedCb status=4803 isPairing=0   ← 距连接成功仅 3 毫秒
22:58:09.524  Encryption is now disabled
22:58:09.609  Remote Features: 3D 01 00 ... ready: wait-for-features ... PHYReady:no
              （之后 30 秒日志里再无任何 GATT / SMP 动作）
22:58:39.514  LE Link disconnected ... reason 722
```

两个可读的结论：

- **3 毫秒**就返回加密失败 ⇒ 这个错误来自**本地控制器**，物理上不可能是一次和键盘的往返（LE 连接间隔 15 ms）。所以不是键盘拒绝、不是配对模式没进、更不是码没显示。
- `PHYReady:no` 之后再无 SMP ⇒ `bluetoothd` 认为链路「还没准备好」，**配对流程压根没开始**。

---

## 根因

Intel 蓝牙固件对**新建的 LE 连接**不会发出这两个 HCI 事件：

| 缺失的事件 | macOS 侧后果 |
|---|---|
| `LE PHY Update Complete` (LE Meta `0x04`) | 卡在 `wait-for-phy` / `PHYReady:no` |
| `LE Data Length Change` (LE Meta `0x07`) | 卡在 `LE_READY_WAIT_FOR_LENGTH` |

`bluetoothd` 的内部状态机必须依次收到它们才会继续：`CONNECTION_COMPLETE → ready → GATT 发现 → SMP 配对`。既然卡在第一步，就永远不会走到「显示 passkey」那一步。

不需要 MITM 的设备（耳机、鼠标、手机）会走 Just Works / 无加密路径，所以它们一直是好的——这正是 issue 里「鼠标能用、键盘不行」的原因。

上游记录：[#497 (AX201: keyboard won't pair, no PIN dialog)](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/497)、[#514 (BLE HID cannot bind, no passkey prompt)](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/514)、[PR #515 (3-stage fake event patch)](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/pull/515)。

---

## 修复原理

`IntelBTPatcher` 拦截 `HCI_OP_LE_READ_REMOTE_FEATURES (0x2016)` 命令，**故意多发两次**，把随之而来的重复 `LE Read Remote Features Complete` 事件改写成缺失的两个事件：

```
第 1 个（真实）  → 原样透传
第 2 个（重复）  → 改写为假 LE PHY Update Complete   {3E 06 0C 00 h_lo h_hi 02 02}
第 3 个（重复）  → 改写为假 LE Data Length Change    {3E 0B 07 00 h_lo h_hi 1B 00 48 01 1B 00 48 01}
```

`bluetoothd` 收到后依次越过 `wait-for-phy` 和 `LE_READY_WAIT_FOR_LENGTH`，进入 GATT 与 SMP，passkey 弹窗就出现了。

> 陷阱：`LE Data Length Change` **没有 status 字节**，句柄写在事件字节 `[3][4]`；`LE PHY Update Complete` 有 status，句柄在 `[4][5]`。写错会继续卡在 `LE_READY_WAIT_FOR_LENGTH`。

---

## 安装

### 方式 A：直接用预编译 kext（推荐，1 分钟）

```bash
git clone https://github.com/soyeoning94/hackintosh-intel-bt-ble-hid-fix.git
cd hackintosh-intel-bt-ble-hid-fix

# 1) 备份现有 OC 目录（务必先做）
sudo mkdir -p /Volumes/EFI && sudo diskutil mount -mountPoint /Volumes/EFI disk0s1
cp -R /Volumes/EFI/EFI/OC ~/Desktop/OC-backup-$(date +%Y%m%d)

# 2) 替换 kext（保持 bundle id 不变，config.plist 无需改动）
sudo rm -rf /Volumes/EFI/EFI/OC/Kexts/IntelBTPatcher.kext
sudo cp -R kext/IntelBTPatcher.kext /Volumes/EFI/EFI/OC/Kexts/
sudo xattr -cr /Volumes/EFI/EFI/OC/Kexts/IntelBTPatcher.kext

# 3) 校验 + 卸载 + 重启
plutil -p /Volumes/EFI/EFI/OC/Kexts/IntelBTPatcher.kext/Contents/Info.plist | grep CFBundleVersion  # 应为 2.5.1
sudo diskutil unmount /Volumes/EFI
sudo reboot
```

`config.plist` 里已有的 `Kernel > Add` 条目（`BundlePath = IntelBTPatcher.kext`、`Enabled = true`、无 Min/MaxKernel 限制）**不需要修改**。

### 方式 B：从源码编译（无完整 Xcode 也能编）

见 [`docs/build-with-clt.md`](docs/build-with-clt.md)，或直接：

```bash
./scripts/build.sh          # 产出 build/IntelBTPatcher.kext
./scripts/install-efi.sh disk0s1
```

---

## 验证

```bash
# 1) kext 是否真的加载（本次启动）
kmutil showloaded | grep IntelBTPatcher
#   → com.zxystd.IntelBTPatcher (2.5.1) ...   ← 必须是 2.5.1，没出现说明被 OpenCore 丢弃了

# 2) 配对时是否出现 passkey
log show --last 5m --predicate 'process == "bluetoothd"' --style compact \
  | grep -iE "Accepting pairing request|smpPairingCompleted|BLEPaired"
```

成功时日志长这样（见 [`logs/after-successful-pairing.log`](logs/after-successful-pairing.log)）：

```
23:38:38.179  LE HID connection complete ... (VID:0x046D/PID:0xB397)
23:38:39.175  Accepting pairing request with passkey 708717        ← 弹窗出现
23:38:44.180  encryptionStatusChangedCb status=0 isPairing=1       ← 加密成功
23:38:44.180  Encryption is now enabled
23:38:44.224  smpPairingCompleted ... status=0                    ← 配对完成
23:38:44.257  Device found: ... DvF 0x202000 < BLEPaired Central >, DvT Keyboard
```

**操作顺序**：键盘长按配对键 3 秒（LED 快闪）→ 系统设置点「连接」→ 屏幕上出现 6 位数字 → **在键盘上敲这 6 位并按 Enter**。

> 实测经验：**第一次点连接可能仍失败一次**（`smpPairingCompleted status=4805`），不用管，**再点一次连接**就成功了。配对成功后键盘会被记住，之后开机自动回连，不再需要码。

---

## 回滚

```bash
sudo diskutil mount -mountPoint /Volumes/EFI disk0s1
sudo rm -rf /Volumes/EFI/EFI/OC/Kexts/IntelBTPatcher.kext
sudo cp -R ~/Desktop/OC-backup-*/Kexts/IntelBTPatcher.kext /Volumes/EFI/EFI/OC/Kexts/
sudo diskutil unmount /Volumes/EFI && sudo reboot
```

kext 加载失败最多让蓝牙不可用，**不会影响磁盘数据或启动**（OpenCore 会跳过它）。

---

## 已知限制

- 只在 **macOS 13.7.8 + Intel 9560 + Logitech K251** 上实测通过；`AX200/AX201/AX210` 等同族控制器理论上同样适用（上游 issue 里 AX201 + Ventura 也有成功报告），但我没有硬件验证。
- macOS 14/15/Tahoe 需要 `lshbluesky` fork 的 Tahoe 支持分支作基座（PR #515 本身就是基于它写的），本仓库的构建脚本默认拉 PR #515 head。
- 预编译 kext **未签名**，与上游 OpenIntelWireless 发布包一致；依赖 OpenCore 注入，仅限黑苹果。
- 补丁靠 `IOUSBHostPipe::io(...)` + `initWithDescriptorsAndOwners(...)` 两个私有符号挂钩。如果你的 macOS 版本导不出它们，补丁会静默不生效（可用启动参数 `-liludbgall` 看 `routed` / `failed to resolve` 日志）。

---

## 仓库结构

```
.
├── README.md                                     ← 你在这里
├── docs/
│   ├── how-we-fixed-it.md                        ← 完整排障时间线（含两次失败）
│   ├── diagnosis.md                              ← 怎么从 bluetoothd 日志判定根因
│   └── build-with-clt.md                         ← 只有 Command Line Tools 时编译 kext
├── patches/
│   ├── 0001-upstream-PR515-le-phy-datalength.patch   ← 上游 PR #515（相对 2.4.0）
│   └── 0002-our-portability-and-link-fixes.patch     ← 本仓库的移植/链接修正
├── src/
│   ├── IntelBTPatcher.cpp / .hpp                 ← 打过补丁的完整源码
│   └── kmod_info.cpp                             ← 手工链接必须补的 _kmod_info
├── scripts/
│   ├── build.sh                                  ← 一键编译（CLT 即可）
│   └── install-efi.sh                            ← 备份 + 写入 EFI 分区
├── kext/IntelBTPatcher.kext                      ← 预编译（2.5.1, x86_64, 未签名）
└── logs/
    ├── before-failed-pairing.log                 ← 修复前：4803 / PHYReady:no
    └── after-successful-pairing.log              ← 修复后：passkey / SMP 完成
```

---

## 参考

- OpenIntelWireless/IntelBluetoothFirmware [#497](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/497)、[#514](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/514)、[PR #515](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/pull/515)
- [acidanthera/Lilu](https://github.com/acidanthera/Lilu)、[acidanthera/MacKernelSDK](https://github.com/acidanthera/MacKernelSDK)
- Logitech K251 官方入门指南（长按底部配对键 3 秒进入配对模式）

## License

本仓库的文档与脚本：MIT（见 [`LICENSE`](LICENSE)）。
`src/` 与 `kext/` 派生自 [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware)（GPL-2.0），同样以 GPL-2.0 提供，详见 [`NOTICE.md`](NOTICE.md)。
