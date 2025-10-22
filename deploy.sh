#!/bin/bash

# ==========================
# Safe Auto-Deployment Script
# ==========================

set -e

LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i "$LOGFILE") 2>&1

# Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}=== DEPLOYMENT STARTED ===${NC}"

# --- Prompt for User Inputs ---
read -p "Enter GitHub repository URL: " REPO_URL
read -p "Enter Personal Access Token: " TOKEN
read -p "Enter Branch name: " BRANCH
read -p "Enter SSH username: " SSH_USER
read -p "Enter Server IP address: " SSH_HOST
read -p "Enter SSH port [default 22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
read -p "Enter SSH key path: " SSH_KEY

# --- Parse repo name ---
REPO_NAME=$(basename -s .git "$REPO_URL")

# --- Clone or Pull Repository ---
if [ -d "$REPO_NAME/.git" ]; then
  echo -e "${YELLOW}[INFO] Repository exists. Pulling latest changes...${NC}"
  cd "$REPO_NAME" && git pull origin "$BRANCH" && cd ..
else
  echo -e "${GREEN}[INFO] Cloning repository...${NC}"
  GIT_ASKPASS_SCRIPT=$(mktemp)
  echo "echo $TOKEN" > "$GIT_ASKPASS_SCRIPT"
  chmod +x "$GIT_ASKPASS_SCRIPT"
  GIT_ASKPASS=$GIT_ASKPASS_SCRIPT git clone -b "$BRANCH" "https://$TOKEN@${REPO_URL#https://}" "$REPO_NAME"
  rm "$GIT_ASKPASS_SCRIPT"
fi

# --- Test SSH connectivity ---
echo -e "${YELLOW}[INFO] Testing SSH connectivity...${NC}"
if ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "echo connected" >/dev/null 2>&1; then
  echo -e "${GREEN}[INFO] SSH connection successful!${NC}"
else
  echo -e "${RED}[ERROR] SSH connection failed. Exiting.${NC}"
  exit 1
fi

# --- Copy Files (no rsync, use scp + tar) ---
echo -e "${YELLOW}[INFO] Copying files to remote server (excluding .git)...${NC}"
tar --exclude='.git' -czf "$REPO_NAME.tar.gz" "$REPO_NAME"

scp -i "$SSH_KEY" -P "$SSH_PORT" "$REPO_NAME.tar.gz" "$SSH_USER@$SSH_HOST:~/" || {
  echo -e "${RED}[ERROR] File transfer failed.${NC}"
  exit 1
}

ssh -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<EOF
set -e
echo "[REMOTE] Extracting project files..."
rm -rf ~/$REPO_NAME
mkdir -p ~/$REPO_NAME
tar -xzf "$REPO_NAME.tar.gz" -C ~/
rm -f "$REPO_NAME.tar.gz"
EOF

rm -f "$REPO_NAME.tar.gz"

# --- Build and Run Docker ---
echo -e "${YELLOW}[INFO] Building Docker image and starting container...${NC}"
ssh -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<EOF
set -e
cd ~/$REPO_NAME

echo "[REMOTE] Building Docker image..."
docker build -t myapp .

echo "[REMOTE] Stopping old container..."
docker stop myapp >/dev/null 2>&1 || true
docker rm myapp >/dev/null 2>&1 || true

echo "[REMOTE] Starting new container on port 8080..."
docker run -d -p 8080:80 --name myapp myapp

echo "[REMOTE] Checking running containers..."
docker ps --filter "name=myapp"
EOF

# --- Configure Nginx Reverse Proxy ---
echo -e "${YELLOW}[INFO] Configuring Nginx reverse proxy...${NC}"
ssh -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
if [ ! -f /etc/nginx/sites-available/default ]; then
    echo "[WARN] Nginx may not be installed or accessible."
else
    echo "[REMOTE] Updating Nginx config..."
    cat <<NGINXCONF > ~/nginx_default.conf
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINXCONF

    # Try moving config if possible (no sudo assumption)
    if [ -w /etc/nginx/sites-available/ ]; then
        mv ~/nginx_default.conf /etc/nginx/sites-available/default
        nginx -t && systemctl reload nginx
    else
        echo "[WARN] No permission to modify Nginx config; skipping reload."
    fi
fi
EOF

# --- Health Check ---
echo -e "${YELLOW}[INFO] Checking app response...${NC}"
ssh -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<EOF
curl -I http://localhost:8080 || echo "[WARN] Could not reach app internally."
EOF

echo -e "${GREEN}=== DEPLOYMENT COMPLETE ===${NC}"
echo "Check your app at: http://$SSH_HOST"
echo "Logs saved to: $LOGFILE"