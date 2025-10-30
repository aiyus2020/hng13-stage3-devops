import os
import time
import re
import json
import requests
from collections import deque

log_path = "/var/log/nginx/access.log"
webhook = os.getenv("SLACK_WEBHOOK_URL")
error_threshold = float(os.getenv("ERROR_RATE_THRESHOLD", "2"))
window_size = int(os.getenv("WINDOW_SIZE", "200"))
cooldown = int(os.getenv("ALERT_COOLDOWN_SEC", "300"))
maintenance_mode = os.getenv("MAINTENANCE_MODE", "false").lower() == "true"

last_pool = None
last_alert_time = 0
window = deque(maxlen=window_size)

def send_slack(message):
    if webhook:
        requests.post(webhook, json={"text": message})

def parse_line(line):
    match = re.search(r'pool=(\w+).*upstream_status=(\d+)', line)
    if not match:
        return None, None
    return match.group(1), int(match.group(2))

def main():
    global last_pool, last_alert_time
    print("Watcher started... Monitoring logs for failovers and 5xx rates")
    with open(log_path, "r") as f:
        f.seek(0, 2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.5)
                continue

            pool, status = parse_line(line)
            if not pool:
                continue

            # Detect failover
            if last_pool and pool != last_pool and not maintenance_mode:
                now = time.time()
                if now - last_alert_time > cooldown:
                    send_slack(f":rotating_light: Failover detected! {last_pool} → {pool}")
                    last_alert_time = now
            last_pool = pool

            # Track errors
            window.append(status)
            errors = sum(1 for s in window if 500 <= s < 600)
            error_rate = (errors / len(window)) * 100

            if error_rate > error_threshold and not maintenance_mode:
                now = time.time()
                if now - last_alert_time > cooldown:
                    send_slack(f":warning: High error rate! {error_rate:.2f}% (>{error_threshold}%)")
                    last_alert_time = now

if __name__ == "__main__":
    main()
