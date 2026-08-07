#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <luci-app-daede data directory>" >&2
  exit 2
fi

data_dir="$(cd "$1" && pwd)"
uci_defaults="${data_dir}/etc/uci-defaults/90-luci-app-daede-init"
generator="${data_dir}/usr/share/luci-app-daede/gen-dae-config.sh"

for required_file in "${uci_defaults}" "${generator}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "Required luci-app-daede file is missing: ${required_file}" >&2
    exit 1
  fi
done

for expected in \
  "uci -q set dae.dns.cn_upstream='udp://dns.alidns.com:53'" \
  "uci -q set dae.dns.fallback_upstream='tcp+udp://dns.google:53'"; do
  if [[ "$(grep -Fc "${expected}" "${uci_defaults}")" != "1" ]]; then
    echo "Unexpected luci-app-daede UCI default: ${expected}" >&2
    exit 1
  fi
done

awk '
  $0 == "\t\tuci -q set dae.dns.cn_upstream='\''udp://dns.alidns.com:53'\''" {
    print "\t\tuci -q set dae.dns.cn_upstream='\''udp://223.5.5.5:53'\''"
    next
  }
  $0 == "\t\tuci -q set dae.dns.fallback_upstream='\''tcp+udp://dns.google:53'\''" {
    print "\t\tuci -q set dae.dns.fallback_upstream='\''udp://223.5.5.5:53'\''"
    next
  }
  $0 == "\tif ! uci -q get dae.config.lan_interface >/dev/null 2>&1; then" {
    in_lan_default = 1
  }
  {
    print
  }
  in_lan_default && $0 == "\tfi" {
    print "\tif ! uci -q get dae.config.bootstrap_resolver >/dev/null 2>&1; then"
    print "\t\tuci -q set dae.config.bootstrap_resolver='\''223.5.5.5:53'\''"
    print "\tfi"
    print "\tif ! uci -q get dae.config.fallback_resolver >/dev/null 2>&1; then"
    print "\t\tuci -q set dae.config.fallback_resolver='\''223.5.5.5:53'\''"
    print "\tfi"
    in_lan_default = 0
  }
' "${uci_defaults}" >"${uci_defaults}.patched"
mv "${uci_defaults}.patched" "${uci_defaults}"

for expected in \
  'config_get lan_interface config lan_interface "br-lan"' \
  'config_get fb_up dns fallback_upstream "tcp+udp://dns.google:53"' \
  'echo "    tcp_check_url: '\''http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'\''"' \
  'echo "    udp_check_dns: '\''dns.google:53,8.8.8.8,2001:4860:4860::8888'\''"'; do
  if [[ "$(grep -Fc "${expected}" "${generator}")" != "1" ]]; then
    echo "Unexpected luci-app-daede generator default: ${expected}" >&2
    exit 1
  fi
done

awk '
  $0 == "\tconfig_get fb_up dns fallback_upstream \"tcp+udp://dns.google:53\"" {
    print "\tconfig_get fb_up dns fallback_upstream \"udp://223.5.5.5:53\""
    next
  }
  $0 == "\tconfig_get lan_interface config lan_interface \"br-lan\"" {
    print
    print "\tconfig_get bootstrap_resolver config bootstrap_resolver \"223.5.5.5:53\""
    print "\tconfig_get fallback_resolver config fallback_resolver \"223.5.5.5:53\""
    next
  }
  $0 == "\tlocal dial_mode log_level wan_interface lan_interface" {
    print "\tlocal dial_mode log_level wan_interface lan_interface bootstrap_resolver fallback_resolver"
    next
  }
  $0 == "\t\techo \"    dial_mode: ${dial_mode}\"" {
    print
    print "\t\techo \"    bootstrap_resolver: ${bootstrap_resolver}\""
    print "\t\techo \"    fallback_resolver: ${fallback_resolver}\""
    next
  }
  $0 == "\t\techo \"    tcp_check_url: '\''http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'\''\"" {
    print "\t\techo \"    tcp_check_url: '\''http://cp.cloudflare.com,1.1.1.1'\''\""
    next
  }
  $0 == "\t\techo \"    udp_check_dns: '\''dns.google:53,8.8.8.8,2001:4860:4860::8888'\''\"" {
    print "\t\techo \"    udp_check_dns: '\''dns.alidns.com:53,223.5.5.5'\''\""
    next
  }
  $0 == "\t\techo \"            fallback: fallbackdns\"" {
    print "\t\techo \"            sub(tag_regex: '\''.*'\'') -> fallbackdns\""
    print "\t\techo \"            node(name_regex: '\''.*'\'') -> fallbackdns\""
    print "\t\techo \"            subnode(subtag_regex: '\''.*'\'') -> fallbackdns\""
    print
    dns_request_end = 1
    next
  }
  dns_request_end && $0 == "\t\techo \"        }\"" {
    print
    print "\t\techo \"        response {\""
    print "\t\techo \"            qtype(aaaa) -> reject\""
    print "\t\techo \"            fallback: accept\""
    print "\t\techo \"        }\""
    dns_request_end = 0
    next
  }
  {
    print
  }
' "${generator}" >"${generator}.patched"
mv "${generator}.patched" "${generator}"

chmod 0755 "${uci_defaults}" "${generator}"

grep -Fq "dae.config.bootstrap_resolver='223.5.5.5:53'" "${uci_defaults}"
grep -Fq "dae.config.fallback_resolver='223.5.5.5:53'" "${uci_defaults}"
grep -Fq "dae.dns.cn_upstream='udp://223.5.5.5:53'" "${uci_defaults}"
grep -Fq "dae.dns.fallback_upstream='udp://223.5.5.5:53'" "${uci_defaults}"
grep -Fq 'bootstrap_resolver: ${bootstrap_resolver}' "${generator}"
grep -Fq 'fallback_resolver: ${fallback_resolver}' "${generator}"
grep -Fq "sub(tag_regex: '.*') -> fallbackdns" "${generator}"
grep -Fq "node(name_regex: '.*') -> fallbackdns" "${generator}"
grep -Fq "subnode(subtag_regex: '.*') -> fallbackdns" "${generator}"
grep -Fq 'qtype(aaaa) -> reject' "${generator}"
if grep -Eq 'dns\.google|8\.8\.8\.8|2606:4700:4700::1111|2001:4860:4860::8888' \
  "${uci_defaults}" "${generator}"; then
  echo "Google or IPv6 DNS defaults remain in luci-app-daede." >&2
  exit 1
fi
