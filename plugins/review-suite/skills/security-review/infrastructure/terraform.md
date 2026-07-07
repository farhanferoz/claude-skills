# Terraform Security Reference

## Overview

Infrastructure-as-code misconfigurations are reproduced on every `apply`, so a single bad default in a module propagates to every environment that consumes it. Review both the resource definitions and any shared/reusable modules — a public-by-default module is a bigger finding than one bad resource instance.

---

## Public Storage

### Flag These

```hcl
# FLAG: S3 bucket with public ACL
resource "aws_s3_bucket_acl" "data" {
  bucket = aws_s3_bucket.data.id
  acl    = "public-read"    # or "public-read-write"
}

# FLAG: Bucket policy allowing anonymous access
resource "aws_s3_bucket_policy" "data" {
  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.data.arn}/*"
    }]
  })
}

# FLAG: Public access block explicitly disabled
resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# FLAG: GCS bucket granted to allUsers/allAuthenticatedUsers
resource "google_storage_bucket_iam_member" "public" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# FLAG: Azure Storage account allowing public blob access
resource "azurerm_storage_account" "data" {
  allow_nested_items_to_be_public = true
}
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: Public access block fully enabled
resource "aws_s3_bucket_public_access_block" "data" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

---

## Open Security Groups

### Flag These

```hcl
# FLAG: Ingress from anywhere on a sensitive port
resource "aws_security_group_rule" "ssh" {
  type        = "ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]   # SSH open to the internet
}

resource "aws_security_group_rule" "db" {
  from_port   = 5432
  to_port     = 5432
  cidr_blocks = ["0.0.0.0/0"]   # database port open to the internet
}

# FLAG: All ports/protocols open
resource "aws_security_group_rule" "allow_all" {
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

# FLAG: Azure NSG rule with wildcard source
resource "azurerm_network_security_rule" "open" {
  source_address_prefix      = "*"
  destination_port_range     = "*"
  access                     = "Allow"
}
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: Scoped to a known CIDR (office/VPN range) or a security-group reference
resource "aws_security_group_rule" "ssh" {
  from_port                = 22
  to_port                  = 22
  cidr_blocks               = ["10.0.0.0/8"]           # internal only
}

resource "aws_security_group_rule" "internal" {
  source_security_group_id = aws_security_group.bastion.id  # SG-to-SG reference
}
```

`0.0.0.0/0` on port 80/443 for a public-facing load balancer is expected — only flag it on administrative (22, 3389), database (3306, 5432, 6379, 27017, 9200), or internal management ports.

---

## Hardcoded Secrets

### Flag These

```hcl
# FLAG: Credentials as literal string values in .tf files
provider "aws" {
  access_key = "AKIAIOSFODNN7EXAMPLE"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
}

resource "aws_db_instance" "main" {
  username = "admin"
  password = "SuperSecret123!"   # FLAG: committed plaintext password
}

# FLAG: Default value on a "secret" variable makes it effectively hardcoded
variable "db_password" {
  type    = string
  default = "changeme"   # defeats the purpose of a variable
}
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: Sourced from a secret manager at apply time
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "prod/db/password"
}

resource "aws_db_instance" "main" {
  password = data.aws_secretsmanager_secret_version.db.secret_string
}

# SAFE: Variable with no default, marked sensitive, populated via TF_VAR_ or a tfvars
# file that is itself gitignored / stored in a secrets backend
variable "db_password" {
  type      = string
  sensitive = true
}
```

`sensitive = true` only redacts a value from CLI/plan output — it does not encrypt it in the state file. Still flag secrets passed as plain Terraform variables without a secrets-manager backend if the state file storage isn't independently verified as encrypted.

---

## IAM Wildcards

### Flag These

```hcl
# FLAG: Wildcard action and resource — equivalent to full account admin
resource "aws_iam_policy" "admin" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = "*"
      Resource = "*"
    }]
  })
}

# FLAG: Wildcard action scoped to a resource is still broad
resource "aws_iam_policy" "s3_wildcard" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:*"
      Resource = "*"
    }]
  })
}

# FLAG: iam:PassRole combined with a broad principal — enables privilege escalation
# (attacker with this permission can pass a highly privileged role to a service they control)
resource "aws_iam_policy" "pass_role" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = "iam:PassRole"
      Resource = "*"
    }]
  })
}
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: Scoped actions and resources
resource "aws_iam_policy" "read_only_bucket" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
    }]
  })
}
```

---

## State File Exposure

### Flag These

```hcl
# FLAG: Local state (no backend configured) — state, including any secret values it
# contains in plaintext, ends up committed or shared ad hoc
# (absence of a `backend` block in the root module is the finding itself)

# FLAG: Remote backend without encryption
terraform {
  backend "s3" {
    bucket = "tf-state"
    key    = "prod/terraform.tfstate"
    # missing: encrypt = true
  }
}

# FLAG: State bucket itself is publicly readable — see "Public Storage" above,
# doubly critical for a bucket holding Terraform state (often contains secrets in plaintext)
```

### Safe Patterns (Do Not Flag)

```hcl
# SAFE: Encrypted remote backend with state locking
terraform {
  backend "s3" {
    bucket         = "tf-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-lock"
  }
}
```

Terraform state routinely contains resource attributes in plaintext — including database passwords and API keys set via resource arguments — regardless of how carefully the `.tf` source avoids hardcoding them. Treat any state file storage location as a secret and verify it is encrypted at rest and access-restricted, not just that the source files look clean.

---

## Grep Patterns

```bash
# Public storage
grep -rn 'acl\s*=\s*"public\|allUsers\|allow_nested_items_to_be_public\s*=\s*true' --include="*.tf"

# Open security groups
grep -rn '0\.0\.0\.0/0' --include="*.tf"

# Hardcoded credentials
grep -rEn 'access_key\s*=\s*"|secret_key\s*=\s*"|password\s*=\s*"[^$]' --include="*.tf"

# IAM wildcards
grep -rn '"Action":\s*"\*"\|Action\s*=\s*"\*"\|Resource\s*=\s*"\*"' --include="*.tf"

# Missing/unencrypted backend
grep -rln 'backend "s3"' --include="*.tf" | xargs grep -L "encrypt"
```

---

## Testing Checklist

- [ ] No S3/GCS/Azure storage resources grant public read/write access
- [ ] Public access blocks enabled on every bucket
- [ ] No security group / NSG rule opens admin or database ports to `0.0.0.0/0`
- [ ] No credentials, passwords, or API keys as literal `.tf` values or variable defaults
- [ ] Secrets sourced from a secrets manager, not plain `tfvars`
- [ ] No IAM policy uses `"*"` for both Action and Resource
- [ ] `iam:PassRole` scoped to specific roles, not `Resource = "*"`
- [ ] Remote state backend configured with encryption and locking
- [ ] State storage bucket/container itself is private and access-restricted

---

## References

- [Terraform Security Best Practices](https://developer.hashicorp.com/terraform/tutorials/aws/aws-integrations)
- [OWASP Cloud Security Cheat Sheets](https://cheatsheetseries.owasp.org/)
- [tfsec / Trivy IaC scanning rules](https://aquasecurity.github.io/tfsec/)
