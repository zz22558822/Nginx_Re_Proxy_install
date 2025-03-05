#!/bin/bash

set -e

# 函數：驗證 URL
validate_url() {
  local url="$1"
  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "錯誤：URL 必須以 http:// 或 https:// 開頭。"
    return 1
  fi
  # 可以添加更嚴格的 URL 格式檢查，例如使用 grep 或正規表達式
  return 0
}

# 函數：安裝 Nginx
install_nginx() {
  echo "正在安裝 Nginx..."
  sudo apt update && sudo apt install -y nginx
  if [ $? -ne 0 ]; then
    echo "錯誤：Nginx 安裝失敗。"
    exit 1
  fi
  echo "Nginx 安裝完成。"
}

# 函數：生成 SSL 證書
generate_ssl_certificate() {
  local domain="$1"
  local days="$2"
  echo "正在生成 SSL 證書..."
  sudo mkdir -p /opt/SSL
  sudo openssl req -x509 -newkey rsa:4096 -keyout /opt/SSL/private.key -out /opt/SSL/certificate.crt -days "$days" -nodes -subj "/CN=$domain"
  if [ $? -ne 0 ]; then
    echo "錯誤：SSL 證書生成失敗。"
    exit 1
  fi
  sudo chmod 600 /opt/SSL/private.key
  sudo chmod 644 /opt/SSL/certificate.crt
  echo "SSL 證書生成完成。"
}

# 函數:確認輸入天數是否正確
validate_days(){
  local days="$1"
  if [[ ! "$days" =~ ^[1-9][0-9]*$ ]] || ((days < 1 || days > 36500)); then
    return 1
  else
    return 0
  fi
}

# 主程式
read -p "請輸入專案名稱 (如 WordPress): " NAME
FILENAME="${NAME}_PROXY"

read -p "請輸入您的來源網址 (如 http://localhost:8080): " SOURCE_URL
if ! validate_url "$SOURCE_URL"; then
  exit 1
fi

read -p "請輸入您的目標反向代理域名 (如 IP 或 example.com): " DOMAIN

read -p "請輸入 SSL 證書的有效天數 (默認為 36499): " days
if validate_days "$days"; then
    echo "天數驗證通過"
else
  echo "無效的天數，將使用默認值 36499 天。"
  days=36499
fi

install_nginx
generate_ssl_certificate "$DOMAIN" "$days"

# 配置 Nginx
sudo tee /etc/nginx/sites-available/"$FILENAME" <<EOF

# 使用 map 指令來根據 X-Forwarded-Proto 設置變量
map \$http_x_forwarded_proto \$redirect_https {
    default 1;
    https 0;
    http 1;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /opt/SSL/certificate.crt;
    ssl_certificate_key /opt/SSL/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass $SOURCE_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name $DOMAIN;

    # 只有當需要重定向時才進行 HTTPS 重定向
    if (\$redirect_https) {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# 檢查並刪除已存在的符號連結
if [ -L "/etc/nginx/sites-enabled/$FILENAME" ]; then
    echo "檔案已存在，正在刪除舊的符號連結..."
    sudo rm -f /etc/nginx/sites-enabled/"$FILENAME"
fi

# 建立新的符號連結
sudo ln -s /etc/nginx/sites-available/"$FILENAME" /etc/nginx/sites-enabled/

# 刪除預設的符號連結
sudo rm -f /etc/nginx/sites-enabled/default

# 檢查 Nginx 設定並重新啟動
sudo nginx -t
sudo systemctl restart nginx

echo -e "\\n-----------------------------\\n"
echo "證書效期: $days 天"
echo "來源網址: $SOURCE_URL"
echo "反向代理: https://$DOMAIN"
echo -e "\\n-----------------------------"