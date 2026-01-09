#!/usr/bin/env bash
# universal_optimize_extreme.sh
# 极限版 Linux 网络与系统性能优化脚本
# 基于原版 universal_optimize.sh 全面增强
# 
# 新增功能：
# - BBR 拥塞控制（论坛用户强烈建议）
# - TCP 快速打开 (TFO)
# - 更激进的 TCP/UDP 缓冲区设置
# - TIME_WAIT 优化
# - 内存管理优化 (vm.swappiness, dirty_ratio)
# - 连接跟踪优化
# - 完善的 Debian 兼容性
# - 自动检测系统内存并动态调整参数
# - 更多网卡 offload 选项
# - 队列调度优化 (fq/fq_codel)
#
# 作者: 基于 buyi06 原版优化
# 版本: 2.0.0 Extreme Edition
# 兼容: Debian / Ubuntu / CentOS / Rocky / Alma / Arch / Alpine / openSUSE

set -Eeuo pipefail

VERSION="2.0.0-extreme"

ACTION="${1:-apply}"
SYSCTL_FILE="/etc/sysctl.d/99-extreme-optimize.conf"
LIMITS_FILE="/etc/security/limits.d/99-extreme.conf"
SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/99-extreme-limits.conf"
OFFLOAD_UNIT="/etc/systemd/system/extreme-offload@.service"
IRQPIN_UNIT="/etc/systemd/system/extreme-irqpin@.service"
QDISC_UNIT="/etc/systemd/system/extreme-qdisc@.service"
HEALTH_UNIT="/etc/systemd/system/extreme-health.service"
ENV_FILE="/etc/default/extreme-optimize"
HAS_SYSTEMD=0
TOTAL_MEM_KB=0
TOTAL_MEM_MB=0

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD=1
fi

#------------- helpers -------------
ok(){   printf "\033[32m[✓] %s\033[0m\n" "$*"; }
warn(){ printf "\033[33m[!] %s\033[0m\n" "$*"; }
err(){  printf "\033[31m[✗] %s\033[0m\n" "$*"; }
info(){ printf "\033[36m[i] %s\033[0m\n" "$*"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "需要 root 权限，请使用 sudo 或切换 root 后再试"
    exit 1
  fi
}

detect_mem() {
  # 检测系统内存，用于动态调整参数
  TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
  info "检测到系统内存: ${TOTAL_MEM_MB} MB"
}

detect_iface() {
  # IFACE 可由环境变量覆盖
  if [[ -n "${IFACE:-}" && -e "/sys/class/net/${IFACE}" ]]; then
    echo "$IFACE"; return
  fi
  # 1) 优先路由探测
  local dev
  dev="$(ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "$dev" && -e "/sys/class/net/${dev}" ]]; then
    echo "$dev"; return
  fi
  # 2) 第一个非 lo 的 UP 接口
  dev="$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true)"
  if [[ -n "$dev" && -e "/sys/class/net/${dev}" ]]; then
    echo "$dev"; return
  fi
  # 3) 兜底：第一个非 lo 接口
  dev="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true)"
  [[ -n "$dev" ]] && echo "$dev"
}

detect_kernel_version() {
  # 检测内核版本，用于判断功能支持
  local ver
  ver=$(uname -r | cut -d. -f1-2)
  echo "$ver"
}

check_bbr_support() {
  # 检查内核是否支持 BBR
  if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      return 0
    fi
  fi
  # 尝试加载 BBR 模块
  modprobe tcp_bbr 2>/dev/null || true
  if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    return 0
  fi
  return 1
}

pkg_install() {
  # 安装必要工具
  local need_ethtool=0
  local need_iproute=0
  
  command -v ethtool >/dev/null 2>&1 || need_ethtool=1
  command -v tc >/dev/null 2>&1 || need_iproute=1
  
  [[ $need_ethtool -eq 0 && $need_iproute -eq 0 ]] && return 0
  
  info "正在安装必要工具..."
  
  if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    [[ $need_ethtool -eq 1 ]] && apt-get install -y ethtool >/dev/null 2>&1 || true
    [[ $need_iproute -eq 1 ]] && apt-get install -y iproute2 >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    [[ $need_ethtool -eq 1 ]] && dnf -y install ethtool >/dev/null 2>&1 || true
    [[ $need_iproute -eq 1 ]] && dnf -y install iproute >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    [[ $need_ethtool -eq 1 ]] && yum -y install ethtool >/dev/null 2>&1 || true
    [[ $need_iproute -eq 1 ]] && yum -y install iproute >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null 2>&1; then
    [[ $need_ethtool -eq 1 ]] && zypper --non-interactive install ethtool >/dev/null 2>&1 || true
    [[ $need_iproute -eq 1 ]] && zypper --non-interactive install iproute2 >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ethtool iproute2 >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ethtool iproute2 >/dev/null 2>&1 || true
  fi
}

calculate_buffer_sizes() {
  # 根据内存大小动态计算缓冲区
  # 小内存 (<2GB): 保守设置
  # 中等内存 (2-8GB): 标准设置
  # 大内存 (>8GB): 激进设置
  
  if [[ $TOTAL_MEM_MB -lt 2048 ]]; then
    # 小内存: 保守设置
    RMEM_MAX=33554432        # 32MB
    WMEM_MAX=33554432        # 32MB
    RMEM_DEFAULT=1048576     # 1MB
    WMEM_DEFAULT=1048576     # 1MB
    TCP_RMEM="4096 87380 16777216"
    TCP_WMEM="4096 65536 16777216"
    UDP_RMEM_MIN=8192
    UDP_WMEM_MIN=8192
    NETDEV_BACKLOG=10000
    SOMAXCONN=4096
    info "小内存模式 (<2GB): 使用保守缓冲区设置"
  elif [[ $TOTAL_MEM_MB -lt 8192 ]]; then
    # 中等内存: 标准设置
    RMEM_MAX=67108864        # 64MB
    WMEM_MAX=67108864        # 64MB
    RMEM_DEFAULT=4194304     # 4MB
    WMEM_DEFAULT=4194304     # 4MB
    TCP_RMEM="4096 131072 67108864"
    TCP_WMEM="4096 65536 67108864"
    UDP_RMEM_MIN=131072
    UDP_WMEM_MIN=131072
    NETDEV_BACKLOG=50000
    SOMAXCONN=16384
    info "标准内存模式 (2-8GB): 使用标准缓冲区设置"
  else
    # 大内存: 激进设置
    RMEM_MAX=134217728       # 128MB
    WMEM_MAX=134217728       # 128MB
    RMEM_DEFAULT=16777216    # 16MB
    WMEM_DEFAULT=16777216    # 16MB
    TCP_RMEM="4096 262144 134217728"
    TCP_WMEM="4096 262144 134217728"
    UDP_RMEM_MIN=262144
    UDP_WMEM_MIN=262144
    NETDEV_BACKLOG=100000
    SOMAXCONN=65535
    info "大内存模式 (>8GB): 使用激进缓冲区设置"
  fi
}

apply_sysctl() {
  info "正在应用极限网络优化参数..."
  
  # 检查 BBR 支持
  local use_bbr=0
  if check_bbr_support; then
    use_bbr=1
    ok "BBR 拥塞控制可用"
  else
    warn "BBR 不可用，将使用 cubic"
  fi
  
  # 计算动态缓冲区大小
  calculate_buffer_sizes
  
  # 生成配置文件
  cat >"$SYSCTL_FILE" <<EOF
# ============================================================
# Extreme Linux Network & System Optimization
# Generated by universal_optimize_extreme.sh v${VERSION}
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Memory: ${TOTAL_MEM_MB} MB
# ============================================================

# ==================== 核心网络缓冲区 ====================
# 最大接收/发送缓冲区 (根据内存动态调整)
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}

# 辅助缓冲区 (用于 IP 选项等)
net.core.optmem_max = 8388608

# 网络设备队列长度 (高流量环境必须增大)
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# 最大等待连接数
net.core.somaxconn = ${SOMAXCONN}

# ==================== TCP 优化 ====================
# TCP 缓冲区 (min default max)
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}

# TCP 内存管理 (pages)
net.ipv4.tcp_mem = 65536 131072 262144

# SYN 队列长度
net.ipv4.tcp_max_syn_backlog = 65535

# TIME_WAIT 优化
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000

# TCP 快速打开 (TFO) - 减少连接延迟
net.ipv4.tcp_fastopen = 3

# TCP keepalive 优化
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# 禁用慢启动重启 (提高长连接性能)
net.ipv4.tcp_slow_start_after_idle = 0

# MTU 探测 (避免 PMTU 黑洞)
net.ipv4.tcp_mtu_probing = 1

# 启用窗口缩放
net.ipv4.tcp_window_scaling = 1

# 启用 SACK 和时间戳 (对 WAN 性能重要)
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# SYN 重试次数 (减少等待时间)
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# 孤儿连接限制
net.ipv4.tcp_max_orphans = 262144

# 启用 ECN (显式拥塞通知)
net.ipv4.tcp_ecn = 1

# TCP 无延迟确认 (减少延迟)
net.ipv4.tcp_no_metrics_save = 1

# ==================== UDP 优化 ====================
# UDP 内存管理 (pages)
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN}

# ==================== 端口范围 ====================
net.ipv4.ip_local_port_range = 1024 65535

# ==================== 连接跟踪优化 ====================
# 增大连接跟踪表 (高并发必须)
net.netfilter.nf_conntrack_max = 2097152
net.nf_conntrack_max = 2097152

# 连接跟踪超时优化
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30

# ==================== 拥塞控制 ====================
EOF

  # BBR 配置
  if [[ $use_bbr -eq 1 ]]; then
    cat >>"$SYSCTL_FILE" <<EOF
# 使用 BBR 拥塞控制 + fq 队列调度
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  else
    cat >>"$SYSCTL_FILE" <<EOF
# BBR 不可用，使用 fq_codel + cubic
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF
  fi

  # 继续添加其他配置
  cat >>"$SYSCTL_FILE" <<EOF

# ==================== 内存管理优化 ====================
# 减少交换倾向 (VPS 推荐 10-30)
vm.swappiness = 10

# 脏页刷新优化
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# VFS 缓存压力
vm.vfs_cache_pressure = 50

# 内存过量提交策略
vm.overcommit_memory = 1
vm.overcommit_ratio = 50

# 最小空闲内存 (KB)
vm.min_free_kbytes = 65536

# ==================== 文件系统优化 ====================
# 增加文件句柄限制
fs.file-max = 2097152
fs.nr_open = 2097152

# inotify 限制
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events = 32768

# ==================== 内核优化 ====================
# 内核 panic 后自动重启
kernel.panic = 10
kernel.panic_on_oops = 1

# 进程 ID 最大值
kernel.pid_max = 4194304

# 消息队列限制
kernel.msgmnb = 65536
kernel.msgmax = 65536

# 共享内存限制
kernel.shmmax = $((TOTAL_MEM_KB * 1024 / 2))
kernel.shmall = $((TOTAL_MEM_KB / 4))

# ==================== IPv6 优化 (可选) ====================
# 如果不使用 IPv6，可以禁用以提高性能
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1

# IPv6 邻居表大小
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536

# ==================== ARP 优化 ====================
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536

# ==================== 安全相关 (保持启用) ====================
# SYN Cookie 防护
net.ipv4.tcp_syncookies = 1

# 反向路径过滤
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 禁用 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 禁用源路由
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
EOF

  # 运行态注入
  info "正在应用 sysctl 参数到运行态..."
  
  # 加载 conntrack 模块 (如果需要)
  modprobe nf_conntrack 2>/dev/null || true
  modprobe nf_conntrack_ipv4 2>/dev/null || true
  
  # 应用配置
  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  
  ok "sysctl 极限优化已应用并持久化: $SYSCTL_FILE"
}

apply_limits() {
  info "正在提升系统资源限制..."
  
  mkdir -p "$(dirname "$LIMITS_FILE")"
  cat >"$LIMITS_FILE" <<'LIM'
# Extreme Optimize: 文件句柄和进程限制
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
* soft memlock unlimited
* hard memlock unlimited
* soft stack unlimited
* hard stack unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
LIM

  mkdir -p "$SYSTEMD_LIMITS_DIR"
  cat >"$SYSTEMD_LIMITS_FILE" <<'SVC'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
DefaultLimitSTACK=infinity
SVC

  ok "ulimit 资源限制已提升 (新会话/服务生效)"
}

apply_offload_unit() {
  local iface="$1"
  
  info "正在配置网卡 offload 关闭服务..."
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$OFFLOAD_UNIT" <<'UNIT'
[Unit]
Description=Extreme Optimize: Disable NIC offloads for %i
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device network-online.target
Wants=network-online.target
ConditionPathExists=/sys/class/net/%i

[Service]
Type=oneshot
# 等待链路 UP (最长 10 秒)
ExecStartPre=/bin/sh -c 'for i in $(seq 1 20); do ip link show %i 2>/dev/null | grep -q "state UP" && exit 0; sleep 0.5; done; exit 0'
# 关闭所有可能的 offload 特性
ExecStart=-/bin/bash -lc '
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  if ! command -v ethtool >/dev/null 2>&1 && [[ ! -x "$ET" ]]; then
    echo "[offload] ethtool 不存在，跳过"
    exit 0
  fi
  
  # 基础 offload 关闭
  $ET -K %i gro off 2>/dev/null || true
  $ET -K %i gso off 2>/dev/null || true
  $ET -K %i tso off 2>/dev/null || true
  $ET -K %i lro off 2>/dev/null || true
  $ET -K %i sg off 2>/dev/null || true
  
  # 高级 offload 关闭
  $ET -K %i rx-gro-hw off 2>/dev/null || true
  $ET -K %i rx-udp-gro-forwarding off 2>/dev/null || true
  $ET -K %i tx-gso-partial off 2>/dev/null || true
  $ET -K %i tx-gre-segmentation off 2>/dev/null || true
  $ET -K %i tx-gre-csum-segmentation off 2>/dev/null || true
  $ET -K %i tx-ipxip4-segmentation off 2>/dev/null || true
  $ET -K %i tx-ipxip6-segmentation off 2>/dev/null || true
  $ET -K %i tx-udp_tnl-segmentation off 2>/dev/null || true
  $ET -K %i tx-udp_tnl-csum-segmentation off 2>/dev/null || true
  
  # 增大 ring buffer (如果支持)
  $ET -G %i rx 4096 tx 4096 2>/dev/null || true
  
  echo "[offload] 已关闭 %i 的 offload 特性"
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable "extreme-offload@${iface}.service" >/dev/null 2>&1 || true
    systemctl restart "extreme-offload@${iface}.service" >/dev/null 2>&1 || true
    ok "systemd offload 服务已配置: extreme-offload@${iface}.service"
  else
    warn "非 systemd 环境，跳过 offload 持久化服务"
  fi

  # 立即执行一次
  if command -v ethtool >/dev/null 2>&1 || [[ -x /usr/sbin/ethtool ]]; then
    local ET
    ET=$(command -v ethtool || echo /usr/sbin/ethtool)
    $ET -K "$iface" gro off gso off tso off lro off sg off 2>/dev/null || true
    $ET -K "$iface" rx-gro-hw off rx-udp-gro-forwarding off 2>/dev/null || true
    $ET -G "$iface" rx 4096 tx 4096 2>/dev/null || true
    ok "已对 $iface 执行即时 offload 关闭"
  fi
}

apply_qdisc_unit() {
  local iface="$1"
  
  info "正在配置队列调度优化..."
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$QDISC_UNIT" <<'UNIT'
[Unit]
Description=Extreme Optimize: Configure qdisc for %i
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device network-online.target extreme-offload@%i.service
Wants=network-online.target
ConditionPathExists=/sys/class/net/%i

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc '
  TC=$(command -v tc || echo /sbin/tc)
  if ! command -v tc >/dev/null 2>&1 && [[ ! -x "$TC" ]]; then
    echo "[qdisc] tc 不存在，跳过"
    exit 0
  fi
  
  # 删除现有 qdisc
  $TC qdisc del dev %i root 2>/dev/null || true
  
  # 设置 fq 队列调度 (BBR 推荐)
  # 注意: 不限制速率，让 BBR 自己控制
  $TC qdisc add dev %i root fq 2>/dev/null || \
  $TC qdisc add dev %i root fq_codel 2>/dev/null || true
  
  echo "[qdisc] 已为 %i 配置 fq/fq_codel 队列调度"
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable "extreme-qdisc@${iface}.service" >/dev/null 2>&1 || true
    systemctl restart "extreme-qdisc@${iface}.service" >/dev/null 2>&1 || true
    ok "systemd qdisc 服务已配置: extreme-qdisc@${iface}.service"
  fi

  # 立即执行
  if command -v tc >/dev/null 2>&1; then
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root fq 2>/dev/null || \
    tc qdisc add dev "$iface" root fq_codel 2>/dev/null || true
    ok "已为 $iface 配置 fq 队列调度"
  fi
}

runtime_irqpin() {
  local iface="$1"
  local cpu_count
  cpu_count=$(nproc 2>/dev/null || echo 1)
  
  info "正在优化 IRQ 亲和性 (CPU 数量: $cpu_count)..."
  
  # 获取主 IRQ
  local main_irq
  main_irq=$(cat /sys/class/net/$iface/device/irq 2>/dev/null || true)
  
  if [[ -n "$main_irq" && -w /proc/irq/$main_irq/smp_affinity ]]; then
    # 绑定到 CPU0
    echo 1 > /proc/irq/$main_irq/smp_affinity 2>/dev/null && \
      info "主 IRQ $main_irq -> CPU0"
  fi
  
  # MSI IRQ 分布到多个 CPU
  local cpu_mask=1
  local irq_count=0
  for f in /sys/class/net/$iface/device/msi_irqs/*; do
    [[ -f "$f" ]] || continue
    local irq
    irq=$(basename "$f")
    if [[ -w /proc/irq/$irq/smp_affinity ]]; then
      echo $cpu_mask > /proc/irq/$irq/smp_affinity 2>/dev/null && \
        info "MSI IRQ $irq -> CPU mask $cpu_mask"
      ((irq_count++))
      # 轮换 CPU
      if [[ $cpu_count -gt 1 ]]; then
        cpu_mask=$(( (cpu_mask << 1) % ((1 << cpu_count) - 1) + 1 ))
      fi
    fi
  done
  
  if [[ $irq_count -eq 0 ]]; then
    warn "未发现可配置的 IRQ (虚拟网卡常见，跳过)"
  fi
}

apply_irqpin_unit() {
  local iface="$1"
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$IRQPIN_UNIT" <<'UNIT'
[Unit]
Description=Extreme Optimize: Pin NIC IRQs for %i
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device
ConditionPathExists=/sys/class/net/%i

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc '
  IF="%i"
  CPU_COUNT=$(nproc 2>/dev/null || echo 1)
  
  main_irq=$(cat /sys/class/net/$IF/device/irq 2>/dev/null || true)
  if [[ -n "$main_irq" && -w /proc/irq/$main_irq/smp_affinity ]]; then
    echo 1 > /proc/irq/$main_irq/smp_affinity 2>/dev/null && \
      echo "[irq] 主 IRQ $main_irq -> CPU0"
  fi
  
  cpu_mask=1
  for f in /sys/class/net/$IF/device/msi_irqs/*; do
    [[ -f "$f" ]] || continue
    irq=$(basename "$f")
    if [[ -w /proc/irq/$irq/smp_affinity ]]; then
      echo $cpu_mask > /proc/irq/$irq/smp_affinity 2>/dev/null
      if [[ $CPU_COUNT -gt 1 ]]; then
        cpu_mask=$(( (cpu_mask << 1) % ((1 << CPU_COUNT) - 1) + 1 ))
      fi
    fi
  done
  exit 0
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable "extreme-irqpin@${iface}.service" >/dev/null 2>&1 || true
    systemctl restart "extreme-irqpin@${iface}.service" >/dev/null 2>&1 || true
    ok "IRQ 绑定服务已配置"
  else
    warn "非 systemd 环境，跳过 IRQ 持久化服务"
  fi

  runtime_irqpin "$iface"
}

apply_health_unit() {
  cat >"$ENV_FILE" <<EOF
IFACE="${IFACE}"
SYSCTL_FILE="${SYSCTL_FILE}"
VERSION="${VERSION}"
EOF

  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$HEALTH_UNIT" <<'UNIT'
[Unit]
Description=Extreme Optimize: Boot health report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '
  source /etc/default/extreme-optimize 2>/dev/null || true
  IF="${IFACE:-$(ip -o route get 1.1.1.1 2>/dev/null | awk "/dev/ {for(i=1;i<=NF;i++) if(\$i==\"dev\"){print \$(i+1); exit}}")}"
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  
  echo "=============================================="
  echo "  Extreme Optimize 自检报告"
  echo "  时间: $(date "+%F %T")"
  echo "  版本: ${VERSION:-unknown}"
  echo "=============================================="
  echo ""
  
  echo "[服务状态]"
  systemctl is-active "extreme-offload@${IF}.service" 2>/dev/null && echo "  offload: ✓ active" || echo "  offload: ✗ inactive"
  systemctl is-active "extreme-qdisc@${IF}.service" 2>/dev/null && echo "  qdisc  : ✓ active" || echo "  qdisc  : ✗ inactive"
  systemctl is-active "extreme-irqpin@${IF}.service" 2>/dev/null && echo "  irqpin : ✓ active" || echo "  irqpin : ✗ inactive/ignored"
  echo ""
  
  echo "[拥塞控制]"
  echo "  算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "  qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  echo ""
  
  echo "[缓冲区设置]"
  echo "  rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
  echo "  wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
  echo "  tcp_rmem: $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo unknown)"
  echo "  tcp_wmem: $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo unknown)"
  echo ""
  
  if [[ -x "$ET" && -n "$IF" ]]; then
    echo "[网卡 Offload 状态: $IF]"
    $ET -k "$IF" 2>/dev/null | grep -E "^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|large-receive-offload):" | head -10 || true
  fi
  echo ""
  echo "=============================================="
'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable extreme-health.service >/dev/null 2>&1 || true
    ok "健康自检服务已配置"
  else
    warn "非 systemd 环境，跳过健康自检持久化"
  fi
}

status_report() {
  local iface="$1"
  
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║           Extreme Optimize 状态报告                          ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  时间: $(date '+%F %T')"
  echo "  版本: $VERSION"
  echo "  网卡: $iface"
  echo "  内存: ${TOTAL_MEM_MB} MB"
  echo ""
  
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│ 拥塞控制                                                     │"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo "  算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "  qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  echo "  TFO:   $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
  echo ""
  
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│ 缓冲区设置                                                   │"
  echo "└─────────────────────────────────────────────────────────────┘"
  printf "  %-20s %s\n" "rmem_max:" "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "wmem_max:" "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "tcp_rmem:" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "tcp_wmem:" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "somaxconn:" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "netdev_backlog:" "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo unknown)"
  echo ""
  
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│ 内存管理                                                     │"
  echo "└─────────────────────────────────────────────────────────────┘"
  printf "  %-20s %s\n" "swappiness:" "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "dirty_ratio:" "$(sysctl -n vm.dirty_ratio 2>/dev/null || echo unknown)"
  printf "  %-20s %s\n" "dirty_bg_ratio:" "$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo unknown)"
  echo ""
  
  local ET
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  if [[ -x "$ET" ]]; then
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ 网卡 Offload 状态                                           │"
    echo "└─────────────────────────────────────────────────────────────┘"
    $ET -k "$iface" 2>/dev/null | grep -E '(gro|gso|tso|lro|scatter-gather):' | head -10 | while read line; do
      echo "  $line"
    done
    echo ""
  fi
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ Systemd 服务状态                                            │"
    echo "└─────────────────────────────────────────────────────────────┘"
    for svc in "extreme-offload@${iface}" "extreme-qdisc@${iface}" "extreme-irqpin@${iface}" "extreme-health"; do
      local status
      status=$(systemctl is-active "${svc}.service" 2>/dev/null || echo "inactive")
      local enabled
      enabled=$(systemctl is-enabled "${svc}.service" 2>/dev/null || echo "disabled")
      printf "  %-30s %s / %s\n" "${svc}:" "$status" "$enabled"
    done
    echo ""
  fi
  
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║ 配置文件                                                      ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo "  sysctl: $SYSCTL_FILE"
  echo "  limits: $LIMITS_FILE"
  echo "  env:    $ENV_FILE"
  echo ""
}

repair_missing() {
  info "正在检查并修复缺失项..."
  
  [[ -f "$SYSCTL_FILE" ]] || { warn "sysctl 配置缺失，重新生成"; apply_sysctl; }
  [[ -f "$LIMITS_FILE" ]] || { warn "limits 配置缺失，重新生成"; apply_limits; }
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    [[ -f "$OFFLOAD_UNIT" ]] || { warn "offload 服务缺失，重新生成"; apply_offload_unit "$IFACE"; }
    [[ -f "$QDISC_UNIT" ]] || { warn "qdisc 服务缺失，重新生成"; apply_qdisc_unit "$IFACE"; }
    [[ -f "$IRQPIN_UNIT" ]] || { warn "irqpin 服务缺失，重新生成"; apply_irqpin_unit "$IFACE"; }
    [[ -f "$HEALTH_UNIT" ]] || { warn "health 服务缺失，重新生成"; apply_health_unit; }
  fi
  
  ok "缺失项检查完成"
}

uninstall() {
  info "正在卸载 Extreme Optimize..."
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl disable --now extreme-offload@*.service 2>/dev/null || true
    systemctl disable --now extreme-qdisc@*.service 2>/dev/null || true
    systemctl disable --now extreme-irqpin@*.service 2>/dev/null || true
    systemctl disable --now extreme-health.service 2>/dev/null || true
  fi
  
  rm -f "$SYSCTL_FILE" \
        "$LIMITS_FILE" \
        "$SYSTEMD_LIMITS_FILE" \
        "$OFFLOAD_UNIT" \
        "$QDISC_UNIT" \
        "$IRQPIN_UNIT" \
        "$HEALTH_UNIT" \
        "$ENV_FILE"
  
  sysctl --system >/dev/null 2>&1 || true
  
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl daemon-reload
  fi
  
  ok "Extreme Optimize 已完全卸载"
  warn "建议重启系统以恢复默认设置"
}

show_help() {
  cat <<EOF
╔══════════════════════════════════════════════════════════════════╗
║     Extreme Linux Network & System Optimizer v${VERSION}        ║
╚══════════════════════════════════════════════════════════════════╝

用法: bash $0 [命令]

命令:
  apply     应用所有优化 (默认)
  status    显示当前状态
  repair    检查并修复缺失配置
  uninstall 完全卸载优化
  help      显示此帮助

环境变量:
  IFACE=xxx   手动指定网卡 (默认自动检测)

示例:
  bash $0                    # 应用所有优化
  bash $0 status             # 查看状态
  IFACE=ens3 bash $0 apply   # 指定网卡

一键安装:
  bash -c "\$(curl -fsSL URL)"

EOF
}

#------------- main -------------
require_root
detect_mem

IFACE="$(detect_iface || true)"
if [[ -z "$IFACE" ]]; then
  err "无法自动探测网卡，请用 IFACE=xxx 再试"
  exit 1
fi

case "$ACTION" in
  apply)
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     Extreme Linux Optimizer v${VERSION}                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    info "目标网卡: $IFACE"
    info "内核版本: $(uname -r)"
    echo ""
    
    pkg_install
    apply_sysctl
    apply_limits
    apply_offload_unit "$IFACE"
    apply_qdisc_unit "$IFACE"
    apply_irqpin_unit "$IFACE"
    apply_health_unit
    
    echo ""
    ok "所有优化已应用完成！"
    echo ""
    
    status_report "$IFACE"
    ;;
  status)
    status_report "$IFACE"
    ;;
  repair)
    pkg_install
    repair_missing
    status_report "$IFACE"
    ;;
  uninstall)
    uninstall
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    err "未知命令: $ACTION"
    show_help
    exit 1
    ;;
esac
