#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <host-daed-binary> <output-wing.db>" >&2
  exit 2
fi

daed_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_db="$2"
seed_dir="$(mktemp -d)"
api_url="http://127.0.0.1:32023/graphql"
daed_pid=""
daed_log="${seed_dir}/daed.log"

stop_daed() {
  if [[ -n "${daed_pid}" ]] && kill -0 "${daed_pid}" 2>/dev/null; then
    kill "${daed_pid}" 2>/dev/null || true
    wait "${daed_pid}" 2>/dev/null || true
  fi
  daed_pid=""
}

cleanup() {
  local status=$?
  stop_daed
  if [[ "${status}" -ne 0 && -s "${daed_log}" ]]; then
    echo "daed seed log:" >&2
    tail -n 120 "${daed_log}" >&2
  fi
  rm -rf "${seed_dir}"
  return "${status}"
}
trap cleanup EXIT

graphql() {
  local payload="$1"
  local token="${2:-}"
  local -a args=(
    --fail-with-body --silent --show-error
    --header "Content-Type: application/json"
  )
  if [[ -n "${token}" ]]; then
    args+=(--header "Authorization: Bearer ${token}")
  fi
  curl "${args[@]}" --data-binary "${payload}" "${api_url}"
}

start_daed() {
  stop_daed
  "${daed_bin}" run \
    --api-only \
    --config "${seed_dir}/config" \
    --listen 127.0.0.1:32023 \
    --logfile "${daed_log}" \
    --logfile-maxbackups 1 \
    --logfile-maxsize 2 &
  daed_pid=$!

  local response=""
  for _ in $(seq 1 60); do
    if ! kill -0 "${daed_pid}" 2>/dev/null; then
      wait "${daed_pid}" || true
      echo "The host daed process stopped before its seed API became ready." >&2
      return 1
    fi
    response="$(
      graphql '{"query":"query Init{numberUsers}"}' 2>/dev/null || true
    )"
    if jq -e '.data.numberUsers | numbers' <<<"${response}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for the host daed seed API." >&2
  return 1
}

create_temporary_user() {
  local username="$1"
  local password="$2"
  local payload response
  payload="$(
    jq -cn \
      --arg username "${username}" \
      --arg password "${password}" \
      '{
        query: "mutation Init($username:String!,$password:String!){createUser(username:$username,password:$password)}",
        variables: {username: $username, password: $password}
      }'
  )"
  response="$(graphql "${payload}")"
  jq -er '.data.createUser | select(type == "string" and length > 0)' \
    <<<"${response}"
}

delete_users() {
  stop_daed
  sqlite3 "${seed_dir}/config/wing.db" 'DELETE FROM users; VACUUM;'
  if [[ "$(sqlite3 "${seed_dir}/config/wing.db" 'SELECT count(*) FROM users;')" != "0" ]]; then
    echo "The generated daed database still contains a user." >&2
    exit 1
  fi
}

dns_config="$(
  cat <<'EOF'
ipversion_prefer: 4
upstream {
  alidns: 'udp://223.5.5.5:53'
}
routing {
  request {
    sub(tag_regex: '.*') -> alidns
    node(name_regex: '.*') -> alidns
    subnode(subtag_regex: '.*') -> alidns
    fallback: alidns
  }
  response {
    qtype(aaaa) -> reject
    fallback: accept
  }
}
EOF
)"

mkdir -p "${seed_dir}/config"
chmod 0755 "${daed_bin}"
start_daed

initial_state="$(graphql '{"query":"query Init{numberUsers}"}')"
jq -e '.data.numberUsers == 0' <<<"${initial_state}" >/dev/null

seed_username="seed_$(openssl rand -hex 8)"
seed_password="A9$(openssl rand -hex 24)z"
seed_token="$(create_temporary_user "${seed_username}" "${seed_password}")"

seed_query="$(
  cat <<'EOF'
mutation Seed($dns:String!) {
  createConfig(
    name: "IPv4 AliDNS"
    global: {
      tcpCheckUrl: ["http://cp.cloudflare.com,1.1.1.1"]
      udpCheckDns: ["dns.alidns.com:53,223.5.5.5"]
      bootstrapResolver: "223.5.5.5:53"
      fallbackResolver: "223.5.5.5:53"
    }
  ) {
    id
  }
  createDns(name: "IPv4 AliDNS", dns: $dns) {
    id
  }
  createRouting(name: "Default") {
    id
  }
}
EOF
)"
seed_payload="$(
  jq -cn --arg query "${seed_query}" --arg dns "${dns_config}" \
    '{query: $query, variables: {dns: $dns}}'
)"
seed_response="$(graphql "${seed_payload}" "${seed_token}")"
jq -e '((.errors // []) | length) == 0' <<<"${seed_response}" >/dev/null
config_id="$(jq -er '.data.createConfig.id' <<<"${seed_response}")"
dns_id="$(jq -er '.data.createDns.id' <<<"${seed_response}")"
routing_id="$(jq -er '.data.createRouting.id' <<<"${seed_response}")"

select_query="$(
  cat <<'EOF'
mutation Select($config:ID!,$dns:ID!,$routing:ID!) {
  selectConfig(id: $config)
  selectDns(id: $dns)
  selectRouting(id: $routing)
}
EOF
)"
select_payload="$(
  jq -cn \
    --arg query "${select_query}" \
    --arg config "${config_id}" \
    --arg dns "${dns_id}" \
    --arg routing "${routing_id}" \
    '{
      query: $query,
      variables: {config: $config, dns: $dns, routing: $routing}
    }'
)"
select_response="$(graphql "${select_payload}" "${seed_token}")"
jq -e '
  ((.errors // []) | length) == 0
  and .data.selectConfig == 1
  and .data.selectDns == 1
  and .data.selectRouting == 1
' <<<"${select_response}" >/dev/null

dry_response="$(
  graphql '{"query":"mutation Check{run(dry:true)}"}' "${seed_token}"
)"
jq -e '((.errors // []) | length) == 0 and .data.run == 1' \
  <<<"${dry_response}" >/dev/null

delete_users
start_daed
jq -e '.data.numberUsers == 0' \
  <<<"$(graphql '{"query":"query Init{numberUsers}"}')" >/dev/null

verify_username="verify_$(openssl rand -hex 8)"
verify_password="B8$(openssl rand -hex 24)y"
verify_token="$(create_temporary_user "${verify_username}" "${verify_password}")"
verify_query="$(
  cat <<'EOF'
query Verify {
  numberUsers
  configs {
    selected
    global {
      tcpCheckUrl
      udpCheckDns
      bootstrapResolver
      fallbackResolver
    }
  }
  dnss {
    selected
    dns {
      string
    }
  }
  routings {
    selected
  }
}
EOF
)"
verify_payload="$(jq -cn --arg query "${verify_query}" '{query: $query}')"
verify_response="$(graphql "${verify_payload}" "${verify_token}")"
jq -e --arg dns "${dns_config}" '
  ((.errors // []) | length) == 0
  and .data.numberUsers == 1
  and (.data.configs | length) == 1
  and .data.configs[0].selected
  and .data.configs[0].global.tcpCheckUrl
    == ["http://cp.cloudflare.com", "1.1.1.1"]
  and .data.configs[0].global.udpCheckDns
    == ["dns.alidns.com:53", "223.5.5.5"]
  and .data.configs[0].global.bootstrapResolver == "223.5.5.5:53"
  and .data.configs[0].global.fallbackResolver == "223.5.5.5:53"
  and (.data.dnss | length) == 1
  and .data.dnss[0].selected
  and .data.dnss[0].dns.string == $dns
  and (.data.routings | length) == 1
  and .data.routings[0].selected
' <<<"${verify_response}" >/dev/null

dry_response="$(
  graphql '{"query":"mutation Check{run(dry:true)}"}' "${verify_token}"
)"
jq -e '((.errors // []) | length) == 0 and .data.run == 1' \
  <<<"${dry_response}" >/dev/null

delete_users
start_daed
final_state="$(graphql '{"query":"query Init{numberUsers}"}')"
jq -e '.data.numberUsers == 0' <<<"${final_state}" >/dev/null
stop_daed

wing_db="${seed_dir}/config/wing.db"
if grep -aFq "${seed_username}" "${wing_db}" ||
   grep -aFq "${seed_password}" "${wing_db}" ||
   grep -aFq "${verify_username}" "${wing_db}" ||
   grep -aFq "${verify_password}" "${wing_db}"; then
  echo "Temporary daed credentials remain in the generated database." >&2
  exit 1
fi

mkdir -p "$(dirname "${output_db}")"
cp "${wing_db}" "${output_db}"
chmod 0640 "${output_db}"
echo "Generated userless daed defaults at ${output_db}"
