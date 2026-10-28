# 只有 Command Line Tools，怎么编这个 kext

本机没有 `Xcode.app`，也没有 Homebrew，只有 `/Library/Developer/CommandLineTools`。这个工程的 Xcode project 需要 `xcodebuild`，所以走**手搓 clang + ld**。

以下命令在 **macOS 13.7.8、Apple clang 14.0.3** 上实测通过。

---

## 依赖

```bash
git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git
git clone --depth 1 https://github.com/acidanthera/Lilu.git          # 头文件在 Lilu/Lilu/Headers
git clone --depth 1 https://github.com/OpenIntelWireless/IntelBluetoothFirmware.git ibtf
cd ibtf
git fetch origin pull/515/head:pr515 --depth 1
git checkout pr515
```

> `IntelBTPatcher` 的 CMake/Xcode 设置里 `HEADER_SEARCH_PATHS` 指向 `Lilu.kext/Contents/Resources`，那里面的 `Headers/` 和仓库里的 `Lilu/Lilu/Headers/` 是同一套，直接 `-I Lilu/Lilu` 即可。

## 源码改动（本仓库已含）

把 `src/` 里的文件覆盖进去，并额外加入 `kmod_info.cpp`：

```bash
cp ../src/IntelBTPatcher.cpp ../src/IntelBTPatcher.hpp ibtf/IntelBTPatcher/
cp ../src/kmod_info.cpp ibtf/
```

相对上游 PR #515 的差异（见 `patches/0002-*.patch`）只有三处，目的都是**去掉内核集合不一定导出的符号**：

| 改动 | 原因 |
|---|---|
| `StandardUSB::getEndpointType(descriptor)` → `descriptor->bmAttributes & 0x3` | 少一个外部符号 |
| `new AsyncOwnerData` / `delete` → 静态池 | 去掉 `__Znwm`、`__ZdlPv` |
| 新增 `kmod_info.cpp` | `ld` 不生成 `_kmod_info`，缺它 kext 会被静默丢弃 |

## 编译

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX13.sdk     # 换成本机存在的 SDK
CF="-std=gnu++14 -mkernel -DKERNEL=1 -fapple-kext -fno-rtti -fno-exceptions \
    -fno-threadsafe-statics -fno-common -nostdinc++ -mmacosx-version-min=10.12 \
    -DMODULE_VERSION=\"2.5.1\" -DPRODUCT_NAME=IntelBTPatcher \
    -I ../MacKernelSDK/Headers -F ../MacKernelSDK/Headers \
    -I ../Lilu/Lilu -F ../Lilu/Lilu/Headers"

clang++ $CF -c IntelBTPatcher/IntelBTPatcher.cpp            -o build/IntelBTPatcher.o
clang++ $CF -c ../Lilu/Lilu/Library/plugin_start.cpp        -o build/plugin_start.o
clang++ $CF -c kmod_info.cpp                                -o build/kmod_info.o

ld -kext -arch x86_64 -static -L $SDK/usr/lib -lkmod -lkmodc++ \
   -o build/IntelBTPatcher build/IntelBTPatcher.o build/plugin_start.o build/kmod_info.o
```

## 四个必踩的坑

### 1. 必须 `-DKERNEL=1`

否则 `IOKit/usb/IOUSBHostPipe.h` 会 include `USBDriverKit/IOUSBHostPipe.h` 的 **dext 分支**：

```
error: unknown type name 'OSClassLoadInformation'
error: 'New' marked 'override' but does not override any member functions
```

`USBDriverKit/*.h` 里那些声明被 `#if !KERNEL` 包着，`-mkernel` 并不自动定义 `KERNEL`。

### 2. 必须一起编 `plugin_start.cpp`

漏了它，产物只有 22 KB，且没有 `_IntelBTPatcher_kern_start` / `_kmod_info` 的 start/stop 目标，kext 加载必失败。正确产物约 **44 KB**。

校验：

```bash
nm build/IntelBTPatcher | grep -E "_kmod_info|kern_start|kern_stop"
# 00000000000026c0 T _IntelBTPatcher_kern_start
# 0000000000002980 T _IntelBTPatcher_kern_stop
# 0000000000003a80 D _kmod_info
```

### 3. `PRODUCT_NAME` 只能给裸 token

`ADDPR(a)` 用 `##` 拼接 `PRODUCT_NAME`，加引号会变成 `"IntelBTPatcher"_debugEnabled`：

```
error: expected unqualified-id
extern bool ADDPR(debugEnabled);
```

正确：`-DPRODUCT_NAME=IntelBTPatcher`（`MODULE_VERSION` 反而要带引号：`-DMODULE_VERSION='"2.5.1"'`）。

### 4. `libkmod` / `libkmodc++` 用 SDK 自带的

`MacKernelSDK/Library/x86_64` 里只有 `libkmod.a`，没有 `libkmodc++.a`：

```
ld: library not found for -lkmodc++
```

改用 `$SDK/usr/lib/libkmod.a`、`$SDK/usr/lib/libkmodc++.a`（链接时会有 "built for newer macOS version" 警告，无害）。

---

## Info.plist：两个键决定生死

Xcode 构建会展开 `$(PRODUCT_NAME)` 之类变量，手工构建不会。**更关键的是这两个键**，缺了 macOS 会**静默丢弃** kext（`log show` 里连报错都没有）：

```xml
<key>CFBundleSupportedPlatforms</key>
<array><string>MacOSX</string></array>
<key>LSMinimumSystemVersion</key>
<string>10.12</string>
```

稳妥做法：直接拿一个**已知能加载的旧版 kext** 的 `Info.plist` 当模板，只改版本号：

```bash
cp /path/to/known-good/IntelBTPatcher.kext/Contents/Info.plist build/IntelBTPatcher.kext/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2.5.1' \
                        -c 'Set :CFBundleShortVersionString 2.5.1' \
                        build/IntelBTPatcher.kext/Contents/Info.plist
```

`CFBundleIdentifier` 必须保持 `com.zxystd.IntelBTPatcher`，这样 `config.plist` 里 `Kernel > Add` 的现成条目无需改动。

---

## 装之前最后一道自检

```bash
# 1) 依赖符号集应是旧版(2.4.0)的子集
diff <(nm -u /path/to/old/IntelBTPatcher | awk '{print $NF}' | sort) \
     <(nm -u build/IntelBTPatcher        | awk '{print $NF}' | sort)
#   输出中只应出现 "<" 行（旧版有、我们没有）；出现 ">" 行说明你引入了新符号，有风险

# 2) 结构自检（可选，无害）
plutil -lint build/IntelBTPatcher.kext/Contents/Info.plist
file build/IntelBTPatcher.kext/Contents/MacOS/IntelBTPatcher
#   → Mach-O 64-bit kext bundle x86_64
```

再执行 `./scripts/install-efi.sh disk0s1` 写入 EFI 并重启。
