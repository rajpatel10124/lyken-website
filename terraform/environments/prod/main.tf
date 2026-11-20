data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
resource "random_id" "suffix" { byte_length = 4 }
locals {
  name_prefix         = "${var.project_name}-${var.environment}"
  website_bucket_name = coalesce(var.website_bucket_name, "${local.name_prefix}-site-${random_id.suffix.hex}")
  common_tags = {
    Project = "Lyken Solutions", Environment = var.environment, ManagedBy = "Terraform"
  }
}

# Static website origin: private S3 bucket accessed only through CloudFront OAC.
resource "aws_s3_bucket" "website" {
  bucket = var.website_bucket_name
  tags   = merge(local.common_tags, { Component = "website" })
}
resource "aws_s3_bucket_ownership_controls" "website" {
  bucket = aws_s3_bucket.website.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
resource "aws_s3_bucket_public_access_block" "website" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_lifecycle_configuration" "website" {
  bucket = aws_s3_bucket.website.id
  rule {
    id     = "expire-old-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "${local.name_prefix}-s3-oac"
  description                       = "Private access from CloudFront to the Lyken website bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Event-driven contact processing.
resource "aws_cloudwatch_event_bus" "contact" {
  name = "${local.name_prefix}-contact-events"
  tags = local.common_tags
}
resource "aws_sqs_queue" "notification_dlq" {
  name                      = "${local.name_prefix}-notification-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.common_tags
}
resource "aws_sqs_queue" "notification" {
  name                       = "${local.name_prefix}-notification-queue"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 10
  sqs_managed_sse_enabled    = true
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.notification_dlq.arn, maxReceiveCount = 5 })
  tags                       = local.common_tags
}
resource "aws_cloudwatch_event_rule" "contact_received" {
  name           = "${local.name_prefix}-contact-received"
  event_bus_name = aws_cloudwatch_event_bus.contact.name
  event_pattern  = jsonencode({ source = ["lyken.website"], "detail-type" = ["ContactInquiryReceived"] })
}
resource "aws_cloudwatch_event_target" "notification_queue" {
  rule           = aws_cloudwatch_event_rule.contact_received.name
  event_bus_name = aws_cloudwatch_event_bus.contact.name
  target_id      = "contact-notification-sqs"
  arn            = aws_sqs_queue.notification.arn
  dead_letter_config { arn = aws_sqs_queue.notification_dlq.arn }
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }
  depends_on = [aws_sqs_queue_policy.notification, aws_sqs_queue_policy.notification_dlq]
}
resource "aws_sqs_queue_policy" "notification" {
  queue_url = aws_sqs_queue.notification.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowEventBridgeSendMessage", Effect = "Allow", Principal = { Service = "events.amazonaws.com" },
      Action    = "sqs:SendMessage", Resource = aws_sqs_queue.notification.arn,
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.contact_received.arn } }
    }]
  })
}
resource "aws_sqs_queue_policy" "notification_dlq" {
  queue_url = aws_sqs_queue.notification_dlq.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowEventBridgeDeliveryFailure", Effect = "Allow", Principal = { Service = "events.amazonaws.com" },
      Action    = "sqs:SendMessage", Resource = aws_sqs_queue.notification_dlq.arn,
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.contact_received.arn } }
    }]
  })
}

# Lambda execution roles and policies.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "submit" {
  name               = "${local.name_prefix}-submit-inquiry-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}
resource "aws_iam_role" "worker" {
  name               = "${local.name_prefix}-notification-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}
resource "aws_iam_role_policy_attachment" "submit_logs" {
  role       = aws_iam_role.submit.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "worker_logs" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "submit_eventbridge" {
  name   = "publish-contact-event"
  role   = aws_iam_role.submit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["events:PutEvents"], Resource = [aws_cloudwatch_event_bus.contact.arn] }] })
}
resource "aws_iam_role_policy" "worker_sqs_ses" {
  name = "consume-contact-and-send-email"
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.notification.arn] },
      { Effect = "Allow", Action = ["ses:SendEmail", "ses:SendRawEmail"], Resource = ["arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${var.ses_from_email}"] }
    ]
  })
}

# Package Python Lambda handlers. boto3 is available in the managed Python runtime.
data "archive_file" "submit_zip" {
  type        = "zip"
  source_file = "${path.root}/../../../backend/submit_inquiry/handler.py"
  output_path = "${path.root}/../../../backend/submit_inquiry/function.zip"
}
data "archive_file" "worker_zip" {
  type        = "zip"
  source_file = "${path.root}/../../../backend/send_notification/handler.py"
  output_path = "${path.root}/../../../backend/send_notification/function.zip"
}
resource "aws_cloudwatch_log_group" "submit" {
  name              = "/aws/lambda/${local.name_prefix}-submit-inquiry"
  retention_in_days = var.lambda_log_retention_days
  tags              = local.common_tags
}
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.name_prefix}-notification-worker"
  retention_in_days = var.lambda_log_retention_days
  tags              = local.common_tags
}
resource "aws_lambda_function" "submit" {
  function_name    = "${local.name_prefix}-submit-inquiry"
  role             = aws_iam_role.submit.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.submit_zip.output_path
  source_code_hash = data.archive_file.submit_zip.output_base64sha256
  timeout          = 10
  memory_size      = 128
  environment { variables = { EVENT_BUS_NAME = aws_cloudwatch_event_bus.contact.name } }
  depends_on = [aws_iam_role_policy_attachment.submit_logs, aws_iam_role_policy.submit_eventbridge, aws_cloudwatch_log_group.submit]
  tags       = local.common_tags
}
resource "aws_lambda_function" "worker" {
  function_name    = "${local.name_prefix}-notification-worker"
  role             = aws_iam_role.worker.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.worker_zip.output_path
  source_code_hash = data.archive_file.worker_zip.output_base64sha256
  timeout          = 30
  memory_size      = 128
  environment {
    variables = {
      SES_FROM_EMAIL        = var.ses_from_email
      NOTIFICATION_TO_EMAIL = var.notification_to_email
    }
  }
  depends_on = [aws_iam_role_policy_attachment.worker_logs, aws_iam_role_policy.worker_sqs_ses, aws_cloudwatch_log_group.worker]
  tags       = local.common_tags
}
resource "aws_lambda_event_source_mapping" "notification_queue" {
  event_source_arn        = aws_sqs_queue.notification.arn
  function_name           = aws_lambda_function.worker.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = true
  depends_on              = [aws_iam_role_policy.worker_sqs_ses]
}

# HTTP API. CloudFront forwards /api/* to this regional API origin.
resource "aws_apigatewayv2_api" "contact" {
  name          = "${local.name_prefix}-contact-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
  tags = local.common_tags
}
resource "aws_apigatewayv2_integration" "submit" {
  api_id                 = aws_apigatewayv2_api.contact.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.submit.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}
resource "aws_apigatewayv2_route" "submit" {
  api_id    = aws_apigatewayv2_api.contact.id
  route_key = "POST /api/contact"
  target    = "integrations/${aws_apigatewayv2_integration.submit.id}"
}
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name_prefix}-contact-api"
  retention_in_days = var.lambda_log_retention_days
  tags              = local.common_tags
}
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.contact.id
  name        = "$default"
  auto_deploy = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst
    throttling_rate_limit  = var.api_throttle_rate
  }
  tags = local.common_tags
}
resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.submit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.contact.execution_arn}/*/*"
}

# CloudFront distribution and private S3 origin.
resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  comment             = "${local.name_prefix} website"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  # ✅ Keep only ONE viewer_certificate block
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "s3-website-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }

  origin {
    domain_name = replace(aws_apigatewayv2_api.contact.api_endpoint, "https://", "")
    origin_id   = "contact-api-origin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-website-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "contact-api-origin"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD", "OPTIONS"]
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  tags = local.common_tags
}

resource "aws_s3_bucket_policy" "website_cloudfront" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowCloudFrontReadOnly", Effect = "Allow", Principal = { Service = "cloudfront.amazonaws.com" },
      Action    = ["s3:GetObject"], Resource = "${aws_s3_bucket.website.arn}/*",
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.website.arn } }
    }]
  })
}

# Operational alarms. CloudWatch metrics are usage-based; review account pricing.
resource "aws_cloudwatch_metric_alarm" "submit_errors" {
  alarm_name          = "${local.name_prefix}-submit-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { FunctionName = aws_lambda_function.submit.function_name }
  treat_missing_data  = "notBreaching"
  tags                = local.common_tags
}
resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  alarm_name          = "${local.name_prefix}-worker-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { FunctionName = aws_lambda_function.worker.function_name }
  treat_missing_data  = "notBreaching"
  tags                = local.common_tags
}
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.name_prefix}-notification-dlq-not-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { QueueName = aws_sqs_queue.notification_dlq.name }
  treat_missing_data  = "notBreaching"
  tags                = local.common_tags
}
