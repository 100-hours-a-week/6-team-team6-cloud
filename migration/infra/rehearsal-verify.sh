#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-${SCRIPT_DIR}/../rehearsal/infra}"

for cmd in terraform aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command not found: $cmd"
    exit 1
  fi
done

alb_dns="$(terraform -chdir="$TF_DIR" output -raw alb_dns_name)"
alb_url="$(terraform -chdir="$TF_DIR" output -raw alb_http8081_endpoint)"
alb_arn="$(terraform -chdir="$TF_DIR" output -raw alb_arn)"
rds_endpoint="$(terraform -chdir="$TF_DIR" output -raw rds_endpoint)"
asg_name="$(terraform -chdir="$TF_DIR" output -raw backend_asg_name)"
tg_arn="$(terraform -chdir="$TF_DIR" output -raw target_group_arn)"
rds_identifier="$(terraform -chdir="$TF_DIR" output -raw rds_identifier)"

echo "ALB DNS: $alb_dns"
echo "ALB URL(8081): $alb_url"
echo "RDS endpoint: $rds_endpoint"
echo

echo "===> ALB Health"
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$alb_arn" \
  --query 'LoadBalancers[0].[LoadBalancerArn,State.Code,Type,Scheme]' \
  --output table || true

echo
echo "===> Target health"
aws elbv2 describe-target-health \
  --target-group-arn "$tg_arn" \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table || true

echo
echo "===> ASG"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$asg_name" \
  --query 'AutoScalingGroups[0].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity]' \
  --output table || true

echo
echo "===> RDS"
aws rds describe-db-instances \
  --db-instance-identifier "$rds_identifier" \
  --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address,Endpoint.Port]' \
  --output table || true
