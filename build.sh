#!/usr/bin/env bash
#
# Build the BakeryOS dev ISO from a throwaway clone of bakeryos-iso.
#
#   ./build.sh
#   ./build.sh --clean --prepare
#
# Everything this variant needs lives next to this script: variant.conf,
# packages.remove and packages.add. The clone under build/src is disposable: it
# is reset to upstream on every run and never committed or pushed.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

upstream_repo="${BAKERYOS_ISO_REPO:-git@github.com:bakeryos-project/bakeryos-iso.git}"
upstream_ref="${BAKERYOS_ISO_REF:-main}"
work_root="${BAKERYOS_ISO_WORK:-${script_dir}/build}"

usage() {
    cat <<'EOF'
usage: build.sh [options]

Clones bakeryos-iso into a build directory, applies this variant's package
patch, and builds the ISO there.

options:
  -w, --work-dir DIR   where the clone and artifacts live (default: ./build)
      --repo URL       upstream repository (default: $BAKERYOS_ISO_REPO)
      --ref REF        upstream branch or tag (default: main)
      --prepare        install build dependencies on this host first (sudo pacman)
      --no-build       stop after cloning and patching, print the build command
      --clean          delete the build directory first
      --keep-src       reuse the existing clone as-is instead of resetting it
  -h, --help           this message

environment:
  BAKERYOS_ISO_REPO    upstream repository
  BAKERYOS_ISO_REF     upstream branch or tag
  BAKERYOS_ISO_WORK    build directory

artifacts:
  build/src    patched clone of bakeryos-iso
  build/work   mkiso working directory, removed after the build
  build/out    ISO plus .sha256
EOF
}

do_prepare=0
do_build=1
do_clean=0
keep_src=0

while (( $# )); do
    case "${1}" in
        -w|--work-dir) work_root="${2:?missing value for ${1}}"; shift 2 ;;
        --repo) upstream_repo="${2:?missing value for ${1}}"; shift 2 ;;
        --ref) upstream_ref="${2:?missing value for ${1}}"; shift 2 ;;
        --prepare) do_prepare=1; shift ;;
        --no-build) do_build=0; shift ;;
        --clean) do_clean=1; shift ;;
        --keep-src) keep_src=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '${1}'" >&2; usage >&2; exit 1 ;;
    esac
done

mkdir -p "${work_root}"
work_root="$(cd -- "${work_root}" && pwd)"

# --clean deletes the whole work dir, so it must never be this script's own
# directory or one of its parents.
if [[ "${script_dir}" == "${work_root}"* ]]; then
    echo "error: refusing to use '${work_root}' as the build directory" >&2
    exit 1
fi

src="${work_root}/src"
work="${work_root}/work"
out="${work_root}/out"

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

if (( do_clean )) && [[ -e "${work_root}" ]]; then
    echo "removing ${work_root}"
    rm -rf -- "${work_root}"
fi

mkdir -p "${work}" "${out}"

if [[ -d "${src}/.git" ]]; then
    if (( keep_src )); then
        echo "reusing existing clone: ${src}"
    else
        echo "updating clone: ${src} (${upstream_ref})"
        git -C "${src}" fetch --quiet --depth 1 origin "${upstream_ref}"
        git -C "${src}" reset --quiet --hard FETCH_HEAD
        git -C "${src}" clean -fdq
    fi
else
    echo "cloning ${upstream_repo} (${upstream_ref}) into ${src}"
    git clone --quiet --depth 1 --branch "${upstream_ref}" "${upstream_repo}" "${src}"
fi

bash "${script_dir}/patch.sh" "${src}"

if (( do_prepare )); then
    echo "installing build dependencies"
    ( cd -- "${src}" && run_root bash scripts/prepare.sh )
fi

cmd=(bash "${src}/scripts/mkiso.sh"
    -C "${src}/pacman.conf"
    -v
    -w "${work}"
    -o "${out}"
    -r
    "${src}")

if (( ! do_build )); then
    echo
    echo "patched profile: ${src}"
    printf 'build command: cd %q && ' "${src}"
    printf '%q ' "${cmd[@]}"
    echo
    exit 0
fi

echo "building (mkiso needs root, this takes a while)"
( cd -- "${src}" && run_root "${cmd[@]}" )

iso="$(ls -1t -- "${out}"/*.iso 2>/dev/null | head -n 1 || true)"
if [[ -z "${iso}" ]]; then
    echo "error: no ISO in ${out}" >&2
    exit 1
fi

( cd -- "${out}" && sha256sum -- "$(basename -- "${iso}")" >"$(basename -- "${iso}").sha256" )

echo
echo "ISO:     ${iso}"
echo "size:    $(du -h -- "${iso}" | cut -f 1)"
echo "sha256:  ${iso}.sha256"
