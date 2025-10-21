# Use official Nginx base image
FROM nginx:latest

# Copy your static web file into the Nginx default HTML directory
COPY index.html /usr/share/nginx/html/index.html

# Expose port 80 for web traffic
EXPOSE 80

# Run Nginx in the foreground
CMD ["nginx", "-g", "daemon off;"]