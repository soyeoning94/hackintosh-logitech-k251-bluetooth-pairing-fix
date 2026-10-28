# 预编译 kext

`IntelBTPatcher.kext` — `com.zxystd.IntelBTPatcher` **2.5.1**（含 PR #515 的 LE PHY / Data Length 补丁 + 本仓库的三处移植修正）。

| 项目 | 值 |
|---|---|
| 架构 | x86_64 |
| 编译环境 | macOS 13.7.8 (22H730) / Apple clang 14.0.3 / MacKernelSDK + Lilu 1.7.2 头文件 |
| 二进制大小 | 44,392 字节 |
| SHA-256 | `e30631269c082108eed785231ea5435a9bec963f67fe6df3ac68fd999fc18b7c` |
| 签名 | 未签名（与上游 OpenIntelWireless 发布包一致） |
| 依赖 | `Lilu >= 1.2.0`、`com.apple.iokit.IOUSBHostFamily` |

安装：把整个 `IntelBTPatcher.kext` 覆盖到 `EFI/OC/Kexts/`，保持 bundle id 不变，`config.plist` 无需改动。

```bash
shasum -a 256 IntelBTPatcher.kext/Contents/MacOS/IntelBTPatcher
```

若不是上面的 SHA-256，说明文件被改动过，建议改用 `../scripts/build.sh` 自己编译。

想自己验证产物是否可加载（不重启也能测）：

```bash
sudo cp -R IntelBTPatcher.kext /tmp/tk.kext && sudo chown -R 0:0 /tmp/tk.kext
sudo kmutil load -p /tmp/tk.kext
# 只报 "Failed to bind '_lilu' ... could not find a kext with 'as.vit9696.Lilu'" = 正常
# （Lilu 由 OpenCore 注入，磁盘上没有；其余检查已通过）
```
