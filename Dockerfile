# Use a lightweight, stable Nginx base image
FROM nginx:1.25-alpine

# Set working directory for static files
WORKDIR /usr/share/nginx/html

# Remove default Nginx static files
RUN rm -rf ./*

# Copy static files (HTML, CSS, JS, etc.) from the repository
COPY . .

# Expose port 80 for HTTP traffic
EXPOSE 80

# Add a health check to verify Nginx is running
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost/ || exit 1

# Start Nginx in the foreground
CMD ["nginx", "-g", "daemon off;"]