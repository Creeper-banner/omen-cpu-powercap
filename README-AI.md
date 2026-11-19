# CPU 功耗墙解锁 — HP OMEN Gaming Laptop 16-am0xxx (board 8D3F)

> 📄 **换对话/接手请先读 [`HANDOFF.md`](HANDOFF.md)**（当前结论、已踩的坑、下一步命令、待核实项）。本文件是完整调查记录。

i7-14650HX (PBP 55W / MTP 157W) + RTX 5060 Laptop，Fedora 45 / kernel 7.3.4。
> `/mnt/sub` 是 `noexec` 挂载，脚本一律 `bash scripts/xxx.sh`。

## 已确认事实

| 项 | 值 | 结论 |
|---|---|---|
| `MSR 0x610` 出厂 | `0x004284e800df81b8` = PL1 55W(en) / PL2 157W(en) / TAU `0xdf` | **LOCK(bit63)=0**，两条写路径都通 |
| **bit16 / bit47（clamp & PL2-enable）** | 出厂=1，被 powercap 写路径抹成 **0** | 抹零后 PL1 沦为参考值：55W 与 90W 实测功耗/性能完全一致 |
| power unit (`0x606=0xa0e03`) | 2^-3 W/LSB、2^-14 J、2^-10 s | 解码已用 55/157W 对齐验证 |
| `constraint_0_max_power_uw` | 55W（TPMI 元数据，来自 `processor_thermal_rapl`） | **实测不强制**：写 90W 成功进 MSR |
| `MSR 0x614` | `0x1b8`（垃圾值） | 55W 天花板不来自这里 |
| `platform_profile` | `performance` | 这台板子 `8D3F` 不在 hp-wmi OMEN 白名单 → 走 legacy `0x4C`，只管风扇 |
| WMI `0x1A` + `0x31` | EC 接受（`thermal profile 0x31 set`），**PL1/PL2 一字未变** | profile 字节不管 CPU 功耗表（**原因已由 AML 确认**：`GM1A` → `EC0.HPCM=data[1]` → `DTPC()` 只写 GPU 侧 `NPCF.*`） |
| tuned `throughput-performance` | 无 RAPL 能力 | 不碰功耗墙 |

## ⚠️ 事故记录（已修复）

`pl.sh set` 里我用 `wrmsr 0x610 <16位十六进制无前缀>`，`wrmsr` 按 C 语言 `strtoull(...,0)` 解析：
**前导 `0` → 八进制**，`"004284e800df82d0"` 在 `8` 处截断 → 八进制 `0042` = 十进制 34 → **PL1 被写成 4.25W**，PL2/TAU 清零。
现在 `pl.sh` 改为：① 优先走 powercap（内核自己编码 TAU，最安全）；② 只在必要时退回 MSR，且**永远带 `0x` 前缀**；③ 写完回读校验。
误写的值全程稳定 → 顺带证明 **EC/SMM 没有周期性改写 MSR**。

第二个坑：`pl.sh` 第 48 行 `pc_write` 里写了 `case "$3"`，但调用方写瓦数时只传 2 个参数，`set -u` 直接
`$3: 未绑定变量` 挂掉。修 `$3` 时又发现真正让文件“炸”的是 `${TAU:+ TAU=${TAU}s"` 少了一个 `}` —— 展开吞掉了后面的引号，
整个 `set`/`fix` 分支语法都不对。而它一直没被发现，是因为 `bash -n scripts/*.sh` **只检第一个文件**（bash 把后面的参数当位置参数）。
现在有了 `selftest.sh` + `lint.py`，两类问题都能主动抦住（注入回去试过：能抦到，复现出 `PL1=4.25W` 的同款损坏）。

## 🔑 谜底 v1：clamp 位（这个解释**已被 v2 推翻**，留着是因为方法论有价值）

> 见下面「第 3 轮」：把 clamp/enable 位全部补回出厂值之后，PL1 从 55W 改到 120W
> 仍然一点反应都没有。所以「位被抹掉」只是**一个真实存在的内核 bug**，不是本机的墙。

对比开机原值和 `fix` 之后的 0x610：

| | `0x004284e800df81b8`（BIOS） | `0x000204e800de82d0`（powercap 写入后） |
|---|---|---|
| PL1 数值 / enable(bit15) | 55W / 1 | 55W / 1 |
| **PL1 clamp(bit16)** | **1** | **0** ← 差在这里 |
| PL2 enable(bit47) | 1 | **0** |
| PL2 window | 2440µs | 1952µs（内核重编码有损失） |

bit16 = "PL1 **clamp** enable"。它是 0 时，硬件把这个限制值当**参考值**而不是**硬顶**——
所以 45s 全核负载在 PL1=55W 下跑了 79W，在 PL1=90W 下跑 78W，bogo-ops/s 21847 vs 21927（差 0.4%，纯噪声）。
**限制值根本没接上电，改它当然没反应。** 也干净利落地解释了之前那个悖论：
PL1=4.25W 时封装照样 61W——那次误写连同 bit16 一起清了。

内核 powercap 写路径为什么会丢这两个位：这台机器的 RAPL 走 **TPMI 元数据**（`processor_thermal_rapl`），
driver 按元数据里的 "no clamp" 标志重建整个 0x610，于是把 BIOS 自己置上的位抹掉了。
（顺带：`loadtest` 之前报 `末段稳态 0W` 是我的锅——每个采样周期实际耗时 ~1.4s，45s 只采到 33 个样，没达到计数阈值。已改成取末 10 个采样。）

## 实测结果（第 2 轮：`bios` 恢复原值 + clamp=1）

| | clamp=0 PL1=55W | clamp=0 PL1=90W | **clamp=1 出厂值** |
|---|---|---|---|
| 全核最高频 | 2.70GHz | 2.70GHz | **2.90GHz** |
| 平均 / 稳态功率 | 79W | 78W | **79W / 73W** |
| 峰值 | 96W | 97W | 102W |
| 最高温 | 64C | 67C | **69C** |
| bogo-ops/s | 21847 | 21927 | **23110 (+5.8%)** |

两个结论：
1. **补回 enable/clamp 位确实有效**（+0.2GHz / +5.8%），所以这些位不是装饰。
2. 稳态看起来仍 ≫ PL1 ——**但这条已作废，见下面的测量修正。**

## ⚠️ 测量修正：之前的瓦数全部虚高 ~36%

`loadtest` 的采样循环是 `sleep 1` + 一堆采集动作（sensors、cat 24 个 cpufreq 文件、3 次 rdmsr），
每轮实际耗时 **≈1.35s**（你的日志：33 个采样 ÷ 45s），而算瓦数时用的是
`Δenergy_uj / 1e6`（当 1 秒处理）→ **所有读数系统性偏高 1.36 倍**。换算：

| 报告值 | 修正后 |
|---|---|
| 平均 79W | **≈ 58W** |
| 稳态 73W | **≈ 54W** |
| 峰值 102W | ≈ 75W |
| 4.25W 事故那次“61W” | **≈ 45W**（正好对应用户最初观察到的 45W） |

→ **PL1=55W 很可能一直是生效的**（稳态 54W ≈ PL1），“PL1 不是墙”的判读建立在错的读数上。
现在 `loadtest` 改成用两次采样的**真实时间差做分母**（`W = Δe[uJ]×1000/Δt[ns]`），
并在结果里打印“平均间隔 Xs”自证；注入精确 79W 的假能量计数器验证，实测报 78W（误差 1.3%）。

## 第 3 轮（决定性）：PL1/RAPL **不是**这堵墙

全部用修正后的读数、`--clamp` 写入、同条件 `stress-ng --cpu 24` 对比：

| 配置（都是 clamp=1、enable=1、PL2=157W、TAU=56s） | 平均 | 末段稳态 | 峰值 | 温度 | bogo-ops/s | `0x64F` |
|---|---|---|---|---|---|---|
| PL1=55W（出厂） | 52W | 41W | 58W | 68C | 21095 | none |
| PL1=90W | 49W | 42W | 58W | 67C | 19746 | none |
| PL1=120W（60s） | 54W | 49W | — | 67C | 21999 | none |
| PL1=120W（180s） | 47W | 42W | — | 67C | 19213 | none |

三个硬事实：
1. **PL1 从 55W 改到 120W，稳态功率纹丝不动（41~42W），bogo 还在噪声范围内。**
2. **`0x64F` 全程 `限幅: none`** —— Punit 自己都不认为在做 RAPL 限功率。
3. **`pl.sh watch 60` 期间 `0x610` 保持 `0x004284e800df83c0` 不变** —— 不是被谁写回去的，
   是我们的写入确实落进了寄存器，只是没有产生任何效果。
4. 温度只有 67~68°C（离 100°C 还远）→ **也不是热墙**。

形状是这样的：**开头 ~35s 约 56W，之后掉到 ~45W 平台**（不同次分别是 35s/67s 掉，不是固定时间常数）。
「先给一档高的、过一会儿落到一个更低的平台」= 典型的 **EC 侧两级预算/TDC 行为**，不是 RAPL 的两级（RAPL 两级是 157W→55W，而且必须报 RAPL 限幅）。

## 🧩 AML 逆向：限功率住在 EC/SMM 里，OS 够不着

把 `8d3f-diag/8d3f-acpi.dat` 解出 DSDT + 12 个 SSDT（`iasl -d`），逐条查功耗相关的路径：

| AML 位置 | 内容 | 结论 |
|---|---|---|
| DSDT `OperationRegion (CPWR, \GMHB()+0x5000)`，偏移 `0x9A0`：`PPL1(15b) PL1E(1b) CLP1(1b)` | **PMC 的 MMIO 视图**，和 `MSR 0x610` 是同一组寄存器；还有 `PPO0-5/DPL1-4/PP1T/PP2T/RA1C/PL4O` | 平台层（Psys/共享预算/DPL）字段在这里；写 MMIO == 写 MSR，**已被第 3 轮证伪** |
| `Method (SPL1/RPL1)`：`PPL1 = PLVL × (PWRU<<2) / 1000`，并**强制 `PL1E=1 CLP1=1`**；RPL1 还原 | 固件有一条「按 GNVS.PLVL 改 CPU PL」的 AML 路径 | 只有 `\_SB.GUAM(One/Zero)`（s2idle 进出，GPE 0x0E/0x05）会调 → **正常负载下不跑**；`PLVL/PLCS` 在 AML 里**从无赋值** → 值由 SMM/BIOS 写 |
| `GNVS.PLCS`(0x2F4) / `GNVS.PLVL`(0x2F5,16b) | 固件自己保存的 PL 状态/值 | 可经 `/dev/mem` 读（`GNVS @ 0x6C447000`）；如果里面是 45000，就是「EC 要回到 45W」的铁证 |
| EC RAM `0x29 NPL1` / `0x2A NPL2` / `0xEA PL12` / `0x34 SRP1` | **EC 里的“新 PL1/PL2”字节** | 在 AML 里**没有任何引用** —— 只有 EC 固件/SMM 能碰，OS 侧看不到（`ec_sys` 内核模块本机没编译，读不了 EC RAM） |
| `WMAA → HWMC`（HP BIOS WMI GUID `5FB7F034-...`）：`COMD=1` 读 / `COMD=2` 写 / `COMD=0x20008` 是 `GMxx` 系列 | HP 所有私有命令的统一入口，命令号→处理函数全在 AML 里 | 已写 `modules/hp_raw` 直接发原始命令 |
| `GM1A`（写 OMEN 性能档）：`EC0.HPCM = data[1]` → `Sleep(20)` → `DTPC()` | 我们之前 `0x31` 确实写进去了（模块发的是 `{0xFF, profile}`，字节序没错） | **`DTPC()` 只写 GPU 侧字段**（`NPCF.ACBT/AMAT/AMIT/OPAT` + `CMSW(0xDE, profile)`），**完全不碰 CPU PL** → 解释了「换性能档 PL 不变」 |
| `GM28`（GET_SYSTEM_DESIGN_DATA）：按 **`EC0.ADPH`（适配器瓦数档，EC `0xA3` 的 4 bit）** 返回瓦数表 40/65/90/120/140/150/180/200/**230**；另有 `byte2=0x35(53)`、`byte5=PL4V`、`byte7 = (SYID==0x103C**8D3F**) ? 0x0D : 0x07`、**`byte8=0x2D`(=45)**、`byte9=0x13` | EC 知道电源是多少瓦并按板子 ID 分支；`0x2D`=45 和观测到的 45W 平台数字对得上 | **待实测**：`hpraw.sh design` 一条命令就能读出来 |
| `0x4C`/`0x2B`/`0x5A` 的读处理是空壳，`GTCS/STCS/GPSS/GBCT/STPS/...` 多是返回常量的桩 | 这板的 BIOS 里“CPU power limit package”那条老路（`hp-wmi` 的 `HPWMI_PERFORMANCE_STATE`）根本没实现 | 别再往这些命令上浪费时间 |

**所以现在的判断**：CPU 的 sustained 预算由 **EC 固件**（适配器档位 `ADPH` + 板子 ID `SYID` + 热状态）算出来，
通过 SMM/PMC 灌进 Punit；`MSR 0x610` 被覆盖或旁路，RAPL 的 enable/clamp 位形同虚设。
OS 侧能动的杠杆只有两个入口：① HP WMI 命令（`hp_raw`）；② EC RAM（无公开通路）。

```bash
cd /mnt/sub/projects/cpu-powercap

# 0) 编 + 加载原始 WMI 探针（只读为主；写要额外传 1）
sudo bash scripts/hpraw.sh build
sudo bash scripts/hpraw.sh load

# 1) ★ 先问 EC：你眼里的电源是多少瓦？（GM28）
sudo bash scripts/hpraw.sh design
#    如果报 150/180/120 而不是 230 → 45W 平台就是适配器预算

# 2) 扫一遍只读命令，找 CPU 功耗相关的返回包
sudo bash scripts/hpraw.sh sweep          # 保守表
sudo bash scripts/hpraw.sh sweep all      # 0x01-0x60 全试（个别读命令有副作用，见 README 风险）

# 3) ★ 读固件的 PL 影子变量（GNVS.PLVL / PLCS，AML 里从不赋值 → 只可能是 SMM 写的）
sudo bash scripts/hpraw.sh gnvs          # PLVL 若是 ~45000 → 45W 平台的来源就在眼前
sudo bash scripts/hpraw.sh peek 0x2F0 48 # 任意 GNVS 窗口
sudo bash scripts/probe.sh | sed -n '/其它 MSR/,/GPU/p'   # 0x64F 限幅原因 + 0x613 累计限幅时间

# 4) 复核第 3 轮的结论（应当仍是：改 PL1 无反应）
sudo bash scripts/pl.sh set 120 157 --clamp && sudo bash scripts/loadtest.sh 120
sudo bash scripts/pl.sh bios
```

判读：
- `design` 报的瓦数 < 230 → **适配器识别问题**（电源 ID 针/线材/接口），先解决这个。
- `design` 报 230 → 预算是 EC 自己按 `SYID`/热档算的，得在 `sweep` 结果里找带 45/56 这类数字的命令，或做 OMEN Hub 抓包对拍。
- `--cpu 8` 频率能上 4GHz+ → 是「功率预算分给全核就不够」；仍卡 2.9GHz → 是硬频率/电流上限。
- **`loadtest` 稳态出现 `RAPL`** → 说明 RAPL 至少在某些时刻是活的，那再回到调 PL 的路子。

## ★ 主线索：`\_SB.NPCF._DSM` func#9 —— HP 自己的「CPU 功率预算」写入口

`ssdt11.dsl:1453 Scope (\_SB)` 里有个 `Device (NPCF)`（`_HID = NVDA0820`，即 NVIDIA 的
**NVPCF** ACPI 接口），它暴露一个 `_DSM`，UUID `36b49710-2483-11e7-9598-0800200c9a66`，
要求 `Arg1 (revision) == 0x0200`，然后按 `Arg2` 分发：

| func | 行为 | 副作用 |
|---|---|---|
| 0 | 返回支持位图 `07 03 00 00` → 声明 0,1,2,8,9 | 无（先跑这个确认通路） |
| 1 | 返回 14 字节能力表 | 无 |
| 2 | 读 `EC0.HPCM`/`OPAT` 算 `ATPP/ACBT/AMAT/AMIT`（GPU 共享预算）并返回 0x31 字节表 | 只改 NPCF 内部变量 |
| 8 | 读 `EC0.BVLB/BVHB`（≥0x36B0 与否）返回不同 TGP 表 | 只读 EC |
| **9** | ★ `CreateDWordField(Arg3, 0x03, CPTD)` → **`EC0.NPL1 = CPTD/1000`**、**`EC0.NPL2 = NPL1×125/100`**，然后 **`SSMP = 0x77`（SystemIO `0xB2` → SMI）** 让 EC 立即应用 | **写 EC + 打 SMI** |
| 5 | `INC5 = Arg3[4]&7`；= 3 → `CUSL`，= 4 → `CUCT`；其余只壮 PBD5 输出缓冲 | 改 NPCF 状态 |
| 10 | 返回 8 字节 DTT 表（`DTTL = TPPL`） | 无 |

这就是 HP/EC 眼里 CPU 功率预算的**正规入口**：单位是 **mW**，EC 里落成 8 位的瓦数字节
（`EC0.ERAM` 的 `NPL1@0x29` / `NPL2@0x2A`）。对比：`GM29` 写的是 `ECL1/ECL2/ECL4`（0x37/0x38/0x39），
`GM2A` 读的是 `EL1R/EL2R/EL4R`（0x3A/0x3B/0x3C）—— **两组字段完全不同**，所以两条路都要试。

模块里已经实现：`dsm`（原始 func 调用，返回体 hexdump）、`dsmscan`（只扫只读 func）、
`npl <瓦数>`（自动拼 `CPTD` 小端 + 32 字节 Arg3，然后 func#9）。

```bash
sudo bash scripts/hpraw.sh dsm 0                     # ① 支持位图（应该看到 07 03 00 00）
sudo bash scripts/hpraw.sh dsmscan                   # ② 只读 func 全部 hexdump（并存档）
sudo bash scripts/hpraw.sh ecl                       # ③ EC 里的 EL1R/EL2R/EL4R
sudo bash scripts/hpraw.sh ecram 0x29 4              # ④ EC 里的 NPL1/NPL2 当前值（只读）
sudo bash scripts/hpraw.sh ecram 0x29 20             #    顺便把 0x29-0x3C 全段存档

echo 1 | sudo tee /sys/module/hp_raw/parameters/allow_write
YES=1 sudo bash scripts/hpraw.sh npl 100             # ⑤ func#9：NPL1=100W NPL2=125W + SMI
sudo bash scripts/loadtest.sh 120                    # ⑥ 看稳态瓦数跟不跟
```

判读：
- `npl` 后 `ecram` 的 `NPL1/NPL2` 变了 → 写入通了；`loadtest` 稳态跟到 ~100W → **解锁成功**。
- `NPL1` 变了但瓦数不动 → 墙在 EC 的其它变量（`TNT3/DTMT/ETMT/PL12`）或 `NPCF.ATPP`
  （NVIDIA 侧共享预算，func#8 的表）——下一步去 read/dump `ecram` 全 0x00-0xFF 找哪个字节跟预算相关。
- `NPL1` 没变 → AML 跑挂了（看 `dmesg | tail` 和 `last_error`），或 `NPCF._STA` 返回 disable。

风险：func#9 会打 **SMI(0xB2)**（跟 HP 自己的工具与 NVIDIA 驱动走同一条路，但仍是固件行为）。
写前先 `ecram 0x29 4` 记下原值，出问题就 `YES=1 npl <原值>` 写回去。

## ★ 第 6 轮实测（谜底）：不是「预算衰减」，是 EC 自己把性能档撤销了

上一轮的 `ecwatch.sh`（负载中逐字节对比整片 EC RAM）一跑，答案直接摆出来了：
**90W→45W 的那一刻，EC 里的 `HPCM` 从 1 变成了 0**，`EL*R` 也跟着重算回 profile 0。

### 证据 1：`GM1A` 是 profile 开关（沿上一轮）

`sudo bash scripts/hpraw.sh gmw 0x1a 00 <v>`（= `EC0.HPCM = v` → `DTPC()` → `CMSW(0xDE)`）：

| `HPCM` = | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| `EL1R`（PL1） | 55 | **90** | 45 | 45 | **90** | 45 |
| `EL2R`（PL2） | 130 | **130** | 56 | 56 | **130** | 56 |
| `EL4R`（PL4） | 200 | **200** | 90 | 90 | **200** | 90 |

### 证据 2：`ecwatch` 的逐字节 diff —— 45W 就是 profile 0

时间轴（`sudo bash scripts/ecwatch.sh 240 15`，全程只读）：

```
  #1 17s 130W   #2 32s 130W   #3 48s 105W   #4-6 63~94s 90W
  #7 109s 54W   #8-15 124~233s 45W(锁死)
```

`#7` 这一格同时发生的变化：

| EC 偏移 | 字段 | #0–#6 | #7 起 |
|---|---|---|---|
| `0x63` | （EC 私有，AML 里没有） | 95→80→65→49→34→19→3（**每秒 -1**） | 0 |
| `0x62` | `OMCC`（bit0）+ 私有位 | 6 | 0 |
| `0x95` | **`HPCM`** | 1 | **0** |
| `0x3a/0x3b/0x3c` | `EL1R/EL2R/EL4R` | 90/130/200 | **45/56/90** |
| `0xba` | `CLOW` | 0 | 2 |
| `0xc1` | `DPPC` | 0 | 2 |

- `0x63` 是个**每秒 -1 的倒计时**，恰好在它归零的那一格，`HPCM` 被清 0、`EL*R` 回落。
  它**不在** AML 的 `ERAM` 字段表里（`0x62`=OMCC 之后下一个字段是 `0x67 LDBG`）
  ⇒ 这是 EC 固件私有的「性能档有效期」定时器，约 **95 秒**。
- 所以根本没有「隐藏的功率预算变量」：**45W 就是 profile 0 的 PL1**，是 EC 把档位撤销了。
- 注意一个细节：EC 自己撤销后落在 **45/56/90**（= 扫描里 `HPCM=2/3/5` 那组），
  而**手动**写 `HPCM=0` 得到的是 55/130/200 ⇒ EC 区分「用户选 0 档」和「自己降档」，
  降档状态还伴随 `CLOW=2`/`DPPC=2`（EC 的 derate 等级），重申 profile 会把它们清回 0。
- 也顺带解释上一轮「冷却 4 分钟后只回到 56W」：那是 `EL2R=56` 的短时档，不是没恢复。

### 证据 3：重新点火有效，性能 +45%

| 场景 | 波形 | bogo-ops/s |
|---|---|---|
| profile 0（被撤销后） | 56W → 45W，63–67°C | 20669 |
| `gmw 0x1a 00 02` → `00 01` 后立刻 | **130W**(~30s) → **90W**(持续)，84°C | **30012** |

130W 阶段会冲到 97°C（散热上限 ≈130W），90W 稳态只有 84°C ⇒ 中间还有余量可以试。

### 结论 & 持久化方式：定期重申 profile（新命令 `hold`）

```bash
sudo bash scripts/hpraw.sh hold 1 300 30
# 每 30s 读一次 EC 0x95(HPCM)，只要它漂了（被 EC 清 0）就用 GM1A 重申 profile=1
# 只在漂移时写，正常运行时零写入
```

⚠ `CMSW(0xDE)` 是**整机 profile 切换**（风扇/GPU TGP 一起变）。GPU 档位异常就
`echo 1 | sudo tee /sys/kernel/omen_wmi_boost/performance` 复位。

### 第 7 轮实测：`hold` 有效（+40%），但细节要调

| 实验 | 结果 |
|---|---|
| 写完 `gmw` 后**什么都不干**等 150s | `ecl` 已回 `45/56/90` ⇒ 倒计时是**墙钟**，不依赖负载 |
| `hold 1 400 30` + `loadtest 300` | 平均 **93W**（此前 50W），28965 bogo-ops/s（此前 20669，**+40%**） |
| 同上，看 `/tmp/hold.log` | 每 ~95s 抓到一次 `HPCM=0` 并重申；但 **30s 间隔**造成每次有 **10–20s 掉到 45W** 的空档 |
| 90W 稳态温度 | **87–90°C**（跑久后比早先的 84°C 高，仍远低于 `ACRT=105`） |
| `ecwr 0x3a 0x73`（EL1R=115） | 写入成功（`0x3a=0x73`），但 **不可持久**：EC 一重算就打回 90 ⇒ 只能由 `hold` 每次补写 |
| 115W 那次的 130W 阶段 | 97–98°C，首次出现新限幅原因 **`VDDt`**（8 次）⇒ 130W 已经贴边 |

⇒ 结论：**profile 1（90W）是稳妥终点；想再高就 `hold ... 105` 试，别超 95°C。**
`hold` 现在支持第 4 个参数（EL1R 瓦数）和更短的检查间隔：

```bash
sudo bash scripts/hpraw.sh hold 1 0 10        # 常驻：90W（EC 默认表）
sudo bash scripts/hpraw.sh hold 1 0 10 105    # 常驻：每次重申后把 EL1R 补到 105W
```

### 第 8 轮实测：定稿（90W 就是上限）

| 实验 | 结果 |
|---|---|
| `hold 1 260 10` + `loadtest 240` | 130W(~43s) → **90W 全程守住**；平均 **93W**、**28902 bogo-ops/s**；温度 85–90°C（峰值 96°C 只在 130W 段） |
| 同上，`/tmp/hold3.log` | 每 **~120s** 抓到一次 `HPCM=0`，重申后 **4–8s** 就回到 90W（30s 间隔时是 10–20s） |
| `hold 1 260 10 105`（EL1R 补写到 105） | `ec_write 0x3a=0x69` 成功，但功率**纹丝不动**：仍是 89–90W（温度反而更低 80–85°C） |

⇒ **`EL1R` 不是 P-unit 的闸门**：写大它不会放开功率（EC/SMM 按内部表 `ECL*`/`PNVS.PL1x` 下发，
和 Windows 上 XTU 也调不动完全一致）。**90W（profile 1）就是这台机器的上限。**

最终方案：

```bash
sudo bash scripts/hpraw.sh gmw 0x1a 00 01     # 一次：切性能档 90/130/200
sudo bash scripts/hpraw.sh hold 1 0 10        # 常驻：每 10s 检查，漂了重申
```

效果：稳态 **45W → 90W**，性能 **20669 → ~28900 bogo-ops/s（+40%）**，温度 85–90°C。

### 开机自动生效

```bash
sudo bash scripts/install-hold.sh           # profile=1，10s 一查（推荐）
sudo bash scripts/install-hold.sh 1 5       # 5s 一查，空档更短
sudo bash scripts/install-hold.sh --uninstall
```

`systemd/omen-cpu-hold.service` 会自己 `insmod … allow_write=1`，`RequiresMountsFor=` 等 `/mnt/sub`
挂好，`Restart=always` 崩了自愈。**睡眠唤醒不用 hook**：`hold` 的 10s 轮询发现 `HPCM` 被清了就补。

### 第 9 轮：装机 + 实战验收（收工）

服务已在真终端装好（顺带处理了一次 SELinux 拦截）。实测：

| 场景 | 结果 |
|---|---|
| 《欧洲卡车模拟2》（AC） | GPU 顶满（`nvidia-smi` Current=Max=**115W**，`SW Power Cap: Not Active`）+ CPU **50W+**（偶有回落） |
| 同游戏 · Windows 对照 | GPU 100W（手动降压后已吃满）+ CPU 55W ⇒ **两边水平相当** |
| 电池 + `loadtest` | CPU **25W**，GPU 功耗墙降到 **50W** ⇒ 节能正常，EC 自己接管 |

结论：**AC 下 90W 档 + `hold` 常驻 = 可用终态；电池下让 EC 自己管，别跑 `hold`。**

⚠ 唯一遗留：`hold` 是无条件重申，**电池上跑会每 10s 跟 EC 的节能策略打架**。
要「仅 AC 生效」就在服务里加电源判断（`on_ac_power` 或 `/sys/class/power_supply/AC*/online`），
现在没做 —— 需要就说。

### 第 10 轮：两个闸门是 AND 关系（RAPL 削峰 / EC 定上限）

重启后掉到 55W 的谜：**MSR `0x610` 是易失的，开机回出厂 `PL1=55W`**，而 EC 的 `EL1R` 一直是 90
（`ecl` 实测 `EL1R=90` + `PL1=55W` + 稳态 55W）⇒ **生效值 = min(EC, RAPL)**。

| PL1 设定 | 稳态实测 | 谁在绑 |
|---|---|---|
| 55（出厂/重启后） | **55W** | RAPL |
| 70 | **70W** | RAPL |
| 80（PL2=100） | **80W**（前 ~35s 顶 100W） | RAPL |
| 90 | **90W** | 相等 |
| 95 | **89–90W** | **EC**（90 = 硬顶） |
| 120 | **89–90W** | **EC** |

- **向上**：PL1 写 95/120 都停在 90 ⇒ 90 是 EC 上限（与 `EL1R=105` 无效、Windows XTU 调不动一致）。
- **向下 / 削峰**：MSR 是精确旋钮。`PL1=90 PL2=100` 与 `PL2=157` 稳态一样 90W，
  但把 `EL2R` 的 **130W 尖峰从 93–97°C + `VDDt` 压到 ~89°C 干净** ⇒ **推荐配置**。
- `限幅: none` 不代表没撞墙：`0x64F` 只报 package 侧降频，EC/RAPL 的稳态钳制它不报。

持久化：unit 的 `ExecStartPre` 现在会跑 `pl.sh set @PL1@ @PL2@ --clamp`
（`--clamp` 必须带 —— powercap 写路径会丢强制执行位，丢了等于没设）。

```bash
sudo bash scripts/install-hold.sh              # PL1=90 PL2=100（推荐）
sudo bash scripts/install-hold.sh 1 10 90 157  # 放开 130W 尖峰：更热、跑分略高
```

## 工具

### 第 10 轮：两个闸门是 AND 关系（RAPL 削峰 / EC 定上限）

重启后掉到 55W 的谜：**MSR `0x610` 是易失的，开机回出厂 `PL1=55W`**，而 EC 的 `EL1R` 一直是 90
（`ecl` 实测 `EL1R=90` + `PL1=55W` + 稳态 55W）⇒ **生效值 = min(EC, RAPL)**。

| PL1 设定 | 稳态实测 | 谁在绑 |
|---|---|---|
| 55（出厂/重启后） | **55W** | RAPL |
| 70 | **70W** | RAPL |
| 80（PL2=100） | **80W**（前 ~35s 顶 100W） | RAPL |
| 90 | **90W** | 相等 |
| 95 | **89–90W** | **EC**（90 = 硬顶） |
| 120 | **89–90W** | **EC** |

- **向上**：PL1 写 95/120 都停在 90 ⇒ 90 是 EC 上限（与 `EL1R=105` 无效、Windows XTU 调不动一致）。
- **向下 / 削峰**：MSR 是精确旋钮。`PL1=90 PL2=100` 与 `PL2=157` 稳态一样 90W，
  但把 `EL2R` 的 **130W 尖峰从 93–97°C + `VDDt` 压到 ~89°C 干净** ⇒ **推荐配置**。
- `限幅: none` 不代表没撞墙：`0x64F` 只报 package 侧降频，EC/RAPL 的稳态钳制它不报。

持久化：unit 的 `ExecStartPre` 现在会跑 `pl.sh set @PL1@ @PL2@ --clamp`
（`--clamp` 必须带 —— powercap 写路径会丢强制执行位，丢了等于没设）。

```bash
sudo bash scripts/install-hold.sh              # PL1=90 PL2=100（推荐）
sudo bash scripts/install-hold.sh 1 10 90 157  # 放开 130W 尖峰：更热、跑分略高
```

## 工具

| 脚本 | 作用 |
|---|---|
| `scripts/selftest.sh` | **回归自测**（假 MSR + 假 powercap，非 root、不碰真机）。改脚本后先跑这个 |
| `scripts/mock/msrtool.py` | 假 rdmsr/wrmsr，忠实复刻 `strtoull(base 0)` 的八进制解析坑 |
| `scripts/mock/lint.py` | 查未闭合的 `${VAR:+...}`（这个坑会让整行引号失衡，且 `bash -n a.sh b.sh` **只检查 a.sh**，容易假绿） |
| `scripts/probe.sh` | 只读体检（powercap/tuned/cpufreq/GPU/温度 + root 下解码 MSR 0x606/0x610/0x614/0x613） |
| `scripts/pl.sh` | `get` / `set PL1 [PL2] [TAU秒] [--clamp]` / `clamp on\|off\|show` / `bios` 恢复开机原值 / `raw 0xHEX` / `fix` / `watch` / `restore` / `nowallimit`；**powercap 优先 + MSR 读改写（不碎 TAU/enable/clamp）+ 写完回读校验** |
| `scripts/loadtest.sh` | stress-ng 负载 + 每秒瓦数/温度/频率/**限幅原因(0x64F)**；`--cpu N` 指定线程数，`--turbostat` 并行记录 |
| `scripts/ecwatch.sh` | ★ **负载中逐字节对比整片 EC RAM**（256B × N 次快照 + 每段真实瓦数 + 6 个 MSR），只打印「变过的字节」——第 6 轮就是靠它抓到 `0x95 HPCM` 被 EC 清 0 |
| `scripts/unlock.sh` | 试 WMI `0x1A` 各 profile 字节、`--ec-flags` 试 EC `0x62/0x63`、`--raw` 手写 |
| `scripts/hpraw.sh` + `modules/hp_raw/` | ★ **通用 HP WMI 原始命令探针 + NPCF._DSM 入口**（内核模块，已在本机编译通过）：`design`=GM28 适配器瓦数解码、`ecl`=GM2A 读 EC 的 EL1R/EL2R/EL4R、`setecl`=GM29 写 ECL1/ECL2/ECL4、**`dsm <func>`=直接调 `\_SB.NPCF._DSM`**、**`npl <瓦数>`=func#9 写 EC NPL1/NPL2 并打 SMI 0x77**、**`ecram`=走 `ec_read()` 直读 EC RAM**、`gnvs`=读固件影子变量 PLCS/PLVL/SYID、`peek`=GNVS 任意偏移、**`phys`/`pnvs`=直读任意物理内存 + 解码 ssdt9 的 `\_SB.PNVS` 功率预算表**、**`emon`=轮询 EC 字段看漂移**、**`gmw <cmd> <hex..>`=COMD=0x20008 带数据的写（GM1A 改 profile 用）**、`rd/gm/sweep`=COMD/CMDT 扫描、`wr`/`ecwr`（默认锁死） |
| `acpi/` | 反编译出来的 `dsdt.dsl` + 12 个 SSDT + `HWMC.dsl`（WMI 分发器）+ `gnvs_offsets.json`（GNVS 字段偏移，逐位算出） |
| `scripts/watchdog.sh` + `systemd/` + `scripts/install.sh` | 确认有效后的持久化（AC 90/157W，拔电回落 55/85W，15s 漂移重申） |

改脚本后的自检约定（都要绿）：
```bash
for f in scripts/*.sh; do bash -n "$f" || echo "FAIL $f"; done   # 必须逐文件
python3 scripts/mock/lint.py scripts                               # 引号/花括号失衡
bash scripts/selftest.sh                                           # 行为回归（60 项）
SELFTEST_BUILD=1 bash scripts/selftest.sh                          # 顺带编译 hp_raw.ko
```

重跑 ACPI 逆向（拿到当前 BIOS 的表）：
```bash
sudo acpidump -b -o /tmp/acpi.dat && mkdir -p /tmp/acpi && cd /tmp/acpi
acpixtract -a /tmp/acpi.dat && iasl -d ./*.dat
grep -n "GM28\|GM1A\|SPL1\|PLVL\|ADPH\|NPL1" dsdt.dsl
```

## 风险

放宽 PL 后散热余量变小；`nowallimit on` 只剩温度墙，最后手段。
每次只改一档，改完就跑 `loadtest.sh` 看温度峰值。

`hp_raw` / WMI 相关（新）：
- **`wr`（COMD=0x02）会真的写 EC**。HP 的 EC 刷坏 = 不开机，没有软恢复。`allow_write` 默认 0，只是防手滑。
- 部分**读**命令也有副作用：例如 `GM10` 会 `EC0.OMCC = One`（相当于给 EC 下个风扇相关触发）。所以 `sweep` 默认只跑安妥的子集，`sweep all` 风险自担。
- `0x5A`/`0x2B`（POSTROM 类）不碰。
- `gnvs`/`peek` 是只读 `memremap()`，不写回；机型 ID 现在从 `EXBU+0x802` 读 `SYID`（应为 `0x103C8D3F`），对不上说明基址变了，别拿数据当结论。
- `ecram` 走内核的 `ec_read()`（`drivers/acpi/ec.c` 导出），只读安全；`ecwr` 直写 EC RAM 需要 `allow_write=1`，**EC 刷坏 = 不开机**。
- `dsm` 的 func#9 会写 `EC0.NPL1/NPL2` 并往 `0xB2` 打 **SMI**（`SSMP=0x77`）——固件行为，风险中等；默认被 `allow_write` 拦着。写之前先把 `ecram 0x29 4` 的结果记下来，方便回退。
