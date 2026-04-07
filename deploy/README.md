# Deploying Odoo 19.0 on AWS EC2

## 1. EC2 Instance Setup

### Recommended specs
| Workload       | Instance Type | vCPU | RAM   | Storage |
|----------------|---------------|------|-------|---------|
| Small (1-10 users)   | t3.medium     | 2    | 4 GB  | 30 GB EBS |
| Medium (10-50 users) | t3.large      | 2    | 8 GB  | 50 GB EBS |
| Large (50+ users)    | m6i.xlarge    | 4    | 16 GB | 100 GB EBS |

### AMI
Ubuntu 24.04 LTS (HVM, SSD Volume Type)

### Security Group Rules
| Port  | Protocol | Source    | Purpose              |
|-------|----------|-----------|----------------------|
| 22    | TCP      | Your IP   | SSH access           |
| 80    | TCP      | 0.0.0.0/0 | HTTP (redirect to HTTPS) |
| 443   | TCP      | 0.0.0.0/0 | HTTPS                |

> Do NOT expose port 8069 directly in production. Use Nginx as a reverse proxy.

## 2. Install Docker on EC2

```bash
# Connect to your instance
ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>

# Install Docker
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Allow ubuntu user to run Docker without sudo
sudo usermod -aG docker ubuntu
newgrp docker
```

## 3. Clone and Configure

```bash
# Clone your fork
git clone -b 19.0 https://github.com/<YOUR_GITHUB_USER>/odoo.git
cd odoo

# Create .env file with secure passwords
cat > .env << 'EOF'
POSTGRES_PASSWORD=<GENERATE_A_STRONG_PASSWORD>
ODOO_PORT=8069
ODOO_LONGPOLL_PORT=8072
EOF

# Update the admin password in docker/odoo.conf
# Change admin_passwd from 'admin' to a strong password
nano docker/odoo.conf
```

## 4. Build and Start

```bash
docker compose up -d --build

# Check status
docker compose ps

# View logs
docker compose logs -f odoo
```

Odoo should now be accessible at `http://<EC2_PUBLIC_IP>:8069`.

## 5. Nginx Reverse Proxy with SSL

```bash
# Install Nginx and Certbot
sudo apt-get install -y nginx certbot python3-certbot-nginx
```

Create `/etc/nginx/sites-available/odoo`:

```nginx
upstream odoo {
    server 127.0.0.1:8069;
}

upstream odoo-chat {
    server 127.0.0.1:8072;
}

server {
    listen 80;
    server_name your-domain.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL will be configured by certbot
    # ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    access_log /var/log/nginx/odoo-access.log;
    error_log /var/log/nginx/odoo-error.log;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;

    location /websocket {
        proxy_pass http://odoo-chat;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        proxy_pass http://odoo;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo;
    }

    client_max_body_size 256m;

    gzip on;
    gzip_types text/css text/plain text/xml application/xml application/javascript application/json;
}
```

```bash
# Enable the site
sudo ln -s /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

# Get SSL certificate (make sure your domain points to this EC2 IP)
sudo certbot --nginx -d your-domain.com
```

## 6. Backups

### Database backup (daily cron)

```bash
# Create backup script
cat > ~/backup-odoo.sh << 'SCRIPT'
#!/bin/bash
BACKUP_DIR="/home/ubuntu/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

# Dump PostgreSQL
docker compose -f /home/ubuntu/odoo/docker-compose.yml exec -T db \
    pg_dumpall -U odoo | gzip > "$BACKUP_DIR/db_${TIMESTAMP}.sql.gz"

# Backup filestore
docker run --rm -v odoo_odoo-filestore:/data -v "$BACKUP_DIR":/backup \
    alpine tar czf "/backup/filestore_${TIMESTAMP}.tar.gz" -C /data .

# Keep only last 7 days
find "$BACKUP_DIR" -name "*.gz" -mtime +7 -delete
SCRIPT

chmod +x ~/backup-odoo.sh

# Add to crontab (daily at 2 AM)
(crontab -l 2>/dev/null; echo "0 2 * * * /home/ubuntu/backup-odoo.sh") | crontab -
```

### Optional: Upload backups to S3

```bash
sudo apt-get install -y awscli
aws configure  # enter your AWS credentials
# Add to backup script:
# aws s3 sync "$BACKUP_DIR" s3://your-bucket/odoo-backups/
```

## 7. Updating Odoo

```bash
cd ~/odoo
git pull origin 19.0
docker compose up -d --build
# Update modules if needed:
docker compose exec odoo odoo --update=all --stop-after-init --config=/etc/odoo/odoo.conf
```

## 8. Custom Addons

Place custom modules in the `extra-addons/` directory. They are automatically mounted into the container and included in the addons path.

```bash
# Example: install a custom module
cp -r /path/to/my_module extra-addons/
docker compose restart odoo
# Then install via Odoo UI: Apps > Update Apps List > search > Install
```
