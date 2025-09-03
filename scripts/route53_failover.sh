#!/usr/bin/env bash
set -euo pipefail

# Set DEBUG=1 in the workflow to show every command.
[[ "${DEBUG:-0}" == "1" ]] && set -x

APP_SUBDOMAIN="${APP_SUBDOMAIN:-app}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-us-west-2}"
EKS_PRIMARY_NAME="${EKS_PRIMARY_NAME:-dr-primary}"
EKS_DR_NAME="${EKS_DR_NAME:-dr-secondary}"
: "${ROOT_DOMAIN:?ROOT_DOMAIN not set}"

RECORD_NAME="${APP_SUBDOMAIN}.${ROOT_DOMAIN}."
log(){ echo "[$(date +%T)] $*"; }

# --- Fetch kubeconfigs and wait for LB hostnames ---
log "Updating kubeconfigs..."
aws eks update-kubeconfig --region "$PRIMARY_REGION" --name "$EKS_PRIMARY_NAME" --alias "$EKS_PRIMARY_NAME" >/dev/null
aws eks update-kubeconfig --region "$DR_REGION" --name "$EKS_DR_NAME" --alias "$EKS_DR_NAME" >/dev/null

get_lb_dns () {
  local ctx="$1"
  kubectl --context="$ctx" -n app get svc demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

wait_for_dns () {
  local ctx="$1" name="$2" tries=30
  for i in $(seq 1 $tries); do
    local dns
    dns=$(get_lb_dns "$ctx")
    if [[ -n "$dns" && "$dns" != "<no value>" ]]; then
      echo "$dns"; return 0
    fi
    sleep 10
  done
  return 1
}

log "Waiting for Primary LB DNS..."
PRIMARY_LB=$(wait_for_dns "$EKS_PRIMARY_NAME" primary) || { echo "Primary LB hostname not ready"; exit 2; }
log "Waiting for DR LB DNS..."
DR_LB=$(wait_for_dns "$EKS_DR_NAME" dr) || { echo "DR LB hostname not ready"; exit 2; }

log "Primary LB: $PRIMARY_LB"
log "DR LB:      $DR_LB"

# --- Get hosted zone id for ROOT_DOMAIN (private) ---
HZID=$(aws route53 list-hosted-zones-by-name --dns-name "${ROOT_DOMAIN}." \
        --query 'HostedZones[0].Id' --output text | sed 's:/hostedzone/::')
[[ -z "$HZID" || "$HZID" == "None" ]] && { echo "Hosted zone '${ROOT_DOMAIN}.' not found"; exit 3; }
log "Route 53 zone id: $HZID"

# --- Resolve ELB CanonicalHostedZoneId (works for ALB/NLB/Classic) ---
get_elb_hzid() {
  local dns="$1" region="$2" id=""
  # ELBv2 (ALB/NLB)
  id=$(aws elbv2 describe-load-balancers --region "$region" \
        --query "LoadBalancers[?DNSName=='${dns}'].CanonicalHostedZoneId" \
        --output text 2>/dev/null || true)
  if [[ -z "$id" || "$id" == "None" ]]; then
    # Classic ELB
    id=$(aws elb describe-load-balancers --region "$region" \
          --query "LoadBalancerDescriptions[?DNSName=='${dns}'].CanonicalHostedZoneNameID" \
          --output text 2>/dev/null || true)
  fi
  echo "$id"
}

P_ELB_HZ=$(get_elb_hzid "$PRIMARY_LB" "$PRIMARY_REGION")
D_ELB_HZ=$(get_elb_hzid "$DR_LB" "$DR_REGION")
[[ -z "$P_ELB_HZ" || -z "$D_ELB_HZ" || "$P_ELB_HZ" == "None" || "$D_ELB_HZ" == "None" ]] && {
  echo "Could not resolve ELB CanonicalHostedZoneId(s)"; exit 4; }

log "Primary ELB hosted zone id: $P_ELB_HZ"
log "DR ELB hosted zone id:      $D_ELB_HZ"

# --- UPSERT ALIAS A records with EvaluateTargetHealth=true (FREE failover) ---
cat > /tmp/r53.json <<EOF
{
  "Comment": "Failover ALIAS for ${RECORD_NAME}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "SetIdentifier": "primary-record",
        "Failover": "PRIMARY",
        "AliasTarget": {
          "HostedZoneId": "${P_ELB_HZ}",
          "DNSName": "${PRIMARY_LB}",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "SetIdentifier": "dr-record",
        "Failover": "SECONDARY",
        "AliasTarget": {
          "HostedZoneId": "${D_ELB_HZ}",
          "DNSName": "${DR_LB}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

log "Submitting UPSERT to Route 53..."
aws route53 change-resource-record-sets --hosted-zone-id "$HZID" \
  --change-batch file:///tmp/r53.json >/dev/null
log "✅ Created/updated failover ALIAS records for ${RECORD_NAME}"
