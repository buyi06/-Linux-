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
# 版本: 2.0.1 Extreme Edition
# 兼容: Debian / Ubuntu / CentOS / Rocky / Alma / Arch / Alpine / openSUSE

set -Eeuo pipefail

VERSION="2.0.1-extreme"

# 统一错误处理：捕获未预期错误行号与退出码，给出可排查的提示
_err_trap() {
  local rc=$?
  local lineno=${1:-?}
  printf '\033[31m[FATAL]\033[0m 第一个不成功的命令在行 %s (退出码 %s)\n' "$lineno" "$rc" >&2
  printf '           详情可查看 /var/log/extreme-optimize.log\n' >&2
  exit "$rc"
}
trap '_err_trap $LINENO' ERR

# 解析参数：首个非 --dry-run 参数作为 ACTION
DRY_RUN=0
ACTION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    *) [[ -z "$ACTION" ]] && ACTION="$arg" ;;
  esac
done
ACTION="${ACTION:-apply}"
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
IS_OPENVZ=0
IS_LXC=0

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD=1
fi

detect_virt() {
  if [[ -f /proc/user_beancounters && ! -d /proc/vz/version ]] || [[ -f /proc/vz/veinfo ]]; then
    IS_OPENVZ=1
  fi
  if grep -qaE '(lxc|container=lxc)' /proc/1/environ 2>/dev/null \
     || [[ -f /.dockerenv ]] \
     || grep -qE ':/(docker|lxc)/' /proc/1/cgroup 2>/dev/null; then
    IS_LXC=1
  fi
  if [[ $IS_OPENVZ -eq 1 ]]; then
    warn "检测到 OpenVZ 容器：内核参数多数不可修改，脚本将尽力而为，但多数优化不会生效"
  fi
  if [[ $IS_LXC -eq 1 ]]; then
    warn "检测到 LXC/Docker 容器：部分参数依赖宿主机内核，当前环境可能无效"
  fi
}

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
    if [[ $need_ethtool -eq 1 ]]; then apt-get install -y ethtool >/dev/null 2>&1 || true; fi
    if [[ $need_iproute -eq 1 ]]; then apt-get install -y iproute2 >/dev/null 2>&1 || true; fi
  elif command -v dnf >/dev/null 2>&1; then
    if [[ $need_ethtool -eq 1 ]]; then dnf -y install ethtool >/dev/null 2>&1 || true; fi
    if [[ $need_iproute -eq 1 ]]; then dnf -y install iproute >/dev/null 2>&1 || true; fi
  elif command -v yum >/dev/null 2>&1; then
    if [[ $need_ethtool -eq 1 ]]; then yum -y install ethtool >/dev/null 2>&1 || true; fi
    if [[ $need_iproute -eq 1 ]]; then yum -y install iproute >/dev/null 2>&1 || true; fi
  elif command -v zypper >/dev/null 2>&1; then
    if [[ $need_ethtool -eq 1 ]]; then zypper --non-interactive install ethtool >/dev/null 2>&1 || true; fi
    if [[ $need_iproute -eq 1 ]]; then zypper --non-interactive install iproute2 >/dev/null 2>&1 || true; fi
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
    TCP_MEM="21845 43690 87380"
    UDP_MEM="21845 43690 87380"
    CONNTRACK_MAX=262144
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
    TCP_MEM="65536 131072 262144"
    UDP_MEM="65536 131072 262144"
    CONNTRACK_MAX=1048576
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
    TCP_MEM="262144 524288 1048576"
    UDP_MEM="262144 524288 1048576"
    CONNTRACK_MAX=2097152
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

  # TFO / ECN 可由环境变量覆盖
  local TFO_VAL="${EXTREME_TFO:-1}"
  local ECN_VAL="${EXTREME_ECN:-2}"
  case "$TFO_VAL" in 0|1|2|3) ;; *) warn "EXTREME_TFO=$TFO_VAL 非法，回退为 1"; TFO_VAL=1 ;; esac
  case "$ECN_VAL" in 0|1|2) ;; *) warn "EXTREME_ECN=$ECN_VAL 非法，回退为 2"; ECN_VAL=2 ;; esac

  # 计算动态缓冲区大小
  calculate_buffer_sizes

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将写入 $SYSCTL_FILE (TFO=$TFO_VAL ECN=$ECN_VAL BBR=$use_bbr) — 跳过实际写入"
    return 0
  fi
  
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

# TCP 内存管理 (pages，根据内存动态调整)
net.ipv4.tcp_mem = ${TCP_MEM}

# SYN 队列长度
net.ipv4.tcp_max_syn_backlog = 65535

# TIME_WAIT 优化
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000

# TCP 快速打开 (TFO) - 默认仅客户端 (1)，生产服务端如需 3 请显式设置 EXTREME_TFO=3
# 某些运营商中间盒对 TFO 服务端位兼容性较差，保守默认为 1
net.ipv4.tcp_fastopen = ${TFO_VAL}

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
# tcp_fack 在内核 4.15+ 已移除，设置会触发 "unknown key" 警告，故不再写入。

# SYN 重试次数 (减少等待时间)
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# 孤儿连接限制
net.ipv4.tcp_max_orphans = 262144

# 启用 ECN (显式拥塞通知) - 默认 2 (被动响应)，老中间盒可能丢弃 ECT 流量
# 激进场景可设 EXTREME_ECN=1
net.ipv4.tcp_ecn = ${ECN_VAL}

# TCP 无延迟确认 (减少延迟)
net.ipv4.tcp_no_metrics_save = 1

# ==================== UDP 优化 ====================
# UDP 内存管理 (pages，根据内存动态调整)
net.ipv4.udp_mem = ${UDP_MEM}
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN}

# ==================== 端口范围 ====================
net.ipv4.ip_local_port_range = 1024 65535

# ==================== 连接跟踪优化 ====================
# 增大连接跟踪表 (高并发必须)
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.nf_conntrack_max = ${CONNTRACK_MAX}

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

# 注意: vm.overcommit_memory 不在本脚本调整，保留内核默认 (0)
# 对数据库/OOM 敏感型服务，设 =1 会显著改变分配语义，故不隐式启用

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
# 内核 panic 后自动重启 (不启用 panic_on_oops，保留 oops 现场便于排障)
kernel.panic = 10

# 进程 ID 最大值
kernel.pid_max = 4194304

# 消息队列限制
kernel.msgmnb = 65536
kernel.msgmax = 65536

# 注意: kernel.shmmax / kernel.shmall 不在本脚本调整
# 这类参数与数据库 (Postgres/Oracle) 配置强相关，应由 DBA 按应用需要设置

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
# 使用松模式 (2)，避免不对称路由场景下合法流量被丢弃
# 如需严格模式，部署后手动 sysctl -w net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

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

  # 应用配置，失败行写入日志便于排障
  local log=/var/log/extreme-optimize.log
  mkdir -p /var/log 2>/dev/null || true
  # 先抓本次 sysctl 输出到临时文件，仅统计本次失败行，避免跨次累积计数
  local tmp_apply
  tmp_apply=$(mktemp) || tmp_apply=/tmp/extreme-sysctl-apply.$$
  {
    echo "=== sysctl apply $(date '+%F %T') ==="
    sysctl -p "$SYSCTL_FILE"
  } >"$tmp_apply" 2>&1 || true
  # 追加到历史日志
  cat "$tmp_apply" >>"$log" 2>/dev/null || true
  local fail_count
  fail_count=$(grep -cE 'cannot stat|No such file|Invalid argument|permission denied|unknown key' "$tmp_apply" 2>/dev/null || echo 0)
  rm -f "$tmp_apply" 2>/dev/null || true
  if [[ "${fail_count:-0}" -gt 0 ]]; then
    warn "部分 sysctl 参数未生效（共 ${fail_count} 行），详见 $log"
  fi

  ok "sysctl 极限优化已应用并持久化: $SYSCTL_FILE"
}

apply_limits() {
  info "正在提升系统资源限制..."

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将写入 $LIMITS_FILE 与 $SYSTEMD_LIMITS_FILE — 跳过"
    return 0
  fi

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

  # 重新执行 systemd manager 以让 DefaultLimit* 对后续启动的服务生效
  if [[ $HAS_SYSTEMD -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reexec 2>/dev/null || true
  fi

  ok "ulimit 资源限制已提升 (新会话/服务生效)"
}

apply_offload_unit() {
  local iface="$1"

  info "正在配置网卡 offload 关闭服务..."

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将创建 $OFFLOAD_UNIT 并对 $iface 关闭 offload — 跳过"
    return 0
  fi

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

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将创建 $QDISC_UNIT 并对 $iface 应用 fq — 跳过"
    return 0
  fi

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
  main_irq=$(cat "/sys/class/net/$iface/device/irq" 2>/dev/null || true)
  
  if [[ -n "$main_irq" && -w /proc/irq/$main_irq/smp_affinity ]]; then
    # 绑定到 CPU0
    echo 1 > "/proc/irq/$main_irq/smp_affinity" 2>/dev/null && \
      info "主 IRQ $main_irq -> CPU0"
  fi
  
  # MSI IRQ 轮询分布到各 CPU (每个 IRQ 固定到单个 CPU)
  local irq_count=0
  local idx=0
  for f in "/sys/class/net/$iface/device/msi_irqs/"*; do
    [[ -f "$f" ]] || continue
    local irq
    irq=$(basename "$f")
    if [[ -w /proc/irq/$irq/smp_affinity ]]; then
      local cpu_mask=$(( 1 << (idx % cpu_count) ))
      printf '%x\n' "$cpu_mask" > "/proc/irq/$irq/smp_affinity" 2>/dev/null && \
        info "MSI IRQ $irq -> CPU$((idx % cpu_count)) (mask 0x$(printf '%x' "$cpu_mask"))"
      ((irq_count++))
      ((idx++))
    fi
  done
  
  if [[ $irq_count -eq 0 ]]; then
    warn "未发现可配置的 IRQ (虚拟网卡常见，跳过)"
  fi
}

apply_irqpin_unit() {
  local iface="$1"

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将创建 $IRQPIN_UNIT 并绑定 $iface IRQ — 跳过"
    return 0
  fi

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

  idx=0
  for f in /sys/class/net/$IF/device/msi_irqs/*; do
    [[ -f "$f" ]] || continue
    irq=$(basename "$f")
    if [[ -w /proc/irq/$irq/smp_affinity ]]; then
      cpu_mask=$(( 1 << (idx % CPU_COUNT) ))
      printf "%x\n" "$cpu_mask" > /proc/irq/$irq/smp_affinity 2>/dev/null
      idx=$((idx + 1))
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
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将创建 $HEALTH_UNIT 与 $ENV_FILE — 跳过"
    return 0
  fi

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
  local congestion_algo
  local qdisc
  local tfo_status
  local rmem_max
  local wmem_max
  local tcp_rmem
  local tcp_wmem
  local somaxconn
  local netdev_backlog
  local swappiness
  local dirty_ratio
  local dirty_bg_ratio
  
  # 获取所有参数值
  congestion_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  tfo_status=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "unknown")
  rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")
  wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "unknown")
  tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "unknown")
  tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "unknown")
  somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "unknown")
  netdev_backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "unknown")
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "unknown")
  dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "unknown")
  dirty_bg_ratio=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo "unknown")
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                    ║"
  echo "║          🚀 Extreme Linux Optimizer 系统状态报告 🚀               ║"
  echo "║                                                                    ║"
  echo "╚════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # 基本信息
  echo "📋 基本信息"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-25s %s\n" "🕐 系统时间:" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "  %-25s %s\n" "📦 脚本版本:" "$VERSION"
  printf "  %-25s %s\n" "🖧 主网卡:" "$iface"
  printf "  %-25s %s MB\n" "💾 系统内存:" "${TOTAL_MEM_MB}"
  printf "  %-25s %s\n" "🐧 内核版本:" "$(uname -r)"
  echo ""
  
  # 拥塞控制
  echo "🔄 拥塞控制与队列调度"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$congestion_algo" == "bbr" ]]; then
    printf "  %-25s ✅ %s (推荐)\n" "🎯 拥塞控制:" "$congestion_algo"
  else
    printf "  %-25s ⚠️  %s\n" "🎯 拥塞控制:" "$congestion_algo"
  fi
  printf "  %-25s %s\n" "📊 队列调度:" "$qdisc"
  printf "  %-25s %s\n" "⚡ TCP快速打开:" "$tfo_status"
  echo ""
  
  # 缓冲区设置
  echo "🔌 网络缓冲区设置"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-25s %s\n" "📥 rmem_max:" "$rmem_max"
  printf "  %-25s %s\n" "📤 wmem_max:" "$wmem_max"
  printf "  %-25s %s\n" "📥 tcp_rmem:" "$tcp_rmem"
  printf "  %-25s %s\n" "📤 tcp_wmem:" "$tcp_wmem"
  printf "  %-25s %s\n" "🔗 somaxconn:" "$somaxconn"
  printf "  %-25s %s\n" "📦 netdev_backlog:" "$netdev_backlog"
  echo ""
  
  # 内存管理
  echo "💾 内存管理优化"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-25s %s\n" "🔄 swappiness:" "$swappiness"
  printf "  %-25s %s\n" "📝 dirty_ratio:" "$dirty_ratio"
  printf "  %-25s %s\n" "📝 dirty_bg_ratio:" "$dirty_bg_ratio"
  echo ""
  
  # 网卡状态
  local ET
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  if [[ -x "$ET" ]]; then
    echo "🖧 网卡 Offload 状态 ($iface)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local offload_info
    offload_info=$($ET -k "$iface" 2>/dev/null | grep -E '(gro|gso|tso|lro|scatter-gather):' | head -10)
    if [[ -n "$offload_info" ]]; then
      echo "$offload_info" | while IFS= read -r line; do
        echo "  $line"
      done
    else
      echo "  ℹ️  虚拟网卡或不支持查询"
    fi
    echo ""
  fi
  
  # Systemd 服务状态
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    echo "⚙️  Systemd 服务状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for svc in "extreme-offload@${iface}" "extreme-qdisc@${iface}" "extreme-irqpin@${iface}" "extreme-health"; do
      local status
      local enabled
      status=$(systemctl is-active "${svc}.service" 2>/dev/null || echo "inactive")
      enabled=$(systemctl is-enabled "${svc}.service" 2>/dev/null || echo "disabled")
      
      local status_icon="⚫"
      local enabled_icon="❌"
      
      [[ "$status" == "active" ]] && status_icon="🟢"
      [[ "$enabled" == "enabled" ]] && enabled_icon="✅"
      
      printf "  %-35s %s %-10s %s %s\n" "${svc}:" "$status_icon" "$status" "$enabled_icon" "$enabled"
    done
    echo ""
  fi
  
  # 配置文件
  echo "📂 配置文件位置"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-25s %s\n" "📄 sysctl 配置:" "$SYSCTL_FILE"
  printf "  %-25s %s\n" "📄 limits 配置:" "$LIMITS_FILE"
  printf "  %-25s %s\n" "📄 环境变量:" "$ENV_FILE"
  echo ""
  
  # 性能建议
  echo "💡 性能建议"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$congestion_algo" != "bbr" ]]; then
    echo "  ⚠️  BBR 未启用，建议升级内核至 4.9+ 以获得更好性能"
  else
    echo "  ✅ BBR 已启用，网络性能已优化"
  fi
  
  if [[ "$swappiness" -gt 30 ]]; then
    echo "  ⚠️  swappiness 较高 ($swappiness)，建议降低至 10-20"
  else
    echo "  ✅ 内存管理已优化"
  fi
  
  if [[ "$somaxconn" -lt 16384 ]]; then
    echo "  ⚠️  somaxconn 较低 ($somaxconn)，可能限制并发连接"
  else
    echo "  ✅ 并发连接限制已提升"
  fi
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║  更多信息请访问: https://github.com/buyi06/-Linux-                 ║"
  echo "╚════════════════════════════════════════════════════════════════════╝"
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

用法: bash $0 [命令] [--dry-run]

命令:
  apply     应用所有优化 (默认)
  status    显示当前状态
  repair    检查并修复缺失配置
  uninstall 完全卸载优化
  help      显示此帮助

选项:
  --dry-run, -n   预演模式，不写入任何文件/执行服务操作

环境变量:
  IFACE=xxx          手动指定网卡 (默认自动检测)
  EXTREME_TFO=0|1|3  TCP Fast Open (默认 1 = 仅客户端；3 = 服务端+客户端)
  EXTREME_ECN=0|1|2  显式拥塞通知 (默认 2 = 被动；1 = 主动可能被老中间盒丢弃)
  EXTREME_OFFLOAD=0  强制关闭网卡 offload（默认不关闭，延续原内核默认）

示例:
  bash $0                      # 应用所有优化
  bash $0 status               # 查看状态
  bash $0 apply --dry-run      # 预演，不改动系统
  IFACE=ens3 bash $0 apply     # 指定网卡
  EXTREME_TFO=3 bash $0 apply  # 显式启用服务端 TFO

一键安装:
  bash -c "\$(curl -fsSL URL)"

EOF
}

#------------- main -------------
require_root
detect_mem
detect_virt

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
    # NIC offload 默认保留，大多数物理/虚拟网卡关闭 offload 会显著降低吞吐。
    # 如确需关闭（特定封装/高 PPS 场景），设置 EXTREME_OFFLOAD=0。
    if [[ "${EXTREME_OFFLOAD:-1}" == "0" ]]; then
      apply_offload_unit "$IFACE"
    else
      info "保留网卡 offload（推荐）。如需关闭，设置 EXTREME_OFFLOAD=0 bash $0 apply"
    fi
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
