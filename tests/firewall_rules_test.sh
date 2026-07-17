#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/firewall_rules.sh
source "$PROJECT_ROOT/lib/firewall_rules.sh"

assert_equal() {
  local expected="$1" actual="$2"
  if [[ "$expected" != "$actual" ]]; then
    printf '期望：%s\n实际：%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    printf '命令本应失败：%s\n' "$*" >&2
    return 1
  fi
}

test_port_parser_normalizes_lists_ranges_duplicates_and_adjacency() {
  local normalized note
  normalized="$(firewall_rules_normalize_ports '443, 80-82,81,83,080')"
  assert_equal '80-83,443' "$normalized"
  note="$(firewall_rules_port_normalization_note '80-82,81,80')"
  [[ "$note" == *'重复端口或重叠区间'* ]]
  [[ "$note" == *'80-82'* ]]
  assert_equal '' "$(firewall_rules_port_normalization_note '80,81-82')"
}

test_port_parser_rejects_invalid_and_injected_input() {
  assert_fails firewall_rules_normalize_ports ''
  assert_fails firewall_rules_normalize_ports '0,22'
  assert_fails firewall_rules_normalize_ports '65536'
  assert_fails firewall_rules_normalize_ports '100-90'
  assert_fails firewall_rules_normalize_ports '22,,80'
  assert_fails firewall_rules_normalize_ports '22; touch /tmp/pwned'
  assert_fails firewall_rules_normalize_ports '$''(id)'
  assert_fails firewall_rules_normalize_ports '80 81'
  assert_fails firewall_rules_normalize_ports $'22\n80'
}

test_interval_overlap_and_difference_cover_partial_and_complete_removal() {
  firewall_rules_intervals_overlap '20-30,80' '30-40'
  if firewall_rules_intervals_overlap '20-29' '30-40'; then
    printf '相邻但不重叠的区间被误判为重叠\n' >&2
    return 1
  fi
  assert_equal '20-21,24-25,80' "$(firewall_rules_interval_difference '20-25,80' '22-23,90')"
  assert_equal '' "$(firewall_rules_interval_difference '20-25' '1-65535')"
}

test_strict_dimension_validators() {
  firewall_rules_validate_action accept
  firewall_rules_validate_action drop
  firewall_rules_validate_direction both
  firewall_rules_validate_protocol all
  firewall_rules_validate_family dual
  firewall_rules_validate_interface eth0.100
  firewall_rules_validate_interface '*'
  assert_fails firewall_rules_validate_action allow
  assert_fails firewall_rules_validate_direction INPUT
  assert_fails firewall_rules_validate_protocol 'tcp udp'
  assert_fails firewall_rules_validate_family inet
  assert_fails firewall_rules_validate_interface 'eth0" accept'
  assert_fails firewall_rules_validate_interface '1234567890123456'
}

test_ipv4_ipv6_and_source_validation() {
  firewall_rules_validate_source '*'
  firewall_rules_validate_source '203.0.113.4'
  firewall_rules_validate_source '203.0.113.0/24'
  firewall_rules_validate_source '2001:db8::1'
  firewall_rules_validate_source '2001:db8::/64'
  firewall_rules_validate_source '::1/128'
  assert_equal ipv4 "$(firewall_rules_source_family '198.51.100.0/24')"
  assert_equal ipv6 "$(firewall_rules_source_family '2001:db8::/32')"
  assert_fails firewall_rules_validate_source '256.1.1.1'
  assert_fails firewall_rules_validate_source '192.168.001.1'
  assert_fails firewall_rules_validate_source '192.0.2.0/33'
  assert_fails firewall_rules_validate_source '192.0.2.0/024'
  assert_fails firewall_rules_validate_source '192.0.2.0/008'
  assert_fails firewall_rules_validate_source '2001:db8::1/129'
  assert_fails firewall_rules_validate_source '2001::db8::1'
  assert_fails firewall_rules_validate_source '1.2.3.4;drop'
}

test_source_containment_and_overlap_cover_ipv4_and_ipv6() {
  firewall_rules_source_contains '*' '198.51.100.8'
  firewall_rules_source_contains '198.51.100.0/24' '198.51.100.8'
  firewall_rules_source_contains '198.51.100.0/24' '198.51.100.128/25'
  firewall_rules_source_contains '2001:db8::/32' '2001:db8:1::/48'
  firewall_rules_source_contains '2001:db8:abcd::/48' '2001:db8:abcd::1'
  firewall_rules_sources_overlap '198.51.100.0/24' '198.51.100.128/25'
  firewall_rules_sources_overlap '2001:db8::/32' '2001:db8:ffff::/48'
  assert_fails firewall_rules_source_contains '198.51.100.128/25' '198.51.100.0/24'
  assert_fails firewall_rules_source_contains '198.51.100.0/24' '198.51.101.8'
  assert_fails firewall_rules_sources_overlap '198.51.100.0/24' '203.0.113.0/24'
  assert_fails firewall_rules_sources_overlap '2001:db8::/32' '2001:db9::/32'
}

test_atomic_expansion_normalizes_ports_and_constrains_source_family() {
  local expanded expected
  expanded="$(firewall_rules_expand_atomic 'accept|both|tcp|dual|443,80-82,81|*|eth0')"
  expected=$'accept|input|tcp|ipv4|80-82,443|*|eth0\naccept|input|tcp|ipv6|80-82,443|*|eth0\naccept|output|tcp|ipv4|80-82,443|*|eth0\naccept|output|tcp|ipv6|80-82,443|*|eth0'
  assert_equal "$expected" "$expanded"
  assert_equal 'accept|input|udp|ipv6|53|2001:db8::/32|*' \
    "$(firewall_rules_expand_atomic 'accept|input|udp|dual|53|2001:db8::/32|*')"
  assert_fails firewall_rules_expand_atomic 'accept|input|tcp|ipv4|22|2001:db8::1|*'
  assert_fails firewall_rules_expand_atomic 'accept|input|all|ipv4|22|*|*'
  assert_fails firewall_rules_expand_atomic 'accept|input|tcp|ipv4|22|*|eth0|accept'
  assert_fails firewall_rules_expand_atomic 'accept|input|tcp|ipv4|22|*|eth0|'
  assert_equal $'accept|input|tcp|ipv4|80|*|*\naccept|input|udp|ipv4|80|*|*' \
    "$(firewall_rules_expand_atomic 'accept|input|both|ipv4|80|*|*')"
}

test_nft_renderer_handles_input_output_ipv4_ipv6_and_all_protocols() {
  assert_equal 'ip saddr 203.0.113.0/24 iifname "eth0" tcp dport { 22, 80-82 } accept' \
    "$(firewall_rules_render_nft 'accept|input|tcp|ipv4|80-82,22|203.0.113.0/24|eth0')"
  assert_equal 'ip6 saddr 2001:db8::/32 oifname "ens3" udp dport { 53 } drop' \
    "$(firewall_rules_render_nft 'drop|output|udp|ipv6|53|2001:db8::/32|ens3')"
  assert_equal 'meta nfproto ipv4 accept' "$(firewall_rules_render_nft 'accept|output|all|ipv4|*|*|*')"
  assert_fails firewall_rules_render_nft 'accept|both|tcp|ipv4|22|*|*'
  assert_fails firewall_rules_render_nft 'accept|input|tcp|ipv4|22|*|eth0"; drop'
}

tests=(
  test_port_parser_normalizes_lists_ranges_duplicates_and_adjacency
  test_port_parser_rejects_invalid_and_injected_input
  test_interval_overlap_and_difference_cover_partial_and_complete_removal
  test_strict_dimension_validators
  test_ipv4_ipv6_and_source_validation
  test_source_containment_and_overlap_cover_ipv4_and_ipv6
  test_atomic_expansion_normalizes_ports_and_constrains_source_family
  test_nft_renderer_handles_input_output_ipv4_ipv6_and_all_protocols
)

for test_name in "${tests[@]}"; do
  "$test_name"
done

printf 'firewall rules tests passed: %s\n' "${#tests[@]}"
