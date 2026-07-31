#!/bin/sh
# gtr postCreate hook: install correct Node version and dependencies if applicable

if [ -f .nvmrc ] || [ -f .node-version ]; then
    fnm use --install-if-missing --silent-if-unchanged
fi

if [ -f package.json ]; then
    npm install
fi
