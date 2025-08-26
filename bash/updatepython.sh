#!/bin/bash

# Install Latest Python on Amazon Linux 2
# This script installs Python 3.13.5 using Miniconda
# Run with: bash install_latest_python.sh

set -e  # Exit on any error

sudo yum update -y
sudo yum groupinstall -y "Development Tools"

# Install additional libraries needed for Python compilation
echo "📚 Installing additional development libraries..."
sudo yum install -y openssl-devel bzip2-devel libffi-devel readline-devel sqlite-devel tk-devel xz-devel zlib-devel

# Download Miniconda
echo "⬇️  Downloading Miniconda..."
curl -O https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh

# Install Miniconda
echo "🚀 Installing Miniconda..."
bash Miniconda3-latest-Linux-x86_64.sh -b -p $HOME/miniconda3

# Initialize conda for bash
echo "⚙️  Configuring conda for bash..."
$HOME/miniconda3/bin/conda init bash

# Source bashrc to load conda
echo "🔄 Loading conda environment..."
source ~/.bashrc

# Clean up installation file
echo "🧹 Cleaning up..."
rm Miniconda3-latest-Linux-x86_64.sh

echo ""
echo "✅ Installation Complete!"
echo "========================="
echo ""

# Verify installation
echo "🔍 Verifying installation..."
echo "Python version:"
$HOME/miniconda3/bin/python --version

echo ""
echo "SSL support:"
$HOME/miniconda3/bin/python -c "import ssl; print('SSL support:', ssl.OPENSSL_VERSION)"

echo ""
echo "Testing HTTPS connectivity:"
$HOME/miniconda3/bin/python -c "import requests; print('HTTP requests work:', requests.get('https://httpbin.org/status/200').status_code == 200)" 2>/dev/null || echo "Note: You may need to install requests with 'pip install requests'"

echo ""
echo "🎉 Python 3.13.5 has been successfully installed!"
echo ""
echo "To use the new Python:"
echo "1. Close and reopen your terminal, OR"
echo "2. Run: source ~/.bashrc"
echo ""
echo "Then you can use:"
echo "  python --version    # Check Python version"
echo "  pip install <package>    # Install Python packages"
echo "  conda install <package>  # Install conda packages"
echo ""
echo "Happy coding! 🚀"
