#!/usr/bin/env bash

set -eu

fly -t pcf set-pipeline -p bosh:265.x \
    -c ci/pipeline.yml \
    --load-vars-from <(lpass show -G "bosh concourse secrets" --notes) \
    -l <(lpass show --note "bats-concourse-pool:vsphere secrets")
