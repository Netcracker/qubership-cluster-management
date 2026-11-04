output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "subnet_ids" {
  description = "IDs of the subnets by their keys"

  value = {
    for key, subnet in aws_subnet.main :
    key => subnet.id
  }
}