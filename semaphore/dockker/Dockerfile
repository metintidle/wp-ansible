# Dockerfile
FROM semaphoreui/semaphore:latest

# Install Ansible and the amazon.aws collection
RUN apt-get update && apt-get install -y ansible

# Set the working directory
WORKDIR /tmp/semaphore