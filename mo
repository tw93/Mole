#!/bin/bash
# Short alias for mole.
exec "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/mole" "$@"
