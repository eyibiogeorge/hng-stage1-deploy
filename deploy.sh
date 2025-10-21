#!/bin/bash
# =========================================================
# Stage 1 DevOps Project - Automated Deployment Script
# =========================================================

set -e
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[ERROR] Something failed. Check $LOG_FILE for details." >&2' ERR

echo "============================================"
echo "[INFO] Starting Automated Deployment Script"
echo "============================================"

# === 1. Collect User Inputs ===
read -p "Enter GitHub Repository URL (e.g. https://github.com/username/repo.git): " GIT_URL
#GIT_URL=${GIT_URL:-https://github.com/Sandraolis/deployment-project.git}

read -p "Enter GitHub Personal Access Token (press Enter to skip if public): " -s GIT_TOKEN
echo

read -p "Enter branch name (press Enter to auto-detect): " BRANCH

read -p "Enter remote SSH username: " SSH_USER
read -p "Enter remote host IP or DNS: " SSH_HOST
# read -p "Enter SSH port (default: 22): " SSH_PORT
#SSH_PORT=${SSH_PORT:-22}
SSH_PORT="22"

# Inject token if provided
if [ -n "$GIT_TOKEN" ]; then
    GIT_URL=$(echo "$GIT_URL" | sed "s#https://#https://$GIT_TOKEN@#")
fi

echo "[INFO] Git: $GIT_URL | Branch: ${BRANCH:-auto-detect}"
echo "[INFO] Target Server: $SSH_USER@$SSH_HOST:$SSH_PORT"

# === 2. Validate SSH Connectivity ===
echo "[INFO] Checking SSH connectivity..."
if ssh -i ~/Desktop/hng/hng-stage1-deploy/hng-kp.pem \
       -o BatchMode=yes \
       -o ConnectTimeout=10 \
       -o StrictHostKeyChecking=no \
       -p 22 ubuntu@54.82.30.68 "echo connected" >/dev/null 2>&1; then
    echo "[INFO] SSH connection successful!"
else
    echo "[ERROR] SSH connection failed. Exiting."
    exit 1
fi


# === 3. Clone or Update Repo Locally ===
REPO_NAME=$(basename -s .git "$GIT_URL")

if [ -d "$REPO_NAME/.git" ]; then
    echo "[INFO] Repository exists. Pulling latest changes..."
    cd "$REPO_NAME"
    if [ -z "$BRANCH" ]; then
        BRANCH=$(git remote show origin | awk '/HEAD branch/ {print $NF}')
        echo "[INFO] Detected default branch: $BRANCH"
    fi
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
    git pull origin "$BRANCH"
    cd ..
else
    echo "[INFO] Cloning repository..."
    if [ -z "$BRANCH" ]; then
        DEFAULT_BRANCH=$(git ls-remote --symref "$GIT_URL" HEAD 2>/dev/null | grep 'ref:' | awk '{print $2}' | sed 's#refs/heads/##')
        BRANCH=${DEFAULT_BRANCH:-main}
        echo "[INFO] Auto-detected default branch: $BRANCH"
    fi
    git clone -b "$BRANCH" "$GIT_URL"
fi

# === 4. Transfer Files to Remote Server ===
echo "[INFO] Copying files to remote server..."
scp -P "$SSH_PORT" -r "$REPO_NAME" "$SSH_USER@$SSH_HOST:~/"

# === 5. Server Preparation ===
echo "[INFO] Preparing remote server (Docker + Nginx)..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
echo "[REMOTE] Updating packages..."
sudo apt-get update -y

echo "[REMOTE] Installing Docker..."
sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo usermod -aG docker $USER

echo "[REMOTE] Installing Nginx..."
sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
EOF

# === 6. Docker Deployment (Idempotent) ===
echo "[INFO] Deploying Docker container..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<EOF
set -e
cd ~/$REPO_NAME

if sudo docker ps -a --format '{{.Names}}' | grep -q "myapp"; then
    echo "[REMOTE] Stopping old container..."
    sudo docker stop myapp || true
    sudo docker rm myapp || true
fi

echo "[REMOTE] Building Docker image..."
sudo docker build -t myapp .

echo "[REMOTE] Starting container on port 8080..."
sudo docker run -d --name myapp -p 8080:80 myapp
EOF

# === 7. Configure Nginx Reverse Proxy ===
echo "[INFO] Configuring Nginx reverse proxy..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
sudo bash -c 'cat > /etc/nginx/sites-available/default <<NGINXCONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINXCONF'

sudo nginx -t
sudo systemctl reload nginx
EOF

# === 8. Deployment Validation ===
echo "[INFO] Running deployment validation..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
echo "[REMOTE] Checking Docker container..."
sudo docker ps | grep myapp && echo "[REMOTE] Docker container running."

echo "[REMOTE] Checking Nginx service..."
sudo systemctl status nginx | grep active && echo "[REMOTE] Nginx is active."

echo "[REMOTE] Checking app response..."
curl -I http://localhost | grep "200 OK" && echo "[REMOTE] Application responding successfully."
EOF

# === 9. Cleanup ===
echo "[INFO] Cleaning up Docker unused resources..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "sudo docker system prune -f >/dev/null 2>&1 || true"

echo "[SUCCESS] Deployment completed successfully!"
echo "[INFO] Log file: $LOG_FILE"