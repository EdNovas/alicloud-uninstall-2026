#!/usr/bin/env bash
# ============================================================
# 阿里云云安全中心 (安骑士 Aegis / AliYunDun) 完全卸载 —— 一键版
# 适配新版 eBPF LSM 自保护客户端 (aegis_12_93 等)。
# 原理：第一次运行改 GRUB 关闭 bpf LSM 并装自恢复任务 -> 自动重启
#       -> 开机后自动完成删除并还原 GRUB。全程只需手动跑这一次。
# 幂等：可重复运行。
# ============================================================
set -u

# ---------- 可调开关 ----------
AUTO_REBOOT=true          # 第一阶段结束后自动重启（false 则提示你手动 reboot）
UNINSTALL_ASSIST=true     # 连云助手(aliyun-service/AssistDaemon)一起卸。
                          # 注意：卸了控制台"发送命令/重置密码/密钥下发"会失效。
BLOCK_IP=true             # 用防火墙封堵安骑士服务器IP，防止被重装/拉回。
RESTORE_LSM_REBOOT=false  # 清理完成后再重启一次以恢复 bpf LSM。默认否(下次开机自然恢复)。
# ------------------------------

SELF="/usr/local/sbin/aegis-uninstall.sh"
RESUME_SVC="/etc/systemd/system/aegis-uninstall-resume.service"
STATE="/root/.aegis-uninstall.state"
AEGIS_IPS=(140.205.201.0/28 140.205.201.16/29 140.205.201.32/28 \
           140.205.225.192/29 140.205.225.200/30 140.205.225.184/29 \
           140.205.225.183 140.205.225.206 140.205.225.205 \
           140.205.225.195 140.205.225.204)

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

regrub() { command -v update-grub >/dev/null 2>&1 && update-grub || grub-mkconfig -o /boot/grub/grub.cfg; }

block_ips() {
    if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        nft add table inet aegisblock 2>/dev/null || true
        nft 'add chain inet aegisblock input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
        for ip in "${AEGIS_IPS[@]}"; do nft add rule inet aegisblock input ip saddr "$ip" drop 2>/dev/null || true; done
        echo "   已用 nftables 封堵安骑士IP"
    elif command -v iptables >/dev/null 2>&1; then
        for ip in "${AEGIS_IPS[@]}"; do iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -I INPUT -s "$ip" -j DROP; done
        echo "   已用 iptables 封堵安骑士IP"
    fi
}

uninstall_assist() {
    echo "==> 卸载云助手 / AssistDaemon"
    pkill -9 aliyun-service 2>/dev/null || true
    systemctl stop AssistDaemon 2>/dev/null || true; systemctl disable AssistDaemon 2>/dev/null || true
    rm -rf /etc/init.d/agentwatch /usr/sbin/aliyun-service /usr/sbin/aliyun-service.backup \
           /usr/sbin/aliyun_installer /etc/systemd/system/aliyun.service \
           /lib/systemd/system/aliyun.service /etc/systemd/system/AssistDaemon.service \
           /usr/local/share/assist-daemon 2>/dev/null || true
}

# ========== 阶段二：删除 + 还原（重启后由自恢复任务调用） ==========
phase2() {
    echo "===== 阶段二：删除残留并还原 ====="
    echo "-- 当前 LSM: $(cat /sys/kernel/security/lsm)"

    echo "==> 停服务、杀进程"
    systemctl stop aegis 2>/dev/null || true
    pkill -9 -f AliYunDun 2>/dev/null || true
    pkill -9 -f /usr/local/aegis 2>/dev/null || true

    echo "==> 跑官方卸载脚本(若可用)"
    for u in uninstall quartz_uninstall; do
        curl -fsSL "http://update.aegis.aliyun.com/download/${u}.sh" -o "/tmp/${u}.sh" 2>/dev/null \
            && bash "/tmp/${u}.sh" 2>/dev/null; rm -f "/tmp/${u}.sh"
    done

    echo "==> 去属性并删除目录"
    chattr -R -i /usr/local/aegis 2>/dev/null || true
    rm -rf /usr/local/aegis*
    rm -f /etc/systemd/system/aegis.service /lib/systemd/system/aegis.service \
          /etc/init.d/aegis /root/aegis.service.bak
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed aegis 2>/dev/null || true

    [ "$UNINSTALL_ASSIST" = true ] && uninstall_assist
    [ "$BLOCK_IP" = true ] && { echo "==> 封堵安骑士IP"; block_ips; }

    echo "==> 还原 GRUB"
    if [ -f /root/grub.bak ]; then cp /root/grub.bak /etc/default/grub
    else sed -i -E 's/ ?systemd\.mask=aegis\.service//g; s/ ?lsm=[^"[:space:]]*//g' /etc/default/grub; fi
    regrub

    echo "==> 撤除自恢复任务"
    systemctl disable aegis-uninstall-resume.service 2>/dev/null || true
    rm -f "$RESUME_SVC" "$SELF"; systemctl daemon-reload 2>/dev/null || true
    rm -f "$STATE"

    echo
    echo "===== 验证（下面应全部无输出）====="
    echo "-- 进程:"; ps -ef | grep -v grep | grep -iE 'aegis|AliYunDun' || true
    echo "-- 目录:"; ls -d /usr/local/aegis* 2>/dev/null || true
    echo "-- 服务:"; systemctl list-unit-files 2>/dev/null | grep -i aegis || true
    echo
    if [ -d /usr/local/aegis ]; then
        echo "!! /usr/local/aegis 仍在，发我: lsattr -d /usr/local/aegis"
    else
        echo "==> 安骑士已彻底卸载完成。"
    fi
    if [ "$RESTORE_LSM_REBOOT" = true ]; then echo "==> 3 秒后重启以恢复 bpf LSM..."; sleep 3; reboot; fi
}

# ========== 阶段一：禁用 + 关 bpf LSM + 装自恢复 ==========
phase1() {
    echo "===== 阶段一：禁用自保护并准备重启 ====="
    cp -n /etc/default/grub /root/grub.bak 2>/dev/null || true

    echo "==> 禁用/屏蔽 aegis 服务"
    systemctl disable aegis 2>/dev/null || true
    update-rc.d -f aegis remove 2>/dev/null || true
    [ -f /etc/systemd/system/aegis.service ] && mv /etc/systemd/system/aegis.service /root/aegis.service.bak 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    local LSM_NEW ADD
    LSM_NEW="$(cat /sys/kernel/security/lsm | tr ',' '\n' | grep -vx bpf | paste -sd,)"
    ADD="systemd.mask=aegis.service lsm=${LSM_NEW}"
    echo "==> 去掉 bpf 后的 LSM: $LSM_NEW"

    sed -i -E 's/ ?systemd\.mask=aegis\.service//g; s/ ?lsm=[^"[:space:]]*//g' /etc/default/grub
    sed -i -E "s/^(GRUB_CMDLINE_LINUX=\")(.*)(\")/\1\2 ${ADD}\3/" /etc/default/grub
    grep -rn 'GRUB_CMDLINE_LINUX' /etc/default/grub.d/ 2>/dev/null \
        && echo "   !! grub.d 下有 CMDLINE，可能覆盖，留意" || true
    regrub

    grep -q 'systemd.mask=aegis.service' /boot/grub/grub.cfg \
        || { echo "!! 参数未写入 grub.cfg，终止，把输出发出来排查"; exit 1; }

    echo "==> 安装开机自恢复任务（重启后自动跑阶段二）"
    install -m 755 "$0" "$SELF" 2>/dev/null || cp "$0" "$SELF"
    chmod 755 "$SELF"
    cat > "$RESUME_SVC" <<EOF
[Unit]
Description=Aegis uninstall resume (phase2)
After=multi-user.target network.target
[Service]
Type=oneshot
ExecStart=$SELF --resume
RemainAfterExit=no
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable aegis-uninstall-resume.service

    echo "phase1_done" > "$STATE"
    echo
    echo "==> 阶段一完成，已设置重启后自动清理。"
    if [ "$AUTO_REBOOT" = true ]; then
        echo "   !! 10 秒后自动重启。确认轻量控制台 VNC 能登录，Ctrl+C 可取消。"
        sleep 10; reboot
    else
        echo "   确认 VNC 可登录后手动执行： reboot （开机后会自动完成卸载）"
    fi
}

# ---------- 入口：判断阶段 ----------
if [ "${1:-}" = "--resume" ] || [ -f "$STATE" ] || ! grep -qw bpf /sys/kernel/security/lsm 2>/dev/null; then
    # bpf 已不在 LSM，或已完成阶段一 -> 走删除
    phase2
elif [ -d /usr/local/aegis ] || systemctl list-unit-files 2>/dev/null | grep -qi '^aegis'; then
    phase1
else
    echo "未检测到安骑士(/usr/local/aegis 与 aegis 服务均不存在)，无需卸载。"
fi
