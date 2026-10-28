resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-eks"
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = values(var.subnet_ids)
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster
  ]

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
