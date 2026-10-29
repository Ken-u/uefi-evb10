#!/usr/bin/env python3
"""抓一段串口输出，还原 UiApp 菜单屏幕，标出被反色（fg37/bg40）的段，并给出
识别出的当前高亮项。解析逻辑在 serial-cli.py（vt_segments / highlighted_raw）。

    ui-highlight.py SECS [KEY ...]

KEY 是 serial-cli.py 认识的按键转义（如 '\\033[B' = Down），会被**真的发出去**：
  * 这个脚本是用来「看」菜单当前高亮在哪一项，不是用来「选」的。
  * 不带 KEY 就纯观察；带 Down/Up 会改变高亮（菜单状态是有记忆的）。
  * 带回车（'\\r'）必须显式 --yes-enter，并且你得先知道当前高亮是哪一项。
    2026-10-27 就是靠串口「盲按 Down + Enter」选中了 UniXNU 菜单的 shutdown，
    PSCI SYSTEM_OFF 把板子整个断了电，没有任何远程手段能拉起来。
    UniXNU 的菜单画在 GOP 上，串口**没有回显**，这个脚本对它也没用。

注意 `>` 是 UiApp 的子菜单标记，不是光标。
"""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sc", os.path.join(here, "serial-cli.py"))
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

args = sys.argv[1:]
if not args:
    print(__doc__)
    sys.exit(2)
secs = float(args[0])
keys = [a for a in args[1:] if a != "--yes-enter"]
if any(k in ("\\r", "\\n", "enter") for k in keys) and "--yes-enter" not in args:
    sys.exit("拒绝：带回车必须显式 --yes-enter（见脚本开头的说明）")

sc.stty()
raw = sc.capture(secs, keys)
print(len(raw), "bytes")
for r, c, f, b, t in sc.vt_segments(raw):
    mark = "HL" if (f, b) == (37, 40) else "  "
    if r < 20:
        print(mark, f"r{r:02d} c{c:02d} fg{f} bg{b}", repr(t.strip())[:60])
print("当前高亮项:", sc.highlighted_raw(raw))
