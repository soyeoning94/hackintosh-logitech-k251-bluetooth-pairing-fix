# 这场排障是怎么打完的（完整时间线）

> 记录 2026-10-28 晚上一次真实排障：从「键盘连不上」到「定位内核驱动缺陷 → 自己编译 kext 补丁 → 两次失败重启 → 成功配对」。
> 所有时间戳、日志、命令都是现场真实产物，没有事后美化。

## 0. 起点：卖家的建议是错的（但不是骗人）

用户提的问题：Mac 能发现 `Logi K251`，点「连接」一直转圈，**没有任何授权码**。卖家说「把屏幕上的授权码在键盘上打一下」。

这句话本身是 Logitech K251 的正常流程（官方文档第 3 步：电脑会要求输入一组随机数字，用键盘敲入并按 Enter）。问题在于**码从来没出现在屏幕上**，所以「敲码」这个动作无从谈起。

第一步要做的不是照着做，而是**证明码有没有被生成过**。

## 1. 取证：先把「不是谁的问题」排掉

```bash
system_profiler SPBluetoothDataType
```

结果里两个字段立刻改变排查方向：

```
Chipset: THIRD_PARTY_DONGLE
Transport: USB
Vendor ID: 0x004C (Apple)
```

这不是白苹果的 Broadcom 蓝牙，而是第三方驱动的 Intel 蓝牙（`IntelBluetoothFirmware`）。再查 USB 树：

```
USB 3.1 Bus:
    Bluetooth USB Host Controller:
      Product ID: 0x0aaa
      Vendor ID: 0x8087 (Intel Corporation)
```

`8087:0aaa`。随后在 `IntelBluetoothFirmware.kext` 的 personalities 里比对：

```bash
python3 -c "..."   # 匹配 idProduct=2730 的 personality
# → personality: IntelBluetoothFirmware_9560
```

**结论：Intel Wireless-AC 9560**（不是最初误判的 AX201 —— 修正依据是固件 personality 名 + Wi-Fi 只报 802.11ac 没有 ax）。

## 2. 抓现场日志：找到「3 毫秒」这个不可能的数字

挂上实时抓取，让用户再点一次连接：

```bash
log stream --predicate 'process == "bluetoothd"' --style compact > bt_retry.log
```

拿到的时间线：

```
22:52:46.371  Connecting device 3C8E... classicPaired 0, lePaired 0, discoveredViaLeScan 1
22:52:46.783  Outgoing LE Connection complete ... status 0
22:52:46.789  Gatt device connected ... status 0
22:52:46.790  encryptionStatusChangedCb status=4803 isPairing=0     ← 距上一步 1 毫秒
22:52:46.790  Encryption is now disabled
22:53:16.4    （30 秒后）设置界面取消，断开 reason 722
```

三点判断：

1. **链路层是通的**（`status 0`），所以不是「找不到设备」「没进配对模式」。
2. **加密失败只用了 1–3 毫秒**。LE 连接间隔是 15 ms，一次和外围设备的往返至少 15–30 ms。3 毫秒的错误只能来自**本地控制器**，不可能是键盘拒绝。
3. `isPairing=0` ⇒ macOS 根本没进入配对流程。所以**不存在「码生成了但没显示」**——码根本没生成。

为了排除「用户没让键盘进配对模式」这个干扰项，让用户按官方文档长按底部配对键 3 秒（LED 快闪）后重试。日志**一模一样**，同样是 3 毫秒返回 4803。

## 3. 转折点：`PHYReady:no`

把过滤词放宽，看到了决定性的一行：

```
22:58:09.607  ReadRemoteVersionInformationCB ... ready: wait-for-version
22:58:09.609  Remote Features: 3D 01 00 00 00 00 00 00, handle E6804090,
              ready: wait-for-features, EDL [...], 2M [...], PHYReady:no
              ← 此后再无任何 GATT / SMP 日志，直到 30 秒超时
```

`bluetoothd` 的 LE 状态机顺序是：

```
CONNECTION_COMPLETE → wait-for-version → wait-for-features → wait-for-phy
                    → LE_READY_WAIT_FOR_LENGTH → ready → GATT 发现 → SMP 配对
```

`PHYReady:no` 说明它卡在 **PHY 阶段**，压根没走到 GATT，更没走到「显示 passkey」。而同机手机、耳机、鼠标能连，是因为它们不走需要 MITM passkey 的加密路径。

搜索这个现象，锁定上游：

- issue **#497**：AX201 上「键盘出不了 PIN 码，鼠标/耳机正常」——和本机完全一致
- issue **#514**：BLE HID 连上了但 bind 不了，`no passkey prompt`，30 秒静默断开
- **PR #515**：给出 3 阶段伪造事件补丁；评论区 2026-10-26 有人确认 **AX201 + Ventura 有效**

## 4. 自己编 kext（没有 Xcode，只有 Command Line Tools）

本机 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，没有 `Xcode.app`，也没有 Homebrew。也就是说 `xcodebuild` 编不了这个工程。

于是手搓 clang 命令。踩了 4 个坑（详见 [`build-with-clt.md`](build-with-clt.md)）：

| 坑 | 症状 | 解法 |
|---|---|---|
| 少 `-DKERNEL=1` | `USBDriverKit/IOUSBHostPipe.h` 走了 dext 分支：`OSClassLoadInformation` 未定义、`New marked override` | 编译时加 `-DKERNEL=1` |
| 漏编 `plugin_start.cpp` | 产物只有 22 KB，`nm` 里没有 `_IntelBTPatcher_kern_start` | 一起编 `Lilu/Lilu/Library/plugin_start.cpp` |
| `PRODUCT_NAME` 加引号 | `ADDPR` 的 `##` 拼接把字符串字面量拼进去 → `"IntelBTPatcher"_debugEnabled` | 只能给裸 token |
| `-lkmodc++` 找不到 | `library not found` | 用 SDK 自带的 `$SDK/usr/lib/libkmod.a`、`libkmodc++.a` |

产物 44 KB，与官方 2.4.0 的 57 KB 结构一致。

## 5. 第一次重启：静默失败

备份 OC 目录 → 替换 `EFI/OC/Kexts/IntelBTPatcher.kext` → 重启。

结果：`kmutil showloaded` 里**根本没有 IntelBTPatcher**，内核日志里**一条报错都没有**。行为变化只是连接状态从「转圈」变成「断开连接」，仍然没有码。

这属于 OpenCore 预链接阶段把 kext 丢弃了——**无声失败**，查日志查不到。

## 6. 第二次尝试：补 Info.plist（还是失败）

对比备份里能正常加载的 2.4.0 的 `Info.plist`，发现少了两个键：

```
CFBundleSupportedPlatforms = [ MacOSX ]
LSMinimumSystemVersion     = 10.12
```

用自己的 plist 时 Xcode 变量（`$(PRODUCT_NAME)` 等）没有展开，也没带这两个键。补上后重装、重启——**依然没加载**。

## 7. 关键一步：用 `kmutil load` 把真实错误逼出来

不想再盲猜着重启，于是直接在运行时试装（需要管理员密码由用户自己输入，agent 不代输）：

```bash
sudo kmutil load -p /path/to/IntelBTPatcher.kext
```

第一次返回：

```
Error Code=30 "Validating extension failed: Invalid ownership (501:20) should be (0:0)"
```

—— 只是归属问题（运行时安装才检查，OC 注入不检查）。把副本 `chown -R 0:0` 后重试，真正的错误浮出来了：

```
Error Code=31 "cannot be placed in kernel collection because:
                kexts must have a _kmod_info symbol"
```

**这就是答案。** Apple 的 Xcode 链接 kext 时会自动生成 `_kmod_info`（2.4.0 里位于 `0x39a0`），而我们手写的 `ld -kext` 不会。没有它，OpenCore 预链接直接丢弃，而且不报错。

顺带还发现我们的二进制比 2.4.0 多引用了两个外部符号：

- `StandardUSB::getEndpointType()`（来自 PR 里新加的 `captureIntelInterruptPipe`）
- `__Znwm`（PR 里的 `new AsyncOwnerData`）与 `__ZdlPv`

这两个符号在 macOS 13.7.8 的内核集合里是否导出无法直接验证（KC 不是普通 Mach-O，`nm` 读不出符号）。稳妥做法是**不依赖它们**：

```diff
- uint8_t epType = StandardUSB::getEndpointType(descriptor);
+ uint8_t epType = descriptor->bmAttributes & 0x3;   // bmAttributes[1:0] = 传输类型

- AsyncOwnerData *ownerData = new AsyncOwnerData;
+ static AsyncOwnerData ownerPool[4];                // 静态池代替 new/delete
+ AsyncOwnerData *ownerData = &ownerPool[ownerIdx++ & 3];
```

同时新增 [`src/kmod_info.cpp`](../src/kmod_info.cpp) 手工定义 `_kmod_info`（用 `<mach/kmod.h>` 的 `kmod_info_t`，start/stop 指向 `IntelBTPatcher_kern_start/_kern_stop`）。

改完再验证符号集：

```bash
diff <(nm -u 官方2.4.0) <(nm -u 我们的产物)
# 只剩官方有、我们没有的三个符号 —— 即我们是它的严格子集
```

「官方能加载的 2.4.0 需要的符号，我们需要的它也需要」，这一步把符号风险清零。

## 8. 成功

写入 EFI（sha256 `e30631…8b7c`）→ 重启 → 用户点连接：

```
23:38:38.179  LE HID connection complete ... (VID:0x046D/PID:0xB397)
23:38:39.175  Accepting pairing request with passkey 708717      ← 屏幕上出现了码
23:38:44.180  encryptionStatusChangedCb status=0 isPairing=1
23:38:44.224  smpPairingCompleted ... status=0
23:38:44.257  Device found: ... DvF 0x202000 < BLEPaired Central >, DvT Keyboard
```

用户在键盘上敲 708717 并按 Enter，连接成功。

另一个值得记录的细节：**第一次点连接仍失败过一次**（`smpPairingCompleted status=4805`），第二次才成功。写文档时把它作为「操作提示」保留了下来——免得下一个人以为补丁没生效就放弃了。

## 复盘：下次怎么更快

1. **先证明「码有没有被生成」**，而不是照着卖家的说法反复试。日志里没有 `Accepting pairing request with passkey` 就是没生成。
2. **毫秒级错误 = 本地问题**。3 ms 的失败不可能是外设回绝，直接把「设备问题 / 操作问题」排除掉。
3. **`PHYReady` / `ready-state` 这类状态机字段比错误码有用**。`status=4803` 到底对应什么错误码查半天没结果，但 `PHYReady:no` 一句话就锁定了阶段。
4. **kext 不加载时，别在 `log show` 里找**。OC 丢弃 kext 是静默的；用 `kmutil load -p` 主动触发校验才能拿到真实错误。
5. **手工链接 kext 的两个必备件**：`_kmod_info` 符号 + `CFBundleSupportedPlatforms` 键。缺任一都是无声失败。
