# 判定手册：这是不是同一个问题

三层判定，从最省事的开始。全部命令都不需要 root。

---

## 第 1 层：环境是否符合

```bash
system_profiler SPBluetoothDataType | head -12
system_profiler SPUSBDataType | grep -A4 -i bluetooth
```

命中条件：

```
Chipset:  THIRD_PARTY_DONGLE      # 非 Apple/Broadcom 原生
Transport: USB
Vendor ID (USB): 0x8087            # Intel
Product ID:      0x0aaa / 0x0026 / 0x0029 / 0x0032  # 9560 / AX200 / AX201 / AX210 系列
```

再看这个 idProduct 对应哪个 personality：

```bash
python3 - <<'EOF'
import plistlib
d = plistlib.load(open('/Volumes/EFI/EFI/OC/Kexts/IntelBluetoothFirmware.kext/Contents/Info.plist','rb'))
for name, per in d.get('IOKitPersonalities', {}).items():
    if per.get('idProduct') == 2730:          # 0x0aaa = 2730
        print(name)
EOF
# → IntelBluetoothFirmware_9560
```

同时确认 Wi-Fi 半边也是 Intel（`system_profiler SPAirPortDataType` 看 `Card Type` 是不是 `0x8086`，驱动是不是 `AirportItlwm`）。

---

## 第 2 层：症状是否符合（核心）

连一次键盘，然后：

```bash
log show --last 5m --predicate 'process == "bluetoothd"' --style compact \
  | grep -iE "Outgoing LE Connection complete|Gatt device connected|encryptionStatusChangedCb|Remote Features|Accepting pairing request|smpPairingCompleted"
```

### 命中（就是本问题）

```
00:00.521  Outgoing LE Connection complete ... status 0
00:00.524  Gatt device connected ... status 0
00:00.524  encryptionStatusChangedCb status=4803 isPairing=0     ← 距连接成功 1~3 毫秒
00:00.524  Encryption is now disabled
00:00.609  Remote Features: ... ready: wait-for-features ... PHYReady:no
（此后 30 秒没有任何 GATT/SMP）
00:30.514  LE Link disconnected ... reason 722
```

四个特征，缺一不可：

| 特征 | 为什么关键 |
|---|---|
| `Outgoing LE Connection complete ... status 0` | 链路层 OK，排除「找不到设备」「没进配对模式」 |
| `encryptionStatusChangedCb status=4803 isPairing=0` | 加密没建立，且 macOS **未进入配对流程** |
| 上面两者间隔 **1–3 毫秒** | LE 间隔 15 ms，物理上无法完成往返 ⇒ 错误来自本地控制器，不是键盘拒绝 |
| `PHYReady:no` 之后无日志 | 状态机卡在 PHY 阶段，永远走不到「显示 passkey」 |

### 不命中

| 日志特征 | 含义 |
|---|---|
| 出现 `Accepting pairing request with passkey <6位>` | 配对流程正常启动 → 检查是不是键盘没敲码 / 敲错 / 没按 Enter |
| 只有 `Connection timeout` / 根本没有 `Outgoing LE Connection complete` | 射频/配对模式问题，与本补丁无关 |
| `Chipset: BCM_...` 或白苹果 | Broadcom 蓝牙，本补丁不适用 |
| 经典蓝牙 HID（`CnS < Classic >`）也能看到该键盘 | 键盘有经典蓝牙可用，优先走经典配对（会正常弹码），不需要本补丁 |

---

## 第 3 层：确认 kext 是否真的在跑（装完补丁后用）

这是最容易翻车的一步——**OpenCore 丢弃 kext 是静默的**，`log show` 里连一行报错都没有。

```bash
kmutil showloaded | grep IntelBTPatcher
```

- 有 `com.zxystd.IntelBTPatcher (2.5.1)` → 已加载
- 什么都没有 → 被丢弃了。此时不要看 `log show`，直接问运行时校验：

```bash
# 需要管理员权限（密码由本人输入）
sudo kmutil load -p /path/to/IntelBTPatcher.kext
```

常见返回与处理：

| 错误 | 原因 | 处理 |
|---|---|---|
| `Invalid ownership (501:20) should be (0:0)` | 只有运行时安装才检查，OC 注入不检查 | `chown -R 0:0` 后重试（仅用于诊断） |
| `Kexts must have a _kmod_info symbol` | 手工 `ld -kext` 不会生成 | 编译时加入 `src/kmod_info.cpp` |
| `Failed to bind '_lilu' as could not find a kext with 'as.vit9696.Lilu'` | Lilu 是 OC 注入的，磁盘上没有 | 正常现象，忽略；OC 注入时会先加载 Lilu |
| 静默消失 + plist 少了 `CFBundleSupportedPlatforms` | macOS 拒绝加载该 kext | Info.plist 必须含 `CFBundleSupportedPlatforms = [MacOSX]` 和 `LSMinimumSystemVersion` |

---

## 附：几个状态码的现场含义（仅记录观测，不代表官方定义）

| 值 | 出现位置 | 本机观测 |
|---|---|---|
| `4803` | `encryptionStatusChangedCb` | 加密未建立。修复前每次连接必现（1–3 ms 内） |
| `4805` | `smpPairingCompleted` | 一次 SMP 结束后失败。修复后**第一次**点连接时出现过一次，再点即成功 |
| `722` | `LE Link disconnected ... reason` | 本机观测为「本地主动断开」（30 秒超时，或用户点取消） |

这些数值不要当成通用结论——不同 macOS 版本/控制器可能含义不同，能用状态机字段（`ready-state`、`PHYReady`）判断时优先用字段。
