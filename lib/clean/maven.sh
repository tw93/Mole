#!/bin/bash
# Maven Repository Cleanup Module
set -euo pipefail

# Maven local repository cleanup.
# Path: ~/.m2/repository
# Note: This path is in the default whitelist. Remove from whitelist to enable cleanup.
clean_maven_repository() {
    local maven_repo="$HOME/.m2/repository"

    # Only clean if the directory exists
    [[ -d "$maven_repo" ]] || return 0

    safe_clean "$maven_repo"/* "${TR_CLEAN_MAVEN_LOCAL_REPO:-Maven local repository}"
}
