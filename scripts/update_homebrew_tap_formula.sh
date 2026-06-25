#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat << 'EOF'
Usage:
  update_homebrew_tap_formula.sh \
    --formula /path/to/Formula/roomy.rb \
    --tag V1.32.0 \
    --source-sha <sha256> \
    --arm-sha <sha256> \
    --amd-sha <sha256>
EOF
}

formula_path=""
tag=""
source_sha=""
arm_sha=""
amd_sha=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --formula)
            formula_path="${2:-}"
            shift 2
            ;;
        --tag)
            tag="${2:-}"
            shift 2
            ;;
        --source-sha)
            source_sha="${2:-}"
            shift 2
            ;;
        --arm-sha)
            arm_sha="${2:-}"
            shift 2
            ;;
        --amd-sha)
            amd_sha="${2:-}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$formula_path" || -z "$tag" || -z "$source_sha" || -z "$arm_sha" || -z "$amd_sha" ]]; then
    usage >&2
    exit 1
fi

if ! [[ "$tag" =~ ^V[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "Invalid tag: $tag (expected V<major>.<minor>.<patch>)" >&2
    exit 1
fi

for checksum in "$source_sha" "$arm_sha" "$amd_sha"; do
    if ! [[ "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Invalid SHA-256 checksum: $checksum" >&2
        exit 1
    fi
done

if [[ ! -f "$formula_path" ]]; then
    echo "Formula not found: $formula_path" >&2
    exit 1
fi

replacement_counts="$(
    TAG="$tag" \
        SOURCE_SHA="$source_sha" \
        ARM_SHA="$arm_sha" \
        AMD_SHA="$amd_sha" \
        perl -0ne '
        my $text = $_;

        my $source_replacements = (
            $text =~ s{url "https://github.com/jake-seo-cl/(?:Roomy|roomy)/archive/refs/tags/[^"]+\.tar\.gz"\n  sha256 "[^"]+"}{
              qq{url "https://github.com/jake-seo-cl/roomy/archive/refs/tags/$ENV{TAG}.tar.gz"\n  sha256 "$ENV{SOURCE_SHA}"}
            }se
        );

        my $arm_replacements = (
            $text =~ s{(on_arm do\s+url ")https://github.com/jake-seo-cl/(?:Roomy|roomy)/releases/download/[^/]+/binaries-darwin-arm64\.tar\.gz("\s+sha256 ")[^"]+(")}{
              qq{$1https://github.com/jake-seo-cl/roomy/releases/download/$ENV{TAG}/binaries-darwin-arm64.tar.gz$2$ENV{ARM_SHA}$3}
            }se
        );

        my $amd_replacements = (
            $text =~ s{(on_intel do\s+url ")https://github.com/jake-seo-cl/(?:Roomy|roomy)/releases/download/[^/]+/binaries-darwin-amd64\.tar\.gz("\s+sha256 ")[^"]+(")}{
              qq{$1https://github.com/jake-seo-cl/roomy/releases/download/$ENV{TAG}/binaries-darwin-amd64.tar.gz$2$ENV{AMD_SHA}$3}
            }se
        );

        print "$source_replacements $arm_replacements $amd_replacements\n";
    ' "$formula_path"
)"

read -r source_replacements arm_replacements amd_replacements <<< "$replacement_counts"

if [[ "$source_replacements" != "1" || "$arm_replacements" != "1" || "$amd_replacements" != "1" ]]; then
    echo "Failed to update formula: expected 1 replacement for source/arm/amd, got ${source_replacements}/${arm_replacements}/${amd_replacements}" >&2
    exit 1
fi

TAG="$tag" \
    SOURCE_SHA="$source_sha" \
    ARM_SHA="$arm_sha" \
    AMD_SHA="$amd_sha" \
    perl -0pi -e '
    s{url "https://github.com/jake-seo-cl/(?:Roomy|roomy)/archive/refs/tags/[^"]+\.tar\.gz"\n  sha256 "[^"]+"}{
      qq{url "https://github.com/jake-seo-cl/roomy/archive/refs/tags/$ENV{TAG}.tar.gz"\n  sha256 "$ENV{SOURCE_SHA}"}
    }se;

    s{(on_arm do\s+url ")https://github.com/jake-seo-cl/(?:Roomy|roomy)/releases/download/[^/]+/binaries-darwin-arm64\.tar\.gz("\s+sha256 ")[^"]+(")}{
      qq{$1https://github.com/jake-seo-cl/roomy/releases/download/$ENV{TAG}/binaries-darwin-arm64.tar.gz$2$ENV{ARM_SHA}$3}
    }se;

    s{(on_intel do\s+url ")https://github.com/jake-seo-cl/(?:Roomy|roomy)/releases/download/[^/]+/binaries-darwin-amd64\.tar\.gz("\s+sha256 ")[^"]+(")}{
      qq{$1https://github.com/jake-seo-cl/roomy/releases/download/$ENV{TAG}/binaries-darwin-amd64.tar.gz$2$ENV{AMD_SHA}$3}
    }se;
' "$formula_path"
