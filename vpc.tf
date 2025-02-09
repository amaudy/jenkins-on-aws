data "aws_vpc" "default" {
  default = true
}

# Use the default subnet
data "aws_subnet" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}

# Get the existing internet gateway attached to the default VPC
data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
