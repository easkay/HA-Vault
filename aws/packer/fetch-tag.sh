#!/bin/bash
# Adapted from https://priocept.com/2017/02/14/aws-tag-retrieval-from-within-an-ec2-instance/

if [ -z $1 ]; then
  SCRIPT_NAME=`basename "$0"`
  echo  >&2 "Usage: $SCRIPT_NAME <tag_name>"
  exit 1
fi

# check that aws and ec2metadata commands are installed
command -v aws >/dev/null 2>&1 || { echo >&2 'aws command not installed.'; exit 2; }
command -v ec2metadata >/dev/null 2>&1 || { echo >&2 'ec2metadata command not installed.'; exit 3; }

INSTANCE_ID=$(ec2metadata --instance-id | cut -d ' ' -f2)
FILTER_PARAMS=( --filters "Name=key,Values=$1" "Name=resource-type,Values=instance" "Name=resource-id,Values=$INSTANCE_ID" )

REGION=$(ec2metadata --availability-zone | cut -d ' ' -f2)
REGION=${REGION%?}

TAG_VALUES=$(aws ec2 describe-tags --output text --region "$REGION" "${FILTER_PARAMS[@]}")
if [ $? -ne 0 ]; then
  echo >&2 "Error retrieving tag value."
  exit 4
fi

TAG_VALUE=$(echo "$TAG_VALUES" | cut -f5)
echo "$TAG_VALUE"
