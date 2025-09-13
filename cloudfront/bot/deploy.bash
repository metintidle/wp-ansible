#!/bin/bash

# Fix Lambda@Edge Region Issue
# This script will help you recreate the function in the correct region

set -e

FUNCTION_NAME="cloudfront-bot-verification"
OLD_REGION="ap-southeast-2"
CORRECT_REGION="us-east-1"
ZIP_FILE="bot-lambda.zip"

echo "🔧 Fixing Lambda@Edge region issue..."

# Step 1: Download the function code from the wrong region (optional backup)
echo "📥 Downloading current function code from $OLD_REGION..."
aws lambda get-function \
    --function-name $FUNCTION_NAME \
    --region $OLD_REGION \
    --query 'Code.Location' \
    --output text > function-download-url.txt

echo "✅ Function code location saved to function-download-url.txt"

# Step 2: Get the current function configuration
echo "📋 Getting current function configuration..."
aws lambda get-function-configuration \
    --function-name $FUNCTION_NAME \
    --region $OLD_REGION > current-config.json

ROLE_ARN=$(cat current-config.json | jq -r '.Role')
RUNTIME=$(cat current-config.json | jq -r '.Runtime')
HANDLER=$(cat current-config.json | jq -r '.Handler')
TIMEOUT=$(cat current-config.json | jq -r '.Timeout')
MEMORY_SIZE=$(cat current-config.json | jq -r '.MemorySize')
DESCRIPTION=$(cat current-config.json | jq -r '.Description // "Bot verification function"')

echo "Current configuration:"
echo "  Role: $ROLE_ARN"
echo "  Runtime: $RUNTIME"
echo "  Handler: $HANDLER"
echo "  Timeout: $TIMEOUT"
echo "  Memory: $MEMORY_SIZE"

# Step 3: Create the function in us-east-1
echo "🚀 Creating function in $CORRECT_REGION..."

# Make sure you have the deployment package
if [ ! -f "$ZIP_FILE" ]; then
    echo "❌ $ZIP_FILE not found. Creating it..."
    # Navigate to your bot directory and create the package
    cd /Users/meti/Projects/wp-ansible/cloudfront/bot/
    npm run build  # This should create the zip file
    cd -
fi

# Create function in correct region
aws lambda create-function \
    --function-name $FUNCTION_NAME \
    --runtime $RUNTIME \
    --role $ROLE_ARN \
    --handler $HANDLER \
    --zip-file fileb://$ZIP_FILE \
    --timeout $TIMEOUT \
    --memory-size $MEMORY_SIZE \
    --description "$DESCRIPTION" \
    --region $CORRECT_REGION

echo "✅ Function created in $CORRECT_REGION"

# Step 4: Publish a version
echo "📝 Publishing version..."
VERSION_RESULT=$(aws lambda publish-version \
    --function-name $FUNCTION_NAME \
    --description "Initial version for Lambda@Edge" \
    --region $CORRECT_REGION)

NEW_ARN=$(echo $VERSION_RESULT | jq -r '.FunctionArn')
VERSION_NUMBER=$(echo $VERSION_RESULT | jq -r '.Version')

echo "✅ Published version $VERSION_NUMBER"
echo "✅ New ARN: $NEW_ARN"

# Step 5: Clean up the old function (optional)
echo "🗑️  You can now delete the old function in $OLD_REGION:"
echo "aws lambda delete-function --function-name $FUNCTION_NAME --region $OLD_REGION"

# Step 6: Display next steps
echo ""
echo "🎉 Success! Your function is now ready for Lambda@Edge"
echo ""
echo "Next steps:"
echo "1. Copy this ARN for CloudFront: $NEW_ARN"
echo "2. Go to your CloudFront distribution"
echo "3. Edit the behavior and add this function to 'Viewer request'"
echo "4. Use the ARN: $NEW_ARN"
echo ""
echo "Or use this AWS CLI command to update CloudFront:"
echo "aws cloudfront get-distribution-config --id YOUR-DISTRIBUTION-ID > distribution-config.json"
echo "# Edit the JSON to add the Lambda association"
echo "aws cloudfront update-distribution --id YOUR-DISTRIBUTION-ID --distribution-config file://distribution-config.json --if-match ETAG"

# Cleanup
rm -f current-config.json function-download-url.txt