#!/bin/bash
#功能：
#1. 更新源 安装基本必备的软件
#2. 设置 root密码 备份 sshd_config文件 修改 ssh 端口为 52255
#3. 配置fail2ban 如果有人5次密码错误，IP会被封30分钟
#4. 配置 bbr 加速
#5. 配置swap虚拟内存 以及优化 
#6. 配置上海时区
#7. 检查系统状态以及服务是否正常
#8. 日志轮转

# 出错即退出
set -e

# 参数检查
if [[ $# -ne 2 ]];then
    echo "❌ 用法错误: sudo bash $0 <SSH_PORT> <SWAP_SIZE_MB>"
    exit 1
fi

# ssh 端口
SSH_PORT="$1"
# swap内存大小
SWAP_SIZE_MB="$2"
# ssh配置文件
SSH_CONFIG="/etc/ssh/sshd_config"




# 设置颜色
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

# 1. 更新源 & 安装常用软件
green "[1/8] 更新系统源并安装基础软件..."

apt update -y && apt upgrade -y
apt install -y vim curl wget git ufw htop net-tools lsof unzip fail2ban sudo ca-certificates gnupg lsb-release logrotate

if ! grep -q "^[[:space:]]*alias ll=['\"]" ~/.bashrc; then
    cat >> ~/.bashrc << 'EOF'
# 常用别名
alias ll='ls -lh --color=auto'
alias la='ls -lAh --color=auto'
alias l='ls -CF --color=auto'
EOF
fi
source ~/.bashrc
# if [[ $? -ne 0 ]]; then
#     red "更新系统源并安装基础软件出现错误...请排查"
#     exit 1

# 2. 更改 sshd_config
green "[2/8] 设置 root 密码（请自行输入新密码）..."
passwd root

green "[2/8] 修改 SSH 端口  ..."
cp -a ${SSH_CONFIG} ${SSH_CONFIG}.bak_$(date +%F_%T)

sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" "${SSH_CONFIG}" 
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" "${SSH_CONFIG}"
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" "${SSH_CONFIG}"
# 最后再重启sshd 服务
systemctl restart sshd
# 3. 配置fail2ban
green "[3/8] 配置fail2ban  ..."
cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1800
findtime = 600
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8
banaction = iptables-multiport

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = /var/log/auth.log
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# 4. 启用 bbr
green "[4/8] 启用 bbr加速  ..."
green "
BBR 加速是什么
BBR 是 Google 开发的一种 TCP 拥塞控制算法，全称是 Bottleneck Bandwidth and Round-trip propagation time。

BBR 的作用：
提升网络速度：更有效地利用可用带宽

减少延迟：降低网络传输的延迟

避免拥塞：智能预测网络瓶颈，避免传统算法的过度缓冲

改善体验：特别适合长途网络、高带宽网络环境

传统算法 vs BBR：
传统 TCP：等到数据包丢失才发现拥塞

BBR：主动测量带宽和延迟，提前调整
"
if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null;then
    echo 'tcp_bbr' >> /etc/modules-load.d/modules.conf
fi

if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi

# 使配置生效
sysctl -p

# 5. 配置虚拟内存
green "[5/8]  配置虚拟内存 swap ${SWAP_SIZE_MB}MB ..."
SWAP_FILE="/swapfile"

if [[ -f ${SWAP_FILE} ]]; then
    yellow "Swap 已存在，跳过创建。"
else
    fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

# 优化 swappiness
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf

# 6. 设置上海时区
green "[6/8]  设置时区为 Asia/Shanghai ..."
timedatectl set-timezone Asia/Shanghai

# 7. 检查服务状态
green "[7/8] 检查关键服务状态..."
systemctl is-active ssh && green "✅ SSH 正常" || red "❌ SSH 异常"
systemctl is-active fail2ban && green "✅ Fail2ban 正常" || red "❌ Fail2ban 异常"

# 8. 配置日志轮转
green "[8/8] 配置日志轮转..."
cat > /etc/logrotate.d/custom <<EOF
/var/log/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF
green "日志轮转已配置完成。"

green "\n✅ VPS 初始化完成！"
echo "------------------------------------------"
echo "SSH 端口：${SSH_PORT}"
echo "Fail2ban：已启用 (5次错误封30分钟)"
echo "BBR：已启用"
echo "Swap：${SWAP_SIZE_MB}MB"
echo "时区：上海"
echo "------------------------------------------"
