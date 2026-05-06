# Reset / tear down the PoC

[`reset-poc.sh`](reset-poc.sh) removes, on the **current** OpenShift cluster context:

- Argo CD **Applications** `dr-poc-setup`, `dr-poc-workload`, `dr-poc-recovery` in `openshift-gitops` (unless `--skip-argo`)
- Namespace **`dr-gitops-poc`** (VM, DataVolume, PVCs)
- Namespace **`openshift-adp`**: Velero **Restore** / **Backup** / **Schedule** CRs, **DataProtectionApplication**, **Subscription** / **CSV** / **InstallPlan** for OADP, **OperatorGroup**, **ObjectBucketClaim**, and everything else in that namespace

**Warning:** Deleting **Velero `Backup`** objects usually triggers removal of backup data from the **NooBaa** bucket according to Velero’s behavior. Treat this as **destructive**.

## Run

```bash
cd /path/to/oadp-virtualization-recovery-iac
chmod +x reset/reset-poc.sh   # once, if needed
RESET_POC_CONFIRM=yes ./reset/reset-poc.sh
```

Without OpenShift GitOps:

```bash
RESET_POC_CONFIRM=yes ./reset/reset-poc.sh --skip-argo
```

## After the script

- If **`openshift-adp`** or **`dr-gitops-poc`** stays **Terminating**, inspect `oc get ns <name> -o yaml` for **finalizers** or stuck **VolumeSnapshots** and resolve manually.
- **Cluster-scoped** snapshot content is not fully cleaned by this PoC script; only delete what your storage team requires.
- Re-install from the repo with [`../README.md`](../README.md) **Path 1** or **Path 2**.
