#!/bin/sh

# 默认开启nat
# nvram
#   zerotier_enabled: 是否启用功能
#   zerotier_client_secret: 客户端密钥，自动生成
#   zerotier_network_id: 网络id，需要手动设置
#   zerotier_moon_name: moon文件的文件名
#   zerotier_moon_content_b64: moon文件的内容，base64后的结果

PROG=/usr/bin/zerotier-one
PROGCLI=/usr/bin/zerotier-cli
PROGIDT=/usr/bin/zerotier-idtool
config_path="/etc/storage/zerotier-one"
network_dir=$config_path/networks.d
moon_dir=$config_path/moons.d

start_zt() {
    enabled=$(nvram get zerotier_enabled)
    if ! [ "$enabled" = "1" ]; then
        logger -t "zerotier" "未开启zerotier功能 (zerotier_enabled)"
        return 0
    fi

    logger -t "zerotier" "开始启动zerotier"

    mkdir -p $config_path
    mkdir -p $network_dir
    mkdir -p $moon_dir

    logger -t "zerotier" "(nvram) zerotier_network_id: 网络id，需要手动设置"
    logger -t "zerotier" "(nvram) zerotier_moon_name: moon文件的文件名"
    logger -t "zerotier" "(nvram) zerotier_moon_content_b64: moon文件的内容，base64后的结果"

    secret_private="$config_path/identity.secret"
    secret_public="$config_path/identity.public"
    client_secret="$(nvram get zerotier_client_secret)"
    if [ -z "$client_secret" ]; then
        logger -t "zerotier" "生成客户端密钥..."
        $PROGIDT generate "$secret_private" "$secret_public" >/dev/null
        if [ $? -ne 0 ]; then
            logger -t "zerotier" "生成客户端密钥失败"
            return 1
        fi
        client_secret="$(cat $secret_private)"
        nvram set zerotier_client_secret="$client_secret"
        nvram commit
    fi

    if [ -n "$client_secret" ]; then
        logger -t "zerotier" "找到客户端密钥"
        echo "$client_secret" >"$secret_private"
        $PROGIDT getpublic "$secret_private" >"$secret_public"
    fi

    moon_name="$(nvram get zerotier_moon_name)"
    moon_content_b64="$(nvram get zerotier_moon_content_b64)"

    if [ -n "$moon_name" ] && [ -n "moon_content_b64" ]; then
        logger -t "zerotier" "找到moon配置"

        # 检测能不能base64 decode
        echo $moon_content_b64 | base64 -d > /dev/null
        if [ $? -ne 0 ]; then
            logger -t "zerotier" "moon内容base64 decode失败"
        else
            echo $moon_content_b64 | base64 -d | cat - > "${moon_dir}/${moon_name}"
            logger -t "zerotier" "已写入文件${moon_dir}/${moon_name}"
        fi
    fi

    network_id=$(nvram get zerotier_network_id)
    if [ -n "$network_id" ]; then
        touch $network_dir/${network_id}.conf
        logger -t "zerotier" "添加网络: ${network_id}"
        $PROG $config_path >/dev/null 2>&1 &
        logger -t "zerotier" "已启动客户端进程"

        enable_nat
    else
        logger -t "zerotier" "未配置网络id (zerotier_network_id)"
    fi

    logger -t "zerotier" "结束启动zerotier"
}

stop_zt() {
    logger -t "zerotier" "开始关闭zerotier"

    disable_nat

    killall zerotier-one
    sleep 2
    killall -9 zerotier-one
    logger -t "zerotier" "已结束客户端进程"
    if [ -d "$config_path" ]; then
        rm -rf $config_path
    fi
    logger -t "zerotier" "结束关闭zerotier"
}

enable_nat() {
    logger -t "zerotier" "开始添加nat配置"

    loopnb=0
    while [ $loopnb -lt 60 ] && [ "$(ifconfig | grep "^zt" | awk '{print $1}')" = "" ]; do
        loopnb=$(expr $loopnb + 1)
        sleep 1
	done

	zt0=$(ifconfig | grep "^zt" | awk '{print $1}')
    if [ -z "$zt0" ]; then
        logger -t "zerotier" "找不到网卡，无法配置转发"
        return 1
    fi

    iptables -A INPUT -i $zt0 -j ACCEPT
	iptables -A FORWARD -i $zt0 -o $zt0 -j ACCEPT
	iptables -A FORWARD -i $zt0 -j ACCEPT
	iptables -t nat -A POSTROUTING -o $zt0 -j MASQUERADE
    logger -t "zerotier" "添加网卡 $zt0 的转发配置"

    loopnb=0
	while [ $loopnb -lt 120 ] && [ "$(ip route | grep "dev $zt0  proto kernel" | awk '{print $1}')" = "" ]; do
        loopnb=$(expr $loopnb + 1)
        sleep 1
    done
	ip_segment=`ip route | grep "dev $zt0  proto kernel" | awk '{print $1}'`
    if [ -z "$ip_segment" ]; then
        logger -t "zerotier" "找不到网段，无法配置转发"
        return 1
    fi

	iptables -t nat -A POSTROUTING -s $ip_segment -j MASQUERADE
    logger -t "zerotier" "添加网段 $ip_segment 的转发配置"

    logger -t "zerotier" "结束添加nat配置"
}

disable_nat() {
    logger -t "zerotier" "开始删除nat配置"

	zt0=$(ifconfig | grep "^zt" | awk '{print $1}')
	ip_segment=`ip route | grep "dev $zt0  proto kernel" | awk '{print $1}'`

    if [ -n "$zt0" ]; then
        iptables -D FORWARD -i $zt0 -j ACCEPT 2>/dev/null
        iptables -D FORWARD -o $zt0 -j ACCEPT 2>/dev/null
        iptables -D FORWARD -i $zt0 -o $zt0 -j ACCEPT
        iptables -D INPUT -i $zt0 -j ACCEPT 2>/dev/null
        iptables -t nat -D POSTROUTING -o $zt0 -j MASQUERADE 2>/dev/null
        logger -t "zerotier" "删除网卡 $zt0 的转发配置"
    fi
    if [ -n "$ip_segment" ]; then
	    iptables -t nat -D POSTROUTING -s $ip_segment -j MASQUERADE 2>/dev/null
        logger -t "zerotier" "删除网段 $ip_segment 的转发配置"
    fi
    logger -t "zerotier" "结束删除nat配置"
}

sleep 2
stop_zt
sleep 2
start_zt

