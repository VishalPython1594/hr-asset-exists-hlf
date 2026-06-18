#!/bin/bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

ROOTDIR=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/local/bin:/usr/local/bin:$PATH
export FABRIC_CFG_PATH=${PWD}/configtx
export VERBOSE=false

pushd ${ROOTDIR} > /dev/null
trap "popd > /dev/null" EXIT

. scripts/utils.sh

: ${CONTAINER_CLI:="docker"}
: ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI}-compose"}
infoln "Using ${CONTAINER_CLI} and ${CONTAINER_CLI_COMPOSE}"

function clearContainers() {
  infoln "Removing remaining containers"
  ${CONTAINER_CLI} rm -f $(${CONTAINER_CLI} ps -aq --filter label=service=hyperledger-fabric) 2>/dev/null || true
  ${CONTAINER_CLI} rm -f $(${CONTAINER_CLI} ps -aq --filter name='dev-peer*') 2>/dev/null || true
}

function removeUnwantedImages() {
  infoln "Removing generated chaincode docker images"
  ${CONTAINER_CLI} image rm -f $(${CONTAINER_CLI} images -aq --filter reference='dev-peer*') 2>/dev/null || true
}

NONWORKING_VERSIONS="^1\.0\. ^1\.1\. ^1\.2\. ^1\.3\. ^1\.4\."

function checkPrereqs() {
  peer version > /dev/null 2>&1

  if [[ $? -ne 0 || ! -d "../config" ]]; then
    errorln "Peer binary and configuration files not found.."
    errorln
    errorln "Follow the instructions in the Fabric docs to install the Fabric Binaries:"
    errorln "https://hyperledger-fabric.readthedocs.io/en/latest/install.html"
    exit 1
  fi

  LOCAL_VERSION=$(peer version | sed -ne 's/^ Version: //p')
  DOCKER_IMAGE_VERSION=$(${CONTAINER_CLI} run --rm bitnami/hyperledger-bitnami/hyperledger-fabric-tools:latest:latest peer version | sed -ne 's/^ Version: //p')

  infoln "LOCAL_VERSION=$LOCAL_VERSION"
  infoln "DOCKER_IMAGE_VERSION=$DOCKER_IMAGE_VERSION"

  if [ "$LOCAL_VERSION" != "$DOCKER_IMAGE_VERSION" ]; then
    warnln "Local fabric binaries and docker images are out of  sync. This may cause problems."
  fi

  for UNSUPPORTED_VERSION in $NONWORKING_VERSIONS; do
    infoln "$LOCAL_VERSION" | grep -q $UNSUPPORTED_VERSION
    if [ $? -eq 0 ]; then
      fatalln "Local Fabric binary version of $LOCAL_VERSION does not match the versions supported by the test network."
    fi

    infoln "$DOCKER_IMAGE_VERSION" | grep -q $UNSUPPORTED_VERSION
    if [ $? -eq 0 ]; then
      fatalln "Fabric Docker image version of $DOCKER_IMAGE_VERSION does not match the versions supported by the test network."
    fi
  done

  if [ "$CRYPTO" == "Certificate Authorities" ]; then

    bitnami/hyperledger-fabric-ca:latest-client version > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      errorln "bitnami/hyperledger-fabric-ca:latest-client binary not found.."
      exit 1
    fi

    CA_LOCAL_VERSION=$(bitnami/hyperledger-fabric-ca:latest-client version | sed -ne 's/ Version: //p')
    CA_DOCKER_IMAGE_VERSION=$(${CONTAINER_CLI} run --rm bitnami/hyperledger-bitnami/hyperledger-fabric-ca:latest:latest bitnami/hyperledger-fabric-ca:latest-client version | sed -ne 's/ Version: //p' | head -1)

    infoln "CA_LOCAL_VERSION=$CA_LOCAL_VERSION"
    infoln "CA_DOCKER_IMAGE_VERSION=$CA_DOCKER_IMAGE_VERSION"

    if [ "$CA_LOCAL_VERSION" != "$CA_DOCKER_IMAGE_VERSION" ]; then
      warnln "Local bitnami/hyperledger-fabric-ca:latest binaries and docker images are out of sync. This may cause problems."
    fi
  fi
}

function createOrgs() {
  if [ -d "organizations/peerOrganizations" ]; then
    rm -Rf organizations/peerOrganizations && rm -Rf organizations/ordererOrganizations
  fi

  if [ "$CRYPTO" == "cryptogen" ]; then
    which cryptogen
    if [ "$?" -ne 0 ]; then
      fatalln "cryptogen tool not found. exiting"
    fi

    infoln "Generating certificates using cryptogen tool"

    cryptogen generate --config=./organizations/cryptogen/crypto-config-org1.yaml --output="organizations"
    cryptogen generate --config=./organizations/cryptogen/crypto-config-org2.yaml --output="organizations"
    cryptogen generate --config=./organizations/cryptogen/crypto-config-orderer.yaml --output="organizations"
  fi

  if [ "$CRYPTO" == "Certificate Authorities" ]; then
    infoln "Generating certificates using Fabric CA"
    ${CONTAINER_CLI_COMPOSE} -f compose/$COMPOSE_FILE_CA -f compose/$CONTAINER_CLI/${CONTAINER_CLI}-$COMPOSE_FILE_CA up -d 2>&1

    . organizations/bitnami/hyperledger-fabric-ca:latest/registerEnroll.sh

    while :
    do
      if [ ! -f "organizations/bitnami/hyperledger-fabric-ca:latest/org1/tls-cert.pem" ]; then
        sleep 1
      else
        break
      fi
    done

    createOrg1
    createOrg2
    createOrderer
  fi

  ./organizations/ccp-generate.sh
}

function networkUp() {
  checkPrereqs

  if [ ! -d "organizations/peerOrganizations" ]; then
    createOrgs
  fi

  COMPOSE_FILES="-f compose/${COMPOSE_FILE_BASE} -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_BASE}"

  if [ "${DATABASE}" == "couchdb" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f compose/${COMPOSE_FILE_COUCH} -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_COUCH}"
  fi

  DOCKER_SOCK="${DOCKER_SOCK}" ${CONTAINER_CLI_COMPOSE} ${COMPOSE_FILES} up -d 2>&1

  $CONTAINER_CLI ps -a
  if [ $? -ne 0 ]; then
    fatalln "Unable to start network"
  fi
}

function createChannel() {
  bringUpNetwork="false"

  if ! $CONTAINER_CLI info > /dev/null 2>&1 ; then
    fatalln "$CONTAINER_CLI network is required to be running to create a channel"
  fi

  CONTAINERS=($($CONTAINER_CLI ps | grep hyperledger/ | awk '{print $2}'))
  len=$(echo ${#CONTAINERS[@]})

  if [[ $len -ge 4 ]] && [[ ! -d "organizations/peerOrganizations" ]]; then
    networkDown
  fi

  [[ $len -lt 4 ]] || [[ ! -d "organizations/peerOrganizations" ]] && bringUpNetwork="true"

  if [ $bringUpNetwork == "true"  ]; then
    networkUp
  fi

  scripts/createChannel.sh $CHANNEL_NAME $CLI_DELAY $MAX_RETRY $VERBOSE
}

function deployCC() {
  scripts/deployCC.sh $CHANNEL_NAME $CC_NAME $CC_SRC_PATH $CC_SRC_LANGUAGE $CC_VERSION $CC_SEQUENCE $CC_INIT_FCN $CC_END_POLICY $CC_COLL_CONFIG $CLI_DELAY $MAX_RETRY $VERBOSE
}

function networkDown() {
  ${CONTAINER_CLI_COMPOSE} down --volumes --remove-orphans
  clearContainers
  removeUnwantedImages
}

CRYPTO="cryptogen"
MAX_RETRY=5
CLI_DELAY=3
CHANNEL_NAME="mychannel"
CC_NAME="NA"
CC_SRC_PATH="NA"
CC_END_POLICY="NA"
CC_COLL_CONFIG="NA"
CC_INIT_FCN="NA"
COMPOSE_FILE_BASE=compose-test-net.yaml
COMPOSE_FILE_COUCH=compose-couch.yaml
COMPOSE_FILE_CA=compose-ca.yaml
CC_SRC_LANGUAGE="NA"
CCAAS_DOCKER_RUN=true
CC_VERSION="1.0"
CC_SEQUENCE=1
DATABASE="leveldb"

MODE=$1

if [ "$MODE" == "up" ]; then
  networkUp
elif [ "$MODE" == "createChannel" ]; then
  createChannel
elif [ "$MODE" == "down" ]; then
  networkDown
elif [ "$MODE" == "deployCC" ]; then
  deployCC
else
  echo "Usage: ./network.sh [up|down|createChannel|deployCC]"
fi