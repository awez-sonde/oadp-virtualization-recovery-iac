#!/usr/bin/env bash
# Tear down everything this PoC creates on the cluster (OADP, Velero data CRs, workload NS, optional Argo apps).
# Velero Backup deletion may remove objects from the NooBaa bucket per your retention / deletion policy.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  RESET_POC_CONFIRM=yes ./reset/reset-poc.sh [options]

Options:
  --skip-argo     Do not delete Argo CD Applications (use if OpenShift GitOps is not installed).
  -h, --help      Show this help.

Requires: oc logged in; cluster-admin or equivalent to delete openshift-adp and OLM objects.
EOF
}

SKIP_ARGO=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-argo) SKIP_ARGO=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ "${RESET_POC_CONFIRM:-}" != "yes" ]]; then
  echo "Refusing to run: this deletes OADP, Velero backups/restores, workload namespaces, and more." >&2
  echo "Re-run with:  RESET_POC_CONFIRM=yes $0 $*" >&2
  exit 1
fi

log() { echo "[reset-poc] $*"; }

# --- Optional: stop GitOps controllers reconciling PoC paths ---
if [[ "${SKIP_ARGO}" != "true" ]] && oc get ns openshift-gitops &>/dev/null; then
  if oc get crd applications.argoproj.io &>/dev/null; then
    log "Deleting Argo CD Applications in openshift-gitops (if present)…"
    oc delete applications.argoproj.io dr-poc-recovery dr-poc-workload dr-poc-setup \
      -n openshift-gitops --ignore-not-found --wait=true --timeout=3m || true
  else
    log "Argo CD Application CRD not found; skipping Application deletes."
  fi
else
  log "Skipping Argo Application deletes (--skip-argo or no openshift-gitops namespace)."
fi

# --- Workload namespace (VM, DV, PVCs) ---
if oc get ns dr-gitops-poc &>/dev/null; then
  log "Deleting namespace dr-gitops-poc…"
  oc delete namespace dr-gitops-poc --wait=true --timeout=10m --ignore-not-found || true
else
  log "Namespace dr-gitops-poc not found; skipping."
fi

# --- OADP / Velero namespace ---
if ! oc get ns openshift-adp &>/dev/null; then
  log "Namespace openshift-adp not found; done."
  exit 0
fi

log "Deleting Velero restores and backups in openshift-adp (removes backup metadata; object storage may be pruned per Velero)…"
oc delete restore -n openshift-adp --all --ignore-not-found --wait=true --timeout=5m || true
oc delete backup -n openshift-adp --all --ignore-not-found --wait=true --timeout=10m || true
oc delete schedule -n openshift-adp --all --ignore-not-found --wait=true --timeout=2m || true

log "Deleting DataProtectionApplication…"
oc delete dataprotectionapplication -n openshift-adp --all --ignore-not-found --wait=true --timeout=5m || true

log "Deleting OLM subscription and related objects…"
oc delete subscription.operators.coreos.com redhat-oadp-operator -n openshift-adp --ignore-not-found --wait=true --timeout=3m || true
oc delete clusterserviceversion -n openshift-adp -l operators.coreos.com/redhat-oadp-operator.openshift-adp --ignore-not-found --wait=true --timeout=3m || true
oc delete installplan.operators.coreos.com -n openshift-adp -l operators.coreos.com/redhat-oadp-operator.openshift-adp --ignore-not-found --wait=true --timeout=2m || true

log "Deleting remaining namespaced resources (OBC, secrets, jobs, operatorgroup, etc.)…"
oc delete operatorgroup openshift-adp -n openshift-adp --ignore-not-found --wait=true --timeout=2m || true
oc delete obc -n openshift-adp --all --ignore-not-found --wait=true --timeout=5m || true

log "Deleting project/namespace openshift-adp…"
oc delete namespace openshift-adp --wait=true --timeout=10m --ignore-not-found || true

log "Finished. If a namespace stays Terminating, check stuck finalizers or dependent resources."
log "NooBaa may retain empty bucket data until garbage-collected; that is outside this script."
