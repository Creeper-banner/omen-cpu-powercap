# HP Omen 11 CPU 功耗解锁

用于在 Linux 上解锁 HP Omen 11 的 CPU 功耗墙。

> 设备信息：
> - HP Omen 11 16-am0xxx（主板 ID：8D3F）
> - i7-14650HX + RTX 5060 Laptop

## 概述

在 Linux 上，由于缺少 OEM 软件，此机器无法调整性能模式，导致 CPU 功耗被锁死在 45W / 55W，仅调整 PL1 / PL2 设定值无效。

本项目在分析 ACPI 表的基础上，通过定时和 EC 通信以调整性能模式，使 CPU 功耗遵从 PL1 / PL2 设定（仍受到机器 PL1 90W / PL2 130W 硬件限制）。

## 仓库内容

- `modules/hp_raw`：内核模块，负责读写 HP BIOS WMI 原始命令；
- `systemd/omen-cpu-hold.service`：Systemd 持久化服务；
- `scripts`：本项目的各种脚本文件：
  - `hpraw.sh`：安装 / 卸载 `hp_raw` 内核模块；
  - `pl.sh`：修改 PL1 / PL2；
  - `loadtest.sh`：烤机并读取功耗（需 sudo）；
  - `install-hold.sh`：安装 `omen-cpu-hold` 服务；
- 若干调试脚本和中间产物。

## 使用方法

1. 构建并加载 `hp_raw` 内核模块（似乎 Systemd 服务包含此内容）：`sudo bash scripts/hpraw.sh build` +  `sudo bash scripts/hpraw.sh load 1`
2. 安装服务：`sudo scripts/install-hold.sh 1 10 [PL1] [PL2]`
  - 参数说明：
    - `1` -> EC 性能模式，保持 1；
    - `10` -> 检查 EC 状态的间隔（每次调整功耗之后会在一段时间后被 EC 自动重置，需要循环调整）；
    - `[PL1]` `[PL2]` -> 希望保持在的 PL1 / PL2，默认 90 / 100。
3. 启动服务：`systemctl enable omen-cpu-hold`

烤机脚本基本使用方法：`sudo scripts/loadtest.sh [烤机时间]`。

> 更新系统内核后可能需要重新构建并加载 `hp_raw` 内核模块。若出现问题请尝试重新运行 `hpraw.sh` 并运行 `systemctl restart omen-cpu-hold`。

## 其他

仅在自己的电脑测试过，可能可以用于同型号其他机器或者同系列其他机型，但手上没有其他设备因此无法测试。

本项目含 AI 生成内容，由 Qwen 3.8 Flash 和 DeepSeek v4.1 Flash 1017 辅助开发。

*100% vibe-coded!*
