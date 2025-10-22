#!/bin/bash

# Set strict mode
set -euo pipefail

# Initialize logging
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# Trap errors and cleanup
cleanup() {
    echo "ERROR: Script failed at line $1 with status $2" >&2
    exit "$2"
}
trap 'cleanup $LINENO $?' ERR

# Default values
DEFAULT_BRANCH="main"
CLEANUP_MODE=false

# Parse optional cleanup flag
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup)
            CLEANUP_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# 1. Collect and validate parameters
prompt_input() {
    read -p "$1: " input
    echo "$input"
}

echo "Collecting deployment parameters..."
REPO_URL=$(prompt_input "Enter Git Repository URL (https://...)")
PAT=$(prompt_input "Enter Personal Access Token")
BRANCH=$(prompt_input "Enter branch name (default: $DEFAULT_BRANCH)")
BRANCH=${BRANCH:-$DEFAULT_BRANCH}
SSH_USER=$(prompt_input "Enter SSH username")
SSH_IP=$(prompt_input "Enter server IP address")
SSH_KEY=$(prompt_input "Enter SSH key path")
APP_PORT=$(prompt_input "Enter application port")

# Validate inputs
[[ -z "$REPO_URL" || ! "$REPO_URL" =~ ^https:// ]] && { echo "Invalid Git URL"; exit 1; }
[[ -z "$PAT" ]] && { echo "PAT cannot be empty"; exit 1; }
[[ -z "$BRANCH" ]] && { echo "Branch name cannot be empty"; exit 1; }
[[ -z "$SSH_USER" ]] && { echo "SSH username cannot be empty"; exit 1; }
[[ -z "$SSH_IP" ]] && { echo "Server IP cannot be empty"; exit 1; }
[[ ! -f "$SSH_KEY" ]] && { echo "SSH key file not found"; exit 1; }
[[ -z "$APP_PORT" || ! "$APP_PORT" =~ ^[0-9]+$ ]] && { echo "Invalid port"; exit 1; }

echo "Parameters validated successfully" >&2

# 2. Clone or update repository
REPO_NAME=$(basename "$REPO_URL" .git)
if [[ -d "$REPO_NAME" ]]; then
    echo "Repository exists, pulling latest changes..."
    cd "$REPO_NAME"
    git fetch origin
    echo "DEBUG: Checking out and pulling branch '$BRANCH'" >&2
    git checkout "$BRANCH"
    git pull origin "$BRANCH" --no-rebase
else
    echo "Cloning repository..."
    git clone -b "$BRANCH" "https://${PAT}@${REPO_URL#https://}" "$REPO_NAME"
    cd "$REPO_NAME"
fi

# 3. Verify Dockerfile or docker-compose.yml
if [[ ! -f "Dockerfile" && ! -f "docker-compose.yml" ]]; then
    echo "ERROR: No Dockerfile or docker-compose.yml found"
    exit 1
fi
echo "Project files verified" >&2

# 4. SSH connectivity check
echo "Testing SSH connection..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 "$SSH_USER@$SSH_IP" "echo 'SSH connection successful'"; then
    echo "ERROR: SSH connection failed"
    exit 1
fi

# 5. Prepare remote environment
echo "Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" /bin/bash << 'EOF'
    set -e
    echo "Updating system packages..."
    sudo apt-get update -y && sudo apt-get upgrade -y
    echo "Installing Docker..."
    if ! command -v docker &> /dev/null; then
        sudo apt-get install -y docker.io
        sudo systemctl enable docker
        sudo systemctl start docker
    fi
    echo "Installing Docker Compose..."
    if ! command -v docker-compose &> /dev/null; then
        sudo apt-get install -y docker-compose
    fi
    echo "Installing Nginx..."
    if ! command -v nginx &> /dev/null; then
        sudo apt-get install -y nginx
    fi
    echo "Adding user to Docker group..."
    sudo usermod -aG docker "$USER"
    echo "Docker version: $(docker --version)"
    echo "Docker Compose version: $(docker-compose --version)"
    echo "Nginx version: $(nginx -v 2>&1)"
EOF

# 6. Deploy application
echo "Transferring project files..."
# Ensure remote directory exists
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" "mkdir -p /home/$SSH_USER/$REPO_NAME"
# Use scp to transfer files recursively
scp -i "$SSH_KEY" -r ./* "$SSH_USER@$SSH_IP:/home/$SSH_USER/$REPO_NAME/"

echo "Deploying application..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" /bin/bash << EOF
    set -e
    cd "/home/$SSH_USER/$REPO_NAME"
    if [[ -f "docker-compose.yml" ]]; then
        echo "Running docker-compose..."
        docker-compose down 2>/dev/null || true
        docker-compose up -d --build
    else
        echo "Building and running Docker container..."
        docker stop "$REPO_NAME" 2>/dev/null || true
        docker rm "$REPO_NAME" 2>/dev/null || true
        docker build -t "$REPO_NAME" .
        docker run -d --name "$REPO_NAME" -p "$APP_PORT:$APP_PORT" "$REPO_NAME"
    fi
    echo "Checking container health..."
    sleep 5
    if ! docker ps | grep "$REPO_NAME"; then
        echo "ERROR: Container failed to start"
        docker logs "$REPO_NAME"
        exit 1
    fi
EOF

# 7. Configure Nginx
echo "Configuring Nginx..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" /bin/bash << 'NGINX_CONF'
    set -e
    cat << EOF | sudo tee /etc/nginx/sites-available/$REPO_NAME
server {
    listen 80;
    server_name $SSH_IP;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    sudo ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl reload nginx
NGINX_CONF

# 8. Validate deployment
echo "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" /bin/bash << 'EOF'
    set -e
    if ! systemctl is-active --quiet docker; then
        echo "ERROR: Docker service is not running"
        exit 1
    fi
    if ! docker ps | grep "$REPO_NAME"; then
        echo "ERROR: Application container is not running"
        exit 1
    fi
    if ! systemctl is-active --quiet nginx; then
        echo "ERROR: Nginx service is not running"
        exit 1
    fi
    if ! curl -s -o /dev/null -w "%{http_code}" "http://localhost" | grep -q 200; then
        echo "ERROR: Application is not accessible"
        exit 1
    fi
    echo "Deployment validated successfully"
EOF

# 9. Cleanup (optional)
if [[ "$CLEANUP_MODE" == true ]]; then
    echo "Running cleanup..."
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" /bin/bash << EOF
        set -e
        cd "/home/$SSH_USER/$REPO_NAME"
        if [[ -f "docker-compose.yml" ]]; then
            docker-compose down
        else
            docker stop "$REPO_NAME" 2>/dev/null || true
            docker rm "$REPO_NAME" 2>/dev/null || true
        fi
        sudo rm -f /etc/nginx/sites-available/$REPO_NAME
        sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
        sudo systemctl reload nginx
        rm -rf "/home/$SSH_USER/$REPO_NAME"
EOF
    rm -rf "$REPO_NAME"
    echo "Cleanup completed"
fi

echo "Deployment completed successfully. Logs saved to $LOG_FILE"