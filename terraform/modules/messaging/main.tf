
resource "aws_sqs_queue" "notifications_dlq" {
  name                      = "${var.project}-${var.env}-notifications-dlq"
  message_retention_seconds = 1209600
  tags                      = var.tags
}

resource "aws_sqs_queue" "notifications" {
  name                       = "${var.project}-${var.env}-notifications"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = 3
  })
  tags = var.tags
}

resource "aws_sns_topic" "sms_notifications" {
  name = "${var.project}-${var.env}-sms"
  tags = var.tags
}

resource "aws_iam_policy" "messaging" {
  name = "${var.project}-${var.env}-messaging-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.notifications.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.sms_notifications.arn
      }
    ]
  })
}
