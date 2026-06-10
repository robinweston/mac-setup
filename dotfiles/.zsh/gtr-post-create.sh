#!/bin/sh
# gtr postCreate hook: install correct Node version and dependencies if applicable

if [ -f .nvmrc ]; then
    fnm install && fnm use
fi

if [ -f package.json ]; then
    npm install
fi
