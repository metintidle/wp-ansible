# Fail2Ban Nginx Protection Ansible Playbook

This Ansible playbook configures Fail2Ban to protect Nginx servers from common attack patterns, including PHP scanning attempts and "Primary script unknown" errors.

## Features

- Installs Fail2Ban if not already present
- Creates custom filters to detect:
  - PHP URL scanning attacks
  - "Primary script unknown" errors from malicious requests
- Configures jails with appropriate settings:
  - Ban duration: 24 hours
  - Ban threshold: 2 failed attempts
  - Monitors Nginx error logs

## Requirements

- Ansible 2.9+
- Target servers running:
  - Amazon Linux 2
  - CentOS/RHEL 7+
  - Or other compatible distributions

## Usage

### Quick Start

1. Make sure you have SSH access to your target servers
2. Update your Ansible inventory file with your servers
3. Run the playbook:

```bash
ansible-playbook -i inventory fail2ban-nginx.yml
```

### For Local Testing

To test on the local machine:

```bash
ansible-playbook -i "localhost," -c local fail2ban-nginx.yml
```

### Sample Inventory File

Create a file named `inventory` with your server details:

```ini
[webservers]
web1.example.com
web2.example.com

[webservers:vars]
ansible_user=ec2-user
ansible_ssh_private_key_file=/path/to/key.pem
```

## Customization

You can modify the playbook to adjust:

- Ban duration (bantime)
- Number of attempts before banning (maxretry)
- Log paths
- Filter regex patterns

## Verification

After running the playbook, you can verify the installation with:

```bash
sudo fail2ban-client status
```

And check specific jails with:

```bash
sudo fail2ban-client status nginx-unknown-script
sudo fail2ban-client status nginx-php-url-hack
```

## Troubleshooting

- Check Fail2Ban logs: `sudo tail -f /var/log/fail2ban.log`
- Verify filter regex: `sudo fail2ban-regex /var/log/nginx/error.log /etc/fail2ban/filter.d/nginx-unknown-script.conf`