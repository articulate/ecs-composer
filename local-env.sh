#!/bin/bash

for line in $(cat .app.json | jq -r ".peer.env[]"); do export $line; done
