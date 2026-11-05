#!/usr/bin/env bash
# END-OF-COURSE CLEANUP for Lab 10. Deletes dependencies inside-out.
# DO NOT RUN while any later lab still needs usms-student-data.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

cat << 'WARN'
This will permanently delete:

   - usms-edge-viewer-request, usms-edge-origin-response (all versions)
   - usms-transcript-notifier (all versions, alias live, resource policy)
   - the notification configuration on the transcripts bucket
   - the usms-transcript-cdn CloudFront distribution, if one exists
   - EVERY OBJECT in the transcripts bucket, and the bucket itself

The S3 configuration lab and everything after it depend on that bucket.
WARN

printf 'Type exactly: DELETE USMS EDGE FUNCTIONS\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS EDGE FUNCTIONS" ] || { echo "aborted"; exit 1; }

echo "1/6 removing the bucket notification (stops new invocations first)"
aws s3api put-bucket-notification-configuration \
   --bucket "$BUCKET" --notification-configuration '{}' 2>/dev/null || true

echo "2/6 disabling and deleting the CloudFront distribution, if present"
DIST_ID="${USMS_CLOUDFRONT_DIST_ID:-not-created}"
if [ "$DIST_ID" != "not-created" ]; then
   echo "   a distribution must be disabled and fully deployed before it can be deleted;"
   echo "   on real AWS that wait is roughly 15 minutes. Doing what we can:"
   ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query 'ETag' --output text 2>/dev/null || echo "")
   [ -n "$ETAG" ] && aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG" 2>/dev/null || true
fi

echo "3/6 removing the resource policy statement"
aws lambda remove-permission --function-name usms-transcript-notifier \
   --qualifier live --statement-id usms-s3-transcript-upload 2>/dev/null || true

echo "4/6 deleting the alias, then the functions"
aws lambda delete-alias --function-name usms-transcript-notifier --name live 2>/dev/null || true
for fn in usms-edge-viewer-request usms-edge-origin-response usms-transcript-notifier; do
   aws lambda delete-function --function-name "$fn" 2>/dev/null \
      && echo "   deleted $fn (and all its versions)" \
      || echo "   $fn already absent"
done

echo "5/6 emptying the bucket"
aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true

echo "6/6 deleting the bucket"
aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null \
   && echo "   deleted $BUCKET" \
   || echo "   $BUCKET not empty or already absent"

echo
echo "Note: usms-lambda-exec-role and its two-principal trust policy are NOT deleted."
echo "They belong to Lab 01 and lab-01-cleanup.sh owns them."
