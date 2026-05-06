# Disaster Recovery as Code — OADP + GitOps (PoC)

## Why this exists

**Problem:** Restoring KubeVirt VMs with the native **`VirtualMachineRestore`** API on ODF (Ceph RBD) often follows a storage workflow that **recreates** volumes. To avoid collisions, KubeVirt may assign **new, random PVC names** (for example `restore-<uuid>-<disk>`). **Argo CD** compares the cluster to Git: it sees drift, tries to **delete** the recovered disk, and recreate a blank PVC from the manifest—**destroying the restore**.

**What we prove:** **OADP (Velero + kubevirt/csi plugins)** backs up Kubernetes resources and storage. On restore, **PVCs and VMs come back with the same names as in Git** (for example `test-dr-vm-root`). Argo CD can report **`Synced`** / **`Healthy`** without fighting the recovered data.

This repo is a **minimal proof of concept**: OADP to NooBaa, a small KubeVirt workload, an example **Backup**, a **Restore** manifest, and optional **Argo CD `Application`** objects.

---

## Layout

| Directory | Purpose |
|-----------|---------|
| [`setup/`](setup/) | OADP operator, NooBaa bucket claim, Velero credentials job, **DataProtectionApplication** |
| [`test-workload/`](test-workload/) | Namespace + **DataVolume** + **VirtualMachine** (predictable PVC name) |
| [`backup/`](backup/) | Example **Velero `Backup`** (apply manually or from CI; not synced by default Argo app) |
| [`recovery/`](recovery/) | **Velero `Restore`** (apply only when you mean to restore) |
| [`argocd-apps/`](argocd-apps/) | Optional **Argo CD Applications** (OpenShift GitOps) |
| [`reset/`](reset/) | **Tear down** script: removes PoC namespaces, OADP, Velero backups/restores, optional Argo apps ([`reset/README.md`](reset/README.md)) |

Clone **once** into an empty folder (avoid `git clone …` inside another checkout of the same repo, or you get a nested duplicate path).

---

## Prerequisites

- OpenShift: permissions for `openshift-adp`, `openshift-gitops` (if using Argo), and workload namespace.
- **OpenShift Virtualization** + **CDI**; **OADP**; **NooBaa** storage class (e.g. `openshift-storage.noobaa.io`).
- Workers can reach the CirrOS URL in the DataVolume, or change the image URL in [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml).

---

## Path 1 — Manual (`oc apply`)

Skip [`argocd-apps/`](argocd-apps/). Apply in order; **do not** `oc apply -f setup/` in one shot on a brand-new cluster (CRD / credential ordering).

1. **OADP stack**

   ```bash
   oc apply -f setup/01-oadp-operator.yaml
   oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
     -n openshift-adp subscription.operators.coreos.com/redhat-oadp-operator --timeout=20m
   oc wait --for=jsonpath='{.status.phase}'=Succeeded \
     -n openshift-adp csv -l operators.coreos.com/redhat-oadp-operator.openshift-adp --timeout=15m
   oc apply -f setup/02-noobaa-obc.yaml
   oc wait --for=condition=Bound obc/velero-dr-noobaa -n openshift-adp --timeout=15m
   oc apply -f setup/03-cloud-credentials.yaml
   oc wait --for=condition=complete job/velero-noobaa-creds-bootstrap -n openshift-adp --timeout=15m
   oc apply -f setup/04-dpa.yaml
   ```

   Wait until `oc get backupstoragelocation -n openshift-adp` shows **Available**.

2. **Workload**

   ```bash
   oc apply -f test-workload/01-test-vm.yaml
   oc wait datavolume test-dr-vm-root -n dr-gitops-poc --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
   oc wait virtualmachine test-dr-vm -n dr-gitops-poc --for=jsonpath='{.status.printableStatus}'=Running --timeout=15m
   ```

3. **Backup** (name must match `spec.backupName` in [`recovery/01-restore.yaml`](recovery/01-restore.yaml))

   ```bash
   oc apply -f backup/01-backup-gitops-dr-gold.yaml
   oc wait --for=jsonpath='{.status.phase}'=Completed -n openshift-adp backup/gitops-dr-gold-backup --timeout=30m
   ```

4. **Optional DR drill:** delete VM + DataVolume; then restore:

   ```bash
   oc delete vm test-dr-vm -n dr-gitops-poc --wait=true
   oc delete datavolume test-dr-vm-root -n dr-gitops-poc --wait=true
   oc apply -f recovery/01-restore.yaml
   oc wait --for=jsonpath='{.status.phase}'=Completed -n openshift-adp restore/gitops-dr-restore-gold --timeout=30m
   oc get vm,pvc -n dr-gitops-poc
   ```

Confirm PVC **`test-dr-vm-root`** and VM **`test-dr-vm`** match Git—Argo would stay **Synced** if this directory were managed by an Application.

---

## Path 2 — OpenShift GitOps (Argo CD)

1. Edit **`spec.source.repoURL`** in each file under [`argocd-apps/`](argocd-apps/) if not using the default GitHub URL.
2. Apply the three Applications into **`openshift-gitops`** (or your Argo CD namespace).

| App | Path | Sync | Destination |
|-----|------|------|---------------|
| `dr-poc-setup` | `setup` | Auto | `openshift-adp` |
| `dr-poc-workload` | `test-workload` | Auto | `dr-gitops-poc` |
| `dr-poc-recovery` | `recovery` | **Manual only** | `openshift-adp` |

3. Sync **setup**, then **workload**; wait for BSL **Available** and VM **Running**.
4. **Backup:** `oc apply -f backup/01-backup-gitops-dr-gold.yaml` (or your pipeline). The workload Argo app **only** includes `01-test-vm.yaml` so backups are not re-applied every sync.
5. Before restore: **disable auto-sync** on the workload app (or delete the app temporarily) so Argo does not prune objects while Velero restores. Then **manually sync** `dr-poc-recovery` once.

`argocd.argoproj.io/*` annotations under `setup/` only affect Argo; **`oc` ignores them**.

---

## Reset / tear down

To **remove the PoC** from the cluster (OADP operator, `openshift-adp`, Velero backups/restores, `dr-gitops-poc`, optional Argo Applications):

```bash
RESET_POC_CONFIRM=yes ./reset/reset-poc.sh
```

See [`reset/README.md`](reset/README.md) for warnings (backup data in NooBaa, stuck namespaces, `--skip-argo`).

---

## Customization

- **ODF disk class:** `storageClassName` in [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml) (default `ocs-external-storagecluster-ceph-rbd`).
- **NooBaa bucket:** same name in [`setup/02-noobaa-obc.yaml`](setup/02-noobaa-obc.yaml) `spec.bucketName` and [`setup/04-dpa.yaml`](setup/04-dpa.yaml) `objectStorage.bucket`. **`objectStorage.prefix`** must start with **`velero`** (or set `backupImages: false` on the DPA).
- **Backup / restore names:** keep [`backup/01-backup-gitops-dr-gold.yaml`](backup/01-backup-gitops-dr-gold.yaml) `metadata.name` and [`recovery/01-restore.yaml`](recovery/01-restore.yaml) `spec.backupName` identical if you rename.

---

## Troubleshooting (short)

| Symptom | Check |
|---------|--------|
| DPA `Reconciled=False`, “velero prefix” | [`setup/04-dpa.yaml`](setup/04-dpa.yaml) has `prefix: velero`. |
| BSL `Unavailable`, x509 to `s3.openshift-storage` | DPA has `insecureSkipTLSVerify: "true"` (in-cluster S3 CA). |
| `oc wait subscription` NotFound | Use `subscription.operators.coreos.com/redhat-oadp-operator`. |

---

## License

Example configuration only; OpenShift and Red Hat operators are under their respective licenses.
