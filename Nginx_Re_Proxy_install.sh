#!/bin/bash

set -e  # 遇到錯誤立即停止腳本

# 讓用戶輸入來源網址、目標反向代理網址
read -p "請輸入專案名稱 (如 WordPress): " NAME
FILENAME="${NAME}_PROXY" # 資料夾名稱

read -p "請輸入您的來源網址 (如 http://localhost:8080): " SOURCE_URL
# 檢查來源網址是否以 http 或 https 開頭，如果沒有，則自動加上 http://
if [[ ! "$SOURCE_URL" =~ ^https?:// ]]; then
    SOURCE_URL="http://$SOURCE_URL"
fi

# 讓用戶輸入目標反向代理域名
read -p "請輸入您的目標反向代理域名 (如 IP 或 example.com): " DOMAIN
PROXY_URL="https://$DOMAIN"

# 讓用戶輸入 SSL 證書的有效期限
read -p "請輸入 SSL 證書的有效天數 (默認為 36499): " days
if [[ ! "$days" =~ ^[1-9][0-9]*$ ]] || ((days < 1 || days > 36500)); then
    echo "無效的天數，將使用默認值 36499 天。"
    days=36499
fi

# 安裝 Nginx
sudo apt update && sudo apt install -y nginx

# 建立 SSL 憑證目錄並生成自簽證書 (含SAN)
sudo mkdir -p /opt/SSL

cat <<EOF | sudo tee /opt/SSL/san.cnf
[ req ]
default_bits = 4096
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C = TW
ST = Taiwan
L = Taichung
O = $FILENAME
OU = IT
CN = $DOMAIN

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $DOMAIN
EOF

# 將憑證和私鑰輸出到 /opt/SSL/
sudo openssl req -x509 -newkey rsa:4096 -keyout /opt/SSL/private.key -out /opt/SSL/certificate.crt -days "$days" -nodes -config /opt/SSL/san.cnf -extensions req_ext

# 設置適當的權限
sudo chmod 600 /opt/SSL/private.key
sudo chmod 644 /opt/SSL/certificate.crt

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
echo "證書位置: /opt/SSL"
echo "來源網址: $SOURCE_URL"
echo "反向代理: https://$DOMAIN"
echo -e "\\n-----------------------------"