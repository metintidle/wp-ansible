#!/bin/bash

# Fix Lambda@Edge IAM Role Trust Policy
ROLE_NAME="cloudfront-bot-verification-role-989usgrm"

echo "🔧 Fixing Lambda@Edge IAM role trust policy..."

# Create the correct trust policy
cat > lambda-edge-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

echo "📝 Created trust policy file"

# Update the role's trust policy
echo "🔄 Updating IAM role trust policy..."
aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document file://lambda-edge-trust-policy.json

if [ $? -eq 0 ]; then
    echo "✅ Trust policy updated successfully!"
    echo "✅ Role '$ROLE_NAME' can now be assumed by Lambda@Edge"
    echo ""
    echo "🎉 You can now go back to the Lambda console and deploy to Lambda@Edge"
else
    echo "❌ Failed to update trust policy"
    echo "💡 Make sure you have IAM permissions or contact your AWS administrator"
fi

# Clean up
rm lambda-edge-trust-policy.json

echo ""
echo "Next steps:"
echo "1. Go back to AWS Lambda console"
echo "2. Click 'Deploy to Lambda@Edge' again"
echo "3. Configure your CloudFront distribution settings"