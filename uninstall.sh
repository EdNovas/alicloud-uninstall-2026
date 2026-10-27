#!/usr/bin/env bash
# ============================================================
# 阿里云监控/安全组件 一键完全卸载
#   - 安骑士 云安全中心 (Aegis / AliYunDun)  —— 支持新版 eBPF LSM 自保护
#   - 云监控 (CloudMonitor / argusagent / CmsGoAgent)
#   - 云助手 (aliyun-service / AssistDaemon)   —— 可选
# 原理：安骑士新版文件被 bpf LSM 锁住，需关闭 bpf 并重启一次才能删。
#       本脚本第一次运行改 GRUB + 装开机自恢复任务 -> 自动重启
#       -> 开机后自动完成删除与还原。全程只手动跑这一次。
# 幂等：可重复运行；无对应组件则自动跳过。
# 仓库：github.com/EdNovas/alicloud-uninstall-2026
# ============================================================
set -u

# ---------------- 可调开关 ----------------
AUTO_REBOOT=true           # 需要重启时自动重启(false 则提示手动 reboot)
UNINSTALL_CLOUDMONITOR=true # 卸载云监控 argusagent
UNINSTALL_AEGIS=true       # 卸载安骑士 云安全中心
UNINSTALL_ASSIST=true      # 卸载云助手。注意：卸后控制台"发命令/重置密码/密钥下发"失效
BLOCK_IP=true              # 防火墙封堵安骑士服务器IP，防止重装/拉回
RESTORE_LSM_REBOOT=false   # 清理后是否再重启一次恢复 bpf LSM(默认否，下次开机自然恢复)
# ------------------------------------------

SELF="/usr/local/sbin/alicloud-uninstall.sh"
RESUME_SVC="/etc/systemd/system/alicloud-uninstall-resume.service"
STATE="/root/.alicloud-uninstall.state"
AEGIS_IPS=(140.205.201.0/28 140.205.201.16/29 140.205.201.32/28 \
           140.205.225.192/29 140.205.225.200/30 140.205.225.184/29 \
           140.205.225.183 140.205.225.206 140.205.225.205 \
           140.205.225.195 140.205.225.204)

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
regrub() { command -v update-grub >/dev/null 2>&1 && update-grub || grub-mkconfig -o /boot/grub/grub.cfg; }
hr() { echo "------------------------------------------------------------"; }

# ===================== 云监控 =====================
remove_cloudmonitor() {
    hr; echo "### 云监控 CloudMonitor / argusagent"
    for svc in cloudmonitor cms_monitor CmsGoAgent; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    [ -f /usr/local/cloudmonitor/cloudmonitorCtl.sh ] && \
        bash /usr/local/cloudmonitor/cloudmonitorCtl.sh uninstall 2>/dev/null || true
    [ -f /etc/init.d/cloudmonitor ] && { /etc/init.d/cloudmonitor stop 2>/dev/null; update-rc.d -f cloudmonitor remove 2>/dev/null; chkconfig --del cloudmonitor 2>/dev/null; } || true
    pkill -9 -f argusagent 2>/dev/null || true
    pkill -9 -f CmsGoAgent 2>/dev/null || true
    pkill -9 -f /usr/local/cloudmonitor 2>/dev/null || true
    # 清理 crontab 拉起任务(老版本会写)
    crontab -l 2>/dev/null | grep -qi cloudmonitor && \
        { crontab -l 2>/dev/null | grep -vi cloudmonitor | crontab -; echo "  已清 root crontab"; } || true
    sed -i '/cloudmonitor/Id' /etc/crontab 2>/dev/null || true
    rm -f /etc/cron.d/cloudmonitor 2>/dev/null || true
    rm -rf /usr/local/cloudmonitor
    rm -f /etc/systemd/system/cloudmonitor.service /usr/lib/systemd/system/cloudmonitor.service /lib/systemd/system/cloudmonitor.service /etc/init.d/cloudmonitor
    find /etc/systemd /usr/lib/systemd /lib/systemd /run/systemd \
         \( -iname 'cloudmonitor*' -o -iname 'cmsgoagent*' \) 2>/dev/null | xargs -r rm -f
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed cloudmonitor 2>/dev/null || true
    echo "  云监控处理完成"
}

# ===================== 云助手 =====================
remove_assist() {
    hr; echo "### 云助手 aliyun-service / AssistDaemon"
    pkill -9 aliyun-service 2>/dev/null || true
    systemctl stop AssistDaemon 2>/dev/null || true; systemctl disable AssistDaemon 2>/dev/null || true
    systemctl stop aliyun.service 2>/dev/null || true; systemctl disable aliyun.service 2>/dev/null || true
    rm -rf /etc/init.d/agentwatch /usr/sbin/aliyun-service /usr/sbin/aliyun-service.backup \
           /usr/sbin/aliyun_installer /etc/systemd/system/aliyun.service \
           /lib/systemd/system/aliyun.service /etc/systemd/system/AssistDaemon.service \
           /usr/local/share/assist-daemon /usr/local/share/aliyun-assist 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    echo "  云助手处理完成"
}

# ===================== 封堵IP =====================
block_ips() {
    hr; echo "### 封堵安骑士服务器IP"
    if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        nft add table inet aegisblock 2>/dev/null || true
        nft 'add chain inet aegisblock input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
        for ip in "${AEGIS_IPS[@]}"; do nft add rule inet aegisblock input ip saddr "$ip" drop 2>/dev/null || true; done
        echo "  已用 nftables 封堵(重启不持久, 需 nft list ruleset > /etc/nftables.conf 保存)"
    elif command -v iptables >/dev/null 2>&1; then
        for ip in "${AEGIS_IPS[@]}"; do iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -I INPUT -s "$ip" -j DROP; done
        echo "  已用 iptables 封堵(重启不持久, 需 iptables-save 保存)"
    else
        echo "  未找到 nft/iptables, 跳过封堵"
    fi
}

# ============ 安骑士：删除残留 + 还原(阶段二) ============
aegis_remove_files() {
    hr; echo "### 安骑士 删除残留 (LSM: $(cat /sys/kernel/security/lsm 2>/dev/null))"
    systemctl stop aegis 2>/dev/null || true
    pkill -9 -f AliYunDun 2>/dev/null || true
    pkill -9 -f /usr/local/aegis 2>/dev/null || true
    for u in uninstall quartz_uninstall; do
        curl -fsSL "http://update.aegis.aliyun.com/download/${u}.sh" -o "/tmp/${u}.sh" 2>/dev/null \
            && bash "/tmp/${u}.sh" 2>/dev/null; rm -f "/tmp/${u}.sh"
    done
    chattr -R -i /usr/local/aegis 2>/dev/null || true
    rm -rf /usr/local/aegis*
    rm -f /etc/systemd/system/aegis.service /lib/systemd/system/aegis.service \
          /etc/init.d/aegis /root/aegis.service.bak
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed aegis 2>/dev/null || true
    [ -d /usr/local/aegis ] && echo "  !! /usr/local/aegis 仍在, 请发 lsattr -d /usr/local/aegis 给我" || echo "  安骑士目录已删除"
}

aegis_restore_grub() {
    if [ -f /root/grub.bak ]; then cp /root/grub.bak /etc/default/grub
    else sed -i -E 's/ ?systemd\.mask=aegis\.service//g; s/ ?lsm=[^"[:space:]]*//g' /etc/default/grub; fi
    regrub
    echo "  GRUB 已还原(bpf LSM 下次开机自然恢复)"
}

# ============ 安骑士：禁用 + 关 bpf + 装自恢复(阶段一) ============
aegis_phase1() {
    hr; echo "### 安骑士 检测到 eBPF 自保护, 准备关闭并重启"
    cp -n /etc/default/grub /root/grub.bak 2>/dev/null || true
    systemctl disable aegis 2>/dev/null || true
    update-rc.d -f aegis remove 2>/dev/null || true
    [ -f /etc/systemd/system/aegis.service ] && mv /etc/systemd/system/aegis.service /root/aegis.service.bak 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    local LSM_NEW ADD
    LSM_NEW="$(cat /sys/kernel/security/lsm | tr ',' '\n' | grep -vx bpf | paste -sd,)"
    ADD="systemd.mask=aegis.service lsm=${LSM_NEW}"
    echo "  去掉 bpf 后 LSM: $LSM_NEW"
    sed -i -E 's/ ?systemd\.mask=aegis\.service//g; s/ ?lsm=[^"[:space:]]*//g' /etc/default/grub
    sed -i -E "s/^(GRUB_CMDLINE_LINUX=\")(.*)(\")/\1\2 ${ADD}\3/" /etc/default/grub
    grep -rn 'GRUB_CMDLINE_LINUX' /etc/default/grub.d/ 2>/dev/null && echo "  !! grub.d 下有 CMDLINE, 可能覆盖, 留意" || true
    regrub
    grep -q 'systemd.mask=aegis.service' /boot/grub/grub.cfg || { echo "!! 参数未写入 grub.cfg, 终止, 把输出发出来排查"; exit 1; }

    install -m 755 "$0" "$SELF" 2>/dev/null || { cp "$0" "$SELF"; chmod 755 "$SELF"; }
    cat > "$RESUME_SVC" <<EOF
[Unit]
Description=Alicloud uninstall resume (aegis phase2)
After=multi-user.target network.target
[Service]
Type=oneshot
ExecStart=$SELF --resume
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable alicloud-uninstall-resume.service
    echo "phase1_done" > "$STATE"
    echo "  已设置开机自恢复, 重启后自动完成删除"
}

aegis_present() { [ -d /usr/local/aegis ] || systemctl list-unit-files 2>/dev/null | grep -qi '^aegis'; }

# ============ 阶段二入口(重启后自动调用) ============
run_phase2() {
    echo "===== 重启后续跑：完成清理 ====="
    [ "$UNINSTALL_CLOUDMONITOR" = true ] && remove_cloudmonitor
    aegis_remove_files
    aegis_restore_grub
    [ "$UNINSTALL_ASSIST" = true ] && remove_assist
    [ "$BLOCK_IP" = true ] && block_ips
    # 撤除自恢复任务
    systemctl disable alicloud-uninstall-resume.service 2>/dev/null || true
    rm -f "$RESUME_SVC" "$SELF" "$STATE"; systemctl daemon-reload 2>/dev/null || true
    final_report
    [ "$RESTORE_LSM_REBOOT" = true ] && { echo "==> 3秒后重启恢复 bpf LSM"; sleep 3; reboot; }
}

final_report() {
    hr; echo "===== 验证(以下应全部无输出) ====="
    echo "-- 安骑士进程:"; ps -ef | grep -v grep | grep -iE 'aegis|AliYunDun' || true
    echo "-- 云监控进程:"; ps -ef | grep -v grep | grep -iE 'argusagent|CmsGoAgent|cloudmonitor' || true
    echo "-- 残留目录:";   ls -d /usr/local/aegis* /usr/local/cloudmonitor 2>/dev/null || true
    echo "-- 相关服务:";   systemctl list-unit-files 2>/dev/null | grep -iE 'aegis|cloudmonitor|aliyun|assist' || true
    hr; echo "==> 全部完成。以上无输出即彻底卸载。"
}

# ==================== 主流程 ====================
# 重启后由自恢复任务带 --resume 进来，或已完成阶段一
if [ "${1:-}" = "--resume" ] || [ -f "$STATE" ]; then
    run_phase2; exit 0
fi

echo "===== 阿里云监控/安全组件 一键卸载 ====="
echo "云监控=$UNINSTALL_CLOUDMONITOR 安骑士=$UNINSTALL_AEGIS 云助手=$UNINSTALL_ASSIST 封IP=$BLOCK_IP 自动重启=$AUTO_REBOOT"

# 1) 云监控：无需重启，先清
[ "$UNINSTALL_CLOUDMONITOR" = true ] && remove_cloudmonitor

# 2) 安骑士：按是否有 eBPF 自保护分流
NEED_REBOOT=false
if [ "$UNINSTALL_AEGIS" = true ]; then
    if aegis_present; then
        if grep -qw bpf /sys/kernel/security/lsm 2>/dev/null; then
            aegis_phase1; NEED_REBOOT=true      # 需重启后续跑
        else
            aegis_remove_files; aegis_restore_grub  # 老版无自保护, 直接删
        fi
    else
        hr; echo "### 安骑士 未安装, 跳过"
    fi
fi

# 3) 若不需要重启, 当场把云助手/封IP做完并收尾
if [ "$NEED_REBOOT" = false ]; then
    [ "$UNINSTALL_ASSIST" = true ] && remove_assist
    [ "$BLOCK_IP" = true ] && block_ips
    final_report
    exit 0
fi

# 4) 需要重启：云助手/封IP 放到重启后的阶段二完成
hr
echo "==> 安骑士自保护已关闭, 需重启一次完成删除。"
if [ "$AUTO_REBOOT" = true ]; then
    echo "   !! 10秒后自动重启, 开机将自动完成剩余清理。确认 VNC 可登录, Ctrl+C 取消。"
    sleep 10; reboot
else
    echo "   确认 VNC 可登录后手动执行: reboot (开机自动完成卸载)"
fi
