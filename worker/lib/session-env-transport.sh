#!/usr/bin/env bash
# Shared session-env transport helpers.

squad_decode_b64_env() {
  local encoded_name="$1" plain_name="${2:-$1}" encoded="${!1:-}" decoded
  [[ -n "$encoded" ]] || return 0
  if ! IFS= read -r -d '' decoded < <(SQUAD_B64_VALUE="$encoded" node - <<'NODE'
const value = process.env.SQUAD_B64_VALUE || '';
if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) {
  process.exit(1);
}
const buf = Buffer.from(value, 'base64');
process.stdout.write(buf);
process.stdout.write('\0');
NODE
  ); then
    return 1
  fi
  export "${plain_name}=${decoded}"
}
