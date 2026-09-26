#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$DIR/db_init_build"
ZIP="$DIR/db_init_lambda.zip"

echo "Building DB Init Lambda package..."

# حذف المجلد القديم
if [ -d "$BUILD_DIR" ]; then
    sudo rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

cp "$DIR/db_init_lambda/index.py" "$BUILD_DIR/"

# بناء الـ packages بـ python3.12 متوافق مع Lambda runtime
docker run --rm \
    --entrypoint pip \
    -v "$BUILD_DIR":/var/task \
    public.ecr.aws/lambda/python:3.12 \
    install psycopg2-binary boto3 -t /var/task/ --quiet

cd "$BUILD_DIR"
zip -r "$ZIP" . -q

echo "Lambda zip created: $ZIP"
echo "Size: $(du -sh "$ZIP" | cut -f1)"
