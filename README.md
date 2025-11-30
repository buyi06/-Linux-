<p align="center">
  <img src="https://img.shields.io/badge/Linux-Optimize-brightgreen?style=for-the-badge&logo=linux" />
  <img src="https://img.shields.io/badge/Safe-Stable-blue?style=for-the-badge&logo=shield" />
  <img src="https://img.shields.io/badge/Bash-Script-orange?style=for-the-badge&logo=gnubash" />
  <br>
  🔥 通用一键 Linux 优化脚本 · 安全、通用、持久
  
</p>
> 一键启用，让你的 VPS 带宽真正「跑满」。


安全、跨平台、可持久、无副作用。
# 🧠 Universal Optimize — Linux 通用安全网络优化脚本

**作者**: @buyi06  
**版本**: v1.1
**兼容系统**: Debian / Ubuntu / AlmaLinux / Rocky / CentOS / Arch / openSUSE / Alpine / KVM / 云主机  
**目标**: "一键执行，全程安全、自动持久化、无副作用的网络性能优化脚本"

---

## 🚀 特性概览

| 模块 | 功能 | 是否自动持久 |
|------|------|-------------|
| 🔧 sysctl 优化 | 调整 TCP/UDP 缓冲、backlog、端口范围等 | ✅ |
| 📦 ulimit 提升 | 调高文件句柄数、nproc 限制 | ✅ |
| 🧩 网卡 offload 关闭 | 自动检测并安全关闭 GRO/GSO/TSO/LRO 等（非 systemd 环境也会即时尝试） | ✅ / ⏱️|
| ⚙️ IRQ 优化 | 尝试将网卡中断绑定到 CPU0（虚拟机无 IRQ 会自动跳过；非 systemd 环境即时绑定） | ✅ / ⏱️|
| 🩺 开机自检 | 每次启动自动输出状态日志（offload/IRQ/sysctl） | ✅（systemd）|
| 🪶 安全 | 失败自动忽略、不锁机、不修改防火墙/代理配置 | ✅ |

---

## 🧰 一键使用

需 root 权限，推荐直接执行以下命令：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/buyi06/-Linux-/main/universal_optimize.sh)"
```

---

## 🏗️ 兼容性与运行要求

- **root 权限**：需以 root 或 `sudo` 执行，否则脚本会直接提示退出。
- **systemd 支持**：检测到 systemd 时会自动生成持久化服务（offload / IRQ 绑定 / 启动自检）。在 OpenVZ、alpine 容器等无 systemd 场景下，脚本会跳过服务部署，但仍即时关闭 offload / 绑定 IRQ，保持兼容性。

---

📊 查看状态

bash -c "$(curl -fsSL https://raw.githubusercontent.com/buyi06/-Linux-/main/universal_optimize.sh)" status

**输出示例**:
```
=== 状态报告 (2025-10-06 02:05:17) ===
- 目标网卡：eth0
- sysctl 文件：/etc/sysctl.d/99-universal-net.conf
     1  67108864
     2  67108864
     3  8388608
     4  16434   21912   32868
     5  8192
     6  8192

scatter-gather: off
rx-gro-hw: off
rx-udp-gro-forwarding: off

univ-offload@eth.service: enabled
univ-offload@eth0.service: active
```

---

### 🩹 自动修复缺失项

```bash
curl -fsSL https://raw.githubusercontent.com/buyi06/-Linux-/main/universal_optimize.sh | bash -s -- repair
脚本会检测并修复：
- sysctl 配置文件是否存在
- offload / irqpin systemd 服务是否丢失
- 健康自检是否正常启用

---

## ⚙️ 手动指定网卡（可选）

默认脚本会自动探测出口网卡。  
若你的网卡名称不是 eth0（比如 ens3），可以手动指定：

```bash
IFACE=ens3 bash -c "$(curl -fsSL https://raw.githubusercontent.com/buyi06/-Linux-/main/universal_optimize.sh)" apply
```

---

## 💡 优化细节

### 网络栈参数（sysctl）

| 参数 | 默认值 | 作用 |
|------|--------|------|
| net.core.rmem_default / wmem_default | 4MB | 默认 socket 缓冲 |
| net.core.optmem_max | 8MB | 额外控制缓冲 |
| net.ipv4.udp_mem | 8192 16384 32768 | UDP 内存阈值 |
| net.ipv4.udp_rmem_min / wmem_min | 128KB | 最小 UDP 缓冲 |
| net.core.netdev_max_backlog | 50000 | 内核队列长度 |
| net.core.somaxconn | 16384 | 最大等待连接数 |
| net.ipv4.ip_local_port_range | 10240–65535 | 可用端口范围 |

### 系统资源限制（ulimit）

| 项目 | 值 |
|------|----|
| nofile | 1,048,576 |
| nproc | unlimited |

### Offload 关闭内容
- GRO / GSO / TSO / LRO
- Scatter-gather
- rx-gro-hw / rx-udp-gro-forwarding

所有关闭操作在：
- systemd 模板：`/etc/systemd/system/univ-offload@.service`
- 即时生效（即便 systemd 延迟，也会即时执行一遍）

### IRQ 优化（可选）
- 主 IRQ → CPU0
- MSI IRQ → CPU0
- 无可用 IRQ 时自动忽略，无风险

---

## 🩵 开机自检日志

每次开机 5 秒后执行一次健康检测：

```bash
journalctl -u univ-health -b --no-pager
```

输出包括：
- offload / irqpin 状态
- 当前 sysctl 参数
- ethtool offload 状态

---

## 🧩 目录结构

| 路径 | 用途 |
|------|------|
| /etc/sysctl/99-universal-net.conf | 网络缓冲优化参数 |
| /etc/security/limits.d/99-universal.conf | ulimit 配置 |
| /etc/systemd/system/univ-offload@.service | Offload 自启服务 |
| /etc/systemd/system/univ-irqpin@.service | IRQ 绑定服务 |
| /etc/systemd/system/univ-health.service | 启动健康自检 |
| /etc/default/universal-optimize | 环境变量文件 |

---

## 🧱 卸载（清理优化）

如需完全恢复默认设置：

```bash
systemctl disable --now univ-offload@*.service univ-irqpin@*.service univ-health.service
rm -f /etc/sysctl.d/99-universal-net.conf \
      /etc/security/limits.d/99-universal.conf \
      /etc/systemd/system/univ-*.service \
      /etc/systemd/system.conf.d/99-universal-limits.conf \
      /etc/default/universal-optimize
sysctl --system >/dev/null 2>&1 || true
systemctl daemon-reload
```

---

## 🧠 设计原则

1. **安全第一**: 所有操作 `|| true` 防炸机
2. **跨平台**: 自动识别 Debian / RHEL / Alpine 包管理器
3. **幂等性**: 重复执行无副作用
4. **无需重启**: 立即生效（健康服务除外）
5. **完全开源可审计**

---

## 🧾 License

MIT License © 2025 buyi06
