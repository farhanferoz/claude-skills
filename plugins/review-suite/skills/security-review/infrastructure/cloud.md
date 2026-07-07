# Cloud Security Reference (AWS/GCP/Azure)

## Overview

This covers runtime cloud configuration and IAM as distinct from IaC source review (see `terraform.md`) — the same misconfigurations apply whether set via console, CLI, SDK calls, or IaC. Coverage is primarily AWS, with GCP and Azure equivalents noted where the pattern differs materially. Focus on identity/access boundaries, the instance metadata service, and data-storage exposure — these three categories account for most cloud breach post-mortems.

---

## IAM Privilege Escalation

### Flag These

```json
// FLAG: iam:PassRole + a service that can assume that role = privilege escalation path
// A principal with only these two permissions can create a Lambda/EC2 instance
// running as a highly privileged role they could not otherwise assume directly.
{
  "Effect": "Allow",
  "Action": ["iam:PassRole", "lambda:CreateFunction", "lambda:InvokeFunction"],
  "Resource": "*"
}
```

```json
// FLAG: iam:CreatePolicyVersion / SetDefaultPolicyVersion — lets a principal
// rewrite their own (or another) policy's permissions
{
  "Effect": "Allow",
  "Action": ["iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion"],
  "Resource": "*"
}
```

```json
// FLAG: Wildcard action/resource on an identity or resource policy
{
  "Effect": "Allow",
  "Action": "*",
  "Resource": "*"
}
```

```json
// FLAG: sts:AssumeRole with a trust policy that allows any AWS principal
{
  "Effect": "Allow",
  "Principal": { "AWS": "*" },
  "Action": "sts:AssumeRole"
}
```

### Safe Patterns (Do Not Flag)

```json
// SAFE: PassRole scoped to a specific role ARN, and only for a specific service
{
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": "arn:aws:iam::123456789012:role/lambda-execution-role",
  "Condition": {
    "StringEquals": { "iam:PassedToService": "lambda.amazonaws.com" }
  }
}
```

There are roughly two dozen known AWS IAM privilege-escalation permission combinations (PassRole+CreateFunction, CreatePolicyVersion, AttachUserPolicy, CreateAccessKey for another user, etc.) — treat any policy granting one of these combinations to a broadly-assumable principal as HIGH confidence, not just the classic `"*":"*"` case.

---

## Metadata Service SSRF

### Flag These

```python
# FLAG: Any SSRF-reachable endpoint on an EC2 instance without IMDSv2 enforced can be
# used to steal the instance role's temporary credentials via the metadata service
requests.get(user_supplied_url)   # if the instance allows IMDSv1, attacker can point
                                    # this at http://169.254.169.254/latest/meta-data/iam/...
```

```hcl
# FLAG: EC2 instance/launch template not requiring IMDSv2 (token-based)
resource "aws_instance" "app" {
  metadata_options {
    http_tokens = "optional"    # IMDSv1 still allowed — vulnerable to SSRF credential theft
  }
}
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: IMDSv2 required (session-token-based, not vulnerable to basic SSRF GET)
resource "aws_instance" "app" {
  metadata_options {
    http_tokens   = "required"
    http_put_response_hop_limit = 1   # also blocks reachability through a container proxy
  }
}
```

```
# GCP equivalent: metadata server at http://metadata.google.internal/ — require the
# "Metadata-Flavor: Google" header (blocks naive SSRF via plain GET) and prefer
# workload identity over instance-level service account keys.

# Azure equivalent: IMDS at http://169.254.169.254/metadata/instance — requires the
# "Metadata: true" header; scope managed identity permissions minimally per resource.
```

IMDSv1 (no required header/token) is the classic SSRF-to-credential-theft chain — any HTTP client on the instance that fetches an attacker-influenced URL, combined with IMDSv1 still being enabled, is a critical finding even if the SSRF itself looks "minor."

---

## Public Buckets / Storage

### Flag These

```bash
# FLAG: S3 bucket ACL or policy grants public read/write (see terraform.md for IaC form)
aws s3api get-bucket-acl --bucket mybucket
# Grantee URI: http://acs.amazonaws.com/groups/global/AllUsers  -> FLAG

aws s3api get-bucket-policy-status --bucket mybucket
# "IsPublic": true  -> FLAG
```

```bash
# FLAG: GCS bucket with allUsers/allAuthenticatedUsers IAM binding
gsutil iam get gs://mybucket
# "members": ["allUsers"]  -> FLAG

# FLAG: Azure Blob container with public access level set to Container/Blob
az storage container show --name mycontainer --account-name myaccount
# "publicAccess": "container"  -> FLAG
```

### Safe Patterns (Do Not Flag)

```bash
# SAFE: Public access blocked at the account/bucket level
aws s3api get-public-access-block --bucket mybucket
# All four settings true -> SAFE

# SAFE: Access via signed URLs / presigned requests, not a public bucket policy
```

A bucket intentionally serving public static assets (e.g. a CDN origin) is expected to be public — only flag it if it also holds anything resembling backups, logs, database dumps, Terraform state, or PII. Check bucket naming and contents, not just the ACL, before deciding severity.

---

## KMS Misuse

### Flag These

```json
// FLAG: KMS key policy grants decrypt to a wildcard principal
{
  "Effect": "Allow",
  "Principal": "*",
  "Action": "kms:Decrypt",
  "Resource": "*"
}
```

```hcl
# FLAG: Sensitive data (RDS, EBS, S3) using the AWS-managed default key instead of a
# customer-managed key — default keys can't have a restrictive key policy, key rotation
# schedule, or CloudTrail-visible per-key access control tailored to this data
resource "aws_db_instance" "main" {
  storage_encrypted = true
  # kms_key_id not set -> uses aws/rds default managed key
}
```

```bash
# FLAG: Key rotation disabled on a customer-managed key holding long-lived sensitive data
aws kms get-key-rotation-status --key-id <id>
# "KeyRotationEnabled": false  -> FLAG for long-lived secrets/data keys
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: Customer-managed key with a scoped key policy and rotation enabled
resource "aws_kms_key" "data" {
  enable_key_rotation = true
  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::123456789012:role/app-role" }
      Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource  = "*"
    }]
  })
}
```

Using the AWS-managed default key is not automatically a vulnerability — it's a lower-severity finding for genuinely sensitive data (health, financial, credentials) where per-resource key policies and rotation control matter, and a non-issue for routine encryption-at-rest of non-sensitive data.

---

## GCP and Azure Notes

- **GCP IAM**: `roles/owner`/`roles/editor` granted broadly, or a service account key (long-lived JSON credential) checked into a repo or embedded in a container image, are the GCP equivalents of an AWS wildcard policy and hardcoded access key respectively. Prefer Workload Identity Federation over exported service account keys.
- **GCP Storage**: `allUsers`/`allAuthenticatedUsers` IAM bindings on a bucket are the direct equivalent of an S3 public ACL — flag identically.
- **Azure RBAC**: `Owner`/`Contributor` roles assigned at the subscription scope to a broad group, or Storage Account keys (as opposed to Azure AD-based access) used for application access, are the equivalent risk patterns.
- **Azure Key Vault**: access policies (or RBAC-based Key Vault permissions) granting `Get`/`List`/`Decrypt` on secrets to overly broad principals mirror the AWS KMS key-policy risk above.

---

## Grep Patterns

```bash
# IAM wildcard actions/resources (policy JSON files)
grep -rn '"Action":\s*"\*"\|"Resource":\s*"\*"' --include="*.json"

# PassRole combined with compute-service create actions
grep -rn "iam:PassRole" --include="*.json" --include="*.tf"

# IMDSv1 not enforced
grep -rn 'http_tokens\s*=\s*"optional"' --include="*.tf"

# Public bucket indicators
grep -rn "AllUsers\|allUsers\|allAuthenticatedUsers\|public-read" --include="*.tf" --include="*.json"

# Default (non-customer-managed) KMS key on sensitive resources
grep -rln "storage_encrypted\s*=\s*true" --include="*.tf" | xargs grep -L "kms_key_id"

# Hardcoded cloud credentials
grep -rEn "AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}" .
```

---

## Testing Checklist

- [ ] No IAM policy combines `iam:PassRole` with an unscoped resource-creation permission
- [ ] No trust policy allows `Principal: "*"` for `sts:AssumeRole`
- [ ] EC2 instances require IMDSv2 (`http_tokens = "required"`)
- [ ] No storage bucket/container is public unless intentionally serving public assets
- [ ] Public buckets checked for accidental sensitive content (backups, state, PII)
- [ ] Sensitive data encrypted with a customer-managed key, not the account default key
- [ ] KMS/Key Vault key policies scoped to specific principals, not wildcarded
- [ ] Key rotation enabled for long-lived customer-managed keys
- [ ] No long-lived service-account keys or access keys committed to source control

---

## References

- [AWS IAM Privilege Escalation Techniques](https://rhinosecuritylabs.com/aws/aws-privilege-escalation-methods-mitigation/)
- [AWS EC2 Instance Metadata Service v2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [OWASP Cloud Security Cheat Sheets](https://cheatsheetseries.owasp.org/)
