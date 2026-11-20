# Lyken Solutions — AWS Serverless Terraform

This repository provisions a small production-style, event-driven website platform:

- Private S3 website bucket + CloudFront Origin Access Control (OAC)
- CloudFront HTTPS endpoint (default CloudFront certificate; no custom domain required)
- API Gateway HTTP API: `POST /api/contact`
- Python Lambda that validates contact submissions and publishes an EventBridge event
- Custom EventBridge bus and rule routing inquiries to SQS
- SQS notification queue with a redrive DLQ, plus EventBridge target delivery DLQ
- Notification Lambda consuming SQS and sending email through SES v2
- Least-privilege IAM policies and CloudWatch log groups/alarms
- Terraform S3 remote-state bootstrap with versioning, encryption, public-access blocking and S3 lockfile support
- GitHub Actions CI and manual deployment workflow using IAM access keys (no OIDC)

## Important assumptions and limitations

1. This package provisions infrastructure and backend code; it does **not** contain your existing Lyken website source. Copy the static website into `website/` and ensure `website/index.html` exists.
2. The existing website contact form must send JSON to the relative URL `/api/contact` with fields `name`, `email`, `message`. Add a hidden honeypot input named `website` if desired. The API returns HTTP 202 when EventBridge accepts the inquiry; this means accepted for asynchronous processing, **not delivered to Gmail**.
3. Verify `ses_from_email` as an SES identity in the same AWS region. In SES sandbox, also verify the destination email (`notification_to_email`) or request SES production access. Inbox delivery is not guaranteed merely because SES accepted the send request.
4. EventBridge and SQS provide at-least-once delivery. Duplicate notifications are possible in retry scenarios; this starter does not implement durable idempotency storage.
5. The API CORS policy is wildcard because the recommended frontend calls the API through the same CloudFront hostname. Tighten it if you expose the API directly or add other clients.
6. This is a production-style learning baseline, not a security/compliance certification. Review IAM, abuse controls, retention, budgets, and account-specific service quotas before public launch.
7. AWS Free Tier / credits do not mean all usage is free. CloudFront, S3 versions/requests, API Gateway, EventBridge, SQS, Lambda, CloudWatch, SES, and data transfer may incur charges. Set AWS Budgets before applying.
8. Your account/project administrator must authorize the required IAM actions and service usage. Terraform cannot bypass account-level restrictions or service control policies.

## Prerequisites

- Terraform >= 1.7
- AWS CLI v2 configured with an authorized IAM identity
- Python 3.12 for local Lambda unit tests
- An AWS region where all selected services are available (default: `ap-south-1`)
- A verified SES sender identity

## 1. Configure and test the Lambda code

The submit Lambda tests use a mocked EventBridge client and do not need AWS credentials:

```bash
cd backend/submit_inquiry
python -m unittest -v
cd ../..
```

## 2. Bootstrap remote Terraform state (one time)

Choose a globally unique S3 bucket name. Do not use a bucket name already owned by another AWS account.

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set a globally unique state_bucket_name.
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
terraform output -raw backend_config_example
```

The bootstrap state initially remains local in this directory. Back up `terraform.tfstate` securely; it contains infrastructure metadata. Do not commit state or `.terraform/` to Git.

## 3. Configure production variables and backend

```bash
cd ../environments/prod
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your verified SES sender and destination email. The example destination is `rajptl244@gmail.com`; change it if needed.

Create `backend.hcl` using the bucket name created in step 2:

```hcl
bucket       = "YOUR_TERRAFORM_STATE_BUCKET"
key          = "lyken/prod/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
```

Then initialize and review the plan:

```bash
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Do not run `apply` until you have reviewed every resource and estimated the charges. Terraform state contains sensitive infrastructure metadata; restrict access.

## 4. Verify SES

In the AWS console, switch to the same region configured in Terraform and open Amazon SES:

1. Verify the sender email configured as `ses_from_email`.
2. If the account is in SES sandbox, verify the recipient email too, or request production access.
3. Check SES sending status and quotas before testing the public form.

## 5. Upload your existing static website

Copy your existing static site files into the repository's `website/` directory. `index.html` must be at its root. Ensure your contact form sends JSON to `/api/contact`:

```javascript
const response = await fetch('/api/contact', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ name, email, message })
});
const result = await response.json();
if (!response.ok) throw new Error(result.message || 'Unable to submit inquiry');
// Show “Inquiry received”, not “Email delivered”.
```

Deploy the static files after Terraform has created the bucket and distribution:

```bash
aws s3 sync website/ "s3://$(terraform -chdir=terraform/environments/prod output -raw website_bucket_name)/" --delete
aws cloudfront create-invalidation \
  --distribution-id "$(terraform -chdir=terraform/environments/prod output -raw cloudfront_distribution_id)" \
  --paths '/*'
```

Open the `website_url` Terraform output. The CloudFront distribution may take several minutes to deploy.

## 6. GitHub Actions without OIDC

The workflow at `.github/workflows/cicd.yml` runs validation on pull requests and pushes to `main`. Deployment only runs when manually triggered from the `main` branch.

If (and only if) your administrator permits an IAM access key for CI, create a dedicated least-privilege deployment identity and configure:

**GitHub repository → Settings → Secrets and variables → Actions**

Secrets:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Variables:
- `AWS_REGION` (e.g. `ap-south-1`)
- `TF_STATE_BUCKET` (state bucket from step 2)
- `SES_FROM_EMAIL`
- `NOTIFICATION_TO_EMAIL`

Create a GitHub Environment named `production` and enable required reviewers if available. Do not use root credentials or personal administrator credentials. If project policy does not allow access keys, keep CI validation enabled and deploy manually from an authorized workstation; do not try to bypass the restriction.

The workflow's IAM identity needs permissions for Terraform-managed resources, state bucket access and lockfile operations, S3 website sync, CloudFront invalidations, and `sts:GetCallerIdentity`. The exact least-privilege policy depends on the resources and account policy; ask the administrator to approve it. The workflow does not create its own deployment access key.

## 7. Contact API contract

Request:

```http
POST /api/contact
Content-Type: application/json
```

```json
{"name":"Visitor Name","email":"visitor@example.com","message":"Project details"}
```

Optional spam honeypot: `"website":""` (must remain empty for real visitors).

Success response: HTTP `202` with a message saying the inquiry has been received. Lambda validates fields, publishes a `ContactInquiryReceived` event to EventBridge, EventBridge routes it to SQS, and the worker sends the email via SES.

## 8. Troubleshooting notes

- `AccessDenied`: your IAM project permissions may not include the action. Do not broaden permissions blindly; identify the denied action and request it from the administrator.
- SES `MessageRejected`: verify sender and recipient identities and sandbox status in the configured region.
- CloudFront 403: confirm the bucket policy, OAC, distribution deployment state, and that `index.html` was uploaded.
- Contact form 404: confirm the request path is exactly `/api/contact`; CloudFront routes `/api/*` to API Gateway.
- Contact form 502/500: inspect `/aws/lambda/lyken-prod-submit-inquiry` logs.
- Email not received: inspect `/aws/lambda/lyken-prod-notification-worker`, the SQS queue, and DLQ. Check SES sending metrics and suppression list.
- API throttling: adjust `api_throttle_rate` and `api_throttle_burst` only after reviewing abuse and cost risk.

## 9. Cleanup

To avoid ongoing charges, destroy production resources when finished:

```bash
cd terraform/environments/prod
terraform destroy
```

The website bucket is versioned. Empty current and noncurrent object versions if Terraform reports that the bucket cannot be deleted. Keep the Terraform state bucket until you are certain the state is no longer needed; it has `prevent_destroy` enabled and must be removed deliberately in a separate reviewed change.

## Architecture flow

Browser → CloudFront → private S3 website.

Browser → CloudFront `/api/*` behavior → API Gateway → submit Lambda → EventBridge custom bus → SQS notification queue → notification Lambda → SES → inbox.

SQS redrive DLQ captures repeatedly failing worker messages. EventBridge target DLQ captures failed deliveries to SQS. CloudWatch stores Lambda logs and alarms on Lambda errors and DLQ depth.
