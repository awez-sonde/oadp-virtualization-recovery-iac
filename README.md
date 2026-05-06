# OADP virtualization recovery (IaC)

This repository holds **OpenShift API for Data Protection (OADP)** install and backup backend manifests for a GitOps-friendly disaster-recovery proof of concept. Object storage uses **Multicloud Object Gateway (NooBaa)** via an **ObjectBucketClaim** (no MinIO).

## Clone and layout (read this once)

**Intended layout** at the root of the clone:

```text
README.md
setup/
  01-oadp-operator.yaml … 04-dpa.yaml
test-workload/
  01-test-vm.yaml
recovery/
  01-restore.yaml
argocd-apps/
  01-setup-app.yaml … 03-recovery-app.yaml
```

**Do not** run `git clone https://github.com/awez-sonde/oadp-virtualization-recovery-iac.git` **inside** an existing checkout of the same repository. GitHub’s default folder name matches the repo name, so you end up with `oadp-virtualization-recovery-iac/oadp-virtualization-recovery-iac/` and may accidentally commit that path. If you need a second copy, clone into a **sibling** directory or use a different folder name:

```bash
cd ~/src
git clone https://github.com/awez-sonde/oadp-virtualization-recovery-iac.git
cd oadp-virtualization-recovery-iac
```

Or: `git clone … oadp-dr-poc` so the inner folder name is not identical to the outer repo.

## Prerequisites

- OpenShift cluster with `oc` logged in as a user who can create namespaces, subscriptions, and resources in `openshift-adp`.
- **NooBaa** storage class available (for example `openshift-storage.noobaa.io`).
- For GitOps: **OpenShift GitOps (Argo CD)** installed so you can create `Application` objects (typically in `openshift-gitops`).

### Apply from the repository root

Always run `oc apply -f setup/...` from the **top level** of the clone (the directory that contains `README.md` and the `setup/` folder). If you see a second `setup/` only under `oadp-virtualization-recovery-iac/oadp-virtualization-recovery-iac/`, you are in a nested clone; use the layout in [Clone and layout](#clone-and-layout-read-this-once) instead.

## What is in `setup/`

| Order | File | Purpose |
|------:|------|--------|
| 1 | [`setup/01-oadp-operator.yaml`](setup/01-oadp-operator.yaml) | Creates `openshift-adp`, an `OperatorGroup`, and a `Subscription` to **redhat-oadp-operator** (stable channel). |
| 2 | [`setup/02-noobaa-obc.yaml`](setup/02-noobaa-obc.yaml) | Creates an **ObjectBucketClaim** `velero-dr-noobaa` with a fixed **bucket name** `velero-gitops-dr-poc` for predictable Velero configuration. |
| 3 | [`setup/03-cloud-credentials.yaml`](setup/03-cloud-credentials.yaml) | RBAC plus a **Job** that reads the OBC Secret and creates **`Secret/cloud-credentials`** with Velero’s expected **`cloud`** key (AWS INI profile). |
| 4 | [`setup/04-dpa.yaml`](setup/04-dpa.yaml) | **`DataProtectionApplication`** pointing at the NooBaa S3 endpoint (`https://s3.openshift-storage.svc.cluster.local`), the bucket above, object key **`prefix: velero`** (required by OADP when image backup is enabled), **`insecureSkipTLSVerify: "true"`** so Velero can reach in-cluster S3 without the service CA bundle, and the `kubevirt` + `csi` plugins (with `EnableCSI`). |

**Apply order matters** because the OADP CRD is not present until the operator installs, and the DPA needs the `cloud-credentials` Secret.

### Sync waves and Argo CD hooks (when using GitOps)

Inside the YAML, ordering is reinforced for Argo CD:

- **01 / 02**: `argocd.argoproj.io/sync-wave` so the namespace and operator objects precede the OBC where applicable.
- **03**: The credential **Job** is a **PostSync** hook at **hook-wave `1`**, so it runs after the main resources (including the OBC) are applied and Argo waits for the Job to finish.
- **04**: The **DPA** is a **PostSync** hook at **hook-wave `2`**, so it is applied **after** `cloud-credentials` exists.

If you use **plain `oc apply`**, follow the manual order below so you do not create the DPA before the OADP CRD exists.

---

## Option A — OpenShift GitOps (recommended order)

1. Push this repository to a Git remote your cluster can reach.
2. Create an Argo CD **Application** whose `spec.source.path` is **`setup`** (and `spec.destination.namespace` is `openshift-adp` or cluster-scoped as appropriate for your app-of-apps pattern).
3. **Sync the Application once** (or enable auto-sync if that matches your policy). Argo CD applies `01` and `02` in the main sync, runs the **PostSync** credential Job, then applies the **DPA** PostSync hook.

**Verify after sync**

```bash
oc get csv -n openshift-adp
oc get obc,secret -n openshift-adp
oc get dataprotectionapplication -n openshift-adp
oc get backupstoragelocation -n openshift-adp
```

You want the default **BackupStorageLocation** to reach **`PHASE: Available`** once the DPA and credentials are reconciled.

---

## Option B — Manual `oc apply` (explicit order)

Use this when you are not driving the folder from Argo CD (hooks in file **03** / **04** are Argo-specific; they are ignored by `oc apply`).

1. **Install the operator**

   ```bash
   oc apply -f setup/01-oadp-operator.yaml
   ```

2. **Wait until OADP is installed** (CRDs and CSV must exist before the DPA).

   ```bash
   oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
     -n openshift-adp subscription.operators.coreos.com/redhat-oadp-operator --timeout=20m
   oc wait --for=jsonpath='{.status.phase}'=Succeeded \
     -n openshift-adp csv -l operators.coreos.com/redhat-oadp-operator.openshift-adp --timeout=15m
   oc get csv -n openshift-adp
   ```

   If `oc wait subscription...` fails with **NotFound** for `subscriptions.apps.open-cluster-management.io`, you are hitting the wrong API group: always use **`subscription.operators.coreos.com`** (as above).

3. **Provision the NooBaa bucket claim**

   ```bash
   oc apply -f setup/02-noobaa-obc.yaml
   oc wait --for=condition=Bound obc/velero-dr-noobaa -n openshift-adp --timeout=15m
   ```

4. **Materialize Velero credentials** (apply RBAC, then run the Job once and wait for it)

   ```bash
   oc apply -f setup/03-cloud-credentials.yaml
   oc wait --for=condition=complete job/velero-noobaa-creds-bootstrap -n openshift-adp --timeout=15m
   ```

5. **Create the DataProtectionApplication**

   ```bash
   oc apply -f setup/04-dpa.yaml
   ```

6. **Confirm backup storage**

   ```bash
   oc get dataprotectionapplication -n openshift-adp
   oc get backupstoragelocation -n openshift-adp
   ```

**Do not** run `oc apply -f setup/` in one shot on a fresh cluster: Kubernetes may attempt the DPA before the OADP CRD exists, or before the credential Job has written `cloud-credentials`.

---

## `test-workload/` — KubeVirt VM and PVC

| File | Purpose |
|------|---------|
| [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml) | Namespace **`dr-gitops-poc`**, a **DataVolume** (imports CirrOS; becomes a PVC named **`test-dr-vm-root`**), and a **VirtualMachine** **`test-dr-vm`**. Labels **`dr-policy: gold`** on namespace, DV, and VM. **StorageClass** defaults to **`ocs-external-storagecluster-ceph-rbd`** — change it if your external ODF class differs. |

**Prerequisites:** OpenShift Virtualization (KubeVirt) and **CDI** installed; workers can reach `download.cirros-cloud.net` for the first import (or replace the DV `http` URL with an allowed internal image).

---

## `recovery/` — Velero Restore

| File | Purpose |
|------|---------|
| [`recovery/01-restore.yaml`](recovery/01-restore.yaml) | **`Restore`** in **`openshift-adp`**, **`restorePVs: true`**, **`backupName: gitops-dr-gold-backup`**, scoped to **`dr-gitops-poc`**. |

The **Velero `Backup`** that produces that archive is **not** committed here on purpose: backups are point-in-time operations (CLI, script, or a separate GitOps app). Whatever creates the backup must use the **same `metadata.name`** as `spec.backupName` in this Restore, or you edit `01-restore.yaml` to match your backup name.

---

## `argocd-apps/` — Argo CD `Application` objects

Apply these into **`openshift-gitops`** (or the namespace where your Argo CD instance watches **`Application`** CRs). Set **`spec.source.repoURL`** to your fork if needed.

| Order | File | Sync policy |
|------:|------|----------------|
| 1 | [`argocd-apps/01-setup-app.yaml`](argocd-apps/01-setup-app.yaml) | **Auto** (`prune` + `selfHeal`) for path **`setup`** → **`openshift-adp`**. |
| 2 | [`argocd-apps/02-workload-app.yaml`](argocd-apps/02-workload-app.yaml) | **Auto** for path **`test-workload`** → **`dr-gitops-poc`**. |
| 3 | [`argocd-apps/03-recovery-app.yaml`](argocd-apps/03-recovery-app.yaml) | **Manual only** (no `spec.syncPolicy.automated`) for path **`recovery`** → **`openshift-adp`**. |

**Suggested lifecycle:** sync **setup** → sync **workload** → take a **Backup** named **`gitops-dr-gold-backup`** (include namespace **`dr-gitops-poc`** and label **`dr-policy=gold`** as needed) → on DR, **pause or set sync-policy none on the workload app** (so it does not fight the restore) → **manually sync recovery** once.

---

## DR / Velero / Argo clarifications

1. **`dr-policy: gold` on the Restore CR** labels the Restore object only. Velero does **not** use that label to pick a backup; **`spec.backupName`** is the link to a specific **`Backup`**.
2. **Label selector on Backup:** when you create a `Backup` CR (YAML or CLI), use `spec.labelSelector` (or `kubectl label` strategy) so only gold workloads are captured. Keep **`includedNamespaces`** / backup scope aligned with **`spec.includedNamespaces`** on the Restore.
3. **PVC naming:** the DataVolume flow yields a PVC with the **same name as the DataVolume** (`test-dr-vm-root`). After restore, that predictable name helps Argo CD **selfHeal** match desired state instead of recreating a “new” PVC.
4. **Recovery app without auto-sync:** omitting `automated` under `syncPolicy` is enough for “manual only”; optional hardening is an Argo **AppProject** deny rule for automated sync on that app.
5. **`CreateNamespace=true`:** allows Argo to create **`dr-gitops-poc`** from the workload app. The workload manifest also defines the Namespace; first sync is idempotent.

---

## Customizing the bucket name

The bucket name is fixed in two places so Velero configuration stays predictable:

- `spec.bucketName` in [`setup/02-noobaa-obc.yaml`](setup/02-noobaa-obc.yaml)
- `spec.backupLocations[0].velero.objectStorage.bucket` in [`setup/04-dpa.yaml`](setup/04-dpa.yaml)

If you change one, change the other to the **same** value. If MCG reports a name collision, pick a new globally unique bucket name in both files.

The **`objectStorage.prefix`** in [`setup/04-dpa.yaml`](setup/04-dpa.yaml) must begin with **`velero`** unless you set `spec.configuration.velero.backupImages` to `false` on the DPA. Otherwise the operator sets `Reconciled=False` with: *BackupLocation must have velero prefix when backupImages is not set to false*.

---

## Troubleshooting

### `RECONCILED` is `False` and no `BackupStorageLocation`

Describe the DPA and read `status.conditions`:

```bash
oc get dataprotectionapplication dr-poc-dpa -n openshift-adp -o yaml
```

If the message mentions the **velero prefix**, set `spec.backupLocations[0].velero.objectStorage.prefix` to a value such as `velero` (see note above), then `oc apply -f setup/04-dpa.yaml` again.

### `BackupStorageLocation` phase `Unavailable` (TLS / x509)

If `status.message` on the BSL mentions **`certificate signed by unknown authority`** when calling `https://s3.openshift-storage.svc.cluster.local`, keep **`insecureSkipTLSVerify: "true"`** in the DPA `backupLocations[0].velero.config` (as in this repo’s `04-dpa.yaml`). For stricter TLS, configure Velero with the OpenShift service CA instead of skipping verification.

### `oc wait subscription` returns NotFound

Use the full resource name **`subscription.operators.coreos.com/redhat-oadp-operator`** (see step 2 in Option B).

---

## License

OpenShift and related operators are subject to their respective Red Hat / upstream licenses. This repository’s YAML is provided as example configuration for your environment.
