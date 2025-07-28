from flask import Flask, request, jsonify
import os
import requests
import subprocess
from dotenv import load_dotenv
import json
from datetime import datetime

load_dotenv()
app = Flask(__name__)

SLACK_TOKEN = os.getenv("SLACK_BOT_TOKEN")
SLACK_CHANNEL = os.getenv("SLACK_CHANNEL_ID")


@app.route('/send-alert', methods=['POST'])
def send_alert():
    data = request.get_json()
    drift_output = data.get("drift", "⚠️ Drift detected, but no detailed output.")

    message = {
        "channel": SLACK_CHANNEL,
        "text": "⚠️ Terraform Drift Detected",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*Terraform Drift Detected:*\n```{drift_output}```"
                }
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Approve Remediation"},
                        "style": "primary",
                        "value": "approve_remediation",
                        "action_id": "approve_remediation"
                    }
                ]
            }
        ]
    }

    headers = {
        "Authorization": f"Bearer {SLACK_TOKEN}",
        "Content-Type": "application/json"
    }

    response = requests.post("https://slack.com/api/chat.postMessage", json=message, headers=headers)

    if response.status_code != 200 or not response.json().get("ok"):
        return jsonify({"error": "Slack API error", "details": response.text}), 500

    return jsonify({"status": "Alert sent to Slack"}), 200


@app.route('/slack/interact', methods=['POST'])
def slack_interact():
    payload = json.loads(request.form.get("payload"))
    user = payload.get("user", {}).get("username")
    action_value = payload.get("actions", [{}])[0].get("value")

    if action_value == "approve_remediation":
        log_approval(user)
        result = run_ansible()

        return jsonify({
            "text": f":white_check_mark: Remediation triggered by *{user}*.",
            "response_type": "in_channel"
        })

    return jsonify({"text": "Unknown action."})


def run_ansible():
    try:
        result = subprocess.run(["ansible-playbook", "../ansible/remediate.yml"], check=True, capture_output=True, text=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        return f"Ansible failed: {e.output}"


def log_approval(user):
    with open("../logs/audit.log", "a") as log_file:
        log_file.write(f"{datetime.now()} - {user} approved remediation\n")


if __name__ == "__main__":
    app.run(debug=True, port=5000)
