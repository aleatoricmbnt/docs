# Agent Job Proxy Test

This directory contains the manifests and instructions required to set up a local Squid Proxy within the agent namespace to verify Scalr Agent proxy functionality.

**Namespace:** Replace `<namespace>` with your namespace name in manifests and commands.

---

## 1. Components

### squid-full.yaml

Deploys a Squid proxy server.

- **Image:** `ubuntu/squid:latest`
- **Port:** 3128
- **Key Configs:**
  - Logging is disabled (`access_log none`) to prevent permission issues with `/dev/stdout`.
  - Blocks `.ifconfig.me` for testing purposes.
  - Runs in the foreground (`-NYd 1`) to keep the container alive in K8s.

```yaml squid-full.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: squid-config
  namespace: <namespace>
data:
  squid.conf: |
    # Test Block
    acl blocked_test_site dstdomain .ifconfig.me
    http_access deny blocked_test_site

    # Standard Setup
    http_access allow all
    http_port 3128

    # Disable all logging to avoid permission/pipe errors
    access_log none
    cache_log /dev/null
---
apiVersion: v1
kind: Service
metadata:
  name: squid-proxy
  namespace: <namespace>
spec:
  selector:
    app: squid
  ports:
    - protocol: TCP
      port: 3128
      targetPort: 3128
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: squid
  namespace: <namespace>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: squid
  template:
    metadata:
      labels:
        app: squid
    spec:
      containers:
      - name: squid
        image: ubuntu/squid:latest
        # -N: No daemon mode
        # -d 1: Minimum logging to stderr (startup info only)
        args: ["-NYd", "1"]
        ports:
        - containerPort: 3128
        volumeMounts:
        - name: config-volume
          mountPath: /etc/squid/squid.conf
          subPath: squid.conf
        - name: var-run
          mountPath: /var/run
      volumes:
      - name: config-volume
        configMap:
          name: squid-config
      - name: var-run
        emptyDir: {}
```

### allow-squid-egress.yaml

A NetworkPolicy extension.

- **Purpose:** The default Scalr Agent Helm chart often includes a restrictive NetworkPolicy that only allows DNS (port 53) and general egress. This policy explicitly allows the Agent's "Task" (runner) pods to talk to the Proxy on port 3128.

```yaml allow-squid-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mshytse-allow-proxy-egress-simple
  namespace: <namespace>
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: task
      app.kubernetes.io/instance: mshytse
  policyTypes:
  - Egress
  egress:
  - ports:
    - protocol: TCP
      port: 3128
    # No "to" section means "Allow to any destination"
```

---

## 2. Installation Steps

### Step 1: Deploy Squid

```bash
kubectl apply -f squid-full.yaml
```

Verify the pod is running and accepting connections:

```bash
kubectl logs -n <namespace> -l app=squid
# Look for something like: "Accepting HTTP Socket connections at ... port 3128"
```

### Step 2: Apply Network Policy

By default, the Agent Task pods may hang when trying to reach the proxy. Apply the egress rule:

```bash
kubectl apply -f allow-squid-egress.yaml
```

### Step 3: Deploy/Upgrade Scalr Agent

Deploy the agent using Helm, ensuring the proxy environment variables are set to point to the internal service.

```bash
helm upgrade --install --namespace=<namespace> mshytse scalr-agent-helm/agent-job \
    --set agent.token="<YOUR_TOKEN>" \
    --set global.proxy.enabled="true" \
    --set global.proxy.httpProxy="http://squid-proxy:3128" \
    --set global.proxy.httpsProxy="http://squid-proxy:3128" \
    --set global.proxy.noProxy="localhost,127.0.0.1,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.169.254"
```

---

## 3. Verification Commands

Run these via run custom hook:

### Test A: Successful Proxying

Should return a 200 Connection established.

```bash
curl https://google.com
```

### Test B: Blocked Domain

Should return a 403 Forbidden (This proves the proxy is the one handling the request).

```bash
curl https://ifconfig.me
```

### Test C: Metadata Protection

Ensure the Agent cannot reach the Cloud Metadata (it shouldn't be proxied). Should timeout.

```bash
curl -I --connect-timeout 2 http://169.254.169.254/metadata/instance?api-version=2021-02-01
```

---

## 4. Troubleshooting

- **Infinite Hang:** If curl hangs at "Trying 10.x.x.x...", the NetworkPolicy is likely blocking egress from the task pod or ingress to the squid pod.
- **Broken Pipe:** Usually related to Squid trying to write logs to a restricted `/dev/stdout`. Ensure `access_log none` is in the ConfigMap.
