# locals {
#   # config with combined key and order
#   runner_matcher_config = { for k, v in var.config.runner_matcher_config : format("%03d-%s", v.matcherConfig.priority, k) => merge(v, { key = k }) }

#   # sorted list
#   runner_matcher_config_sorted = [for k in sort(keys(local.runner_matcher_config)) : local.runner_matcher_config[k]]

#   # handler
#   lambda_handler_function = var.config.legacy_mode ? "index.githubWebhook" : "index.eventBridgeWebhook"

#   lambda_zip       = var.config.lambda_zip == null ? "${path.module}/../../../lambdas/functions/webhook/webhook.zip" : var.config.lambda_zip

# }

# resource "aws_ssm_parameter" "runner_matcher_config" {
#   name  = "${var.config.ssm_paths.root}/${var.config.ssm_paths.webhook}/runner-matcher-config"
#   type  = "String"
#   value = jsonencode(local.runner_matcher_config_sorted)
#   tier  = var.config.matcher_config_parameter_store_tier
# }

# resource "aws_cloudwatch_event_rule" "workflow_job" {
#   name           = "${var.config.prefix}-workflow_job"
#   description    = "Workflow job event ruule for job queued."
#   event_bus_name = aws_cloudwatch_event_bus.main.name

#   event_pattern = <<EOF
# {
#   "detail-type": [
#     "workflow_job"
#   ],
#   "source": ["github"],
#   "detail": {
#     "action": ["queued"]
#   }
# }
# EOF
# }


resource "aws_cloudwatch_event_rule" "workflow_job" {
  name           = "${var.config.prefix}-workflow_job"
  description    = "Workflow job event ruule for job queued."
  event_bus_name = aws_cloudwatch_event_bus.main.name

  event_pattern = <<EOF
{
  "detail-type": [
    "workflow_job"
  ]
}
EOF
}


resource "aws_cloudwatch_event_target" "github_welcome" {
  arn            = aws_lambda_function.dispatcher.arn
  rule           = aws_cloudwatch_event_rule.workflow_job.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
}


resource "aws_lambda_function" "dispatcher" {
  s3_bucket         = var.config.lambda_s3_bucket != null ? var.config.lambda_s3_bucket : null
  s3_key            = var.config.lambda_s3_key != null ? var.config.lambda_s3_key : null
  s3_object_version = var.config.lambda_s3_object_version != null ? var.config.lambda_s3_object_version : null
  filename          = var.config.lambda_s3_bucket == null ? local.lambda_zip : null
  source_code_hash  = var.config.lambda_s3_bucket == null ? filebase64sha256(local.lambda_zip) : null
  function_name     = "${var.config.prefix}-dispatch-to-runner"
  role              = aws_iam_role.dispatcher_lambda.arn
  handler           = "index.workflowJob"
  runtime           = var.config.lambda_runtime
  memory_size       = var.config.lambda_memory_size
  timeout           = var.config.lambda_timeout
  architectures     = [var.config.lambda_architecture]

  environment {
    variables = {
      for k, v in {
        LOG_LEVEL                                = var.config.log_level
        POWERTOOLS_LOGGER_LOG_EVENT              = var.config.log_level == "debug" ? "true" : "false"
        POWERTOOLS_SERVICE_NAME                  = "dispatcher"
        POWERTOOLS_TRACE_ENABLED                 = var.config.tracing_config.mode != null ? true : false
        POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS = var.config.tracing_config.capture_http_requests
        POWERTOOLS_TRACER_CAPTURE_ERROR          = var.config.tracing_config.capture_error
        PARAMETER_GITHUB_APP_WEBHOOK_SECRET      = var.config.github_app_parameters.webhook_secret.name
        REPOSITORY_ALLOW_LIST                    = jsonencode(var.config.repository_white_list)
        SQS_WORKFLOW_JOB_QUEUE                   = try(var.config.sqs_workflow_job_queue.id, null)
        PARAMETER_GITHUB_APP_WEBHOOK_SECRET      = var.config.github_app_parameters.webhook_secret.name
        PARAMETER_RUNNER_MATCHER_CONFIG_PATH     = aws_ssm_parameter.runner_matcher_config.name
      } : k => v if v != null
    }
  }

  dynamic "vpc_config" {
    for_each = var.config.lambda_subnet_ids != null && var.config.lambda_security_group_ids != null ? [true] : []
    content {
      security_group_ids = var.config.lambda_security_group_ids
      subnet_ids         = var.config.lambda_subnet_ids
    }
  }

  tags = merge(var.config.tags, var.config.lambda_tags)

  dynamic "tracing_config" {
    for_each = var.config.tracing_config.mode != null ? [true] : []
    content {
      mode = var.config.tracing_config.mode
    }
  }

  lifecycle {
    replace_triggered_by = [aws_ssm_parameter.runner_matcher_config, null_resource.github_app_parameters]
  }
}

resource "aws_cloudwatch_log_group" "dispatcher" {
  name              = "/aws/lambda/${aws_lambda_function.dispatcher.function_name}"
  retention_in_days = var.config.logging_retention_in_days
  kms_key_id        = var.config.logging_kms_key_id
  tags              = var.config.tags
}

# resource "aws_lambda_permission" "dispatcher" {
#   statement_id  = "AllowExecutionFromAPIGateway"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.dispatcher.function_name
#   principal     = "apigateway.amazonaws.com"
#   source_arn    = var.config.api_gw_source_arn
#   lifecycle {
#     replace_triggered_by = [aws_ssm_parameter.runner_matcher_config, null_resource.github_app_parameters]
#   }
# }

resource "aws_lambda_permission" "allow_cloudwatch_to_call_lambda" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.workflow_job.arn
}


# data "aws_iam_policy_document" "lambda_assume_role_policy" {
#   statement {
#     actions = ["sts:AssumeRole"]

#     principals {
#       type        = "Service"
#       identifiers = ["lambda.amazonaws.com"]
#     }
#   }
# }

resource "aws_iam_role" "dispatcher_lambda" {
  name                 = "${var.config.prefix}-dispatcher-lambda-role"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role_policy.json
  path                 = var.config.role_path
  permissions_boundary = var.config.role_permissions_boundary
  tags                 = var.config.tags
}

resource "aws_iam_role_policy" "dispatcher_logging" {
  name = "logging-policy"
  role = aws_iam_role.dispatcher_lambda.name
  policy = templatefile("${path.module}/../policies/lambda-cloudwatch.json", {
    log_group_arn = aws_cloudwatch_log_group.dispatcher.arn
  })
}

resource "aws_iam_role_policy_attachment" "dispatcher_vpc_execution_role" {
  count      = length(var.config.lambda_subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.dispatcher_lambda.name
  policy_arn = "arn:${var.config.aws_partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "dispatcher_sqs" {
  name = "publish-sqs-policy"
  role = aws_iam_role.dispatcher_lambda.name

  policy = templatefile("${path.module}/../policies/lambda-publish-sqs-policy.json", {
    sqs_resource_arns = jsonencode([for k, v in var.config.runner_matcher_config : v.arn])
    kms_key_arn       = var.config.kms_key_arn != null ? var.config.kms_key_arn : ""
  })
}

resource "aws_iam_role_policy" "dispatcher_ssm" {
  name = "publish-ssm-policy"
  role = aws_iam_role.dispatcher_lambda.name

  policy = templatefile("${path.module}/../policies/lambda-ssm.json", {
    github_app_webhook_secret_arn       = var.config.github_app_parameters.webhook_secret.arn,
    parameter_runner_matcher_config_arn = aws_ssm_parameter.runner_matcher_config.arn
  })
}

resource "aws_iam_role_policy" "dispatcher_xray" {
  count  = var.config.tracing_config.mode != null ? 1 : 0
  name   = "xray-policy"
  policy = data.aws_iam_policy_document.lambda_xray[0].json
  role   = aws_iam_role.dispatcher_lambda.name
}
