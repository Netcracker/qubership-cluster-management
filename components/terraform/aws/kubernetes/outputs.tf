output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_data" {
  description = "Certificate authority data in base64 format"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}