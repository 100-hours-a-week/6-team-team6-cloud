# =============================================================================
# Discord Notification Lambda
# =============================================================================
# Optional: Creates a Lambda function to send CloudWatch alarms to Discord
# =============================================================================

# Lambda function code
data "archive_file" "discord_lambda" {
  count       = var.enable_discord ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/lambda/discord_notifier.zip"

  source {
    content  = <<-EOF
import json
import urllib.request
import os

def lambda_handler(event, context):
    """
    Lambda function to forward SNS notifications to Discord webhook.
    """
    webhook_url = os.environ.get('DISCORD_WEBHOOK_URL')

    if not webhook_url:
        print("ERROR: DISCORD_WEBHOOK_URL not set")
        return {'statusCode': 500, 'body': 'Webhook URL not configured'}

    # Parse SNS message
    try:
        sns_message = event['Records'][0]['Sns']
        subject = sns_message.get('Subject', 'CloudWatch Alarm')
        message_str = sns_message.get('Message', '{}')

        # Try to parse as JSON (CloudWatch alarm format)
        try:
            alarm_data = json.loads(message_str)
            alarm_name = alarm_data.get('AlarmName', 'Unknown')
            new_state = alarm_data.get('NewStateValue', 'Unknown')
            reason = alarm_data.get('NewStateReason', 'No reason provided')
            description = alarm_data.get('AlarmDescription', '')
            timestamp = alarm_data.get('StateChangeTime', '')

            # Set color based on state
            if new_state == 'ALARM':
                color = 0xFF0000  # Red
                emoji = "🚨"
            elif new_state == 'OK':
                color = 0x00FF00  # Green
                emoji = "✅"
            else:
                color = 0xFFFF00  # Yellow
                emoji = "⚠️"

            # Build Discord embed
            embed = {
                "title": f"{emoji} {alarm_name}",
                "description": description,
                "color": color,
                "fields": [
                    {"name": "상태", "value": new_state, "inline": True},
                    {"name": "시간", "value": timestamp[:19] if timestamp else "N/A", "inline": True},
                    {"name": "상세 정보", "value": reason[:1000] if reason else "N/A", "inline": False}
                ],
                "footer": {"text": "AWS CloudWatch Alarm"}
            }

            payload = {"embeds": [embed]}

        except json.JSONDecodeError:
            # Plain text message
            payload = {
                "content": f"**{subject}**\n{message_str}"
            }

    except Exception as e:
        print(f"Error parsing message: {e}")
        payload = {"content": f"CloudWatch Alert: {str(event)}"}

    # Send to Discord
    try:
        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={'Content-Type': 'application/json'}
        )

        with urllib.request.urlopen(req, timeout=10) as response:
            print(f"Discord response: {response.status}")
            return {'statusCode': 200, 'body': 'Message sent to Discord'}

    except Exception as e:
        print(f"Error sending to Discord: {e}")
        return {'statusCode': 500, 'body': str(e)}
EOF
    filename = "discord_notifier.py"
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "discord_lambda" {
  count = var.enable_discord ? 1 : 0
  name  = "${local.name_prefix}-discord-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

# Lambda basic execution policy
resource "aws_iam_role_policy_attachment" "discord_lambda_basic" {
  count      = var.enable_discord ? 1 : 0
  role       = aws_iam_role.discord_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda Function
resource "aws_lambda_function" "discord_notifier" {
  count         = var.enable_discord ? 1 : 0
  function_name = "${local.name_prefix}-discord-notifier"
  role          = aws_iam_role.discord_lambda[0].arn
  handler       = "discord_notifier.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.discord_lambda[0].output_path
  source_code_hash = data.archive_file.discord_lambda[0].output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
    }
  }

  tags = local.tags
}

# SNS permission to invoke Lambda
resource "aws_lambda_permission" "sns_invoke" {
  count         = var.enable_discord ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord_notifier[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarms.arn
}

# SNS subscription for Lambda
resource "aws_sns_topic_subscription" "discord_lambda" {
  count     = var.enable_discord ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord_notifier[0].arn
}