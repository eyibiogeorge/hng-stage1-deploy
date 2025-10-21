# ===============================
# Simple Nginx Static Site Dockerfile
# ===============================

# Use a lightweight, stable Nginx version instead of :latest for predictability
FROM nginx:1.25-alpine

# Set working directory for clarity (optional but clean)
WORKDIR /usr/share/nginx/html

# Remove default nginx page
RUN rm -rf ./*

# Copy your static files (HTML, CSS, JS, etc.) into container
COPY . .

# Expose port 80 for HTTP
EXPOSE 80

# Start Nginx in the foreground
CMD ["nginx", "-g", "daemon off;"]
