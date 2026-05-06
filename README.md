# OADP + GitOps DR PoC

Small example: back up a KubeVirt VM with Velero (OADP), store backups on NooBaa, restore so PVC names stay stable enough that GitOps (Argo CD) would not “fix” a recovered disk back to empty.

## Background (short)

KubeVirt’s own `VirtualMachineRestore` flow on Ceph RBD often ends up with new PVC names. Argo CD compares the cluster to Git, sees names that do not match the manifest, and may delete the recovered volume and recreate what Git says. That undoes the restore. Here we use OADP instead so the restored objects line up with what you would keep in Git (same PVC name, same VM name).

This repo is only a wiring demo: manifests under `setup/`, one test VM, one Backup CR, one Restore CR, optional Argo `Application` YAML.

## What’s in each folder

| Directory | Contents |
|-----------|----------|
| [`setup/`](setup/) | OADP subscription, NooBaa bucket claim, bootstrap job for Velero credentials, `DataProtectionApplication` |
| [`test-workload/`](test-workload/) | Namespace, `DataVolume`, `VirtualMachine` (fixed PVC name `test-dr-vm-root`) |
| [`backup/`](backup/) | Example Velero `Backup` (apply by hand or from CI; not part of the default Argo workload app) |
| [`recovery/`](recovery/) | Example Velero `Restore` (apply only when you really want a restore) |
| [`argocd-apps/`](argocd-apps/) | Optional GitOps `Application` objects |
| [`reset/`](reset/) | Script to tear the PoC down; see [`reset/README.md`](reset/README.md) |

Clone into its own directory once. Nesting two clones of the same repo inside each other is an easy way to edit the wrong tree.

## What you need on the cluster

- Rights to create resources in `openshift-adp` and the workload namespace; GitOps namespace too if you use Argo.
- OpenShift Virtualization, CDI, OADP operator available from OperatorHub, and a NooBaa-backed storage class (commonly `openshift-storage.noobaa.io`).
- Worker nodes that can pull the CirrOS image used in the sample `DataVolume`, or change the URL in [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml).

---

## Path 1 — run everything with `oc`

Ignore [`argocd-apps/`](argocd-apps/) for this path. Apply manifests in the order below. Do not run `oc apply -f setup/` as a single bulk apply on a fresh cluster; the operator CRDs and credentials need to exist before the DPA.

Velero’s **backup and restore are ordinary Kubernetes objects** (`Backup` and `Restore` in the `velero.io` API group). You describe intent in YAML: a `Backup` names what to include (namespaces, labels, options); a `Restore` names which completed backup to replay. The Velero deployment watches those resources, runs the work, and writes progress into `status` (for example `phase: Completed`). The heavy data lives in object storage behind the `BackupStorageLocation`; the CRs in `openshift-adp` are the contract and bookkeeping. So in this path you “retrieve” the workload by **applying** a `Restore` manifest the same way you applied the `Backup`—no separate restore CLI is required for the flow in this repo.

### Part A — OADP stack (operator → bucket → Velero)

Goal: install the OADP operator, give Velero an S3-compatible bucket on NooBaa, drop in credentials Velero understands, then create the `DataProtectionApplication` so Velero and a default `BackupStorageLocation` come up.

If you would rather not paste each block, `./setup/apply-oadp-stack.sh` from the repo root runs the same sequence (use `chmod +x` once if needed).

**1. Operator install (namespace, OperatorGroup, Subscription)**  
[`setup/01-oadp-operator.yaml`](setup/01-oadp-operator.yaml) creates `openshift-adp`, wires OLM to the `redhat-oadp-operator` package, and subscribes to a release channel.

```bash
oc apply -f setup/01-oadp-operator.yaml
```

**2. Wait for the subscription**  
OLM still has to reconcile the catalog and mark the subscription healthy before the operator install proceeds.

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  -n openshift-adp subscription.operators.coreos.com/redhat-oadp-operator --timeout=20m
```

**3. Wait for the ClusterServiceVersion**  
The CSV is the installed operator instance. When its phase is `Succeeded`, the OADP controller and CRDs you need later are in place.

```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  -n openshift-adp csv -l operators.coreos.com/redhat-oadp-operator.openshift-adp --timeout=15m
```

**4. Object bucket claim (NooBaa bucket + keys)**  
[`setup/02-noobaa-obc.yaml`](setup/02-noobaa-obc.yaml) asks the Multicloud Object Gateway for a bucket and a Secret with access keys. The bucket name is fixed so the DPA can reference it from Git.

```bash
oc apply -f setup/02-noobaa-obc.yaml
```

**5. Wait until the claim is bound**  
The claim is ready when `status.phase` is `Bound`.

```bash
oc wait obc/velero-dr-noobaa -n openshift-adp --for=jsonpath='{.status.phase}'=Bound --timeout=15m
```

**6. Velero credentials Secret**  
[`setup/03-cloud-credentials.yaml`](setup/03-cloud-credentials.yaml) is the bridge between what NooBaa gives you and what this Velero install expects.

When the OBC binds, the provisioner creates a Secret (same name as the claim) with **S3-style fields**: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as separate keys. That matches how many S3 clients read credentials, but it is **not** the layout the Velero **AWS** object-store plugin is wired for in this DPA. There the `DataProtectionApplication` points `credential` at a Secret named `cloud-credentials` with a **single key** (here `cloud`) whose value is a small **INI file**: a `[default]` profile block containing `aws_access_key_id` and `aws_secret_access_key` lines, the same shape the AWS SDK uses when it reads `~/.aws/credentials`.

Rather than hand-copy keys into Git, the manifest defines a **ServiceAccount**, **Role**, and **Job** that run the OpenShift CLI in the cluster: wait until the OBC Secret exists, read the two keys, assemble the INI string, then `oc apply` the `cloud-credentials` Secret idempotently. The Job is safe to re-run; it only overwrites that Secret when the source keys are present. RBAC is scoped to `openshift-adp` so the bootstrap pod can read the OBC Secret and create or patch `cloud-credentials`.

```bash
oc apply -f setup/03-cloud-credentials.yaml
```

**7. Wait for that Job**  
The job exits once the Secret exists.

```bash
oc wait --for=condition=complete job/velero-noobaa-creds-bootstrap -n openshift-adp --timeout=15m
```

**8. DataProtectionApplication**  
[`setup/04-dpa.yaml`](setup/04-dpa.yaml) tells the OADP operator to deploy Velero with the kubevirt/openshift/aws/csi plugins, node agent, and a `BackupStorageLocation` pointing at the NooBaa S3 endpoint.

```bash
oc apply -f setup/04-dpa.yaml
```

**9. Sanity check**  
Until this shows `Available`, Velero will not run backups cleanly.

```bash
oc get backupstoragelocation -n openshift-adp
```

---

### Part B — workload (create a VM you will back up)

Here you are not doing DR yet. You are standing up a disposable Linux VM so there is something in `dr-gitops-poc` worth backing up. Later steps delete it on purpose to simulate data loss.

**1. Apply the VM stack**  
[`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml) creates the namespace, a CDI `DataVolume` (imports a small CirrOS image into a PVC named `test-dr-vm-root`), and a `VirtualMachine` that uses that disk.

```bash
oc apply -f test-workload/01-test-vm.yaml
```

**2. Wait for the import disk**  
CDI populates the PVC from HTTP; this can take several minutes depending on the cluster.

```bash
oc wait datavolume test-dr-vm-root -n dr-gitops-poc --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
```

**3. Wait for the VM**  
KubeVirt starts the guest once the volume is ready.

```bash
oc wait virtualmachine test-dr-vm -n dr-gitops-poc --for=jsonpath='{.status.printableStatus}'=Running --timeout=15m
```

At this point you have a running VM and a stable PVC name. That matches the story this repo is trying to tell for GitOps.

---

### Part C — backup (copy cluster state to the bucket)

This step is entirely **declarative**: you apply [`backup/01-backup-gitops-dr-gold.yaml`](backup/01-backup-gitops-dr-gold.yaml), which creates a `Backup` resource. Velero’s controller reconciles that object: it snapshots the API resources you asked for, coordinates volume data through the plugins enabled on the DPA (OpenShift, kubevirt, CSI, AWS-style S3), and uploads the result to the bucket configured on the `BackupStorageLocation`. Status on the `Backup` CR moves to `Completed` when the run finishes; the backup tarball and metadata in the bucket are what a later restore will read.

[`backup/01-backup-gitops-dr-gold.yaml`](backup/01-backup-gitops-dr-gold.yaml) uses `metadata.name` `gitops-dr-gold-backup`. That string must stay aligned with `spec.backupName` inside [`recovery/01-restore.yaml`](recovery/01-restore.yaml).

```bash
oc apply -f backup/01-backup-gitops-dr-gold.yaml
oc wait backup.velero.io/gitops-dr-gold-backup -n openshift-adp --for=jsonpath='{.status.phase}'=Completed --timeout=30m
```

Use `backup.velero.io/...` in `oc wait` (and similar commands) on clusters where the short name `backup` resolves to another API group.

---

### Part D — optional DR drill (delete the VM, then restore)

Only do this when you want to exercise restore end-to-end. You are intentionally removing the VM and its root `DataVolume` from the cluster while the backup objects still exist in `openshift-adp` and in object storage.

**1. Remove the VM and disk**  
This simulates “the app namespace is gone” or a bad day in that namespace.

```bash
oc delete vm test-dr-vm -n dr-gitops-poc --wait=true
oc delete datavolume test-dr-vm-root -n dr-gitops-poc --wait=true
```

**2. Restore from the backup**  
[`recovery/01-restore.yaml`](recovery/01-restore.yaml) is another declarative object: a Velero `Restore` with `spec.backupName` set to the completed backup’s name. Applying it tells Velero to pull that backup’s payload from object storage and recreate resources (here `dr-gitops-poc` and the VM disk) according to the backup contents. The controller drives the restore; you wait on the same CR until `status.phase` is `Completed`.

```bash
oc apply -f recovery/01-restore.yaml
oc wait restore.velero.io/gitops-dr-restore-gold -n openshift-adp --for=jsonpath='{.status.phase}'=Completed --timeout=30m
```

**3. Inspect**  
You should see `test-dr-vm` and `test-dr-vm-root` again with the same names as in Git.

```bash
oc get vm,pvc -n dr-gitops-poc
```

Again, use `restore.velero.io/...` for waits; short `restore` often binds to Open Cluster Management on the same cluster.

---

## Path 2 — Argo CD

1. Point [`argocd-apps/`](argocd-apps/) at your Git URL (`spec.source.repoURL`) if it is not already correct.
2. Apply the three `Application` manifests into `openshift-gitops` (or wherever your Argo lives).

| Application | Path in repo | Sync | Namespace |
|-------------|--------------|------|-----------|
| `dr-poc-setup` | `setup` | automatic | `openshift-adp` |
| `dr-poc-workload` | `test-workload` | automatic | `dr-gitops-poc` |
| `dr-poc-recovery` | `recovery` | manual only | `openshift-adp` |

3. Let setup finish (BSL `Available`), then workload (VM `Running`).
4. Run backups the same way as Path 1 — `backup/` is deliberately not in the workload app so sync does not constantly re-apply a `Backup` CR.
5. Before a restore, turn off auto-sync on the workload app (or remove it temporarily) so Argo does not prune half-created objects while Velero is still replaying the backup. Sync `dr-poc-recovery` once by hand when you are ready.

Annotations under `setup/` that start with `argocd.argoproj.io/` are for Argo only; plain `oc apply` ignores them.

---

## Tear down

```bash
RESET_POC_CONFIRM=yes ./reset/reset-poc.sh
```

That removes the PoC namespaces, OADP subscription/CSV, Velero CRs, and optionally Argo apps. Read [`reset/README.md`](reset/README.md): deleting Velero `Backup` objects can delete data from the bucket depending on settings, and namespaces can stick in `Terminating` if finalizers disagree.

---

## Things you might change

- Disk class for the VM: `storageClassName` in [`test-workload/01-test-vm.yaml`](test-workload/01-test-vm.yaml) (sample uses `ocs-external-storagecluster-ceph-rbd`).
- Bucket name: keep [`setup/02-noobaa-obc.yaml`](setup/02-noobaa-obc.yaml) `spec.bucketName` and [`setup/04-dpa.yaml`](setup/04-dpa.yaml) `objectStorage.bucket` identical. The object store `prefix` in the DPA must start with `velero` unless you turn off image backup in the DPA spec.
- Renaming the backup: change `metadata.name` in the backup file and `spec.backupName` in the restore file together.

---

## When something breaks

- DPA never reconciles, mentions Velero prefix: see `prefix: velero` under [`setup/04-dpa.yaml`](setup/04-dpa.yaml).
- BSL `Unavailable` with TLS errors against `s3.openshift-storage`: in-cluster S3 often needs `insecureSkipTLSVerify: "true"` on the BSL config (already set in the sample DPA).
- `oc wait` on the subscription says NotFound: use the full name `subscription.operators.coreos.com/redhat-oadp-operator`.
- `oc wait restore/...` or `backup/...` NotFound and the error mentions `cluster.open-cluster-management.io`: your client picked the ACM API. Spell out `restore.velero.io/...` and `backup.velero.io/...`.

---

## License

Example YAML only. Red Hat operators and OpenShift carry their own license terms.
