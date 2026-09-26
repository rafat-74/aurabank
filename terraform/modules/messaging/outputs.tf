
output "sqs_queue_url"        { value = aws_sqs_queue.notifications.url }
output "sqs_queue_arn"        { value = aws_sqs_queue.notifications.arn }
output "sns_topic_arn"        { value = aws_sns_topic.sms_notifications.arn }
output "messaging_policy_arn" { value = aws_iam_policy.messaging.arn }
