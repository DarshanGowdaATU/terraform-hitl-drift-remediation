```markdown
# Human-in-the-Loop Terraform Drift Remediation (AWS)

Detect drift fast. Ask a human. Remediate safely. Prove it happened.

**Stack:** Terraform · GitHub Actions · Slack (Block Kit) · Flask (signed webhooks) · Ansible · Checkov · AWS OIDC

---

## Overview

This repo implements a human-in-the-loop (HITL) pipeline:

1. **Detect** drift with a refresh-only `terraform plan`.
2. **Notify** Slack with a concise diff + CIS context (Checkov).
3. **Approve / Reject** in Slack (signed, replay-protected).
4. **Remediate** via Ansible orchestrating `terraform apply`.
5. **Verify** post-apply with Checkov and **audit** everything.

---


> **Required move:**  
> GitHub Actions workflows must live under `.github/workflows/`  
> ```
> mkdir -p .github/workflows
> git mv detect-drift.yml .github/workflows/detect-drift.yml
> ```

If you later split by folders, keep `TF_DIR` in the workflow aligned with where the `.tf` files live.

---

## Before you start (fill these)

| Placeholder            | Replace with                                  |
|------------------------|-----------------------------------------------|
| `<state-bucket>`       | S3 bucket name for Terraform state            |
| `<lock-table>`         | DynamoDB table name for state locks           |
| `<aws-region>`         | e.g., `us-east-1`                             |
| `<ACCOUNT_ID>`         | Your AWS account ID                           |
| `<ORG>` / `<REPO>`     | Your GitHub org and repo                      |
| `<api-gateway-domain>` | Public HTTPS for Slack → API Gateway → Flask  |

---

## Terraform backend (S3 + DynamoDB)

`backend.tf` should declare an S3 backend with locking:

```hcl
terraform {
  backend "s3" {
    bucket         = "<state-bucket>"
    key            = "global/terraform.tfstate"
    region         = "<aws-region>"
    dynamodb_table = "<lock-table>"
    encrypt        = true
  }
}
````

Enable **versioning** on the bucket. Make sure the DDB table exists.

---

## AWS OIDC role (no long-lived keys)

Create an IAM role that trusts GitHub OIDC and restricts usage to this repo/branch.

**Trust policy example:**

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:ref:refs/heads/main" }
    }
  }]
}
```

**GitHub → Settings → Secrets and variables → Actions → New repository secret**

* `AWS_ROLE_TO_ASSUME` – ARN of the role above
* `AWS_REGION` – e.g., `us-east-1`
* `SLACK_BOT_TOKEN` – from Slack app install

---

## Slack app (manifest)

Create at **api.slack.com/apps → Create New App → From an app manifest**:

```json
{
  "display_information": { "name": "DriftBot" },
  "features": { "bot_user": { "display_name": "DriftBot" } },
  "oauth_config": {
    "scopes": { "bot": ["chat:write", "chat:write.public", "chat:write.customize"] }
  },
  "settings": {
    "interactivity": {
      "is_enabled": true,
      "request_url": "https://<api-gateway-domain>/slack-action"
    }
  }
}
```

Install the app, copy the **Bot Token** and **Signing Secret**.

---

## Flask decision endpoint

**File:** `app.py`

**Environment variables:**

```
SLACK_SIGNING_SECRET=…          # from Slack -> Basic Information
AUDIT_LOG_FILE=./logs/audit.log
ANSIBLE_PLAYBOOK_PATH=./remediate.yml
TZ=Europe/Dublin
```

Expose `app.py` behind **API Gateway (HTTP API)** and set Slack **Interactivity Request URL** to:

```
https://<api-gateway-domain>/slack-action
```

**Important:** API Gateway must forward the **raw** `application/x-www-form-urlencoded` body (no mapping), or signature verification will fail.

---

## GitHub Actions workflow

**File:** `.github/workflows/detect-drift.yml` (after moving)

What it does:

* Assumes AWS role via OIDC (`aws-actions/configure-aws-credentials@v4`)
* Caches Terraform providers
* Runs `terraform init` → `terraform plan -refresh-only -detailed-exitcode`
* Saves `plan.txt` / `plan.json` as artifacts
* Runs **Checkov** and parses fail/warn counts
* Posts a Slack Block Kit message with **Approve** / **Reject**
* Appends timing to `logs/metrics.csv`

**Workflow requirements**

```yaml
permissions:
  id-token: write
  contents: read
```

Set `TF_DIR` so the workflow points at the directory with your `.tf` files (here it’s `./` since TF files are in the repo root).

---

## Ansible remediation

**File:** `remediate.yml`

Flow:

1. Ensure `./logs/` exists
2. `terraform apply -auto-approve` (respects state lock)
3. Run post-apply **Checkov** → `./logs/checkov-post.json`
4. Post Slack thread update with a short recap

Ensure `ansible` and `checkov` are available on the runner (install them in the workflow step if needed).

---

## Drift scenarios (quick tests)

Start a run via **Actions → Detect Terraform Drift → Run workflow** or wait for the schedule. Use the **Drift ID** in Slack to correlate with artifacts.

1. **Security group SSH open to world**
   In the AWS console, add `0.0.0.0/0` to TCP/22 on the public SG.
   Expect: plan shows SG update; Checkov failing; approve to revert.

2. **EC2 root volume size/type change**
   Change the root volume from `8 → 16 GiB` (or gp3→gp2).
   Expect: plan updates `root_block_device`; approve to restore.

3. **S3 public path**
   Uncheck **Block Public Access** on the bucket; then modify the **bucket policy** to allow public read.
   Expect: drift on `aws_s3_bucket_public_access_block` and the policy resource; approve to restore private posture.
   *ACL drift is blocked by BucketOwnerEnforced (expected).*

4. **IAM wildcard policy (optional)**
   Manage an inline policy for `aws_iam_user.developer` in Terraform (least-privilege), then in the console replace it with `Action:"*", Resource:"*"`.
   Expect: plan updates the inline policy back to least-privilege.

5. **EC2 deletion**
   Terminate a Terraform-managed instance.
   Expect: plan shows create; approve to re-create.

---

## Observability & artifacts

* `logs/audit.log` — timestamp, user, decision, status, drift\_id
* `logs/metrics.csv` — timings per phase keyed by `drift_id` (UTC)
* CI artifacts per run — `plan.txt`, `plan.json`, `checkov-pre.json`, `checkov-post.json`, `slack-payload.json`, `ansible_apply.log`

---

## Security model

* **No long-lived AWS keys:** OIDC role assumption scoped to repo/branch
* **Signed Slack requests:** HMAC verification + 5-minute replay window
* **HITL gate:** applies only after explicit human approval
* **Guardrails:** Checkov pre and post remediation
* **Auditability:** append-only logs + artifacts tied by **Drift ID**

---

## Metrics (how numbers are produced)

* **Detection latency:** `plan_exit_time − plan_start_time`
* **End-to-end (machine time only):** detection → post-Checkov (human delay excluded)
* **p50/p95:** computed per scenario from `logs/metrics.csv` (p50 = median; p95 = nearest-rank; with `n=3`, p95 = max)

---

## Troubleshooting

* **Signature mismatch:** API Gateway must pass the raw form body; don’t JSON-map it.
* **Slack retries:** handler must ACK in <3s; check `X-Slack-Retry-Num`.
* **State lock:** another apply in progress; wait or clear only if safe.
* **IAM drift not detected:** Terraform must manage the intended policy; extra console attachments aren’t flagged unless declared in code.

---

## .gitignore (suggested)

```
logs/*
!.gitkeep
.terraform/
terraform.tfstate*
*.tfstate.backup
```

---

## Source notes (files in this repo)

* Workflow: `.github/workflows/detect-drift.yml`
* Flask verifier: `app.py`
* Ansible playbook: `remediate.yml`
* Terraform stack: `backend.tf`, `provider.tf`, `variables.tf`, `outputs.tf`, `main.tf`

```

If you already pasted the earlier version, you can just patch the three fixed sections (table header + two code blocks).
```
