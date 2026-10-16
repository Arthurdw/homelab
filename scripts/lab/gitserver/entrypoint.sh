#!/bin/sh
set -eu

mkdir -p /run

# Run fcgiwrap on a unix socket in the background, then nginx in the foreground.
fcgiwrap -s unix:/run/fcgiwrap.sock &
sleep 0.3

exec nginx -g 'daemon off;'
