# 把用户态崩溃现场翻成函数名（iPad7,1 17.7.11 的 dyld 共享缓存）

内核在进程以 SIGTRAP/SIGSEGV/… 退出时打一行（`xnu-patches/userland-mounts`，`evb10: crash pid …`）：

```
evb10: crash pid 26 (SpringBoard) sig 5 pc 0x1a50ab2ec lr 0x1a50ab2ec sp … x16 0x1954286bc esr 0xf2000000 far 0
  | up 0x1acdb684c 0x195282cc0 … 0x1af12a228 0 | cache base 0x180000000 first 0x5ccc000 slide 0x5ccc000
```

`pc`/`lr`/`up`（frame pointer 链上的返回地址）是**滑动之后**的用户地址；`slide` 是这次启动共享缓存的随机滑动
（每次启动不同，所以必须用同一行里的值）。`未滑动地址 = 地址 − slide`。主程序（`0x100…` 开头）的滑动是 4 KiB 粒度，
用 `pc` 的低 12 位对 `llvm-objdump` 的地址就行，见下面「主程序」。

## 一次性准备（全在草稿目录 `$ULAND`，默认 `/tmp/uland`；没有 root，都是解到目录里）

1. **根镜像的两个窗口**（`userdata-root.img` 的布局见 `HANDOFF.md`，SHNGROOT 清单；当前是
   `OS` offset `0x100000` size 6077580800，`SystemOS` offset `0x16a600000` size 3303014400）：

   ```
   dd if=…/userdata-root.img of=$ULAND/systemos.apfs bs=1M iflag=skip_bytes,count_bytes skip=$((0x16a600000)) count=3303014400
   dd if=…/userdata-root.img of=$ULAND/os.apfs       bs=1M iflag=skip_bytes,count_bytes skip=$((0x100000))     count=6077580800
   ```

2. **7-Zip 25.01**（`7zz`，Linux x64 静态版，ip7z/7zip 的 GitHub release；7-zip.org 的链接会 404）。
   libfsapfs（`pyfsapfs`，`apfs_ls.py`）读不了封印的 SystemOS 卷，7-Zip 可以：

   ```
   7zz x systemos.apfs -o$ULAND/dsc -y 'System/Library/Caches/com.apple.dyld/*'      # 52 个子缓存 + .symbols
   7zz x os.apfs -o$ULAND/osx -y usr/libexec/watchdogd System/Library/LaunchDaemons/*.plist   # 要看的主程序
   ```

   `7zz` 会报 3 个 sub item error：`*.dyldlinkedit` 和 `.symbols` 是 decmpfs 压缩文件（数据叉是空的，内容在资源叉里）。
3. **libzbitmap**（`git clone https://github.com/eafer/libzbitmap`，`make`，得到 `libzbitmap.so`，放 `$ULAND/libzbitmap/`），
   然后用 `decmpfs14.py`（类型 14 = LZBITMAP）解那三个文件：

   ```
   cd $ULAND/dsc/System/Library/Caches/com.apple.dyld
   for n in 34 52; do python3 decmpfs14.py "dyld_shared_cache_arm64.$n.dyldlinkedit:com.apple.decmpfs" \
        "dyld_shared_cache_arm64.$n.dyldlinkedit:com.apple.ResourceFork" $ULAND/dsc/dsc.$n.linkedit; done
   python3 decmpfs14.py dyld_shared_cache_arm64.symbols:com.apple.decmpfs dyld_shared_cache_arm64.symbols:com.apple.ResourceFork $ULAND/dsc/dyld_shared_cache_arm64.symbols
   ```

   （`.symbols` 是本地符号，`.34/.52.dyldlinkedit` 里是各个映像的 LINKEDIT，导出符号在那里。）
4. `llvm-objdump`/`llvm-objcopy` 用 AOSP 的 `clang-r547379/bin`（`dsc.py` 里写死了路径；没有 `llvm-mc`）。

## 用法

```
python3 dsc.py sym --slide 5ccc000 0x1a50ab2ec 0x1acdb684c …   # 给地址起名：映像`符号+偏移
python3 dsc.py fn  --slide 5ccc000 0x1a50ab2ec 0x10            # 反汇编包含该地址的整个函数（到 pc+0x10），分支目标带名字
python3 dsc.py dis --slide 5ccc000 0x1a50ab2a0 30              # 从某个地址起反汇编 30 条
python3 dsc.py img 0x19f3df2ec                                 # 地址属于哪个映像
python3 dsc.py exports libdyld.dylib                           # 一个映像的导出表
```

`adrp` 的目标页没有按页取整（只对分支/`bl` 的目标可靠），要读字符串/CFString 请自己算。

## 主程序（`0x100…` 的地址，比如 watchdogd）

从 OS 窗口里 7zz 解出来，`llvm-objdump -d --macho --no-show-raw-insn` 反汇编，运行时基址 `B = pc − 文件内偏移`（4 KiB 对齐，
崩溃现场的 `pc` 低 12 位和 `brk` 存根的地址低 12 位一致即可）。`nm`/`strings` 看符号和字符串。

## 已经解出来的三个崩溃（emmc5m，2026-10-27，`tools/xnu-probe/runs/emmc5m.kernel.log`）

| 进程 | 现场 | 原因 |
| --- | --- | --- |
| `watchdogd` | `connect_to_kext()` 里 `os_crash("… unable to lookup watchdog KEXT service")`，`brk #1` | 找不到 `IOWatchdog` 服务，且 `kern.hv_vmm_present == 0`；启动里 `PanicOnCrash`，所以内核跟着 panic。**ADT 里 `/defaults/vmm-present = 1` 让它干净退出**（`make-evb10-adt.py`，默认开） |
| `SpringBoard`、`mediaserverd` | `-[FBSDisplayMonitor _initWithBookendObserver:transformer:]+0x47c`，`brk #0` 在 `__bs_set_crash_log_message` 之后 | `[[CADisplay displays] firstObject]` 是 nil：没有显示器（没有 IOMobileFramebuffer）。**要靠显示移植解决** |
| `liveactivitiesd` | `SessionSyncEngine` 的 Swift 代码（`Keybag.shared` → `SessionCore.Daemon.init`），`brk #1` | Swift 运行时陷阱（强制解包/先决条件），疑似 Keybag 状态不可用；优先级低 |

## 找一个字符串/全局变量是谁用的（QuartzCore 之类的映像）

```
python3 qcfind.py QuartzCore.framework/QuartzCore CAEnableDeepFramebuffer     # cstring → CFString 对象 → 引用它的代码（adrp+add）
python3 dataref.py QuartzCore.framework/QuartzCore 0x1f491ae10 0x1f4919c20    # 谁读写这些全局（未滑动地址；adrp + add/ldr/str）
python3 dsc.py fn 0x18957bea0 0x120                                           # 然后反汇编那个函数
```

（2026-10-29 用它查出 `b3a8` 的来路：`IOMFBDisplay::framebuffer_pixel_formatEv` 在显示器标志位 3（0x238 处）置位时返回 `b3a8`，
位 3 由 `IOMFBDisplay` 构造函数按 `___CADeviceUseCIF10_block_invoke` 写的全局字节 `0x1f491ae10` 设；那个字节 = MobileGestalt `Aixt/MEN2O2B7f+8m4TxUA` 的答案，
再被偏好 `CAEnableDeepFramebuffer`（`CFPreferencesGetAppBooleanValue`，当前应用域，找不到退全局域）覆盖。）
