#!/bin/bash
export PATH="$HOME/tools/node-v20.17.0-linux-x64/bin:$PATH"
cd /mnt/c/src/repos/aca-flake || exit 99
timeout 60 bash worker/tests/test_credential_withholding.sh
echo "EXIT=$?"
