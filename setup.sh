#!/usr/bin/env bash

echo "Preparing challenge environment..."

mkdir -p ~/challenge

cp -r challenge/* ~/challenge/

chmod -R 755 ~/challenge

echo "Environment ready."