#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_ssh_hardening_test() {
  local real_ssh_keygen actual_uid actual_gid
  setup_test_root
  real_ssh_keygen="$(command -v ssh-keygen)"
  actual_uid="$(id -u)"
  actual_gid="$(id -g)"
  mkdir -p \
    "$TEST_ROOT/fs/etc/ssh/sshd_config.d" \
    "$TEST_ROOT/fs/etc/vps-guard" \
    "$TEST_ROOT/fs/home/alice/.ssh"
  chmod 0700 "$TEST_ROOT/fs/home/alice/.ssh"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '%s\n' \
    '/etc/ssh/sshd_config' \
    '/etc/ssh/sshd_config.d' \
    '/etc/vps-guard/ssh.conf' >"$TEST_ROOT/managed-paths"

  "$real_ssh_keygen" -q -t ed25519 -N '' -f "$TEST_ROOT/alice_fixture"
  "$real_ssh_keygen" -q -t ed25519 -N '' -f "$TEST_ROOT/wrong_fixture"
  printf 'not-a-key\n' >"$TEST_ROOT/invalid.pub"

  write_stub id "
case \"\$*\" in
  '-u') printf '0\\n' ;;
  '-un') printf 'root\\n' ;;
  '-u alice') printf '$actual_uid\\n' ;;
  '-g alice') printf '$actual_gid\\n' ;;
  *) '$real_ssh_keygen' >/dev/null 2>&1 || true; exit 1 ;;
esac
"
  write_stub getent "
if [[ \"\${1:-}\" == passwd && \"\${2:-}\" == alice ]]; then
  printf 'alice:x:$actual_uid:$actual_gid:Alice:/home/alice:/bin/bash\\n'
  exit 0
fi
exit 2
"
  write_stub runuser "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/runuser.log'
if [[ -e '$TEST_ROOT/fail-runuser' && "\$*" == *'id_ed25519.pub'* ]]; then
  exit 91
fi
if [[ -e '$TEST_ROOT/fail-compensation' && "\$*" == *'.authorized_keys.vps-guard'* ]]; then
  exit 92
fi
[[ \"\${1:-}\" == '-u' && \"\${3:-}\" == '--' ]] || exit 2
shift 3
exec \"\$@\"
"
  write_stub sshd "
if [[ \"\${1:-}\" == '-t' ]]; then
  exit 0
fi
if [[ \"\${1:-}\" != '-T' ]]; then
  exit 1
fi
value() {
  local directive=\"\$1\" fallback=\"\$2\" found
  found=\$(grep -Eih \"^[[:space:]]*\${directive}[[:space:]]+\" \
    '$TEST_ROOT/fs/etc/ssh/sshd_config.d/'*.conf 2>/dev/null | head -n 1 | awk '{ print \$2 }')
  printf '%s\\n' \"\${found:-\$fallback}\"
}
printf 'port 22\\n'
printf 'passwordauthentication %s\\n' \"\$(value PasswordAuthentication yes)\"
printf 'kbdinteractiveauthentication %s\\n' \"\$(value KbdInteractiveAuthentication yes)\"
printf 'permitrootlogin %s\\n' \"\$(value PermitRootLogin yes)\"
printf 'permitemptypasswords %s\\n' \"\$(value PermitEmptyPasswords yes)\"
printf 'maxauthtries %s\\n' \"\$(value MaxAuthTries 6)\"
printf 'logingracetime %s\\n' \"\$(value LoginGraceTime 120)\"
printf 'exposeauthinfo %s\\n' \"\$(value ExposeAuthInfo no)\"
printf 'authorizedkeysfile .ssh/authorized_keys\\n'
if [[ -e '$TEST_ROOT/authorized-command' ]]; then
  printf 'authorizedkeyscommand /usr/local/bin/keys\\n'
else
  printf 'authorizedkeyscommand none\\n'
fi
if [[ -e '$TEST_ROOT/authentication-methods-combined' ]]; then
  printf 'authenticationmethods publickey,password\\n'
else
  printf 'authenticationmethods any\\n'
fi
"
  write_stub systemd-run "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemd-run.log'"
  write_stub systemctl "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemctl.log'
if [[ \"\$*\" == 'is-active --quiet ssh.socket' || \"\$*\" == 'is-enabled --quiet ssh.socket' ]]; then
  exit 1
fi
exit 0
"
  write_stub ss "printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd,pid=1,fd=3))\\n'"
  write_stub ssh-keygen "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/ssh-keygen.log'
if [[ \"\${1:-}\" == '-l' || \"\${1:-}\" == '-E' ]]; then
  exec '$real_ssh_keygen' \"\$@\"
fi
if [[ \" \$* \" == *' -y '* ]]; then
  previous=''
  for argument in \"\$@\"; do
    if [[ \"\$previous\" == '-P' && -z \"\$argument\" ]]; then
      # 无口令无法解开测试私钥，代表它确实受口令保护。
      exit 1
    fi
    previous=\"\$argument\"
  done
  sed -n '1p' '$TEST_ROOT/alice_fixture.pub'
  exit 0
fi
[[ -t 0 ]] || exit 90
target=''
while [[ \"\$#\" -gt 0 ]]; do
  if [[ \"\$1\" == '-f' && \"\$#\" -ge 2 ]]; then
    target=\"\$2\"
    break
  fi
  shift
done
[[ -n \"\$target\" ]] || exit 2
mkdir -p \"\$(dirname \"\$target\")\"
printf '%s\\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'bcrypt encrypted test payload' '-----END OPENSSH PRIVATE KEY-----' >\"\$target\"
cp '$TEST_ROOT/alice_fixture.pub' \"\$target.pub\"
chmod 0600 \"\$target\"
chmod 0644 \"\$target.pub\"
"

  TEST_SUDO_USER=alice
  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
  TEST_PROC_ROOT=""
  TEST_PARENT_PID=""
}

file_mode_for_test() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

token_after_label() {
  local label="$1"
  local value="${COMMAND_OUTPUT#*"$label"}"
  printf '%s\n' "${value%%$'\n'*}"
}

set_publickey_auth_evidence() {
  local fingerprint="$1"
  local connection="${2:-198.51.100.10 50001 203.0.113.20 22}"
  local expected_fingerprint public_key
  mkdir -p "$TEST_ROOT/proc/100"
  expected_fingerprint="$(ssh-keygen -lf "$TEST_ROOT/alice_fixture.pub" | awk '{ print $2 }')"
  if [[ "$fingerprint" == "$expected_fingerprint" ]]; then
    public_key="$(<"$TEST_ROOT/alice_fixture.pub")"
  else
    public_key="$(<"$TEST_ROOT/wrong_fixture.pub")"
  fi
  # SSH_USER_AUTH 记录真实公钥正文；被测程序必须自行计算并比对 SHA256 指纹。
  printf 'publickey %s\n' "$public_key" >"$TEST_ROOT/auth-info"
  chmod 0600 "$TEST_ROOT/auth-info"
  printf 'SSH_CONNECTION=%s\0SSH_USER_AUTH=%s\0USER=alice\0' \
    "$connection" "$TEST_ROOT/auth-info" >"$TEST_ROOT/proc/100/environ"
  printf 'Name:\tbash\nPPid:\t1\n' >"$TEST_ROOT/proc/100/status"
  TEST_PROC_ROOT="$TEST_ROOT/proc"
  TEST_PARENT_PID=100
  TEST_SSH_CONNECTION="$connection"
}

import_and_confirm_key() {
  local token fingerprint
  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  token="$(token_after_label 'SSH 密钥等待新会话确认：')"
  [[ -n "$token" ]]
  fingerprint="$(ssh-keygen -lf "$TEST_ROOT/alice_fixture.pub" | awk '{ print $2 }')"
  set_publickey_auth_evidence "$fingerprint"
  run_vps_guard ssh key confirm "$token"
  assert_status 0
  printf '%s\n' "$token"
}

run_vps_guard_in_tty() {
  local input="$1"
  local command status
  shift
  local command_parts=(
    env
    "PATH=$TEST_ROOT/bin:$PATH"
    "VPS_GUARD_FS_ROOT=$TEST_ROOT/fs"
    "VPS_GUARD_DATA_DIR=$TEST_ROOT/data"
    "VPS_GUARD_AUDIT_LOG=$TEST_ROOT/log/audit.log"
    "VPS_GUARD_MANAGED_PATHS_FILE=$TEST_ROOT/managed-paths"
    "VPS_GUARD_SSH_CONNECTION=${TEST_SSH_CONNECTION:-}"
    "VPS_GUARD_PROC_ROOT=${TEST_PROC_ROOT:-}"
    "VPS_GUARD_PARENT_PID=${TEST_PARENT_PID:-}"
    "SUDO_USER=${TEST_SUDO_USER:-}"
    "$PROJECT_ROOT/vps-guard.sh" "$@"
  )
  set +e
  if script --version >/dev/null 2>&1; then
    printf -v command '%q ' "${command_parts[@]}"
    command="stty -echo; $command; result=\$?; stty echo; exit \$result"
    COMMAND_OUTPUT="$(script -qec "$command" /dev/null <<<"$input" 2>&1)"
    status=$?
  else
    printf -v command '%q ' "${command_parts[@]}"
    command="stty -echo; $command; result=\$?; stty echo; exit \$result"
    COMMAND_OUTPUT="$(script -q /dev/null /bin/sh -c "$command" <<<"$input" 2>&1)"
    status=$?
  fi
  # 由 test_helper.sh 的 assert_status 在调用方读取。
  # shellcheck disable=SC2034
  COMMAND_STATUS=$status
  set -e
}

test_inspect_reports_effective_values_and_risks() {
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh inspect --user alice

  assert_status 0
  assert_output_contains "SSH 实际生效配置"
  assert_output_contains "目标用户：alice"
  assert_output_contains "PasswordAuthentication：yes"
  assert_output_contains "KbdInteractiveAuthentication：yes"
  assert_output_contains "PermitRootLogin：yes"
  assert_output_contains "PermitEmptyPasswords：yes"
  assert_output_contains "风险：允许密码登录"
  assert_output_contains "风险：允许 root 登录"
  assert_output_contains "风险：允许空密码"
}

test_client_guide_prefers_ed25519_and_current_port() {
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh key guide --user alice

  assert_status 0
  assert_output_contains "在客户端执行"
  assert_output_contains "ssh-keygen -t ed25519"
  assert_output_contains "ssh-copy-id"
  assert_output_contains "-p 22"
  assert_output_not_contains "PRIVATE KEY"
}

test_key_import_rejects_invalid_input_and_is_idempotent_with_safe_permissions() {
  local token auth_file before fingerprint
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard --dry-run ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  assert_output_contains "dry-run"
  [[ ! -e "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/01-vps-guard-hardening.conf" ]]

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/invalid.pub" --yes
  assert_status 2
  assert_output_contains "公钥无效"
  [[ ! -e "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" ]]

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  assert_output_contains "SSH 密钥等待新会话确认："
  token="$(token_after_label 'SSH 密钥等待新会话确认：')"
  [[ -n "$token" ]]
  auth_file="$TEST_ROOT/fs/home/alice/.ssh/authorized_keys"
  [[ "$(file_mode_for_test "$TEST_ROOT/fs/home/alice/.ssh")" == 700 ]]
  [[ "$(file_mode_for_test "$auth_file")" == 600 ]]
  [[ "$(wc -l <"$auth_file" | tr -d ' ')" == 1 ]]
  before="$(<"$auth_file")"

  fingerprint="$(ssh-keygen -lf "$TEST_ROOT/alice_fixture.pub" | awk '{ print $2 }')"
  set_publickey_auth_evidence "$fingerprint"
  run_vps_guard ssh key confirm "$token"
  assert_status 0

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  assert_output_contains "已经存在"
  [[ "$(<"$auth_file")" == "$before" ]]
  [[ "$(wc -l <"$auth_file" | tr -d ' ')" == 1 ]]
}

test_key_import_rejects_multiline_keys_symlinks_and_hardlinks() {
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  {
    cat "$TEST_ROOT/alice_fixture.pub"
    cat "$TEST_ROOT/wrong_fixture.pub"
  } >"$TEST_ROOT/two-keys.pub"

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/two-keys.pub" --yes
  assert_status 2
  assert_output_contains "只包含一条公钥"

  rm -rf "$TEST_ROOT/fs/home/alice/.ssh"
  mkdir "$TEST_ROOT/redirected-ssh"
  ln -s "$TEST_ROOT/redirected-ssh" "$TEST_ROOT/fs/home/alice/.ssh"
  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 3
  assert_output_contains "符号链接"
  [[ ! -e "$TEST_ROOT/redirected-ssh/authorized_keys" ]]

  rm "$TEST_ROOT/fs/home/alice/.ssh"
  mkdir "$TEST_ROOT/fs/home/alice/.ssh"
  printf '# existing\n' >"$TEST_ROOT/fs/home/alice/.ssh/authorized_keys"
  ln "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" "$TEST_ROOT/linked-authorized-keys"
  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 3
  assert_output_contains "硬链接"
}

test_key_import_rejects_external_authorized_keys_command() {
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  : >"$TEST_ROOT/authorized-command"

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes

  assert_status 3
  assert_output_contains "AuthorizedKeysCommand"
  assert_output_contains "默认拒绝"
  [[ ! -e "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" ]]
}

test_pending_key_import_has_automatic_revert_and_blocks_overlap() {
  local token
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  token="$(token_after_label 'SSH 密钥等待新会话确认：')"
  grep -q -- '--on-active=5m' "$TEST_ROOT/systemd-run.log"
  [[ -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/01-vps-guard-hardening.conf" ]]

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/wrong_fixture.pub" --yes
  assert_status 3
  assert_output_contains "未确认的 SSH 密钥操作"

  run_vps_guard ssh key discard "$token"
  assert_status 0
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/01-vps-guard-hardening.conf" ]]
  [[ ! -s "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" ]]
}

test_schedule_and_compensation_failure_reports_retry_token() {
  local token
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  write_stub systemd-run ": >'$TEST_ROOT/fail-compensation'; exit 1"

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes

  assert_status 1
  assert_output_contains "自动撤销调度和立即补偿均失败"
  assert_output_contains "ssh key discard key-"
  token="${COMMAND_OUTPUT##*ssh key discard }"
  token="${token%%$'\n'*}"
  [[ -r "$TEST_ROOT/data/ssh-enrollments/$token/state" ]]
  grep -q '^status=pending$' "$TEST_ROOT/data/ssh-enrollments/$token/state"
  [[ -s "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" ]]
}

test_server_generation_requires_tty_and_never_exposes_passphrase() {
  local private_file
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh key generate-server --user alice --yes
  assert_status 3
  assert_output_contains "必须在交互式终端"
  [[ ! -e "$TEST_ROOT/ssh-keygen.log" ]]

  run_vps_guard_in_tty $'correct horse battery staple\ncorrect horse battery staple\n' \
    ssh key generate-server --user alice --yes
  assert_status 0
  assert_output_contains "服务器端备用流程"
  assert_output_contains "scp"
  assert_output_contains "确认后将删除服务器私钥"
  # script(1) 会在子进程接管 TTY 前回显 here-string，不能把该测试驱动回显误判为程序泄漏；
  # 下方分别检查 ssh-keygen 参数与审计日志，真实 ssh-keygen 会自行关闭口令回显。
  if grep -Eq '(^| )-N( |$)|correct horse battery staple' "$TEST_ROOT/ssh-keygen.log"; then
    printf '口令不得进入 ssh-keygen 参数或日志\n' >&2
    return 1
  fi
  private_file="$(find "$TEST_ROOT" -type f -name 'id_ed25519' -print -quit)"
  [[ -n "$private_file" ]]
  [[ "$(file_mode_for_test "$private_file")" == 600 ]]
  grep -q 'bcrypt encrypted' "$private_file"
  if [[ -r "$TEST_ROOT/log/audit.log" ]]; then
    if grep -q 'correct horse battery staple' "$TEST_ROOT/log/audit.log"; then
      printf '口令不得写入审计日志\n' >&2
      return 1
    fi
  fi
}

test_server_generation_cleans_private_material_when_delivery_fails() {
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  : >"$TEST_ROOT/fail-runuser"

  run_vps_guard_in_tty $'correct horse battery staple\ncorrect horse battery staple\n' \
    ssh key generate-server --user alice --yes

  assert_status 1
  assert_output_contains "已清理生成材料"
  [[ -z "$(find "$TEST_ROOT" -type f -name id_ed25519 -print -quit)" ]]
  [[ -z "$(find "$TEST_ROOT" -type d -name '.keygen-*' -print -quit)" ]]
}

test_key_confirmation_requires_target_user_new_session_and_matching_auth_info() {
  local token fingerprint wrong_fingerprint
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  token="$(token_after_label 'SSH 密钥等待新会话确认：')"

  run_vps_guard ssh key confirm "$token"
  assert_status 3
  assert_output_contains "不同的新 SSH 会话"

  wrong_fingerprint="SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  set_publickey_auth_evidence "$wrong_fingerprint"
  run_vps_guard ssh key confirm "$token"
  assert_status 3
  assert_output_contains "公钥指纹"

  fingerprint="$(ssh-keygen -lf "$TEST_ROOT/alice_fixture.pub" | awk '{ print $2 }')"
  set_publickey_auth_evidence "$fingerprint"
  TEST_SUDO_USER=root
  run_vps_guard ssh key confirm "$token"
  assert_status 3
  assert_output_contains "目标用户 alice"

  TEST_SUDO_USER=alice
  run_vps_guard ssh key confirm "$token"
  assert_status 0
  assert_output_contains "SSH 密钥已验证"

  run_vps_guard ssh key status "$token"
  assert_status 0
  assert_output_contains "状态：verified"
  assert_output_not_contains "ssh-ed25519"
}

test_discard_removes_pending_key_and_server_private_material() {
  local token
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh key import --user alice --file "$TEST_ROOT/alice_fixture.pub" --yes
  assert_status 0
  token="$(token_after_label 'SSH 密钥等待新会话确认：')"
  run_vps_guard ssh key discard "$token"

  assert_status 0
  assert_output_contains "已放弃"
  [[ ! -s "$TEST_ROOT/fs/home/alice/.ssh/authorized_keys" ]]
  run_vps_guard ssh key status "$token"
  assert_status 0
  assert_output_contains "状态：discarded"
}

test_password_disable_requires_verified_proof_and_dry_run_writes_nothing() {
  local proof before
  setup_ssh_hardening_test
  trap teardown_test_root RETURN

  run_vps_guard ssh harden apply --user alice --password-auth no --yes
  assert_status 3
  assert_output_contains "已验证的密钥 proof"

  proof="$(import_and_confirm_key)"
  before="$(find "$TEST_ROOT/fs/etc/ssh/sshd_config.d" -type f -exec shasum -a 256 {} + 2>/dev/null || true)"
  run_vps_guard --dry-run ssh harden apply --user alice --proof "$proof" \
    --password-auth no --root-login prohibit-password --empty-passwords no \
    --max-auth-tries 3 --login-grace-time 30 --rollback-minutes 5 --yes

  assert_status 0
  assert_output_contains "SSH 加固差异"
  assert_output_contains "PasswordAuthentication：yes -> no"
  assert_output_contains "PermitRootLogin：yes -> prohibit-password"
  assert_output_contains "MaxAuthTries：6 -> 3"
  assert_output_contains "LoginGraceTime：120 -> 30"
  assert_output_contains "dry-run"
  [[ "$(find "$TEST_ROOT/fs/etc/ssh/sshd_config.d" -type f -exec shasum -a 256 {} + 2>/dev/null || true)" == "$before" ]]
}

test_hardening_applies_all_options_then_requires_new_key_session_to_confirm() {
  local proof token fingerprint hardening_file rollback_token
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  proof="$(import_and_confirm_key)"

  run_vps_guard ssh harden apply --user alice --proof "$proof" \
    --password-auth no --root-login prohibit-password --empty-passwords no \
    --max-auth-tries 3 --login-grace-time 30 --rollback-minutes 5 --yes
  assert_status 0
  assert_output_contains "SSH 加固等待新会话确认："
  token="$(token_after_label 'SSH 加固等待新会话确认：')"
  rollback_token="$(token_after_label '自动回滚已启动：')"
  hardening_file="$(grep -Eil '^[[:space:]]*PasswordAuthentication[[:space:]]+no' \
    "$TEST_ROOT/fs/etc/ssh/sshd_config.d/"*.conf | head -n 1)"
  grep -Eqi '^KbdInteractiveAuthentication[[:space:]]+no$' "$hardening_file"
  grep -Eqi '^PermitRootLogin[[:space:]]+prohibit-password$' "$hardening_file"
  grep -Eqi '^PermitEmptyPasswords[[:space:]]+no$' "$hardening_file"
  grep -Eqi '^MaxAuthTries[[:space:]]+3$' "$hardening_file"
  grep -Eqi '^LoginGraceTime[[:space:]]+30$' "$hardening_file"

  run_vps_guard rollback confirm "$rollback_token"
  assert_status 3
  assert_output_contains "只能通过 ssh harden confirm 提交"

  run_vps_guard ssh harden confirm "$token"
  assert_status 3
  assert_output_contains "不同的新 SSH 会话"

  fingerprint="$(ssh-keygen -lf "$TEST_ROOT/alice_fixture.pub" | awk '{ print $2 }')"
  set_publickey_auth_evidence "$fingerprint" "198.51.100.10 50002 203.0.113.20 22"
  run_vps_guard ssh harden confirm "$token"
  assert_status 0
  assert_output_contains "SSH 加固已提交"
  run_vps_guard ssh harden status "$token"
  assert_status 0
  assert_output_contains "状态：committed"
}

test_hardening_timeout_restores_effective_configuration() {
  local proof rollback_token
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  proof="$(import_and_confirm_key)"

  run_vps_guard ssh harden apply --user alice --proof "$proof" \
    --password-auth no --root-login no --empty-passwords no \
    --max-auth-tries 2 --login-grace-time 20 --yes
  assert_status 0
  rollback_token="$(token_after_label '自动回滚已启动：')"

  run_vps_guard rollback run "$rollback_token"
  assert_status 0
  assert_output_contains "自动回滚完成"
  run_vps_guard ssh inspect --user alice
  assert_status 0
  assert_output_contains "PasswordAuthentication：yes"
  assert_output_contains "PermitRootLogin：yes"
  assert_output_contains "MaxAuthTries：6"
  assert_output_contains "LoginGraceTime：120"
}

test_hardening_option_ranges_and_explicit_yes_are_supported() {
  local proof
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  proof="$(import_and_confirm_key)"

  run_vps_guard --dry-run ssh harden apply --user alice --proof "$proof" \
    --password-auth yes --root-login yes --empty-passwords yes \
    --max-auth-tries 10 --login-grace-time 120 --yes
  assert_status 0
  assert_output_contains "PasswordAuthentication：yes"

  run_vps_guard --dry-run ssh harden apply --user alice --proof "$proof" \
    --password-auth keep --root-login keep --empty-passwords keep \
    --max-auth-tries 0 --login-grace-time 9 --yes
  assert_status 2
  assert_output_contains "MaxAuthTries"
  assert_output_contains "1-10"
}

test_password_disable_rejects_combined_authentication_methods() {
  local proof
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  proof="$(import_and_confirm_key)"
  : >"$TEST_ROOT/authentication-methods-combined"

  run_vps_guard --dry-run ssh harden apply --user alice --proof "$proof" --password-auth no --yes

  assert_status 3
  assert_output_contains "AuthenticationMethods"
  assert_output_contains "组合认证"
}

test_global_configuration_transaction_lock_rejects_overlap() {
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  mkdir -p "$TEST_ROOT/data/.config-transaction.owner.test-hardening"
  printf '%s\n' "$$" >"$TEST_ROOT/data/.config-transaction.owner.test-hardening/pid"
  printf '%s\n' '.config-transaction.owner.test-hardening' >"$TEST_ROOT/data/config-transaction.lock"

  run_vps_guard --dry-run ssh harden apply --user alice --password-auth yes --yes

  assert_status 3
  assert_output_contains "另一个配置事务"
}

test_real_configuration_lock_owner_cannot_be_reaped_as_stale() {
  local first_pid first_status=0
  setup_ssh_hardening_test
  trap teardown_test_root RETURN
  mv "$TEST_ROOT/bin/sshd" "$TEST_ROOT/bin/sshd-base"
  : >"$TEST_ROOT/hold-first-sshd"
  write_stub sshd "
if [[ -e '$TEST_ROOT/hold-first-sshd' && \"\${1:-}\" == '-T' ]]; then
  rm -f '$TEST_ROOT/hold-first-sshd'
  : >'$TEST_ROOT/first-lock-held'
  sleep 2
fi
exec '$TEST_ROOT/bin/sshd-base' \"\$@\"
"

  PATH="$TEST_ROOT/bin:$PATH" \
    VPS_GUARD_FS_ROOT="$TEST_ROOT/fs" \
    VPS_GUARD_DATA_DIR="$TEST_ROOT/data" \
    VPS_GUARD_AUDIT_LOG="$TEST_ROOT/log/audit.log" \
    VPS_GUARD_MANAGED_PATHS_FILE="$TEST_ROOT/managed-paths" \
    SUDO_USER=alice \
    "$PROJECT_ROOT/vps-guard.sh" --dry-run ssh harden apply --user alice --password-auth yes --yes \
    >"$TEST_ROOT/first-transaction.out" 2>&1 &
  first_pid=$!
  for _ in {1..50}; do
    [[ ! -e "$TEST_ROOT/first-lock-held" ]] || break
    sleep 0.05
  done
  [[ -e "$TEST_ROOT/first-lock-held" ]]

  run_vps_guard --dry-run ssh harden apply --user alice --password-auth yes --yes
  assert_status 3
  assert_output_contains "另一个配置事务"

  wait "$first_pid" || first_status=$?
  [[ "$first_status" -eq 0 ]]
  grep -q 'dry-run' "$TEST_ROOT/first-transaction.out"
}

test_inspect_reports_effective_values_and_risks
test_client_guide_prefers_ed25519_and_current_port
test_key_import_rejects_invalid_input_and_is_idempotent_with_safe_permissions
test_key_import_rejects_multiline_keys_symlinks_and_hardlinks
test_key_import_rejects_external_authorized_keys_command
test_pending_key_import_has_automatic_revert_and_blocks_overlap
test_schedule_and_compensation_failure_reports_retry_token
test_server_generation_requires_tty_and_never_exposes_passphrase
test_server_generation_cleans_private_material_when_delivery_fails
test_key_confirmation_requires_target_user_new_session_and_matching_auth_info
test_discard_removes_pending_key_and_server_private_material
test_password_disable_requires_verified_proof_and_dry_run_writes_nothing
test_hardening_applies_all_options_then_requires_new_key_session_to_confirm
test_hardening_timeout_restores_effective_configuration
test_hardening_option_ranges_and_explicit_yes_are_supported
test_password_disable_rejects_combined_authentication_methods
test_global_configuration_transaction_lock_rejects_overlap
test_real_configuration_lock_owner_cannot_be_reaped_as_stale

printf 'ssh_hardening_test: ok\n'
