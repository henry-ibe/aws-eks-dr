#!/usr/bin/env bash
set -euo pipefail
APP_SUBDOMAIN="${APP_SUBDOMAIN:-app}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-us-west-2}"
EKS_PRIMARY_NAME="${EKS_PRIMARY_NAME:-dr-primary}"
EKS_DR_NAME="${EKS_DR_NAME:-dr-secondary}"
if [[ -z "${ROOT_DOMAIN:-}" ]]; then echo "ROOT_DOMAIN not set"; exit 1; fi
RECORD_NAME="${APP_SUBDOMAIN}.${ROOT_DOMAIN}."
aws eks update-kubeconfig --region "$PRIMARY_REGION" --name "$EKS_PRIMARY_NAME" --alias "$EKS_PRIMARY_NAME" >/dev/null
aws eks update-kubeconfig --region "$DR_REGION" --name "$EKS_DR_NAME" --alias "$EKS_DR_NAME" >/dev/null
PRIMARY_LB=$(kubectl --context="$EKS_PRIMARY_NAME" -n app get svc demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
DR_LB=$(kubectl --context="$EKS_DR_NAME" -n app get svc demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
[[ -z "$PRIMARY_LB" || -z "$DR_LB" ]] && { echo "LB hostnames not ready"; exit 2; }
HZID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${ROOT_DOMAIN}.'].Id" --output text | sed 's|/hostedzone/||')
[[ -z "$HZID" ]] && { echo "Hosted zone not found"; exit 3; }
HCID=$(aws route53 create-health-check --caller-reference "$(date +%s)" \
 --health-check-config "{\"FullyQualifiedDomainName\":\"${PRIMARY_LB}\",\"Port\":80,\"Type\":\"HTTP\",\"ResourcePath\":\"/health\",\"RequestInterval\":30,\"FailureThreshold\":3}" \
 --query 'HealthCheck.Id' --output text)
cat > /tmp/r53.json <<EOF
{"Comment":"Failover CNAME for ${RECORD_NAME}","Changes":[
{"Action":"UPSERT","ResourceRecordSet":{"Name":"${RECORD_NAME}","Type":"CNAME","SetIdentifier":"primary-record","Failover":"PRIMARY","TTL":30,"HealthCheckId":"${HCID}","ResourceRecords":[{"Value":"${PRIMARY_LB}"}]}},
{"Action":"UPSERT","ResourceRecordSet":{"Name":"${RECORD_NAME}","Type":"CNAME","SetIdentifier":"dr-record","Failover":"SECONDARY","TTL":30,"ResourceRecords":[{"Value":"${DR_LB}"}]}}
]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$HZID" --change-batch file:///tmp/r53.json
echo "✅ Created/updated failover DNS for ${RECORD_NAME}"
