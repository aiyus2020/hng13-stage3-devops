import os
import re
import time
import collections
import requests
from datetime import datetime, timedelta

# Load environment variables
SLACK_WEBHOOK_URL = os.environ.get('SLACK_WEBHOOK_URL')
ERROR_RATE_THRESHOLD = float(os.environ.get('ERROR_RATE_THRESHOLD', 2))
WINDOW_SIZE = int(os.environ.get('WINDOW_SIZE', 200))
ALERT_COOLDOWN_SEC = int(os.environ.get('ALERT_COOLDOWN_SEC', 300))
MAINTENANCE_MODE = os.environ.get('MAINTENANCE_MODE', 'false').lower() == 'true'
LOG_FILE = os.environ.get('LOG_FILE', '/logs/access.log')

if not SLACK_WEBHOOK_URL:
    raise ValueError("SLACK_WEBHOOK_URL is required")

# Regex to parse custom log format
LOG_PATTERN = re.compile(
    r'(?P<remote_addr>.*?) - (?P<remote_user>.*?) \[(?P<time_local>.*?)\] '
    r'"(?P<request>.*?)" (?P<status>\d+) (?P<body_bytes_sent>\d+) '
    r'"(?P<http_referer>.*?)" "(?P<http_user_agent>.*?)" '
    r'pool:"(?P<pool>.*?)" release:"(?P<release>.*?)" '
    r'upstream_status:(?P<upstream_status>\d+|-) upstream_addr:(?P<upstream_addr>.*?) '
    r'request_time:(?P<request_time>.*?) upstream_response_time:(?P<upstream_response_time>.*?)'
)

# Sliding window for error rates (deque of upstream_status)
error_window = collections.deque(maxlen=WINDOW_SIZE)

# Track last seen pool
last_pool = None

# Track last alert times
last_failover_alert = datetime.min
last_error_rate_alert = datetime.min

def send_slack_alert(message):
    payload = {'text': message}
    try:
        response = requests.post(SLACK_WEBHOOK_URL, json=payload)
        response.raise_for_status()
    except Exception as e:
        print(f"Failed to send Slack alert: {e}")

def is_5xx(status):
    try:
        return 500 <= int(status) < 600
    except ValueError:
        return False

def tail_log():
    with open(LOG_FILE, 'r') as f:
        # Seek to end
        f.seek(0, 2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue
            yield line.strip()

for log_line in tail_log():
    match = LOG_PATTERN.match(log_line)
    if not match:
        print(f"Failed to parse log: {log_line}")
        continue

    data = match.groupdict()
    pool = data['pool']
    upstream_status = data['upstream_status']
    now = datetime.now()

    if MAINTENANCE_MODE:
        continue  # Suppress all alerts

    # Detect failover
    if last_pool is None:
        last_pool = pool  # Initial set
    elif last_pool != pool and (now - last_failover_alert) > timedelta(seconds=ALERT_COOLDOWN_SEC):
        message = f"Failover Detected: Switched from {last_pool} to {pool} at {data['time_local']}"
        send_slack_alert(message)
        last_failover_alert = now
        last_pool = pool

    # Error rate check
    if upstream_status != '-':
        error_window.append(upstream_status)
        if len(error_window) >= WINDOW_SIZE:
            error_count = sum(1 for s in error_window if is_5xx(s))
            error_rate = (error_count / len(error_window)) * 100
            if error_rate > ERROR_RATE_THRESHOLD and (now - last_error_rate_alert) > timedelta(seconds=ALERT_COOLDOWN_SEC):
                message = f"High Error Rate Alert: {error_rate:.2f}% 5xx errors over last {WINDOW_SIZE} requests at {data['time_local']}"
                send_slack_alert(message)
                last_error_rate_alert = now