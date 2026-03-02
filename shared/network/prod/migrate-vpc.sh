#!/bin/bash
# shared/network/prod/migrate-vpc.sh
# Prod VPC 소유권 마이그레이션: v1-bigbang/envs/prod → shared/network/prod
#
# [안전성]
# - 실제 AWS 리소스는 절대 건드리지 않음
# - Terraform state만 이동하는 작업
# - 운영 중인 서비스에 영향 없음
#
# [전제 조건]
# 1. AWS credentials 설정되어 있어야 함
# 2. S3 backend (billage-terraform-state-prod) 접근 가능해야 함
# 3. DynamoDB lock table (billage-terraform-lock-prod) 존재해야 함
#
# [사용법]
# chmod +x migrate-vpc.sh
# ./migrate-vpc.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V1_DIR="$(cd "$SCRIPT_DIR/../../../v1-bigbang/envs/prod" && pwd)"
SHARED_NET_DIR="$SCRIPT_DIR"

echo "=============================================="
echo "  Prod VPC 마이그레이션 스크립트"
echo "  v1-bigbang/envs/prod → shared/network/prod"
echo "=============================================="
echo ""
echo -e "${YELLOW}[주의] 이 스크립트는 Terraform state만 이동합니다.${NC}"
echo -e "${YELLOW}실제 AWS 리소스(VPC, Subnet 등)는 변경되지 않습니다.${NC}"
echo ""

#==============================================================================
# Step 1: v1-bigbang/envs/prod에서 리소스 ID 추출
#==============================================================================
echo "=============================================="
echo "  Step 1: 기존 리소스 ID 확인"
echo "=============================================="
echo ""

cd "$V1_DIR"
echo "Working directory: $V1_DIR"
echo ""

# terraform init (backend 연결)
echo "terraform init 실행 중..."
terraform init -input=false > /dev/null 2>&1
echo -e "${GREEN}✓ terraform init 완료${NC}"
echo ""

# 리소스 ID 추출
echo "리소스 ID 추출 중..."

VPC_ID=$(terraform state show module.vpc.aws_vpc.main 2>/dev/null | grep '^\s*id\s*=' | head -1 | awk -F'"' '{print $2}')
IGW_ID=$(terraform state show module.vpc.aws_internet_gateway.main 2>/dev/null | grep '^\s*id\s*=' | head -1 | awk -F'"' '{print $2}')
SUBNET_ID=$(terraform state show module.vpc.aws_subnet.public 2>/dev/null | grep '^\s*id\s*=' | head -1 | awk -F'"' '{print $2}')
RTB_ID=$(terraform state show module.vpc.aws_route_table.public 2>/dev/null | grep '^\s*id\s*=' | head -1 | awk -F'"' '{print $2}')

# 검증
if [ -z "$VPC_ID" ] || [ -z "$IGW_ID" ] || [ -z "$SUBNET_ID" ] || [ -z "$RTB_ID" ]; then
  echo -e "${RED}✗ 리소스 ID를 가져올 수 없습니다.${NC}"
  echo "  VPC_ID:    ${VPC_ID:-NOT FOUND}"
  echo "  IGW_ID:    ${IGW_ID:-NOT FOUND}"
  echo "  SUBNET_ID: ${SUBNET_ID:-NOT FOUND}"
  echo "  RTB_ID:    ${RTB_ID:-NOT FOUND}"
  echo ""
  echo "v1-bigbang/envs/prod의 state에 VPC 리소스가 있는지 확인하세요:"
  echo "  terraform state list | grep vpc"
  exit 1
fi

echo -e "${GREEN}✓ 리소스 ID 추출 완료${NC}"
echo "  VPC_ID:    $VPC_ID"
echo "  IGW_ID:    $IGW_ID"
echo "  SUBNET_ID: $SUBNET_ID"
echo "  RTB_ID:    $RTB_ID"
echo ""

#==============================================================================
# Step 2: 사용자 확인
#==============================================================================
echo "=============================================="
echo "  Step 2: 마이그레이션 확인"
echo "=============================================="
echo ""
echo "다음 리소스의 Terraform state 소유권을 이전합니다:"
echo ""
echo "  FROM: v1-bigbang/envs/prod (module.vpc.*)"
echo "  TO:   shared/network/prod (aws_vpc.main 등)"
echo ""
echo "  1. aws_vpc.main              → $VPC_ID"
echo "  2. aws_internet_gateway.main → $IGW_ID"
echo "  3. aws_subnet.public_a       → $SUBNET_ID"
echo "  4. aws_route_table.public    → $RTB_ID"
echo "  5. aws_route.public_internet → ${RTB_ID}_0.0.0.0/0"
echo "  6. aws_route_table_association.public_a → ${SUBNET_ID}/${RTB_ID}"
echo ""
echo -e "${YELLOW}실제 AWS 리소스는 변경되지 않습니다. state만 이동합니다.${NC}"
echo ""
read -p "계속하시겠습니까? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "마이그레이션을 취소합니다."
  exit 0
fi
echo ""

#==============================================================================
# Step 3: shared/network/prod에 import
#==============================================================================
echo "=============================================="
echo "  Step 3: shared/network/prod에 import"
echo "=============================================="
echo ""

cd "$SHARED_NET_DIR"
echo "Working directory: $SHARED_NET_DIR"
echo ""

echo "terraform init 실행 중..."
terraform init -input=false > /dev/null 2>&1
echo -e "${GREEN}✓ terraform init 완료${NC}"
echo ""

echo "리소스 import 시작..."
echo ""

# 3-1. VPC
echo -n "  [1/6] aws_vpc.main ... "
if terraform import aws_vpc.main "$VPC_ID" > /dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo "  이미 import 되어 있을 수 있습니다. 계속 진행합니다."
fi

# 3-2. Internet Gateway
echo -n "  [2/6] aws_internet_gateway.main ... "
if terraform import aws_internet_gateway.main "$IGW_ID" > /dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo "  이미 import 되어 있을 수 있습니다. 계속 진행합니다."
fi

# 3-3. Public Subnet
echo -n "  [3/6] aws_subnet.public_a ... "
if terraform import aws_subnet.public_a "$SUBNET_ID" > /dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo "  이미 import 되어 있을 수 있습니다. 계속 진행합니다."
fi

# 3-4. Route Table
echo -n "  [4/6] aws_route_table.public ... "
if terraform import aws_route_table.public "$RTB_ID" > /dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo "  이미 import 되어 있을 수 있습니다. 계속 진행합니다."
fi

# 3-5. Route (internet)
echo -n "  [5/6] aws_route.public_internet ... "
if terraform import aws_route.public_internet "${RTB_ID}_0.0.0.0/0" > /dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo "  이미 import 되어 있을 수 있습니다. 계속 진행합니다."
fi

# 3-6. Route Table Association
echo -n "  [6/6] aws_route_table_association.public_a ... "
if terraform import aws_route_table_association.public_a "${SUBNET_ID}/${RTB_ID}" > /dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo "  이미 import 되어 있을 수 있습니다. 계속 진행합니다."
fi

echo ""
echo -e "${GREEN}✓ import 완료${NC}"
echo ""

#==============================================================================
# Step 4: plan으로 검증
#==============================================================================
echo "=============================================="
echo "  Step 4: terraform plan 검증"
echo "=============================================="
echo ""
echo "terraform plan 실행 중..."
echo ""

terraform plan -detailed-exitcode 2>&1 | tee /tmp/vpc-migration-plan.txt
PLAN_EXIT=$?

echo ""

if [ $PLAN_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ 변경사항 없음 - 완벽합니다!${NC}"
elif [ $PLAN_EXIT -eq 2 ]; then
  echo -e "${YELLOW}⚠ 변경사항이 있습니다 (위 plan 출력 확인)${NC}"
  echo ""
  echo "태그 추가(ManagedBy, Component)만 있다면 정상입니다."
  echo "리소스 삭제/재생성이 있다면 즉시 중단하세요!"
  echo ""
  read -p "변경사항이 안전한가요? plan 출력을 확인 후 계속하시겠습니까? (yes/no): " PLAN_CONFIRM
  if [ "$PLAN_CONFIRM" != "yes" ]; then
    echo ""
    echo -e "${RED}마이그레이션을 중단합니다.${NC}"
    echo "shared/network/prod의 state를 정리하려면:"
    echo "  terraform state rm aws_vpc.main"
    echo "  terraform state rm aws_internet_gateway.main"
    echo "  terraform state rm aws_subnet.public_a"
    echo "  terraform state rm aws_route_table.public"
    echo "  terraform state rm aws_route.public_internet"
    echo "  terraform state rm aws_route_table_association.public_a"
    exit 1
  fi
else
  echo -e "${RED}✗ terraform plan 실패${NC}"
  echo "에러를 확인하고 수정한 후 다시 시도하세요."
  exit 1
fi

echo ""

#==============================================================================
# Step 5: v1-bigbang/envs/prod에서 state 제거
#==============================================================================
echo "=============================================="
echo "  Step 5: v1-bigbang/envs/prod에서 state 제거"
echo "=============================================="
echo ""
echo -e "${YELLOW}[중요] 이 단계에서 v1 state에서 VPC 리소스를 제거합니다.${NC}"
echo "실제 AWS 리소스는 삭제되지 않습니다 (state rm ≠ destroy)"
echo ""
read -p "v1 state에서 VPC 리소스를 제거하시겠습니까? (yes/no): " REMOVE_CONFIRM

if [ "$REMOVE_CONFIRM" != "yes" ]; then
  echo ""
  echo "Step 5를 건너뜁니다."
  echo "나중에 수동으로 실행하려면:"
  echo "  cd $V1_DIR"
  echo "  terraform state rm module.vpc.aws_vpc.main"
  echo "  terraform state rm module.vpc.aws_internet_gateway.main"
  echo "  terraform state rm module.vpc.aws_subnet.public"
  echo "  terraform state rm module.vpc.aws_route_table.public"
  echo "  terraform state rm module.vpc.aws_route.public_internet"
  echo "  terraform state rm module.vpc.aws_route_table_association.public"
  exit 0
fi

echo ""
cd "$V1_DIR"
echo "Working directory: $V1_DIR"
echo ""

echo -n "  [1/6] module.vpc.aws_vpc.main ... "
terraform state rm module.vpc.aws_vpc.main > /dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP (이미 제거됨)${NC}"

echo -n "  [2/6] module.vpc.aws_internet_gateway.main ... "
terraform state rm module.vpc.aws_internet_gateway.main > /dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP (이미 제거됨)${NC}"

echo -n "  [3/6] module.vpc.aws_subnet.public ... "
terraform state rm module.vpc.aws_subnet.public > /dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP (이미 제거됨)${NC}"

echo -n "  [4/6] module.vpc.aws_route_table.public ... "
terraform state rm module.vpc.aws_route_table.public > /dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP (이미 제거됨)${NC}"

echo -n "  [5/6] module.vpc.aws_route.public_internet ... "
terraform state rm module.vpc.aws_route.public_internet > /dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP (이미 제거됨)${NC}"

echo -n "  [6/6] module.vpc.aws_route_table_association.public ... "
terraform state rm module.vpc.aws_route_table_association.public > /dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP (이미 제거됨)${NC}"

echo ""
echo -e "${GREEN}✓ v1 state에서 VPC 리소스 제거 완료${NC}"
echo ""

#==============================================================================
# Step 6: 최종 검증
#==============================================================================
echo "=============================================="
echo "  Step 6: 최종 검증"
echo "=============================================="
echo ""

echo "shared/network/prod state 확인:"
cd "$SHARED_NET_DIR"
terraform state list
echo ""

echo "v1-bigbang/envs/prod에서 VPC 리소스가 제거되었는지 확인:"
cd "$V1_DIR"
VPC_REMAINS=$(terraform state list 2>/dev/null | grep "module.vpc" || true)
if [ -z "$VPC_REMAINS" ]; then
  echo -e "${GREEN}✓ v1 state에서 VPC 리소스 모두 제거됨${NC}"
else
  echo -e "${YELLOW}⚠ 아직 남아있는 VPC 리소스:${NC}"
  echo "$VPC_REMAINS"
fi

echo ""
echo "=============================================="
echo -e "${GREEN}  마이그레이션 완료!${NC}"
echo "=============================================="
echo ""
echo "이제 v1-bigbang/envs/prod를 destroy해도"
echo "VPC는 shared/network/prod가 관리하므로 안전합니다."
echo ""
echo "다음 단계:"
echo "  1. shared/network/prod에서 terraform apply (태그 업데이트)"
echo "  2. v1-bigbang/envs/prod에서 terraform plan으로 VPC 없이 정상인지 확인"
