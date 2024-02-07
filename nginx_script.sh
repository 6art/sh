#!/bin/bash

# 定义存储路径信息的文件
info_file="/home/web/nginx_path_info.txt"

# 检查Nginx是否已经安装
if ! command -v nginx &> /dev/null && ! docker ps -a | grep nginx > /dev/null
then
    echo "Nginx没有安装，请先安装Nginx再运行此脚本。"
    exit 1
fi

# 检查Nginx是否在docker的cgroup中
function is_nginx_in_docker() {
    docker ps -a | grep nginx > /dev/null
}

function is_nginx_running() {
    docker ps | grep nginx > /dev/null
}

function copy_certificates() {
    cp /etc/letsencrypt/live/$DOMAIN_NAME/cert.pem ${host_cert_dir}/${DOMAIN_NAME}_cert.pem || { echo "复制证书失败"; exit 1; }
    cp /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem ${host_cert_dir}/${DOMAIN_NAME}_key.pem || { echo "复制证书失败"; exit 1; }
}

if [[ $EUID -ne 0 ]]; then
   echo "请以root用户运行此脚本" 
   exit 1
fi

if is_nginx_in_docker; then
    if is_nginx_running; then
        echo "Nginx正在Docker容器中运行，一切正常！"
    else
        echo "Nginx在Docker容器中存在，但未运行！"
    fi
    # 检查jq是否已经安装
    if ! command -v jq &> /dev/null
    then
        echo "jq未安装，正在为您安装..."
        sudo apt update
        echo "y" | sudo apt install jq
    fi
    # 获取容器ID
    container_id=$(docker ps -a | grep nginx | awk '{print $1}')
    # 获取nginx配置文件中的ssl_certificate指令
    cert_path=$(docker exec $container_id grep -r "ssl_certificate" /etc/nginx | head -n1 | awk '{print $2}' | tr -d ';')
    # 获取容器的挂载点
    mounts=$(docker inspect $container_id --format '{{ json .Mounts }}' | jq -r '.[] | select(.Destination | startswith("/etc/nginx")) | "\(.Source)\(.Destination)"')
    # 找到证书文件在宿主机上的路径
    host_cert_dir=$(echo "$mounts" | grep -oP '.*(?=/etc/nginx/certs)')
    # 找到网站配置文件在宿主机上的路径
    host_conf_dir=$(echo "$mounts" | grep -oP '.*(?=/etc/nginx/conf.d)')
else
    if is_nginx_running; then
        echo "Nginx正在宿主机上运行，一切正常！"
    else
        echo "Nginx在宿主机上存在，但未运行！"
    fi
    # 获取nginx配置文件中的ssl_certificate指令
    cert_path=$(grep -r "ssl_certificate" /etc/nginx | head -n1 | awk '{print $2}' | tr -d ';')
    # 找到证书文件在宿主机上的路径
    host_cert_dir=$(dirname $cert_path)
    # 找到网站配置文件在宿主机上的路径
    host_conf_dir="/etc/nginx/conf.d"
fi

# 将路径信息存储到文件中
echo "证书目录：$host_cert_dir" > "$info_file"
echo "网站配置文件目录：$host_conf_dir" >> "$info_file"

# 输出路径信息
cat "$info_file"


# 设置默认的电子邮件地址
EMAIL="your@email.com"

# 询问域名
echo "请输入您的域名:"
read DOMAIN_NAME

# 检查域名是否已经解析到本机IP
DOMAIN_IP=$(dig +short $DOMAIN_NAME)
LOCAL_IP=$(hostname -I | awk '{print $1}')
if [ "$DOMAIN_IP" != "$LOCAL_IP" ]; then
    echo ""
    echo -e "\033[33m提示：域名尚未解析到本机IP。如果您使用了CDN服务（如Cloudflare），这可能是正常的，因为CDN会将流量引导到其自己的服务器，而不是直接到您的服务器。\033[0m"
else
    echo ""
    echo -e "\033[32m域名已成功解析到本机IP。\033[0m"
fi

# 检查是否已经存在该域名的证书
if [ -f "${host_cert_dir}/${DOMAIN_NAME}_cert.pem" ] && [ -f "${host_cert_dir}/${DOMAIN_NAME}_key.pem" ]; then
    echo ""
    echo "已存在域名${DOMAIN_NAME}的证书，是否需要更新证书？（默认不更新，输入'y'或'n'表示更新或不更新）:"
    read RENEW_CERT
    RENEW_CERT=${RENEW_CERT:-n}
    RENEW_CERT=$(echo $RENEW_CERT | tr '[:upper:]' '[:lower:]')
else
    RENEW_CERT="y"
fi

# 询问反向代理的地址和端口
while true; do
    echo "请输入您的反向代理地址和端口（例如：http://172.18.18.18:9000）:"
    read PROXY_PASS

    # 检查反向代理地址的格式
    if [[ ! "$PROXY_PASS" =~ ^(http|https)://[^/]+:[0-9]+$ ]]; then
        echo -e "\033[33m警告：反向代理地址的格式不正确。\033[0m"
        echo ""
    fi

    # 检查反向代理地址的端口是否在合理范围内
    PROXY_PORT=$(echo $PROXY_PASS | cut -d ':' -f 3)
    if ((PROXY_PORT < 1 || PROXY_PORT > 65535)); then
        echo ""
        echo -e "\033[33m警告：反向代理地址的端口不在合理范围内（1-65535）。\033[0m"
    fi

    # 如果反向代理地址和端口都正确，打印一行祝贺信息
    if [[ "$PROXY_PASS" =~ ^(http|https)://[^/]+:[0-9]+$ ]] && ((PROXY_PORT >= 1 && PROXY_PORT <= 65535)); then
        echo ""
        echo -e "\033[32m反向代理地址和端口检查通过。\033[0m"
        break
    fi

    echo ""
    echo "是否要重新输入反向代理地址和端口？（默认是，输入'n'表示不重新输入）:"
    read REENTER
    REENTER=${REENTER:-y}
    REENTER=$(echo $REENTER | tr '[:upper:]' '[:lower:]')
    if [ "$REENTER" = "n" ]; then
        break
    fi
done

# 询问客户端最大请求体大小
echo "请输入客户端最大请求体大小（默认值：1000，如果自定义请输入如2000这样的值，回车使用默认值）:"
read CLIENT_MAX_BODY_SIZE
CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-1000}

# 询问是否启用WebSocket
echo "是否启用WebSocket（默认不启用，输入'y'或'n'表示启用或不启用）:"
read ENABLE_WEBSOCKET
ENABLE_WEBSOCKET=${ENABLE_WEBSOCKET:-n}
ENABLE_WEBSOCKET=$(echo $ENABLE_WEBSOCKET | tr '[:upper:]' '[:lower:]')

# 询问是否启用HTTP/2
echo "是否启用HTTP/2（默认不启用，输入'y'或'n'表示启用或不启用）:"
read ENABLE_HTTP2
ENABLE_HTTP2=${ENABLE_HTTP2:-n}
ENABLE_HTTP2=$(echo $ENABLE_HTTP2 | tr '[:upper:]' '[:lower:]')

# 申请证书
if [ "$RENEW_CERT" = "y" ]; then
    certbot certonly --standalone -d $DOMAIN_NAME --email $EMAIL --agree-tos --no-eff-email --force-renewal
    if [ $? -ne 0 ]; then
        echo "申请证书失败"
        exit 1
    fi
    # 复制证书
    copy_certificates
fi

# 创建Nginx配置
echo "
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;
    return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl" > ${host_conf_dir}/${DOMAIN_NAME}.conf || { echo "创建Nginx配置失败"; exit 1; }

if [ "$ENABLE_HTTP2" = "y" ]; then
    echo " http2;" >> ${host_conf_dir}/${DOMAIN_NAME}.conf
else
    echo ";" >> ${host_conf_dir}/${DOMAIN_NAME}.conf
fi

echo "  server_name $DOMAIN_NAME;

  ssl_certificate ${host_cert_dir}/${DOMAIN_NAME}_cert.pem;
  ssl_certificate_key ${host_cert_dir}/${DOMAIN_NAME}_key.pem;

  location / {
      proxy_set_header   X-Real-IP \$remote_addr;
      proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header   Host \$host;
      proxy_pass         $PROXY_PASS;
      proxy_http_version 1.1;" >> ${host_conf_dir}/${DOMAIN_NAME}.conf

if [ "$ENABLE_WEBSOCKET" = "y" ]; then
    echo "      proxy_set_header   Upgrade \$http_upgrade;
      proxy_set_header   Connection \"upgrade\";" >> ${host_conf_dir}/${DOMAIN_NAME}.conf
fi

echo "  }
  client_max_body_size ${CLIENT_MAX_BODY_SIZE}m;
}" >> ${host_conf_dir}/${DOMAIN_NAME}.conf || { echo "创建Nginx配置失败"; exit 1; }

# 定义一个函数来显示日志
show_logs() {
    if is_nginx_in_docker; then
        output=$(docker exec $container_id nginx -t 2>&1)
        echo -e "\e[33m以下是使用 'docker exec $container_id nginx -t' 命令打印的错误信息：\e[0m"
        echo ""
        echo "$output"
        echo ""
    else
        output=$(nginx -t 2>&1)
        echo -e "\e[33m以下是使用 'nginx -t' 命令打印的错误信息：\e[0m"
        echo ""
        echo "$output"
        echo ""
    fi
    sleep 3
    if [[ $output == *"Error response from daemon: Container"* && $output == *"is restarting, wait until the container is running"* ]]; then
        sleep 3
        echo -e "\e[33m错误分析：Nginx已等待重启足够长的时间，但问题并非出在等待。请仔细查看上述错误日志并检查Nginx的配置文件。\e[0m"
        echo ""
    fi
    echo -e "\e[36m当前nginx在docker中运行,您可以在命令行输入\e[0m" 
    echo -e "\e[36m'docker logs $container_id'(Nginx的容器ID)来查看Docker日志;\e[0m"
    sleep 3
    if is_nginx_in_docker; then
        echo ""
    else
        echo -e "\e[36m当前nginx直接在宿主机上运行,\e[0m"
        echo -e "\e[36m日志文件路径为“/var/log/nginx/error.log”,可用cat命令查看。\e[0m"  
        echo ""
        sleep 3
    fi
    echo -e "\e[32m我也可以协助打印日志内容。\e[0m"
    echo -e "\e[32m注意：我只在Shell中输出日志最后30行，避免覆盖掉屏幕所有内容。\e[0m"
    echo -e "\e[32m如果您想查看日志，请输入y并按回车键。\e[0m"
    echo -e "\e[32m如果您不想查看日志，请输入n或直接按回车键。\e[0m"
    echo -e "\e[32m您也可以自行查看日志,方法已在上面说明。\e[0m"
    echo ""
    sleep 3
    while true; do
        read -p "请输入您的选择" user_input
        if [ "$user_input" = "y" ]; then
            if is_nginx_in_docker; then
                echo "以下是使用 'docker logs $container_id | tail -n 30' 命令打印的Docker日志(等待5秒）:"
                sleep 5
                docker logs $container_id | tail -n 30
            else
                echo "以下是使用 'tail -n 30 /var/log/nginx/error.log' 命令打印的Nginx日志(等待5秒）:"
                sleep 5
                tail -n 30 /var/log/nginx/error.log
            fi
            break
        elif [ "$user_input" = "n" ] || [ -z "$user_input" ]; then
            break
        else
            echo "无效的输入，请输入y或n。"
        fi
    done
    echo ""
    echo -e "\e[34m请不要气馁,你完全有能力解决这个问题,加油!\e[0m"
}
#注释：\e[33m：黄色  \e[36m：青色  \e[32m：绿色  \e[34m：蓝色

# 重启Nginx
if is_nginx_in_docker; then
    if docker start $container_id; then
        echo -e "\033[32m恭喜！Nginx已成功启动。\033[0m"
    else
        echo "启动Nginx失败。请检查Docker日志以获取更多信息。"
        show_logs
        exit 1
    fi
else
    if service nginx start; then
        echo -e "\033[32m恭喜！Nginx已成功启动。\033[0m"
    else
        echo "启动Nginx失败。请检查Nginx的配置文件是否正确，或者查看Nginx的错误日志以获取更多信息。"
        show_logs
        exit 1
    fi
fi

# 检查Nginx是否已开始运行
max_attempts=5
attempts=0
while [ $attempts -lt $max_attempts ]; do
    if curl --output /dev/null --silent --head --fail http://localhost; then
        echo -e "\033[32mNginx已成功启动并且可以正常响应HTTP请求。\033[0m"
        break
    else
        echo "Nginx还未开始运行，等待一会儿..."
        sleep 1.5
        attempts=$((attempts+1))
    fi
done

if [ $attempts -eq $max_attempts ]; then
    echo -e "\033[33m警告：Nginx已成功启动，但没有正确运行。\033[0m"
    show_logs
    exit 1
fi

echo "操作完成！"
