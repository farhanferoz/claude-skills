# Kubernetes Security Reference

## Overview

Kubernetes misconfigurations in pod specs, RBAC, secrets handling, and network policy commonly lead to container breakout, lateral movement across the cluster, or credential exposure. Review manifests, Helm charts, and Kustomize overlays together — defaults set in a base template are frequently the actual source of a vulnerable value.

---

## Privileged Pods

### Flag These

```yaml
# FLAG: Privileged container — full access to host devices/kernel
spec:
  containers:
    - name: app
      securityContext:
        privileged: true

# FLAG: Dangerous added capabilities
securityContext:
  capabilities:
    add: ["SYS_ADMIN", "NET_ADMIN", "ALL"]

# FLAG: Allows privilege escalation from a non-root process (e.g. via setuid binaries)
securityContext:
  allowPrivilegeEscalation: true  # default is true unless explicitly set false

# FLAG: Running as root with no runAsNonRoot constraint
securityContext:
  runAsUser: 0
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: Restrictive pod security context
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

---

## hostPath and Host Namespace Sharing

### Flag These

```yaml
# FLAG: hostPath mount exposes host filesystem to the container
volumes:
  - name: host-root
    hostPath:
      path: /            # entire host filesystem
      type: Directory

volumes:
  - name: docker-sock
    hostPath:
      path: /var/run/docker.sock   # container can control the host's Docker daemon

# FLAG: Sharing host namespaces
spec:
  hostNetwork: true   # bypasses network policy / sees host network traffic
  hostPID: true        # can see and signal host processes
  hostIPC: true         # shares host IPC namespace
```

### Check Context

```yaml
# CHECK: Narrow hostPath mounts (e.g. for a node-level log directory) are lower risk
# than mounting /, /etc, /var/run/docker.sock, or the kubelet's credential directory —
# still confirm the mount is read-only and actually necessary (e.g. a DaemonSet log shipper).
volumes:
  - name: varlog
    hostPath:
      path: /var/log
volumeMounts:
  - name: varlog
    mountPath: /var/log
    readOnly: true
```

---

## RBAC

### Flag These

```yaml
# FLAG: Wildcard verbs/resources — effectively cluster-admin
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]

# FLAG: cluster-admin bound to a broad or default subject
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dangerous-binding
subjects:
  - kind: ServiceAccount
    name: default
    namespace: default
roleRef:
  kind: ClusterRole
  name: cluster-admin

# FLAG: secrets/exec/pods/attach access granted broadly
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]  # cluster-wide secret read access
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]                 # exec into any pod = de facto root on nodes
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: Namespaced Role scoped to specific resources and verbs
kind: Role
metadata:
  namespace: app-team
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
```

The `default` ServiceAccount in a namespace is auto-mounted into every pod that doesn't set `automountServiceAccountToken: false` — flag any binding of privileged permissions to it, and flag pods that don't disable the auto-mount when they don't need API access.

---

## Secrets Handling

### Flag These

```yaml
# FLAG: Secret values hardcoded directly in a manifest committed to source control
apiVersion: v1
kind: Secret
data:
  password: cGFzc3dvcmQxMjM=   # base64 is encoding, not encryption — trivially reversible

# FLAG: Secret injected as a plaintext environment variable
# (visible via `kubectl describe pod`, process env, and often crash-dump/log tooling)
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: password

# FLAG: etcd encryption at rest not configured (cluster-level, verify with the platform team)
```

### Safer Patterns

```yaml
# SAFER: Mounted as a file, not an env var (reduces exposure via env dumps/child processes)
volumes:
  - name: db-secret
    secret:
      secretName: db-secret
volumeMounts:
  - name: db-secret
    mountPath: /etc/secrets
    readOnly: true

# SAFER: External secret manager integration (Vault, External Secrets Operator, cloud KMS)
```

`valueFrom.secretKeyRef` is the standard, expected way to consume a Kubernetes Secret — flag it as a note/informational item about blast radius (env vars leak more easily than mounted files), not as a hard vulnerability, unless the underlying `Secret` object itself has hardcoded/committed data.

---

## Network Policies

### Flag These

```yaml
# FLAG: No NetworkPolicy present in the namespace — default is allow-all pod-to-pod traffic
# (absence is the finding; grep for a NetworkPolicy resource covering this namespace)

# FLAG: NetworkPolicy that allows all ingress despite being present
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector: {}
  ingress:
    - {}   # empty rule = allow from anywhere
```

### Safe Patterns (Do Not Flag)

```yaml
# SAFE: Default-deny baseline plus explicit allow rules
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels: { app: backend }
  ingress:
    - from:
        - podSelector: { matchLabels: { app: frontend } }
      ports:
        - port: 8080
```

---

## Admission Control

### Check Context

```yaml
# CHECK: Pod Security Admission (or legacy PSP) not enforcing a restricted baseline
# for namespaces that run untrusted or user-supplied workloads
apiVersion: v1
kind: Namespace
metadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged  # FLAG if this namespace runs general workloads

# SAFE: restricted baseline for general application namespaces
labels:
  pod-security.kubernetes.io/enforce: restricted

# CHECK: No image policy / admission webhook restricting image provenance
# (allows pulling from any untrusted registry, including :latest with no digest pin)
```

---

## Grep Patterns

```bash
# Privileged / capability escalation
grep -rn "privileged: true\|allowPrivilegeEscalation: true\|SYS_ADMIN\|NET_ADMIN" --include="*.yaml" --include="*.yml"

# hostPath and host namespaces
grep -rn "hostPath:\|hostNetwork: true\|hostPID: true\|hostIPC: true" --include="*.yaml" --include="*.yml"

# RBAC wildcards
grep -rn 'resources: \["\*"\]\|verbs: \["\*"\]\|apiGroups: \["\*"\]' --include="*.yaml" --include="*.yml"

# cluster-admin bindings
grep -rn "cluster-admin" --include="*.yaml" --include="*.yml"

# Secrets as env vars
grep -rn "secretKeyRef" --include="*.yaml" --include="*.yml"

# Missing/allow-all network policy
grep -rln "kind: NetworkPolicy" --include="*.yaml" --include="*.yml"
```

---

## Testing Checklist

- [ ] No pods run `privileged: true` or add dangerous capabilities
- [ ] `allowPrivilegeEscalation: false` and non-root user set
- [ ] No `hostPath` mounts of sensitive host paths (`/`, `/etc`, docker/containerd sockets)
- [ ] `hostNetwork`/`hostPID`/`hostIPC` not used except where explicitly required
- [ ] RBAC roles scoped to specific namespaces, resources, and verbs (no wildcards)
- [ ] `default` ServiceAccount not bound to elevated roles; token auto-mount disabled where unneeded
- [ ] Secrets consumed as mounted volumes where practical; source manifests hold no hardcoded values
- [ ] Default-deny `NetworkPolicy` present, with explicit allow rules for required traffic
- [ ] Pod Security Admission set to `restricted`/`baseline` for general workloads
- [ ] Images pinned by digest and pulled from an allowlisted registry

---

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
