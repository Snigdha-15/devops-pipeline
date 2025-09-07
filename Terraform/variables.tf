variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2" # or "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (Free Tier eligible)"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair"
  type        = string
  default     = "snigdha-key"
}
