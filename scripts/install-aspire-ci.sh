#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "This CI bootstrap requires Linux x64." >&2
  exit 1
fi

install_dir="${1:?Usage: install-aspire-ci.sh INSTALL_DIRECTORY}"
version="17.0.0"
asset="aspire-cli-linux-x64-${version}.tar.gz"
archive="${install_dir}/${asset}"
mkdir -p "${install_dir}/bin"

curl --fail --silent --show-error --location \
  "https://github.com/microsoft/aspire/releases/download/v${version}/${asset}" \
  --output "${archive}"
printf '%s  %s\n' \
  "74a6d6418fcddb117770ccd235e2de4a96a02e36ebcfd0b0e2a0e69d6e85fc18" \
  "${archive}" | sha256sum --check
tar -xzf "${archive}" -C "${install_dir}/bin"
"${install_dir}/bin/aspire" --version
ASPIRE_HOME="${install_dir}/home" "${install_dir}/bin/aspire" setup \
  --install-path "${install_dir}/home" --non-interactive --nologo

printf '%s\n' "${install_dir}/bin" >> "${GITHUB_PATH:?GitHub Actions is required}"
printf 'ASPIRE_HOME=%s\n' "${install_dir}/home" >> "${GITHUB_ENV:?GitHub Actions is required}"
