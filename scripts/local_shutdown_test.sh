#!/bin/bash

# Copyright 2017 Google Inc. All rights reserved.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# exit on command failure
set -e

readonly dir=$(dirname $0)
readonly projectRoot="$dir/.."
readonly testAppDir="$projectRoot/test-application"
readonly deployDir="$testAppDir/target/deploy"

APP_IMAGE='openjdk-local-integration'
CONTAINER=${APP_IMAGE}-container
OUTPUT_FILE=${CONTAINER}-output.txt
DEPLOYMENT_TOKEN=$(uuidgen)

readonly imageUnderTest=$1
if [[ -z "$imageUnderTest" ]]; then
  echo "Usage: ${0} <image_under_test>"
  exit 1
fi


pushd ${testAppDir}
mvn clean package -Ddeployment.token="${DEPLOYMENT_TOKEN}" -DskipTests --batch-mode
popd

# build app container locally
pushd $deployDir
# escape special characters in docker image name
STAGING_IMAGE=$(echo $imageUnderTest | sed -e 's/\//\\\//g')
sed -e "s/FROM .*/FROM $STAGING_IMAGE/" Dockerfile.in > Dockerfile
echo "Building app container..."
docker build -t $APP_IMAGE . || gcloud docker -- build -t $APP_IMAGE .

docker rm -f $CONTAINER || echo "Integration-test-app container is not running, ready to start a new instance."

# run app container locally to test shutdown logging
echo "Starting app container..."
docker run --rm --name $CONTAINER -p 8080 -e "SHUTDOWN_LOGGING_THREAD_DUMP=true" -e "SHUTDOWN_LOGGING_HEAP_INFO=true" $APP_IMAGE &> $OUTPUT_FILE &

function waitForOutput() {
  found_output='false'
  for run in {1..20}
  do
    grep -P "$1" $OUTPUT_FILE && found_output='true' && break
    sleep 1
  done

  if [ "$found_output" == "false" ]; then
    cat $OUTPUT_FILE
    echo "did not match '$1' in '$OUTPUT_FILE'"
    exit 1
  fi
}

waitForOutput 'Started Application'

getPort() {
   docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}' ${CONTAINER}
}


PORT=`getPort`

echo port is $PORT

until [[ $(curl --silent --fail "http://localhost:$PORT/deployment.token" | grep "$DEPLOYMENT_TOKEN") ]]; do
  sleep 2
done


docker stop $CONTAINER

docker rmi $APP_IMAGE

echo 'verify thread dump'
waitForOutput 'Full thread dump OpenJDK 64-Bit Server VM'

echo 'verify heap info'
waitForOutput '\d+:\s+\d+\s+\d+\s+java.lang.Class'

popd

echo 'OK'