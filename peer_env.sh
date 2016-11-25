#!/bin/bash
if [ ${PEER_CONSUL_ADDR} ]
then
  if consul-template -consul=$PEER_CONSUL_ADDR -template=/peer_exports.ctmpl:/tmp/peer_exports.sh -once
  then
    source /tmp/peer_exports.sh
  else
    echo "======== COULD NOT LOAD PEER VARS ========"
    exit 1
  fi
else
  echo "PEER_CONSUL_ADDR is not set skipping peer-specific exports"
fi
