# shared/elasticache/dev/outputs.tf

output "endpoint" {
  description = "Redis Endpoint"
  value       = aws_elasticache_cluster.main.cache_nodes[0].address
}

output "port" {
  description = "Redis Port"
  value       = aws_elasticache_cluster.main.cache_nodes[0].port
}

output "security_group_id" {
  description = "Redis Security Group ID"
  value       = aws_security_group.redis.id
}

output "cluster_id" {
  description = "ElastiCache Cluster ID"
  value       = aws_elasticache_cluster.main.cluster_id
}