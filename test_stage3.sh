#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
NGINX_PORT="${NGINX_PORT:-8080}"
APP_BLUE="app_blue"
APP_GREEN="app_green"
NGINX_CONTAINER="bg_nginx"
WATCHER_CONTAINER="alert_watcher"
SCREENSHOTS_DIR="./screenshots"
LOG_FILE="/var/log/nginx/access.log"
REQUESTS_FOR_ERROR=250
DELAY_BETWEEN_REQUESTS=0.05
COOLDOWN_WAIT=15  # Slack cooldown is 300s, but we just wait a bit for message

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === HELPER FUNCTIONS ===
log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

take_screenshot() {
  local name="$1"
  local output="$SCREENSHOTS_DIR/$name.png"
  mkdir -p "$SCREENSHOTS_DIR"

  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    screencapture -x "$output" && log "Screenshot saved: $output"
  elif [[ -n "${DISPLAY:-}" ]] && command -v scrot >/dev/null; then
    # Linux with scrot
    scrot "$output" && log "Screenshot saved: $output"
  else
    warn "Auto-screenshot skipped (no GUI or tool). Manually capture: $name"
    echo "Press Enter when you've taken the screenshot manually..."
    read -r
  fi
}

send_traffic() {
  local count=$1
  log "Sending $count requests to http://localhost:$NGINX_PORT..."
  for ((i=1; i<=count; i++)); do
    curl -s -o /dev/null "http://localhost:$NGINX_PORT" || true
    sleep "$DELAY_BETWEEN_REQUESTS"
  done
}

# === MAIN ===
log "Starting Stage 3 Automated Test"

# 1. Start stack
log "Starting Docker Compose..."
docker compose up -d
sleep 10

# 2. Failover Test (Blue → Green)
log "Triggering FAILOVER: stopping $APP_BLUE"
docker stop "$APP_BLUE"

send_traffic 30

log "Waiting for Slack failover alert..."
warn "CHECK SLACK NOW! You should see: 'Failover Detected: Switched from blue to green'"
echo "Take screenshot of Slack message → name it: 1_slack_failover.png"
take_screenshot "1_slack_failover"

# Bring blue back
log "Restarting $APP_BLUE for next test"
docker start "$APP_BLUE"
docker compose restart nginx
sleep 10

# 3. High Error Rate Test
log "Injecting 5xx errors by breaking health endpoint in $APP_BLUE"

docker exec "$APP_BLUE" sh -c '
  pkill -f "python" || true
  cat > /tmp/evil.py <<'"'"'PY'"'"'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(500); self.end_headers()
HTTPServer(("", 3000), H).serve_forever()
PY
  chmod +x /tmp/evil.py
  /tmp/evil.py &
'

send_traffic "$REQUESTS_FOR_ERROR"

log "Waiting for Slack error-rate alert..."
warn "CHECK SLACK NOW! You should see: 'High Error Rate Alert: XX% 5xx...'"
echo "Take screenshot → name it: 2_slack_error_rate.png"
take_screenshot "2_slack_error_rate"

# 4. Restore healthy app
log "Restoring healthy app in $APP_BLUE"
docker exec "$APP_BLUE" sh -c 'pkill -f evil.py || true; exit 0'
docker restart "$APP_BLUE"
sleep 10

# 5. Capture Nginx log line
log "Capturing structured Nginx log line..."
LOG_LINE=$(docker exec "$NGINX_CONTAINER" tail -n 1 "$LOG_FILE")
echo "$LOG_LINE"

# Display in terminal for screenshot
clear
echo "=== NGINX LOG LINE (for screenshot) ==="
echo "$LOG_LINE"
echo "======================================"
warn "Take screenshot of this terminal → name it: 3_nginx_log_line.png"
take_screenshot "3_nginx_log_line"

# 6. Finalize
log "All tests completed!"
log "Screenshots should be in: $SCREENSHOTS_DIR"
log "Upload these 3 files with your submission:"
echo "   • $SCREENSHOTS_DIR/1_slack_failover.png"
echo "   • $SCREENSHOTS_DIR/2_slack_error_rate.png"
echo "   • $SCREENSHOTS_DIR/3_nginx_log_line.png"

warn "Don't forget to:"
echo "   1. Push screenshots to GitHub"
echo "   2. Update README.md with links"
echo "   3. Submit via Google Form"

exit 0