# Disaster Recovery as Code: OpenShift Virtualization and OADP via GitOps

A Proof of Concept (PoC) demonstrating how to reliably back up and restore KubeVirt Virtual Machines (VMs) using the OpenShift API for Data Protection (OADP) and Velero, backed by NooBaa object storage.

This repository proves how to maintain stable PersistentVolumeClaim (PVC) names during restore, satisfying the strict state-matching requirements of GitOps tools like Argo CD.

## Background: the GitOps naming challenge

When using KubeVirt's native `VirtualMachineRestore` API on storage backends like Ceph RBD, the snapshot controller commonly follows a delete-and-recreate flow. To avoid name collisions, it creates a replacement PVC with a generated name (for example `restore-<uuid>-<diskname>`).

**The problem:** GitOps controllers treat that generated PVC as drift. Argo CD sees an unmanaged PVC and a missing expected PVC, then may reconcile by deleting the restored volume and recreating an empty PVC from Git.

**The solution:** OADP (Velero) backs up Kubernetes manifests together with volume data. During restore, resources come back with their original names (`test-dr-vm`, `test-dr-vm-root`), so Argo CD sees expected state and reports `Synced` instead of overwriting recovered data.

## Repository structure

| Directory | Purpose |
|-----------|---------|
| [`setup/`](setup/) | OADP Operator deployment, NooBaa ObjectBucketClaim, Velero credentials bootstrap job, and `DataProtectionApplication` (DPA). |
| [`test-workload/`](test-workload/) | Workload namespace, `DataVolume` (CirrOS image), and `VirtualMachine` with fixed PVC name `test-dr-vm-root`. |
| [`backup/`](backup/) | Example Velero `Backup` Custom Resource (CR). |
| [`recovery/`](recovery/) | Example Velero `Restore` CR (apply only during DR drills). |
| [`gitops-install/`](gitops-install/) | OpenShift GitOps operator setup, `ArgoCD` overlay, and required RBAC. |
| [`argocd-apps/`](argocd-apps/) | Argo CD `Application` manifests for syncing setup/workload/recovery paths. |
| [`reset/`](reset/) | Automated teardown scripts. See [`reset/README.md`](reset/README.md). |

> Clone this repository into its own isolated directory to avoid nested Git trees.

## Prerequisites

- **Cluster access:** `cluster-admin` (or equivalent rights to create resources in `openshift-adp`, `dr-gitops-poc`, and GitOps namespaces).
- **Required operators:** OpenShift Virtualization, CDI, and OADP available in OperatorHub.
- **Storage:** NooBaa-backed storage class (commonly `openshift-storage.noobaa.io`).
- **Network:** Worker nodes can pull the CirrOS image in [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml), or update the image URL.

---

## Execution paths

You can run this PoC using:

1. **Path 1:** Manual CLI execution (`oc`)
2. **Path 2:** GitOps-driven sync using Argo CD

### Path 1: manual execution via `oc`

Ignore [`argocd-apps/`](argocd-apps/) for this path.

#### Part A: deploy OADP stack

You can run `./setup/apply-oadp-stack.sh` from the repository root, or apply resources in sequence:

1. **Install OADP operator**

```bash
oc apply -f setup/01-oadp-operator.yaml
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  -n openshift-adp subscription.operators.coreos.com/redhat-oadp-operator --timeout=20m
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  -n openshift-adp csv -l operators.coreos.com/redhat-oadp-operator.openshift-adp --timeout=15m
```

2. **Provision NooBaa bucket claim**

```bash
oc apply -f setup/02-noobaa-obc.yaml
oc wait obc/velero-dr-noobaa -n openshift-adp --for=jsonpath='{.status.phase}'=Bound --timeout=15m
```

3. **Bootstrap Velero credentials**

```bash
oc apply -f setup/03-cloud-credentials.yaml
oc wait --for=condition=complete job/velero-noobaa-creds-bootstrap -n openshift-adp --timeout=15m
```

4. **Deploy DataProtectionApplication**

```bash
oc apply -f setup/04-dpa.yaml
oc get backupstoragelocation -n openshift-adp
```

Wait until the default `BackupStorageLocation` reports `Available` before running backups.

#### Part B: deploy test workload

```bash
oc apply -f test-workload/01-test-vm.yaml
oc wait datavolume test-dr-vm-root -n dr-gitops-poc \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
oc wait virtualmachine test-dr-vm -n dr-gitops-poc \
  --for=jsonpath='{.status.printableStatus}'=Running --timeout=15m
```

#### Part C: execute backup

```bash
oc apply -f backup/01-backup-gitops-dr-gold.yaml
oc wait backup.velero.io/gitops-dr-gold-backup -n openshift-adp \
  --for=jsonpath='{.status.phase}'=Completed --timeout=30m
```

> `backup.velero.io/...` is used explicitly because short names can collide with other APIs on some clusters.

#### Part D: disaster recovery drill

1. **Simulate loss**

```bash
oc delete vm test-dr-vm -n dr-gitops-poc --wait=true
oc delete datavolume test-dr-vm-root -n dr-gitops-poc --wait=true
```

2. **Restore**

```bash
oc apply -f recovery/01-restore.yaml
oc wait restore.velero.io/gitops-dr-restore-gold -n openshift-adp \
  --for=jsonpath='{.status.phase}'=Completed --timeout=30m
```

3. **Verify stable naming**

```bash
oc get vm,pvc -n dr-gitops-poc
```

You should see `test-dr-vm` and `test-dr-vm-root` restored with their original names.

---

### Path 2: GitOps execution via Argo CD

This path keeps `setup/` and `test-workload/` synchronized from Git.

1. **Install OpenShift GitOps**
   Follow [`gitops-install/README.md`](gitops-install/README.md) to:
   - install the operator,
   - wait for the default `openshift-gitops` Argo CD instance,
   - apply required RBAC.

2. **Update repository URLs**
   Edit `spec.source.repoURL` in files under [`argocd-apps/`](argocd-apps/) to point to your fork/repository.

3. **Apply Argo CD applications**

```bash
oc apply -f argocd-apps/
```

| Application | Source path | Sync policy | Destination namespace |
|-------------|-------------|-------------|-----------------------|
| `dr-poc-setup` | `setup/` | Automatic | `openshift-adp` |
| `dr-poc-workload` | `test-workload/` | Automatic | `dr-gitops-poc` |
| `dr-poc-recovery` | `recovery/` | Manual only | `openshift-adp` |

4. **GitOps DR drill**
   - Wait until setup and workload applications are `Healthy`.
   - Trigger a backup manually (Path 1, Part C).
   - **Pause auto-sync** on `dr-poc-workload` before restore.
   - Simulate disaster by deleting the workload VM.
   - Manually sync `dr-poc-recovery` to trigger restore.
   - Re-enable auto-sync on `dr-poc-workload`.

If restore succeeds, Argo CD should converge to `Synced` without replacing recovered PVCs.

---

## Cleanup

```bash
RESET_POC_CONFIRM=yes ./reset/reset-poc.sh
```

This removes PoC namespaces, OADP resources, Velero CRs, and GitOps apps. See [`reset/README.md`](reset/README.md) for data-retention details and finalizer caveats.

---

## Configuration tweaks

- **Storage class:** update `storageClassName` in [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml) for your environment.
- **Bucket naming:** keep [`setup/02-noobaa-obc.yaml`](setup/02-noobaa-obc.yaml) `spec.bucketName` and [`setup/04-dpa.yaml`](setup/04-dpa.yaml) `objectStorage.bucket` identical.
- **Backup/restore naming:** if you change backup name, update both [`backup/01-backup-gitops-dr-gold.yaml`](backup/01-backup-gitops-dr-gold.yaml) and [`recovery/01-restore.yaml`](recovery/01-restore.yaml).
