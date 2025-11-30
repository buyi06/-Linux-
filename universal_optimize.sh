#!/usr/bin/env bash
# universal_optimize.sh
# 通用安全网络优化（UDP/TCP缓冲、关闭网卡 offload、可选 IRQ 绑定、开机自检）
# - 幂等可重复执行
# - 失败默认忽略（不锁机、不卡网）
# - 不修改应用/防火墙/代理配置
set -Eeuo pipefail

VERSION="1.1.0"

ACTION="${1:-apply}"
SYSCTL_FILE="/etc/sysctl.d/99-universal-net.conf"
LIMITS_FILE="/etc/security/limits.d/99-universal.conf"
SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/99-universal-limits.conf"
OFFLOAD_UNIT="/etc/systemd/system/univ-offload@.service"
IRQPIN_UNIT="/etc/systemd/system/univ-irqpin@.service"
HEALTH_UNIT="/etc/systemd/system/univ-health.service"
ENV_FILE="/etc/default/universal-optimize"
HAS_SYSTEMD=0

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD=1
fi

#------------- helpers -------------
ok(){   printf "\033[32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[33m%s\033[0m\n" "$*"; }
err(){  printf "\033[31m%s\033[0m\n" "$*"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "[universal-optimize] 需要 root 权限，请使用 sudo 或切换 root 后再试"
    exit 1
  fi
}

detect_iface() {
  # IFACE 可由环境变量覆盖：IFACE=ens3 bash universal_optimize.sh apply
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

pkg_install() {
  # 仅在缺失时尝试安装 ethtool（静默失败也无所谓）
  command -v ethtool >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ethtool >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install ethtool >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum -y install ethtool >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install ethtool >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ethtool >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ethtool >/dev/null 2>&1 || true
  fi
}

runtime_sysctl_safe() {
  # 按键值对运行态注入，忽略不存在的键，避免报错
  local k v
  while IFS='=' read -r k v; do
    k="$(echo "$k" | xargs)"; v="$(echo "$v" | xargs)"
    [[ -z "$k" || "$k" =~ ^# ]] && continue
    sysctl -w "$k=$v" >/dev/null 2>&1 || true
  done <<'KV'
net.core.rmem_default=4194304
net.core.wmem_default=4194304
net.core.optmem_max=8388608
net.core.netdev_max_backlog=50000
net.core.somaxconn=16384
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.udp_mem=8192 16384 32768
net.ipv4.udp_rmem_min=131072
net.ipv4.udp_wmem_min=131072
KV
}

apply_sysctl() {
  # 持久化 sysctl（键都很通用，内核缺失也无碍；加载失败不阻塞）
  cat >"$SYSCTL_FILE" <<'CONF'
# === universal-optimize: safe network tuning ===
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.optmem_max   = 8388608
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 16384
net.ipv4.ip_local_port_range = 10240 65535
# UDP pages triple ≈ 32MB / 64MB / 128MB (4K page)
net.ipv4.udp_mem      = 8192 16384 32768
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
CONF
  # 运行态注入（避免因某些键不存在而报错）
  runtime_sysctl_safe
  # 持久加载（即使有键不存在也忽略退出码）
  sysctl --system >/dev/null 2>&1 || true
  ok "[universal-optimize] sysctl 已应用并持久化：$SYSCTL_FILE"
}

apply_limits() {
  # 提升文件句柄数（对交互用户与大多数服务友好）
  mkdir -p "$(dirname "$LIMITS_FILE")"
  cat >"$LIMITS_FILE" <<'LIM'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
LIM
  mkdir -p "$SYSTEMD_LIMITS_DIR"
  cat >"$SYSTEMD_LIMITS_FILE" <<'SVC'
[Manager]
DefaultLimitNOFILE=1048576
SVC
  # 不强制 daemon-reexec，留到下次引导或服务重启生效
  ok "[universal-optimize] ulimit 默认提升（新会话/服务生效）"
}

apply_offload_unit() {
  local iface="$1"
  # systemd 模板单元：绑定网卡设备、等待链路UP、关闭常见 offload
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$OFFLOAD_UNIT" <<'UNIT'
[Unit]
Description=Universal: disable NIC offloads for %i
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device network-online.target
Wants=network-online.target
ConditionPathExists=/sys/class/net/%i

[Service]
Type=oneshot
# 等链路UP（最长8秒）
ExecStartPre=/bin/sh -c 'for i in $(seq 1 16); do ip link show %i 2>/dev/null | grep -q "state UP" && exit 0; sleep 0.5; done; exit 0'
# 容错：自动寻找 ethtool；不支持的特性忽略
ExecStart=-/bin/bash -lc '
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  if ! command -v ethtool >/dev/null 2>&1 && [[ ! -x "$ET" ]]; then
    echo "[offload] ethtool 不存在，跳过"
    exit 0
  fi
  $ET -K %i gro off gso off tso off lro off scatter-gather off rx-gro-hw off rx-udp-gro-forwarding off 2>/dev/null || true
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable "univ-offload@${iface}.service" >/dev/null 2>&1 || true
    systemctl restart "univ-offload@${iface}.service" >/dev/null 2>&1 || true
    ok "[universal-optimize] systemd 持久化 offload 关闭：univ-offload@${iface}.service"
  else
    warn "[universal-optimize] 检测到非 systemd 环境，跳过 offload 持久化服务"
  fi

  # 立即尝试一次（即便 systemd 未生效也尽量落地）
  if command -v ethtool >/dev/null 2>&1 || [[ -x /usr/sbin/ethtool ]]; then
    (ethtool -K "$iface" gro off gso off tso off lro off scatter-gather off rx-gro-hw off rx-udp-gro-forwarding off >/dev/null 2>&1 || true)
    ok "[universal-optimize] 已对 $iface 进行一次性 offload 关闭尝试"
  fi
}

runtime_irqpin() {
  local iface="$1"
  local main_irq
  main_irq=$(cat /sys/class/net/$iface/device/irq 2>/dev/null || true)
  if [[ -n "$main_irq" && -w /proc/irq/$main_irq/smp_affinity ]]; then
    echo 1 > /proc/irq/$main_irq/smp_affinity 2>/dev/null && echo "[irq] 主 IRQ $main_irq -> CPU0"
  else
    echo "[irq] 未发现主 IRQ（虚拟网卡常见，跳过）"
  fi
  for f in /sys/class/net/$iface/device/msi_irqs/*; do
    [[ -f "$f" ]] || continue
    irq=$(basename "$f")
    echo 1 > /proc/irq/$irq/smp_affinity 2>/dev/null && echo "[irq] MSI IRQ $irq -> CPU0"
  done
}

apply_irqpin_unit() {
  local iface="$1"
  # IRQ 绑定（KVM/virtio 多数没有主 IRQ / MSI，这里全程容错）
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$IRQPIN_UNIT" <<'UNIT'
[Unit]
Description=Universal: pin NIC IRQs of %i to CPU0 (safe)
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device
ConditionPathExists=/sys/class/net/%i

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc '
  IF="%i"
  main_irq=$(cat /sys/class/net/$IF/device/irq 2>/dev/null || true)
  if [[ -n "$main_irq" && -w /proc/irq/$main_irq/smp_affinity ]]; then
    echo 1 > /proc/irq/$main_irq/smp_affinity 2>/dev/null && echo "[irq] 主 IRQ $main_irq -> CPU0"
  else
    echo "[irq] 未发现主 IRQ（虚拟网卡常见，跳过）"
  fi
  for f in /sys/class/net/$IF/device/msi_irqs/*; do
    [[ -f "$f" ]] || continue
    irq=$(basename "$f")
    echo 1 > /proc/irq/$irq/smp_affinity 2>/dev/null && echo "[irq] MSI IRQ $irq -> CPU0"
  done
  exit 0
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable "univ-irqpin@${iface}.service" >/dev/null 2>&1 || true
    systemctl restart "univ-irqpin@${iface}.service" >/dev/null 2>&1 || true
    ok "[universal-optimize] IRQ 绑定服务已配置（缺 IRQ 时自动跳过）"
  else
    warn "[universal-optimize] 检测到非 systemd 环境，跳过 IRQ 持久化服务"
  fi

  runtime_irqpin "$iface"
}

apply_health_unit() {
  # 持久记录一次自检到日志（不依赖网络，不依赖脚本路径）
  cat >"$ENV_FILE" <<EOF
IFACE="${IFACE}"
SYSCTL_FILE="${SYSCTL_FILE}"
EOF

  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    cat >"$HEALTH_UNIT" <<'UNIT'
[Unit]
Description=Universal Optimize: boot health report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '
  source /etc/default/universal-optimize 2>/dev/null || true
  IF="${IFACE:-$(ip -o route get 1.1.1.1 2>/dev/null | awk "/dev/ {for(i=1;i<=NF;i++) if(\$i==\"dev\"){print \$(i+1); exit}}")}"
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  echo "=== 自检报告 ($(date "+%F %T")) ==="
  systemctl is-active "univ-offload@${IF:-$IF}.service" >/dev/null 2>&1 && echo "offload: active" || echo "offload: inactive"
  systemctl is-active "univ-irqpin@${IF:-$IF}.service"   >/dev/null 2>&1 && echo "irqpin : active" || echo "irqpin : inactive/ignored"
  [[ -n "${SYSCTL_FILE:-}" && -f "${SYSCTL_FILE:-}" ]] && echo "sysctl : ${SYSCTL_FILE}" || echo "sysctl : missing"
  if [[ -x "$ET" && -n "$IF" ]]; then
    $ET -k "$IF" 2>/dev/null | egrep -i "gro|gso|tso|lro|scatter-gather" | sed -n "1,40p" || true
  fi
  sysctl -n net.core.rmem_default net.core.wmem_default net.core.optmem_max \
             net.core.netdev_max_backlog net.core.somaxconn net.ipv4.udp_mem \
             net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min 2>/dev/null | nl -ba || true
'
UNIT
    systemctl daemon-reload || true
    systemctl enable univ-health.service >/dev/null 2>&1 || true
  else
    warn "[universal-optimize] 检测到非 systemd 环境，跳过健康自检持久化"
  fi
}

status_report() {
  local iface="$1"
  echo "=== 状态报告 ($(date '+%F %T')) ==="
  echo "- 目标网卡：$iface"
  echo "- sysctl 文件：$SYSCTL_FILE"
  sysctl -n net.core.rmem_default net.core.wmem_default net.core.optmem_max \
           net.core.netdev_max_backlog net.core.somaxconn net.ipv4.udp_mem \
           net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min 2>/dev/null | nl -ba || true
  echo
  local ET
  ET=$(command -v ethtool || echo /usr/sbin/ethtool)
  if [[ -x "$ET" ]]; then
    $ET -k "$iface" 2>/dev/null | egrep -i 'gro|gso|tso|lro|scatter-gather' | sed -n '1,60p' || true
  else
    warn "ethtool 不存在，无法显示 offload 细节"
  fi
  echo
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl is-enabled "univ-offload@${iface}.service" 2>/dev/null || true
    systemctl is-active  "univ-offload@${iface}.service" 2>/dev/null || true
    systemctl is-enabled "univ-irqpin@${iface}.service" 2>/dev/null || true
    systemctl is-active  "univ-irqpin@${iface}.service" 2>/dev/null || true
  else
    warn "systemd 不存在，跳过 systemd 服务状态检测"
  fi
}

repair_missing() {
  # 只补缺，不动已有
  [[ -f "$SYSCTL_FILE" ]] || apply_sysctl
  [[ -f "$LIMITS_FILE" ]] || apply_limits
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    [[ -f "$OFFLOAD_UNIT" ]] || apply_offload_unit "$IFACE"
    [[ -f "$IRQPIN_UNIT"  ]] || apply_irqpin_unit "$IFACE"
    [[ -f "$HEALTH_UNIT"  ]] || apply_health_unit
  else
    warn "[universal-optimize] 非 systemd 环境，仅执行即时优化"
  fi
  ok "✅ 缺失项已自动补齐"
}

#------------- main -------------
require_root

IFACE="$(detect_iface || true)"
if [[ -z "$IFACE" ]]; then
  err "[universal-optimize] 无法自动探测网卡，请用 IFACE=xxx 再试"
  exit 1
fi

case "$ACTION" in
  apply)
    pkg_install
    apply_sysctl
    apply_limits
    apply_offload_unit "$IFACE"
    apply_irqpin_unit "$IFACE"
    apply_health_unit
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
  *)
    echo "用法：bash $0 [apply|status|repair]"
    echo "示例：IFACE=ens3 bash $0 apply    # 手动指定网卡"
    exit 1
    ;;
esac
