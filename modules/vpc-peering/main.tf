# modules/vpc-peering/main.tf
# VPC Peering 연결 및 양방향 라우팅 설정
# [주의] auto_accept = true는 동일 AWS 계정 및 리전 내에서만 동작

resource "aws_vpc_peering_connection" "main" {
  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.accepter_vpc_id
  auto_accept = true

  tags = {
    Name        = "${var.project_name}-${var.env}-to-${var.peer_name}-peering"
    Environment = var.env
    Project     = var.project_name
    PeerEnv     = var.peer_name
  }
}

# 요청측 VPC → 수락측 VPC 라우팅
resource "aws_route" "to_peer" {
  count                     = length(var.requester_route_table_ids)
  route_table_id            = var.requester_route_table_ids[count.index]
  destination_cidr_block    = var.accepter_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
}

# 수락측 VPC → 요청측 VPC 라우팅
resource "aws_route" "from_peer" {
  count                     = length(var.accepter_route_table_ids)
  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.requester_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
}

# VPN 클라이언트 대역 → 수락측 VPC Route Table에 라우트 추가 (Pure Routing용)
# Dev/Prod에서 VPN 클라이언트(10.100.0.0/24)로의 응답 경로
# [주의] 이 라우트가 없으면 VPN 클라이언트로의 응답 패킷이 유실됨
resource "aws_route" "vpn_to_accepter" {
  count                     = var.vpn_cidr != "" ? length(var.accepter_route_table_ids) : 0
  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.vpn_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
}
