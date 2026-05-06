#!/usr/bin/env bash
# Apply OADP operator → NooBaa OBC → credentials job → DPA in safe order (see README Path 1).
# ObjectBucketClaim uses status.phase, not a Bound condition — do not use --for=condition=Bound on OBC.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

oc apply -f setup/01-oadp-operator.yaml
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  -n openshift-adp subscription.operators.coreos.com/redhat-oadp-operator --timeout=20m
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  -n openshift-adp csv -l operators.coreos.com/redhat-oadp-operator.openshift-adp --timeout=15m
oc apply -f setup/02-noobaa-obc.yaml
oc wait obc/velero-dr-noobaa -n openshift-adp --for=jsonpath='{.status.phase}'=Bound --timeout=15m
oc apply -f setup/03-cloud-credentials.yaml
oc wait --for=condition=complete job/velero-noobaa-creds-bootstrap -n openshift-adp --timeout=15m
oc apply -f setup/04-dpa.yaml

echo "Wait until BackupStorageLocation is Available, e.g.: oc get backupstoragelocation -n openshift-adp"
