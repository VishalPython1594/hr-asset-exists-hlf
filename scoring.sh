#!/usr/bin/env bash

SCORE=0

cd ~/challenge/test-network

source ./scripts/setOrgPeerContext.sh 1
export FABRIC_CFG_PATH=${PWD}/configtx

RESULT=$(peer chaincode query -C mychannel -n assetcc \
-c '{"Args":["ReadAsset","asset1"]}' 2>&1)

if [[ $RESULT == *"does not exist"* ]]; then
    SCORE=50
fi

echo $SCORE