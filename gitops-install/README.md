# Install OpenShift GitOps + Argo CD for this PoC

These manifests install the **Red Hat OpenShift GitOps** operator (which includes Argo CD), keep a declarative baseline for the **default** `ArgoCD` instance in `openshift-gitops`, and grant that instance’s **application controller** service account **namespace admin** in `dr-gitops-poc` and `openshift-adp` so the [`argocd-apps/`](../argocd-apps/) `Application` objects can sync.

You need **cluster-admin** (or equivalent) to install operators and to bind `ClusterRole` `admin` into those namespaces.

## Order

1. **Create `openshift-adp`** if it is not there yet (this repo’s OADP operator manifest does that):

   ```bash
   oc apply -f ../setup/01-oadp-operator.yaml
   ```

2. **Install the GitOps operator**

   ```bash
   oc apply -f 01-openshift-gitops-operator.yaml
   oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
     -n openshift-gitops-operator subscription.operators.coreos.com/openshift-gitops-operator --timeout=20m
   oc wait --for=jsonpath='{.status.phase}'=Succeeded \
     -n openshift-gitops-operator \
     csv -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator \
     --timeout=20m
   ```

   If the CSV label selector does not match your cluster, run `oc get csv -n openshift-gitops-operator` and adjust the `-l` filter.

3. **Wait for the default Argo CD instance** (created by the operator in `openshift-gitops`)

   ```bash
   oc wait --for=jsonpath='{.status.phase}'=Available argocd/openshift-gitops -n openshift-gitops --timeout=15m
   ```

   If that wait errors (some versions lag updating `status.phase`), fall back to the server pod:

   ```bash
   oc wait --for=condition=Available deployment/openshift-gitops-server -n openshift-gitops --timeout=15m
   ```

4. **Optional overlay** — merge OpenShift-specific settings on the default `ArgoCD` CR:

   ```bash
   oc apply -f 02-argocd-openshift-gitops.yaml
   ```

5. **Workload namespace** (so RBAC can bind before the workload Application syncs)

   ```bash
   oc apply -f 03-namespace-dr-gitops-poc.yaml
   ```

6. **RBAC** — controller must exist in `openshift-gitops` before bindings succeed

   ```bash
   oc apply -f 04-rbac-dr-gitops-poc.yaml
   oc apply -f 05-rbac-openshift-adp.yaml
   ```

7. **Applications (phase-by-phase, not all at once)** — from repo root, after editing `repoURL` in `argocd-apps/*.yaml` if needed:

   ```bash
   # Phase 1: setup app only
   oc apply -f argocd-apps/01-setup-app.yaml
   oc get application dr-poc-setup -n openshift-gitops
   ```

   Wait for `dr-poc-setup` to be `Healthy`/`Synced`, then verify:

   ```bash
   oc get backupstoragelocation -n openshift-adp
   ```

   ```bash
   # Phase 2: workload app only
   oc apply -f argocd-apps/02-workload-app.yaml
   oc get application dr-poc-workload -n openshift-gitops
   ```

   Wait until the VM is running:

   ```bash
   oc wait datavolume test-dr-vm-root -n dr-gitops-poc \
     --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
   oc wait virtualmachine test-dr-vm -n dr-gitops-poc \
     --for=jsonpath='{.status.printableStatus}'=Running --timeout=15m
   ```

   ```bash
   # Phase 3: backup app (manual Sync creates / reconciles the Velero Backup CR)
   oc apply -f argocd-apps/04-backup-app.yaml
   oc get application dr-poc-backup -n openshift-gitops
   ```

   ```bash
   # Phase 4: recovery app only when you need to perform a restore
   oc apply -f argocd-apps/03-recovery-app.yaml
   ```

   Keep `dr-poc-backup` and `dr-poc-recovery` manual: sync backup when you want a point-in-time; sync recovery only during a DR drill.

## Troubleshooting: `permission denied: applications, sync` in the Argo CD UI

Argo CD enforces **UI RBAC** separately from OpenShift RBAC. If you log in via OpenShift (Dex) and your token only matches policies that grant `role:readonly`, you can list Applications but **cannot click Sync**.

Fix for this PoC:

1. Apply the overlay in [`02-argocd-openshift-gitops.yaml`](02-argocd-openshift-gitops.yaml) (it maps `system:authenticated:oauth` to `role:admin` for workshop-style demos).
2. Log out of the Argo CD UI, log back in, and hard-refresh the browser.

For a one-off fix on an existing cluster (same effect as the overlay):

```bash
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p '{
  "spec": {
    "rbac": {
      "defaultPolicy": "",
      "policy": "g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\ng, admin, role:admin\ng, system:authenticated:oauth, role:admin",
      "scopes": "[groups]"
    }
  }
}'
oc rollout restart deployment/openshift-gitops-server -n openshift-gitops
```

**Workaround without changing RBAC:** run sync from the CLI as a user who is a cluster admin (Argo still uses your kube credentials for `argocd app sync` when configured that way), or rely on **automated sync** on `dr-poc-workload` so you never need the Sync button for Workflow 1.

## Service account name

The default controller service account is usually `openshift-gitops-argocd-application-controller` in `openshift-gitops`. If `Application` sync fails with permission errors, list service accounts and align the `subjects` in `04`/`05` with the name that ends in `application-controller`:

```bash
oc get sa -n openshift-gitops
```

## Uninstall

Uninstalling the operator does not remove Argo CD-managed workloads by itself. Use this PoC’s [`reset/reset-poc.sh`](../reset/reset-poc.sh) for app data, and remove the GitOps subscription/CSV from `openshift-gitops-operator` when you no longer need Argo CD.
