variable "aws_region" {
  description = "AWS region for regional resources"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  type    = string
  default = "lyken"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "website_bucket_name" {
  description = "Optional globally unique website bucket name; leave null to generate one"
  type        = string
  default     = "lyken-prod-frontend-bucket"
  nullable    = true
}

variable "ses_from_email" {
  description = "Verified SES sender identity"
  type        = string
}

variable "notification_to_email" {
  description = "Destination inbox for contact inquiries"
  type        = string
}

variable "lambda_log_retention_days" {
  type    = number
  default = 14
}

variable "api_throttle_rate" {
  type    = number
  default = 2
}

variable "api_throttle_burst" {
  type    = number
  default = 5
}
