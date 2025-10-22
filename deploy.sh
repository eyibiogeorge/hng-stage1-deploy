#!/bin/bash

set -euo pipefail

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "Error occurred at line $LINENO. Exiting."; exit 99' ERR

function log() {
    echo "[INFO] $1"
}

function error_exit() {
    echo "[ERROR] $1"
    exit "$2"
}

# 1. Collect Parameters
read -rp "Git Repository URL: " REPO_URL
[[ -z "$REPO_URL" ]] && error_exit "Repository URL is required." 1

read -rp "Personal Access Token (PAT): " PAT
[[ -z "$PAT" ]] && error_exit "PAT is required." 2

read -rp "Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -rp "Remote SSH Username: " SSH_USER
[[ -z "$SSH_USER" ]] && error_exit "SSH username is required." 3

read -rp "Remote Server IP: " SERVER_IP
[[ -z "$SERVER_IP" ]] && error_exit "Server IP is required." 4

read -rp "SSH Key Path: " SSH_KEY
[[ ! -f "$SSH_KEY" ]] && error_exit "SSH key not found at $SSH_KEY." 5

read -rp "Application internal port (e.g., 3000): " APP_PORT
[[ -z "$APP_PORT" ]] && error_exit "Application port is required." 6

# 2. Clone or Pull Repository
REPO_NAME=$(basename "$REPO_URL" .git)
if [[ -d "$REPO_NAME" ]]; then
    log "Repository exists. Pulling latest changes..."
    cd "$REPO_NAME" || error_exit "Failed to enter repo directory." 7
    git pull origin "$BRANCH"
else
    log "Cloning repository..."
    git clone "https://${PAT}@${REPO_URL#https://}" || error_exit "Git clone failed." 8
    cd "$REPO_NAME" || error_exit "Failed to enter repo directory." 9
fi

git checkout "$BRANCH" || error_exit "Failed to switch to branch $BRANCH." 10

# 3. Verify Docker setup
[[ -f "Dockerfile" || -f "docker-compose.yml" ]] || error_exit "No Dockerfile or docker-compose.yml found." 11
log "Docker configuration found."

# 4. SSH Connectivity Check
log "Checking SSH connectivity..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo SSH connection successful" || error_exit "SSH connection failed." 12

# 5. Prepare Remote Environment
log "Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
sudo apt update
sudo apt install -y docker.io docker-compose nginx curl
sudo usermod -aG docker \$USER
sudo systemctl enable docker nginx
sudo systemctl start docker nginx
docker --version
nginx -v
EOF

# 6. Deploy Dockerized Application
log "Creating remote project directory..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "mkdir -p ~/deploy_temp/$REPO_NAME"

log "Transferring project files using scp..."
scp -i "$SSH_KEY" -r . "$SSH_USER@$SERVER_IP:~/deploy_temp/$REPO_NAME"

log "Deploying containers..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
cd ~/deploy_temp/$REPO_NAME
docker-compose down || true
docker-compose up -d --build
sleep 5
docker ps
EOF

# 7. Configure Nginx
NGINX_CONF="/etc/nginx/sites-available/$REPO_NAME"
log "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
sudo bash -c 'cat > $NGINX_CONF' <<NGINX
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX
sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
EOF

# 8. Validate Deployment
log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
docker ps | grep $REPO_NAME || exit 13
curl -s http://localhost:$APP_PORT || exit 14
curl -s http://localhost || exit 15
EOF

log "Deployment successful and validated."

# 9. Cleanup Option
if [[ "${1:-}" == "--cleanup" ]]; then
    log "Cleaning up remote resources..."
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
    cd ~/deploy_temp/$REPO_NAME
    docker-compose down
    sudo rm -rf ~/deploy_temp/$REPO_NAME
    sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
    sudo rm -f /etc/nginx/sites-available/$REPO_NAME
    sudo systemctl reload nginx
EOF
    log "Cleanup completed."
fi

exit 0