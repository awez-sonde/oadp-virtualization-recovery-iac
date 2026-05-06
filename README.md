# OADP virtualization recovery (IaC)

This repository holds **OpenShift API for Data Protection (OADP)** install and backup backend manifests for a GitOps-friendly disaster-recovery proof of concept. Object storage uses **Multicloud Object Gateway (NooBaa)** via an **ObjectBucketClaim** (no MinIO).

## Prerequisites

- OpenShift cluster with `oc` logged in as a user who can create namespaces, subscriptions, and resources in `openshift-adp`.
- **NooBaa** storage class available (for example `openshift-storage.noobaa.io`).
- For GitOps: **OpenShift GitOps (Argo CD)** installed so you can create `Application` objects (typically in `openshift-gitops`).

### Apply from the right copy of this repo

If you ran `git clone ...` **inside** an existing checkout, you may have two trees, for example:

- `.../oadp-virtualization-recovery-iac/setup/` (this project’s root), and  
- `.../oadp-virtualization-recovery-iac/oadp-virtualization-recovery-iac/setup/` (nested clone).

`oc apply` uses whatever YAML is on disk in your **current directory**. Run `git pull` in the folder you actually use, or remove the nested clone so you only maintain one tree.

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
