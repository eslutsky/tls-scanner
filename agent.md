# TLS Scanner Agent Guide

## 🎯 Project Overview

This is a TLS/SSL security scanner that runs as a Kubernetes Job in OpenShift/CRC clusters. It:
- Scans pods in the cluster for open ports using `nmap`
- Detects TLS/SSL cipher suites and protocols
- Identifies processes listening on ports using `lsof`
- Outputs results in JSON, CSV, and log formats

**Critical Context:**
- Scanner runs **inside** the cluster as a privileged pod
- Container image size: **~1.4 GB**
- CRC environment has **limited disk space** (~4-5GB available)
- Artifacts are stored in ephemeral storage and must be copied before pod exits

---

## ⚠️ DANGEROUS COMMANDS - NEVER RUN WITHOUT EXPLICIT USER APPROVAL

### 🔥 DESTRUCTIVE - Will Delete Everything
```bash
crc cleanup          # DESTROYS entire CRC VM, all data, all configs
crc delete           # Removes the CRC instance completely
crc stop --force     # Force stops CRC (may corrupt data)
```

### ⚠️ POTENTIALLY DESTRUCTIVE - Ask First
```bash
oc delete namespace <name>           # Deletes entire namespace and all resources
oc delete job --all                  # Deletes all jobs in namespace
oc adm prune images --confirm        # May delete images still in use
podman system prune -af              # Deletes all local images/containers
```

**ALWAYS ask the user before running any of these commands!**

---

## 🧹 Safe Cleanup Procedures

### Handling CRC Disk Space Issues (MOST COMMON PROBLEM)

**Symptoms:**
- Pods show status `Evicted` or `Failed`
- Pod description shows: "The node was low on resource: ephemeral-storage"
- Available disk space < 5GB

**Safe Resolution Steps (in order):**

1. **Delete failed/evicted pods** (safest):
   ```bash
   oc delete pods -n default -l job-name=tls-scanner-job --field-selector=status.phase=Failed
   oc delete pods --field-selector=status.phase=Evicted --all-namespaces
   ```

2. **Delete completed scanner jobs** (keeps current one):
   ```bash
   oc delete job tls-scanner-job -n default
   ```

3. **Check disk space on node** (read-only):
   ```bash
   oc get nodes
   oc describe node/crc | grep -A 5 "Allocated resources"
   ```

4. **If desperate, restart CRC** (last resort):
   ```bash
   crc stop
   crc start
   ```
   This is much better than `crc cleanup` as it preserves the VM and configuration.

**DO NOT:**
- Run `crc cleanup` (destroys everything)
- Run `crc delete` (destroys everything)
- Try to SSH into CRC node to manually clean disk (risky)

---

## 📁 Project Structure

```
tls-scanner/
├── deploy.sh                      # Main deployment script
├── scanner-job.yaml.template      # Kubernetes Job template
├── Dockerfile.local               # Container image definition
├── cmd/scanner/                   # Main Go application
├── pkg/                           # Scanner logic packages
└── artifacts/                     # Output directory (created by deploy.sh)
    ├── results.json              # JSON scan results
    ├── results.csv               # CSV scan results
    └── scan.log                  # Detailed scan logs
```

---

## 🚀 Deployment Workflow

### Standard Deployment
```bash
./deploy.sh --local full-deploy
```

This performs:
1. **Build**: Compiles Go binary and builds ~1.4GB container image
2. **Push**: Pushes to OpenShift internal registry
3. **Deploy**: Creates Kubernetes Job with scanner pod
4. **Wait**: Monitors for "Scanner finished" message
5. **Copy**: Copies artifacts from pod (during 300-second sleep window)
6. **Complete**: Waits for job to complete

### Important Flags

**Scanner flags** (in scanner-job.yaml.template):
- `--all-pods`: Scan all pods in cluster (default behavior)
- `--namespace <name>`: Scan only specific namespace
- `--limit-ips <N>`: Limit scan to first N IPs (use for testing!)
- `--json-file <path>`: Output JSON results
- `--csv-file <path>`: Output CSV results
- `--log-file <path>`: Output detailed logs

**Deployment modes**:
- `--local`: Use CRC internal registry (most common)
- Without `--local`: Use external registry (requires SCANNER_IMAGE env var)

---

## 🧪 Testing TLS Configuration Detection

To validate the scanner correctly detects TLS configuration changes on the API Server:

### Run TLS Config Test
```bash
./deploy.sh --local test-tls-config
```

### What This Test Does

1. **Saves** current API Server TLS configuration
2. **Applies** restrictive TLS 1.2 config with single cipher (ECDHE-RSA-AES128-GCM-SHA256)
3. **Waits** for cluster to stabilize (~10 minutes by default)
4. **Runs** scanner against API server pods (openshift-kube-apiserver, openshift-apiserver)
5. **Verifies** scan detects TLS 1.2 and the configured cipher
6. **Restores** original configuration
7. **Reports** pass/fail with detailed results

**Note:** TLS 1.3 cipher suites are not configurable per the TLS 1.3 specification, so the test uses TLS 1.2 which allows cipher customization.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TLS_TEST_TIMEOUT` | 600 | Timeout in seconds for cluster stabilization |

### Example Usage

```bash
# Run with default settings (scans openshift-kube-apiserver,openshift-apiserver)
./deploy.sh --local test-tls-config

# Run with custom timeout (15 minutes)
TLS_TEST_TIMEOUT=900 ./deploy.sh --local test-tls-config

# Test a specific namespace only
./deploy.sh --local -n openshift-kube-apiserver test-tls-config

# Test multiple specific namespaces
./deploy.sh --local -n "openshift-apiserver,openshift-oauth-apiserver" test-tls-config
```

### Test Results

Results are saved to `./tls-test-results/custom-tls-scan/`:
- `results.json` - Full JSON scan results
- `results.csv` - CSV format results
- `scan.log` - Detailed scan logs

### What PASS Means

The test passes when the scanner correctly detects:
- **TLS Version**: TLSv1.2
- **Cipher**: ECDHE-RSA-AES128-GCM-SHA256 (or IANA equivalent: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256)

### What FAIL Means

The test fails if:
- Unexpected TLS versions are detected
- Additional/unexpected ciphers are detected
- No TLS information is detected at all
- The cluster doesn't stabilize within the timeout

### Important Notes

- This test **modifies live cluster configuration** and requires cluster-admin privileges
- The test includes automatic restoration of original config on failure or interruption
- Use `Ctrl+C` to abort - original config will still be restored

---

## 📊 Viewing Nmap Scan Results

### Option 1: Pod Logs (Real-time, Always Available)
```bash
# Find the scanner pod
oc get pods -n default -l job-name=tls-scanner-job

# View logs (includes full nmap XML output)
oc logs pod/<pod-name> -n default

# Follow logs in real-time
oc logs -f job/tls-scanner-job -n default
```

**What you'll see in logs:**
- Full nmap command executed
- Complete XML output from nmap
- TLS cipher suites discovered
- Process names from lsof
- Progress through all IPs

### Option 2: Artifact Files (Structured Data)
```bash
# After successful deployment:
ls -lh ./artifacts/
cat ./artifacts/results.json    # JSON format
cat ./artifacts/results.csv     # CSV format
cat ./artifacts/scan.log        # Same as pod logs
```

**Note:** Artifacts only available if:
- Scan completed successfully
- Artifacts were copied during the 300-second sleep window
- Pod didn't get evicted due to disk space

---

## 🐛 Known Issues & Solutions

### Issue 1: Pod Evicted Due to Disk Pressure
**Symptoms:**
```
Status: Failed
Reason: Evicted
Message: The node was low on resource: ephemeral-storage
```

**Solution:**
1. Delete old failed pods (see "Safe Cleanup Procedures")
2. Reduce scan scope: Add `--limit-ips 5` to scanner-job.yaml.template
3. Don't run full scans on disk-constrained CRC

### Issue 2: Cannot Copy Artifacts from Completed Pod
**Symptoms:**
```
error: cannot exec into a container in a completed pod; current phase is Succeeded
```

**Root Cause:**
- Pod already exited; `oc cp` requires running pod
- Artifacts stored in emptyDir volume (deleted when pod terminates)

**Solution:**
- This should NOT happen anymore - deploy.sh now copies during sleep window
- If it does happen, artifacts are lost but logs are still available via `oc logs`

### Issue 3: "Invalid Reference Format" When Building Image
**Symptoms:**
```
Error: tag default-route-openshift-image-registry.apps-crc.testing//tls-scanner:latest: invalid reference format
```

**Root Cause:**
- Double slash `//` in image name
- Registry namespace not set correctly

**Solution:**
- Check NAMESPACE environment variable
- Ensure `oc project` shows correct namespace
- Verify `--local` flag is used with deploy.sh

### Issue 4: Scan Seems Stuck or Very Slow
**Normal Behavior:**
- Each IP takes 15-90 seconds to scan (nmap is thorough)
- Full cluster scan (70 pods) can take 20+ minutes
- Progress visible in logs

**If truly stuck:**
- Check pod logs: `oc logs -f job/tls-scanner-job`
- Check pod status: `oc describe pod/<pod-name>`
- May be blocked by network policies or firewalls

---

## 🔧 Troubleshooting Commands

### Check CRC Status
```bash
crc status
crc console --credentials    # Get admin password
```

### Check Deployment Status
```bash
oc get jobs -n default
oc get pods -n default -l job-name=tls-scanner-job
oc describe job/tls-scanner-job -n default
oc logs job/tls-scanner-job -n default
```

### Check Pod Details
```bash
oc get pod/<pod-name> -o yaml
oc describe pod/<pod-name>
oc logs pod/<pod-name> --previous    # View logs from crashed container
```

### Check Image Registry
```bash
oc get imagestream -n default
oc describe imagestream/tls-scanner -n default
```

### Check Node Resources
```bash
oc get nodes
oc describe node/crc
oc adm top nodes    # Requires metrics server
```

---

## 🔄 Recovery Procedures

### If CRC Gets Destroyed (e.g., after `crc cleanup`)
```bash
# This takes ~15-20 minutes
crc setup
crc start

# Configure oc client
eval $(crc oc-env)
oc login -u kubeadmin https://api.crc.testing:6443

# Redeploy scanner
cd ~/tls-scanner
./deploy.sh --local full-deploy
```

**Note:** All previous scan data is LOST. Backups are in `./artifacts/` if copied before destruction.

### If Pod Fails to Start
```bash
# Get detailed information
oc describe pod/<pod-name>
oc logs pod/<pod-name>

# Common fixes:
# 1. Delete and retry
oc delete job/tls-scanner-job
./deploy.sh --local deploy

# 2. Clean up disk space (see Safe Cleanup Procedures)

# 3. Reduce scan scope
# Edit scanner-job.yaml.template and add: --limit-ips 5
```

### If Artifacts Weren't Copied
**The logs contain all scan data!**
```bash
# Get the pod name
POD=$(oc get pods -n default -l job-name=tls-scanner-job -o jsonpath='{.items[0].metadata.name}')

# Save logs to file
oc logs pod/$POD -n default > scan-output.log

# Logs include:
# - Full nmap XML output for each IP
# - TLS cipher suites
# - Process information
# - Everything needed for analysis
```

---

## 📝 Best Practices for Agents

1. **Always check pod logs first** - they contain full scan output
2. **Use `--limit-ips` for testing** - saves time and disk space
3. **Ask before cleanup commands** - especially anything with `delete`, `prune`, `cleanup`
4. **Monitor disk space** - CRC has limited resources
5. **Copy artifacts during sleep window** - deploy.sh handles this now
6. **Read error messages carefully** - eviction vs failure have different solutions
7. **Prefer `oc logs` over artifact files** - logs are always available

---

## 🔍 Understanding the Scanner Output

### In Pod Logs
You'll see output like:
```
Running command: /usr/bin/nmap -Pn -sV --script ssl-enum-ciphers -p 8443 -oX - 10.217.0.10
Command output: <?xml version="1.0" encoding="UTF-8"?>
<nmaprun ...>
  <host>
    <ports>
      <port protocol="tcp" portid="8443">
        <service name="https-alt" tunnel="ssl"/>
        <script id="ssl-enum-ciphers">
          <table key="TLSv1.2">
            <table key="ciphers">
              <table>
                <elem key="name">TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256</elem>
                <elem key="strength">A</elem>
              </table>
            </table>
          </table>
        </script>
      </port>
    </ports>
  </host>
</nmaprun>
```

This shows:
- **Port**: 8443
- **Protocol**: TLS/SSL over HTTPS
- **Cipher**: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
- **Strength**: A (strong)

---

## 💡 Common Agent Mistakes to Avoid

1. ❌ Running `crc cleanup` to fix disk space (DESTROYS EVERYTHING)
   ✅ Delete failed pods instead

2. ❌ Trying to `oc cp` from completed pods
   ✅ Check logs with `oc logs` instead

3. ❌ Assuming artifacts are the only data source
   ✅ Pod logs contain full scan output

4. ❌ Running full scans without checking disk space
   ✅ Use `--limit-ips` for testing

5. ❌ Force-stopping or deleting running scans prematurely
   ✅ Let scans complete; they take 15-90s per IP

---

## 🎓 Learning Resources

- **Nmap SSL Script**: https://nmap.org/nsedoc/scripts/ssl-enum-ciphers.html
- **OpenShift Jobs**: https://docs.openshift.com/container-platform/latest/nodes/jobs/nodes-nodes-jobs.html
- **CRC Documentation**: https://crc.dev/crc/
- **TLS Cipher Suites**: https://ciphersuite.info/

---

## ✅ Quick Reference: What to Do When...

| Situation | Command | Notes |
|-----------|---------|-------|
| View scan progress | `oc logs -f job/tls-scanner-job` | Shows real-time nmap output |
| Pod evicted | Delete failed pods, free disk space | See "Safe Cleanup Procedures" |
| Check artifacts | `ls -lh ./artifacts/` | Only works if copy succeeded |
| Find pod name | `oc get pods -l job-name=tls-scanner-job` | Look for scanner pods |
| Redeploy scanner | `./deploy.sh --local full-deploy` | Full build + deploy |
| Quick redeploy | `./deploy.sh --local deploy` | Skip build if image unchanged |
| Test with small scan | Edit template, add `--limit-ips 5` | Faster, uses less space |
| CRC not responding | `crc stop && crc start` | NOT `crc cleanup`! |
| Need admin access | `crc console --credentials` | Get kubeadmin password |

---

**Remember:** When in doubt, check the logs first. The nmap scan output is always in `oc logs`, even if artifact copying fails!

