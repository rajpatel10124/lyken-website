variable "aws_region" {
  description = "AWS region for the Terraform state bucket"
  type        = string
  default     = "ap-southeast-2"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state"
  type        = string
  default     = "lyken-website-terraform-state-bucket"
}
