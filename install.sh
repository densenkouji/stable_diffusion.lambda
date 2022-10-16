#!/bin/sh
echo -n "(Create New) Input AWS Lambda Function Name [ex.mySdFunction]:"
read LAMBDANAME
echo -n "[Hugging Face] User Access Tokens:"
read HFTOKEN
echo -n "[Hugging Face] Model Name [ex.CompVis/stable-diffusion-v1-4]:"
read HFMODELNAME

if [ -z ${HFMODELNAME} ]; then
  HFMODELNAME="CompVis/stable-diffusion-v1-4"
fi

REGION=$(aws configure get region)
ACCOUNTID=$(aws sts get-caller-identity --output text --query Account)
RAND=$(date +%Y%m%d%H%M%S%3N | shasum -a 512 | base64 | fold -w 16 | head -1 | tr 'A-Z' 'a-z')

# lmabda function Name
LAMBDANAME="$LAMBDANAME-$RAND"
# Role Name
ROLENAME="$LAMBDANAME-role"
# ECR Repository - lambda container image stored
REPOSITORYNAME=$(echo "$LAMBDANAME-repo" | tr 'A-Z' 'a-z')
# S3 Bucket where the created images will be stored
BUCKETNAME=$(echo "$LAMBDANAME-bucket" | tr 'A-Z' 'a-z')

echo "(1/6) Create AWS ECR Repository"
RESULT=$(aws ecr create-repository --repository-name ${REPOSITORYNAME})
if [ "`echo $RESULT | grep 'repositoryArn'`" ]; then
  echo "Success!!: Create Repository"
else
  echo "Error occurred.${REPOSITORYNAME}"
  exit
fi

echo "(2/6) Build Container"
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ACCOUNTID}.dkr.ecr.${REGION}.amazonaws.com
docker build -t ${REPOSITORYNAME} --build-arg hf_token="${HFTOKEN}" --build-arg hf_modelname="${HFMODELNAME}" .
if [ "`echo $(docker images) | grep $REPOSITORYNAME`" ]; then
  echo "Success!!: Build image"
else
  aws ecr delete-repository --output text --repository-name ${REPOSITORYNAME} --force
  echo "Error docker build."
  exit
fi
docker tag ${REPOSITORYNAME}:latest ${ACCOUNTID}.dkr.ecr.${REGION}.amazonaws.com/${REPOSITORYNAME}:latest

echo "(3/6) Create Role"
RESULT=$(aws iam create-role --role-name ${ROLENAME} --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{ "Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}')
aws iam attach-role-policy --role-name ${ROLENAME} --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam attach-role-policy --role-name ${ROLENAME} --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

echo "(4/6) Push Container"
docker push ${ACCOUNTID}.dkr.ecr.${REGION}.amazonaws.com/${REPOSITORYNAME}:latest

echo "(5/6) Create S3 Bucket"
aws s3api create-bucket --bucket ${BUCKETNAME} --region ${REGION}

echo "(6/6) Create Lambda"
ROLE_ARN=arn:aws:iam::${ACCOUNTID}:role/${ROLENAME}
DIGEST=$(aws ecr list-images --repository-name ${REPOSITORYNAME} --out text --query 'imageIds[?imageTag==`latest`].imageDigest')
aws lambda create-function --function-name ${LAMBDANAME} --out text \
    --package-type Image --code ImageUri=${ACCOUNTID}.dkr.ecr.${REGION}.amazonaws.com/${REPOSITORYNAME}@${DIGEST} \
    --memory-size 10240 --timeout 900 --environment Variables={"BUCKET"="${BUCKETNAME}"} \
    --role ${ROLE_ARN}

# uninstaller
cat ./uninstall.txt | sed -e "s/BEFORELAMBDANAME/${LAMBDANAME}/" \
    -e "s/BEFOREROLENAME/${ROLENAME}/" \
    -e "s/BEFOREREPOSITORYNAME/${REPOSITORYNAME}/" \
    -e "s/BEFOREBUCKETNAME/${BUCKETNAME}/" > ./"uninstall-$LAMBDANAME.sh"

echo "******* Complete!! *******"
echo "The following resources were created."
echo "- Lmabda function: $LAMBDANAME"
echo "- Role: $ROLENAME"
echo "- ECR Repository: $REPOSITORYNAME"
echo "- S3 Bucket: $BUCKETNAME"
