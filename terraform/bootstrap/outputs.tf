output "state_bucket_name" { value = aws_s3_bucket.terraform_state.bucket }
output "backend_config_example" {
  value = <<-EOT
bucket       = "${aws_s3_bucket.terraform_state.bucket}"
key          = "lyken/prod/terraform.tfstate"
region       = "${var.aws_region}"
encrypt      = true
use_lockfile = true
EOT
}
