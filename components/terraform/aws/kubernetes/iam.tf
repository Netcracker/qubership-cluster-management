resource "aws_iam_role" "cluster" {
  name = "${var.environment}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "eks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_user" "kubectl" {
  name          = "${var.environment}-kubectl"
  force_destroy = true

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
