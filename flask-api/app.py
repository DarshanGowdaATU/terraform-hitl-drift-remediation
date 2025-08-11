from flask import Flask, request, jsonify, abort
import os
import hmac
import hashlib
import time
import json
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo
import requests

app = Flask(__name__)

# Load environment variables
SLACK_SIGNING_SECRET = os.getenv("SLACK_SIGNING_SECRET")
if not SLACK_SIGNING_SECRET:
    raise RuntimeError("SLACK_SIGNING_SECRET is not set")

AUDIT_LOG_FILE = os.getenv("AUDIT_LOG_FILE", "../logs/audit.log")
ANSIBLE_PLAYBOOK_PATH = os.getenv("ANSIBLE_PLAYBOOK_PATH", "../ansible/remediate.yml")
DISPLAY_TZ = ZoneInfo(os.getenv("TZ", "Europe/Dublin"))  # shown in Slack updates

def verify_slack_request(req):
    """Verify Slack request using signing secret"""
    timestamp = req.headers.get('X-Slack-Request-Timestamp')
    slack_signature = req.headers.get('X-Slack-Signature')
    if not timestamp or not slack_signature:
        return False
    # replay protection
    try:
        if abs(time.time() - int(timestamp)) > 60 * 5:
            return False
    except ValueError:
        return False

    sig_basestring = f"v0:{timestamp}:{req.get_data(as_text=True)}"
    my_signature = "v0=" + hmac.new(
        SLACK_SIGNING_SECRET.encode(),
        sig_basestring.encode(),
        hashlib.sha256
    ).hexdigest()

    return hmac.compare_digest(my_signature, slack_signature)

def log_audit(user, action, status):
    """Log HITL actions to audit log file"""
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    log_entry = f"{ts} | User: {user} | Action: {action} | Status: {status}\n"
    os.makedirs(os.path.dirname(AUDIT_LOG_FILE), exist_ok=True)
    with open(AUDIT_LOG_FILE, "a") as log_file:
        log_file.write(log_entry)

def trigger_ansible():
    """Run Ansible playbook to remediate drift"""
    try:
        result = subprocess.run(
            ["ansible-playbook", ANSIBLE_PLAYBOOK_PATH],
            capture_output=True,
            text=True,
            check=True
        )
        return True, result.stdout
    except subprocess.CalledProcessError as e:
        return False, e.stderr

def now_hhmm():
    return datetime.now(DISPLAY_TZ).strftime("%H:%M")

def update_original_message(response_url, blocks):
    # Replace the original Slack message with provided blocks
    try:
        requests.post(response_url, json={
            "replace_original": True,
            "blocks": blocks
        }, timeout=8)
    except requests.RequestException:
        # Don't crash the handler if Slack update fails
        pass

# Support both paths to avoid mismatches
@app.route("/slack-action", methods=["POST"])
@app.route("/slack/actions", methods=["POST"])
def slack_actions():
    """Handle Slack interactive button click, update message, run Ansible if approved"""
    if not verify_slack_request(request):
        return "Invalid request", 403

    payload = request.form.get("payload")
    if not payload:
        return "No action payload", 400

    data = json.loads(payload)

    # Extract essentials
    action_value = data["actions"][0].get("value")
    user_id = data.get("user", {}).get("id") or data.get("user", {}).get("username", "unknown")
    response_url = data.get("response_url")  # Slack-provided URL to update the original message

    if action_value not in {"approve", "reject"}:
        log_audit(user_id, f"Unknown:{action_value}", "Ignored")
        return jsonify({"text": "Unknown action"}), 200

    # Build immediate decision update
    decision_text = "Approved ✅" if action_value == "approve" else "Rejected ❌"
    decided_by = f"{decision_text} by <@{user_id}> at {now_hhmm()}"

    updated_blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": "⚠️ Drift detected", "emoji": True}},
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*Decision:* {decided_by}"}}
    ]

    # Immediate UI update so the button click reflects in Slack
    if response_url:
        update_original_message(response_url, updated_blocks)

    if action_value == "approve":
        ok, output = trigger_ansible()
        status = "Success" if ok else "Failed"
        log_audit(user_id, "Approve", status)

        # Append remediation result and (short) log snippet
        result_blocks = updated_blocks + [
            {"type": "section", "text": {"type": "mrkdwn", "text": f"*Remediation result:* *{status}*"}}
        ]

        if output:
            snippet = "\n".join(output.splitlines()[:20])
            if snippet.strip():
                result_blocks.append({
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": f"```{snippet}```"}
                })

        if response_url:
            update_original_message(response_url, result_blocks)

        return jsonify({"text": "Approval processed"}), 200

    # Reject path
    log_audit(user_id, "Reject", "No remediation executed")
    return jsonify({"text": "Rejection processed"}), 200

if __name__ == "__main__":
    # Flask dev server
    app.run(host="0.0.0.0", port=5000)
