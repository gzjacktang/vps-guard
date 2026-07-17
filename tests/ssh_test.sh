#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_ssh_test() {
  setup_test_root
  mkdir -p \
    "$TEST_ROOT/fs/etc/ssh/sshd_config.d" \
    "$TEST_ROOT/fs/etc/nftables.d" \
    "$TEST_ROOT/fs/etc/vps-guard"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '#!/usr/sbin/nft -f\ninclude "/etc/nftables.d/vps-guard.nft" # vps-guard\n' >"$TEST_ROOT/fs/etc/nftables.conf"
  printf 'table inet vps_guard { }\n' >"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  printf '%s\n' \
    'enabled=1' \
    'ssh_ports=22' \
    'tcp_ports=80' \
    'udp_ports=53' >"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  printf '%s\n' \
    '/etc/ssh/sshd_config' \
    '/etc/ssh/sshd_config.d' \
    '/etc/vps-guard/ssh.conf' \
    '/etc/nftables.conf' \
    '/etc/nftables.d/vps-guard.nft' \
    '/etc/vps-guard/firewall.conf' \
    '/etc/fail2ban/jail.d/vps-guard.local' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub sshd "
if [[ \"\$1\" == '-t' ]]; then
  exit 0
fi
if [[ \"\$1\" == '-T' ]]; then
  managed='$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf'
  if [[ -r \"\$managed\" ]]; then
    awk 'tolower(\$1) == \"port\" { print \"port \" \$2 }' \"\$managed\"
  else
    printf 'port 22\\npasswordauthentication yes\\n'
  fi
  exit 0
fi
exit 1
"
  write_stub ss "
managed='$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf'
if [[ -r \"\$managed\" ]]; then
  awk 'tolower(\$1) == \"port\" { printf \"LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:((sshd,pid=1,fd=3))\\n\", \$2 }' \"\$managed\"
else
  printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd,pid=1,fd=3))\\n'
fi
"
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  exit 0
fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' || \"\$1 \${2:-}\" == '-c -f' ]]; then
  exit 0
fi
exit 0
"
  write_stub systemd-run "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemd-run.log'"
  write_stub systemctl "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemctl.log'
if [[ \"\$*\" == 'is-active --quiet ssh.socket' || \"\$*\" == 'is-enabled --quiet ssh.socket' ]]; then
  exit 1
fi
exit 0
"
  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
  TEST_PROC_ROOT=""
  TEST_PARENT_PID=""
}

test_ssh_migration_dry_run_shows_two_phase_plan_without_writes() {
  local before
  setup_ssh_test
  trap teardown_test_root RETURN
  before="$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")"

  run_vps_guard --dry-run ssh migrate --port 2222 --rollback-minutes 5 --yes

  assert_status 0
  assert_output_contains "SSH 端口两阶段迁移摘要"
  assert_output_contains "当前端口：22"
  assert_output_contains "迁移期间端口：22,2222"
  assert_output_contains "提交后端口：2222"
  assert_output_contains "只有从新端口 2222 建立的 SSH 会话才能确认"
  assert_output_contains "最坏后果：SSH 连接中断，VPS 可能暂时失联"
  assert_output_contains "dry-run：不会写入 SSH、防火墙或启动自动回滚"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == "$before" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
  [[ ! -d "$TEST_ROOT/data/ssh-migrations" ]]
}

test_ssh_migration_keeps_old_port_until_new_session_commits_once() {
  local token rollback_token
  setup_ssh_test
  trap teardown_test_root RETURN

  run_vps_guard ssh migrate --port 2222 --yes

  assert_status 0
  assert_output_contains "SSH 迁移等待新会话确认："
  assert_output_contains "请保留当前会话"
  token="${COMMAND_OUTPUT#*SSH 迁移等待新会话确认：}"
  token="${token%%$'\n'*}"
  grep -q '^# vps-guard disabled original port: Port 22$' "$TEST_ROOT/fs/etc/ssh/sshd_config"
  [[ "$(tr '\n' ',' <"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf")" == "Port 22,Port 2222," ]]
  grep -q '^ssh_ports=22,2222$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  rollback_token="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/ssh-migrations/$token/state")"
  grep -q '^hook=ssh-firewall$' "$TEST_ROOT/data/rollbacks/$rollback_token/state"
  grep -q '^status=pending$' "$TEST_ROOT/data/ssh-migrations/$token/state"

  run_vps_guard ssh confirm "$token"
  assert_status 3
  assert_output_contains "确认必须来自新端口 2222 的 SSH 会话"
  [[ "$(tr '\n' ',' <"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf")" == "Port 22,Port 2222," ]]

  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"
  run_vps_guard ssh confirm "$token"

  assert_status 0
  assert_output_contains "SSH 端口迁移已提交"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf")" == "Port 2222" ]]
  grep -q '^ssh_ports=2222$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^status=committed$' "$TEST_ROOT/data/ssh-migrations/$token/state"
  grep -q '^status=confirmed$' "$TEST_ROOT/data/rollbacks/$rollback_token/state"

  run_vps_guard ssh confirm "$token"
  assert_status 0
  assert_output_contains "已经提交，无需重复确认"
}

test_ssh_migration_keeps_fail2ban_ports_in_sync() {
  local token config
  setup_ssh_test
  trap teardown_test_root RETURN
  mkdir -p "$TEST_ROOT/fs/etc/fail2ban/jail.d"
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = true\nport = 22\n' >"$config"
  chmod 0600 "$config"
  printf '%s\n' 'rule=accept|input|tcp|ipv4|8443|198.51.100.0/24|eth0' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  write_stub fail2ban-client "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/fail2ban-client.log'; exit 0"

  run_vps_guard ssh migrate --port 2222 --yes

  assert_status 0
  grep -q '^port = 22,2222$' "$config"
  grep -q '^rule=accept|input|tcp|ipv4|8443|198.51.100.0/24|eth0$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  token="${COMMAND_OUTPUT#*SSH 迁移等待新会话确认：}"
  token="${token%%$'\n'*}"

  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"
  run_vps_guard ssh confirm "$token"

  assert_status 0
  grep -q '^port = 2222$' "$config"
  grep -q '^rule=accept|input|tcp|ipv4|8443|198.51.100.0/24|eth0$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ "$(grep -c '^restart fail2ban$' "$TEST_ROOT/systemctl.log")" -eq 2 ]]
}

test_ssh_migration_reloads_ubuntu_socket_activation_generator() {
  setup_ssh_test
  trap teardown_test_root RETURN
  write_stub ss "
managed='$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf'
if [[ -r \"\$managed\" ]]; then
  awk 'tolower(\$1) == \"port\" { printf \"LISTEN 0 4096 *:%s *:* users:((systemd,pid=1,fd=3))\\n\", \$2 }' \"\$managed\"
else
  printf 'LISTEN 0 4096 *:22 *:* users:((systemd,pid=1,fd=3))\\n'
fi
"
  write_stub systemctl "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemctl.log'
if [[ \"\$*\" == 'is-active --quiet ssh.socket' ]]; then
  exit 0
fi
exit 0
"

  run_vps_guard ssh migrate --port 2222 --yes

  assert_status 0
  grep -q '^daemon-reload$' "$TEST_ROOT/systemctl.log"
  grep -q '^restart ssh.socket$' "$TEST_ROOT/systemctl.log"
}

test_ssh_syntax_failure_restores_original_files_and_cancels_timer() {
  local token rollback_token
  setup_ssh_test
  trap teardown_test_root RETURN
  write_stub sshd "
managed='$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf'
if [[ \"\$1\" == '-t' ]]; then
  [[ ! -e \"\$managed\" ]]
  exit \$?
fi
if [[ \"\$1\" == '-T' ]]; then
  printf 'port 22\\n'
  exit 0
fi
exit 1
"

  run_vps_guard ssh migrate --port 2222 --yes

  assert_status 1
  assert_output_contains "阶段：syntax"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == $'Include /etc/ssh/sshd_config.d/*.conf\nPort 22' ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  token="$(basename "$(find "$TEST_ROOT/data/ssh-migrations" -mindepth 1 -maxdepth 1 -type d)")"
  rollback_token="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/ssh-migrations/$token/state")"
  grep -q '^status=failed$' "$TEST_ROOT/data/ssh-migrations/$token/state"
  grep -q '^status=confirmed$' "$TEST_ROOT/data/rollbacks/$rollback_token/state"
}

test_ssh_rollback_schedule_failure_leaves_configuration_untouched() {
  setup_ssh_test
  trap teardown_test_root RETURN
  write_stub systemd-run 'exit 1'

  run_vps_guard ssh migrate --port 2222 --yes

  assert_status 1
  assert_output_contains "无法安排 SSH 自动回滚，未写入配置"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == $'Include /etc/ssh/sshd_config.d/*.conf\nPort 22' ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ ! -d "$TEST_ROOT/data/ssh-migrations" ]]
}

test_ssh_timeout_rollback_restores_sshd_and_firewall_runtime() {
  local token rollback_token
  setup_ssh_test
  trap teardown_test_root RETURN

  run_vps_guard ssh migrate --port 2222 --yes
  assert_status 0
  token="${COMMAND_OUTPUT#*SSH 迁移等待新会话确认：}"
  token="${token%%$'\n'*}"
  rollback_token="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/ssh-migrations/$token/state")"

  run_vps_guard rollback confirm "$rollback_token"
  assert_status 3
  assert_output_contains "只能通过 ssh confirm 提交"

  run_vps_guard rollback run "$rollback_token"

  assert_status 0
  assert_output_contains "自动回滚完成"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == $'Include /etc/ssh/sshd_config.d/*.conf\nPort 22' ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^status=rolled-back$' "$TEST_ROOT/data/rollbacks/$rollback_token/state"
  grep -q '^reload ssh$' "$TEST_ROOT/systemctl.log"
  grep -q -- "-f $TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" "$TEST_ROOT/nft.log"

  run_vps_guard ssh status "$token"
  assert_status 0
  assert_output_contains "自动回滚：$rollback_token (rolled-back)"

  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"
  run_vps_guard ssh confirm "$token"
  assert_status 3
  assert_output_contains "关联自动回滚已不是等待确认状态：rolled-back"
  assert_output_contains "拒绝在回滚已执行或正在执行后重新应用 SSH 迁移"
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
}

test_ssh_confirm_cannot_race_the_timeout_rollback_lock() {
  local token rollback_token managed_before firewall_before
  setup_ssh_test
  trap teardown_test_root RETURN
  run_vps_guard ssh migrate --port 2222 --yes
  assert_status 0
  token="${COMMAND_OUTPUT#*SSH 迁移等待新会话确认：}"
  token="${token%%$'\n'*}"
  rollback_token="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/ssh-migrations/$token/state")"
  mkdir "$TEST_ROOT/data/rollbacks/$rollback_token/lock"
  printf '%s\n' "$$" >"$TEST_ROOT/data/rollbacks/$rollback_token/lock/pid"
  write_stub sleep 'exit 0'
  managed_before="$(<"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf")"
  firewall_before="$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")"
  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"

  run_vps_guard ssh confirm "$token"

  assert_status 1
  assert_output_contains "回滚任务正由另一个进程处理"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf")" == "$managed_before" ]]
  [[ "$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")" == "$firewall_before" ]]
  grep -q '^status=pending$' "$TEST_ROOT/data/ssh-migrations/$token/state"
}

test_ssh_migration_rejects_invalid_duplicate_occupied_or_unprotected_targets() {
  setup_ssh_test
  trap teardown_test_root RETURN

  run_vps_guard ssh migrate --port 0 --yes
  assert_status 2
  assert_output_contains "1-65535"

  run_vps_guard ssh migrate --port 22 --yes
  assert_status 3
  assert_output_contains "已在 sshd 生效配置中"

  write_stub ss 'printf "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n"'
  run_vps_guard ssh migrate --port 2222 --yes
  assert_status 3
  assert_output_contains "端口 2222 已被监听"

  write_stub ss 'printf "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n"'
  rm -f "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  run_vps_guard ssh migrate --port 2222 --yes
  assert_status 3
  assert_output_contains "请先启用 VPS Guard 防火墙"

  teardown_test_root
  setup_ssh_test
  TEST_SSH_CONNECTION=""
  run_vps_guard ssh migrate --port 2222 --yes
  assert_status 3
  assert_output_contains "当前不是可验证的 SSH 会话"

  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_ssh_restore_rejects_path_like_snapshot_identifiers() {
  setup_ssh_test
  trap teardown_test_root RETURN

  run_vps_guard ssh restore .. --yes

  assert_status 2
  assert_output_contains "快照 ID 不合法"
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_ssh_migration_recovers_session_from_sudo_parent_chain() {
  setup_ssh_test
  trap teardown_test_root RETURN
  TEST_SSH_CONNECTION=""
  TEST_PROC_ROOT="$TEST_ROOT/proc"
  TEST_PARENT_PID=100
  mkdir -p "$TEST_PROC_ROOT/100"
  printf 'SUDO_USER=admin\0SSH_CONNECTION=198.51.100.10 50000 203.0.113.20 22\0' \
    >"$TEST_PROC_ROOT/100/environ"
  printf 'Name:\tsudo\nPPid:\t1\n' >"$TEST_PROC_ROOT/100/status"

  run_vps_guard --dry-run ssh migrate --port 2222 --yes

  assert_status 0
  assert_output_contains "当前端口：22"
  assert_output_contains "提交后端口：2222"
}

test_ssh_migration_rolls_back_when_new_listener_does_not_appear() {
  setup_ssh_test
  trap teardown_test_root RETURN
  write_stub ss 'printf "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd,pid=1,fd=3))\n"'

  run_vps_guard ssh migrate --port 2222 --yes

  assert_status 1
  assert_output_contains "sshd 重载后没有监听计划端口：2222"
  assert_output_contains "阶段：listener-check"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == $'Include /etc/ssh/sshd_config.d/*.conf\nPort 22' ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
}

test_ssh_migration_blocks_overlap_and_reset_to_22_uses_same_safe_flow() {
  setup_ssh_test
  trap teardown_test_root RETURN

  run_vps_guard ssh migrate --port 2222 --yes
  assert_status 0

  run_vps_guard firewall open --ports 443 --protocol tcp --yes
  assert_status 3
  assert_output_contains "仍有等待确认的防火墙自动回滚"

  run_vps_guard ssh migrate --port 3333 --yes
  assert_status 3
  assert_output_contains "仍有等待确认的防火墙自动回滚"

  teardown_test_root
  setup_ssh_test
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n# vps-guard disabled original port: Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf"
  sed -i.bak 's/^ssh_ports=.*/ssh_ports=2222/' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  rm -f "$TEST_ROOT/fs/etc/vps-guard/firewall.conf.bak"
  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 2222"
  write_stub ss 'printf "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n"'

  run_vps_guard --dry-run ssh reset-port-22 --yes

  assert_status 0
  assert_output_contains "警告：重置到 22"
  assert_output_contains "当前端口：2222"
  assert_output_contains "提交后端口：22"
  assert_output_contains "只有从新端口 22 建立的 SSH 会话才能确认"
}

test_ssh_restore_uses_selected_snapshot_and_a_new_rollback_guard() {
  local snapshot rollback_token
  setup_ssh_test
  trap teardown_test_root RETURN

  run_vps_guard backup create --label ssh-known-good
  assert_status 0
  snapshot="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  printf 'Port 9999\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  sed -i.bak 's/^ssh_ports=.*/ssh_ports=9999/' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  rm -f "$TEST_ROOT/fs/etc/vps-guard/firewall.conf.bak"
  printf '#!/usr/sbin/nft -f\n' >"$TEST_ROOT/fs/etc/nftables.conf"

  run_vps_guard ssh restore "$snapshot" --yes

  assert_status 0
  assert_output_contains "SSH 快照恢复摘要"
  assert_output_contains "不会恢复 Fail2ban、日志、密钥或其他第三方配置"
  assert_output_contains "SSH 快照已恢复"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == $'Include /etc/ssh/sshd_config.d/*.conf\nPort 22' ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ "$(grep -Fc 'include "/etc/nftables.d/vps-guard.nft" # vps-guard' "$TEST_ROOT/fs/etc/nftables.conf")" -eq 1 ]]
  rollback_token="${COMMAND_OUTPUT##*rollback confirm }"
  rollback_token="${rollback_token%%。*}"
  grep -q '^hook=ssh-restore$' "$TEST_ROOT/data/rollbacks/$rollback_token/state"

  run_vps_guard rollback confirm "$rollback_token"
  assert_status 0
  assert_output_contains "自动回滚已取消"
}

test_ssh_restore_dry_run_is_read_only_even_when_backup_storage_is_not_writable() {
  local snapshot before
  setup_ssh_test
  trap teardown_test_root RETURN
  run_vps_guard backup create --label ssh-preview
  assert_status 0
  snapshot="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  printf 'Port 9999\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  before="$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")"
  chmod 0500 "$TEST_ROOT/data/backups"

  run_vps_guard --dry-run ssh restore "$snapshot" --yes
  chmod 0700 "$TEST_ROOT/data/backups"

  assert_status 0
  assert_output_contains "dry-run：将从快照 $snapshot 选择性恢复 SSH"
  assert_output_contains "将恢复：/etc/ssh/sshd_config"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == "$before" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
  if find "$TEST_ROOT/data/backups" -mindepth 1 -maxdepth 1 -type d -name '.ssh-restore-*.tmp' | grep -q .; then
    printf 'dry-run 不应创建临时恢复视图\n' >&2
    return 1
  fi
}

test_ssh_restore_treats_a_missing_dropin_directory_as_an_empty_exact_set() {
  local snapshot
  setup_ssh_test
  trap teardown_test_root RETURN
  rm -rf "$TEST_ROOT/fs/etc/ssh/sshd_config.d"
  run_vps_guard backup create --label ssh-no-dropins
  assert_status 0
  snapshot="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  mkdir -p "$TEST_ROOT/fs/etc/ssh/sshd_config.d"
  printf 'Port 9999\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf"

  run_vps_guard --dry-run ssh restore "$snapshot" --yes
  assert_status 0
  assert_output_contains "将删除：/etc/ssh/sshd_config.d/00-vps-guard-port.conf"
  [[ -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]

  run_vps_guard ssh restore "$snapshot" --yes
  assert_status 0
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
}

test_ssh_migration_dry_run_shows_two_phase_plan_without_writes
test_ssh_migration_keeps_old_port_until_new_session_commits_once
test_ssh_migration_keeps_fail2ban_ports_in_sync
test_ssh_migration_reloads_ubuntu_socket_activation_generator
test_ssh_syntax_failure_restores_original_files_and_cancels_timer
test_ssh_rollback_schedule_failure_leaves_configuration_untouched
test_ssh_timeout_rollback_restores_sshd_and_firewall_runtime
test_ssh_confirm_cannot_race_the_timeout_rollback_lock
test_ssh_migration_rejects_invalid_duplicate_occupied_or_unprotected_targets
test_ssh_migration_recovers_session_from_sudo_parent_chain
test_ssh_restore_rejects_path_like_snapshot_identifiers
test_ssh_migration_rolls_back_when_new_listener_does_not_appear
test_ssh_migration_blocks_overlap_and_reset_to_22_uses_same_safe_flow
test_ssh_restore_uses_selected_snapshot_and_a_new_rollback_guard
test_ssh_restore_dry_run_is_read_only_even_when_backup_storage_is_not_writable
test_ssh_restore_treats_a_missing_dropin_directory_as_an_empty_exact_set
