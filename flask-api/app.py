from flask import Flask, request, jsonify
import os, hmac, hashlib, time, json, subprocess, threading
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from pathlib import Path
import requests

app = Flask(__name__)

# ====== Config ======
SLACK_SIGNING_SECRET = os.getenv("SLACK_SIGNING_SECRET")
SLACK_BOT_TOKEN = os.getenv("SLACK_BOT_TOKEN")  # for thread posts
AUDIT_LOG_FILE = os.getenv("AUDIT_LOG_FILE", "./logs/audit.log")
ANSIBLE_PLAYBOOK_PATH = os.getenv("ANSIBLE_PLAYBOOK_PATH", "./ansible/remediate.yml")
TERRAFORM_DIR = os.getenv("TERRAFORM_DIR", "./terraform")
CHECKOV_BIN = os.getenv("CHECKOV_BIN", "checkov")  # should be in PATH (pipx)
METRICS_CSV = os.getenv("METRICS_CSV", "./logs/metrics.csv")
PROCESSED_DIR = os.getenv("PROCESSED_DIR", "./logs/processed")  # idempotency marker dir
DISPLAY_TZ = ZoneInfo(os.getenv("TZ", "Europe/Dublin"))
METRICS_INGEST_TOKEN = os.getenv("METRICS_INGEST_TOKEN")  # optional auth for /metrics/t012

Path(os.path.dirname(AUDIT_LOG_FILE)).mkdir(parents=True, exist_ok=True)
Path(PROCESSED_DIR).mkdir(parents=True, exist_ok=True)

if not SLACK_SIGNING_SECRET:
    raise RuntimeError("SLACK_SIGNING_SECRET must be set")

# ====== Helpers ======
def verify_slack_request(req):
    ts = req.headers.get("X-Slack-Request-Timestamp")
    sig = req.headers.get("X-Slack-Signature")
    if not ts or not sig:
        return False
    try:
        if abs(time.time() - int(ts)) > 60 * 5:
            return False
    except ValueError:
        return False
    body = req.get_data(as_text=True)
    basestring = f"v0:{ts}:{body}"
    expected = "v0=" + hmac.new(SLACK_SIGNING_SECRET.encode(), basestring.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)

def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def now_local_hhmm():
    return datetime.now(DISPLAY_TZ).strftime("%H:%M")

def append_metrics(row):
    header = ["drift_id","t0","t1","t2","t3","t4","t5","t6","pre_cis_failed","post_cis_failed","status"]
    p = Path(METRICS_CSV)
    p.parent.mkdir(parents=True, exist_ok=True)
    if not p.exists():
        p.write_text(",".join(header) + "\n", encoding="utf-8")
    line = ",".join(str(row.get(k,"")) for k in header) + "\n"
    with open(p, "a", encoding="utf-8") as f:
        f.write(line)

def audit(user, action, status, extra=None):
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    extra_txt = f" | {extra}" if extra else ""
    with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
        f.write(f"{ts} | User:{user} | Action:{action} | Status:{status}{extra_txt}\n")

def post_thread(channel, thread_ts, text):
    if not (SLACK_BOT_TOKEN and channel and thread_ts):
        return
    try:
        requests.post(
            "https://slack.com/api/chat.postMessage",
            headers={
                "Authorization": f"Bearer {SLACK_BOT_TOKEN}",
                "Content-Type": "application/json; charset=utf-8",
            },
            json={"channel": channel, "thread_ts": thread_ts, "text": text},
            timeout=10,
        )
    except requests.RequestException:
        pass

def replace_original(response_url, blocks):
    if not response_url:
        return
    try:
        requests.post(response_url, json={"replace_original": True, "blocks": blocks}, timeout=8)
    except requests.RequestException:
        pass

def idempotency_mark_path(drift_id):
    return Path(PROCESSED_DIR) / f"{drift_id}.done"

def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)

def run_apply():
    return run(["ansible-playbook", ANSIBLE_PLAYBOOK_PATH])

def run_checkov_json():
    return run([CHECKOV_BIN, "-d", TERRAFORM_DIR, "-o", "json"])

def parse_checkov_failed(json_text):
    try:
        data = json.loads(json_text)
        if isinstance(data, dict) and "summary" in data:
            return int(data["summary"].get("failed", 0))
        if isinstance(data, list):
            return sum(int(item.get("summary",{}).get("failed",0)) for item in data)
    except Exception:
        pass
    return ""

def parse_action_context(payload):
    """Return decision, drift_id, env, channel_id, thread_ts, response_url, user_id"""
    user_id = (payload.get("user") or {}).get("id") or "unknown"
    response_url = payload.get("response_url")
    act = (payload.get("actions") or [{}])[0]
    action_id = act.get("action_id") or ""
    decision = None
    drift_id = ""
    env = ""

    if action_id:
        parts = action_id.split("::")
        if parts:
            decision = parts[0]
            if len(parts) >= 3:
                env, drift_id = parts[1], parts[2]

    if not decision:
        v = act.get("value")
        if v in {"approve","reject"}:
            decision = v

    container = payload.get("container") or {}
    message = payload.get("message") or {}
    channel_id = (payload.get("channel") or {}).get("id") or container.get("channel_id")
    thread_ts = container.get("message_ts") or message.get("ts")

    return decision, drift_id, env, channel_id, thread_ts, response_url, user_id

def immediate_ui_ack(response_url, user_id, decision):
    text = "Approved ✅" if decision == "approve" else "Rejected ❌"
    blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": "⚠️ Drift detected", "emoji": True}},
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*Decision:* {text} by <@{user_id}> at {now_local_hhmm()}"}}
    ]
    replace_original(response_url, blocks)

def background_pipeline(drift_id, user_id, channel_id, thread_ts):
    # t4
    t4 = now_iso()
    ans = run_apply()
    ok = (ans.returncode == 0)
    status = "success" if ok else "failed"
    # t5
    t5 = now_iso()

    snippet = (ans.stdout or ans.stderr or "").strip().splitlines()
    snippet = "\n".join(snippet[:30])
    post_thread(channel_id, thread_ts, f"*Remediation* for `{drift_id}`: *{status}*\n```{snippet}```")

    # Post-Checkov
    chk = run_checkov_json()
    post_failed = parse_checkov_failed(chk.stdout)
    post_thread(channel_id, thread_ts, f"*Post-Checkov:* failing={post_failed}")  # <— added

    # t6
    t6 = now_iso()

    audit(user_id, f"Approve:{drift_id}", status, extra=f"post_checkov_failed={post_failed}")
    append_metrics({
        "drift_id": drift_id, "t4": t4, "t5": t5, "t6": t6,
        "post_cis_failed": post_failed, "status": status
    })

    idempotency_mark_path(drift_id).write_text(now_iso(), encoding="utf-8")

# ====== Routes ======
@app.route("/slack/actions", methods=["POST"])
def slack_actions():
    # Ignore Slack retries
    if request.headers.get("X-Slack-Retry-Num"):
        return jsonify(ok=True, ignored="retry"), 200

    if not verify_slack_request(request):
        return "Invalid", 403

    payload = request.form.get("payload")
    if not payload:
        return "No payload", 400

    try:
        data = json.loads(payload)
    except Exception:
        return "Bad payload", 400

    decision, drift_id, env, channel_id, thread_ts, response_url, user_id = parse_action_context(data)
    if decision not in {"approve","reject"}:
        audit(user_id, "UnknownDecision", "ignored", extra=str(decision))
        return jsonify(ok=True), 200

    # t3
    append_metrics({"drift_id": drift_id, "t3": now_iso()})

    # immediate ACK and UI feedback
    immediate_ui_ack(response_url, user_id, decision)

    # idempotency guard
    if drift_id:
        marker = idempotency_mark_path(drift_id)
        if marker.exists():
            post_thread(channel_id, thread_ts, f"Duplicate action ignored for `{drift_id}`.")
            audit(user_id, f"{decision.capitalize()}:{drift_id}", "duplicate")
            return jsonify(ok=True, duplicate=True), 200

    if decision == "reject":
        audit(user_id, f"Reject:{drift_id}", "no-op")
        post_thread(channel_id, thread_ts, f"Remediation *rejected* for `{drift_id}` by <@{user_id}> at {now_local_hhmm()}.")
        return jsonify(ok=True), 200

    # approve -> background remediation
    th = threading.Thread(target=background_pipeline, args=(drift_id, user_id, channel_id, thread_ts), daemon=True)
    th.start()
    return jsonify(ok=True, processing=True), 200

# Minimal metrics ingest so Actions can send t0/t1/t2 (+pre_cis_failed)
@app.post("/metrics/t012")
def metrics_t012():
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return "Bad JSON", 400
    # Optional auth
    if METRICS_INGEST_TOKEN:
        token = request.headers.get("X-Auth-Token")
        if token != METRICS_INGEST_TOKEN:
            return "Forbidden", 403
    if not isinstance(data, dict) or "drift_id" not in data:
        return "Bad payload", 400
    row = {
        "drift_id": data.get("drift_id", ""),
        "t0": data.get("t0", ""),
        "t1": data.get("t1", ""),
        "t2": data.get("t2", ""),
        "pre_cis_failed": data.get("pre_cis_failed", ""),
    }
    append_metrics(row)
    return jsonify(ok=True)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
