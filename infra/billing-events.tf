resource "aws_sqs_queue" "billing_events" {
  name                       = "${local.name_prefix}-billing-events"
  fifo_queue                 = false
  sqs_managed_sse_enabled    = true
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
}

resource "aws_sqs_queue" "billing_events_dlq" {
  name                       = "${local.name_prefix}-billing-events-dlq"
  fifo_queue                 = false
  sqs_managed_sse_enabled    = true
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 60
  message_retention_seconds  = 1209600
}

resource "aws_sqs_queue_redrive_allow_policy" "billing_events_dlq" {
  queue_url = aws_sqs_queue.billing_events_dlq.url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.billing_events.arn]
  })
}

resource "aws_sqs_queue_redrive_policy" "billing_events" {
  queue_url = aws_sqs_queue.billing_events.url
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.billing_events_dlq.arn
    maxReceiveCount     = 5
  })

  depends_on = [aws_sqs_queue_redrive_allow_policy.billing_events_dlq]
}

output "billing_events_queue_url" {
  value = aws_sqs_queue.billing_events.url
}

output "billing_events_queue_arn" {
  value = aws_sqs_queue.billing_events.arn
}

output "billing_events_dlq_url" {
  value = aws_sqs_queue.billing_events_dlq.url
}

output "billing_events_dlq_arn" {
  value = aws_sqs_queue.billing_events_dlq.arn
}
