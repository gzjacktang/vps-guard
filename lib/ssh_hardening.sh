#!/usr/bin/env bash

ssh_hardening_config_path() {
  printf '%s/etc/ssh/sshd_config.d/01-vps-guard-hardening.conf\n' "${VPS_GUARD_FS_ROOT:-}"
}

ssh_enrollment_root() {
  printf '%s/ssh-enrollments\n' "$(backup_data_dir)"
}

ssh_hardening_transaction_root() {
  printf '%s/ssh-hardening\n' "$(backup_data_dir)"
}

validate_ssh_operation_token() {
  local token="$1"
  [[ -n "$token" && "$token" != "." && "$token" != ".." && "$token" != *[!A-Za-z0-9._-]* ]]
}

ssh_operation_directory() {
  local root="$1"
  local token="$2"
  validate_ssh_operation_token "$token" || {
    error "SSH 操作令牌不合法"
    return "$EXIT_USAGE"
  }
  printf '%s/%s\n' "$root" "$token"
}

acquire_ssh_operation_lock() {
  local state_dir="$1"
  if ! mkdir "$state_dir/lock" 2>/dev/null; then
    error "该 SSH 操作正由另一个进程处理"
    return "$EXIT_CONFLICT"
  fi
}

release_ssh_operation_lock() {
  rm -rf "$1/lock"
}

ssh_user_record() {
  local requested="$1"
  local record name password uid gid _gecos home _shell _extra
  [[ -n "$requested" && "$requested" != *[!A-Za-z0-9._-]* ]] || {
    error "目标用户名不合法"
    return "$EXIT_USAGE"
  }
  command_exists getent || {
    error "缺少 getent，无法安全解析目标用户"
    return "$EXIT_FAILURE"
  }
  record="$(getent passwd "$requested" 2>/dev/null | head -n 1)"
  [[ -n "$record" ]] || {
    error "目标用户不存在：$requested"
    return "$EXIT_CONFLICT"
  }
  IFS=: read -r name password uid gid _gecos home _shell _extra <<<"$record"
  if [[ "$name" != "$requested" || ! "$uid" =~ ^[0-9]+$ || ! "$gid" =~ ^[0-9]+$ ||
    "$home" != /* || "$home" == "/" || "$home" == *$'\n'* ]]; then
    error "目标用户记录不安全，拒绝修改：$requested"
    return "$EXIT_CONFLICT"
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$gid" "$home"
}

sshd_effective_for_user() {
  local user="$1"
  command_exists sshd || {
    error "缺少 sshd，无法读取生效配置"
    return "$EXIT_FAILURE"
  }
  sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null || {
    error "无法读取用户 $user 的 sshd 实际生效配置"
    return "$EXIT_FAILURE"
  }
}

sshd_effective_value() {
  local effective="$1"
  local key="$2"
  awk -v wanted="$key" 'tolower($1) == wanted { print $2; exit }' <<<"$effective"
}

inspect_ssh_effective_config() {
  local user="$1"
  local record effective password kbd root empty tries grace auth_files auth_command methods expose
  record="$(ssh_user_record "$user")" || return $?
  effective="$(sshd_effective_for_user "$user")" || return $?
  password="$(sshd_effective_value "$effective" passwordauthentication)"
  kbd="$(sshd_effective_value "$effective" kbdinteractiveauthentication)"
  root="$(sshd_effective_value "$effective" permitrootlogin)"
  empty="$(sshd_effective_value "$effective" permitemptypasswords)"
  tries="$(sshd_effective_value "$effective" maxauthtries)"
  grace="$(sshd_effective_value "$effective" logingracetime)"
  auth_files="$(sshd_effective_value "$effective" authorizedkeysfile)"
  auth_command="$(sshd_effective_value "$effective" authorizedkeyscommand)"
  methods="$(sshd_effective_value "$effective" authenticationmethods)"
  expose="$(sshd_effective_value "$effective" exposeauthinfo)"

  printf 'SSH 实际生效配置\n目标用户：%s\n' "$user"
  printf 'PasswordAuthentication：%s\n' "${password:-未知}"
  printf 'KbdInteractiveAuthentication：%s\n' "${kbd:-未知}"
  printf 'PermitRootLogin：%s\n' "${root:-未知}"
  printf 'PermitEmptyPasswords：%s\n' "${empty:-未知}"
  printf 'MaxAuthTries：%s\n' "${tries:-未知}"
  printf 'LoginGraceTime：%s\n' "${grace:-未知}"
  printf 'AuthorizedKeysFile：%s\n' "${auth_files:-未知}"
  printf 'AuthorizedKeysCommand：%s\n' "${auth_command:-未知}"
  printf 'AuthenticationMethods：%s\n' "${methods:-未知}"
  printf 'ExposeAuthInfo：%s\n' "${expose:-未知}"
  [[ "$password" != "yes" ]] || printf '风险：允许密码登录。\n'
  [[ "$kbd" != "yes" ]] || printf '风险：允许键盘交互认证，PAM 可能继续接受密码。\n'
  [[ "$root" != "yes" ]] || printf '风险：允许 root 登录。\n'
  [[ "$empty" != "yes" ]] || printf '风险：允许空密码。\n'
  if [[ "$tries" =~ ^[0-9]+$ && "$tries" -gt 6 ]]; then
    printf '风险：认证重试次数较高。\n'
  fi
  if [[ "$grace" == "0" ]]; then
    printf '风险：登录等待时间无限制。\n'
  fi
}

show_client_key_guide() {
  local user="$1"
  local record ports
  record="$(ssh_user_record "$user")" || return $?
  ports="$(effective_sshd_ports)" || return $?
  ports="${ports%%,*}"
  printf '推荐流程：在客户端生成并保管私钥，服务器只接收公钥。\n'
  printf '在客户端执行：\n'
  printf '  ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519_vps_guard\n'
  printf '  ssh-copy-id -i ~/.ssh/id_ed25519_vps_guard.pub -p %s %s@<服务器>\n' "$ports" "$user"
  printf '若要让 VPS Guard 校验、去重并生成验证令牌，请先把 .pub 文件传到服务器，再执行：\n'
  printf '  sudo vps-guard ssh key import --user %s --file <服务器上的公钥文件>\n' "$user"
  printf '私钥不得上传到服务器；导入后请从新终端进行密钥登录验证。\n'
}

authorized_keys_path_for_user() {
  local user="$1"
  local home="$2"
  local effective configured auth_command item
  effective="$(sshd_effective_for_user "$user")" || return $?
  configured="$(sshd_effective_value "$effective" authorizedkeysfile)"
  auth_command="$(sshd_effective_value "$effective" authorizedkeyscommand)"
  if [[ -n "$auth_command" && "$auth_command" != "none" ]]; then
    error "当前启用了 AuthorizedKeysCommand（${auth_command}）；v1 默认拒绝自动写入复杂密钥来源"
    return "$EXIT_CONFLICT"
  fi
  if [[ ! -d "${VPS_GUARD_FS_ROOT:-}$home" || -L "${VPS_GUARD_FS_ROOT:-}$home" ]]; then
    error "目标用户 home 不存在、不是目录或是符号链接：$home"
    return "$EXIT_CONFLICT"
  fi
  for item in $configured; do
    case "$item" in
      .ssh/authorized_keys | %h/.ssh/authorized_keys | "$home/.ssh/authorized_keys")
        printf '%s%s/.ssh/authorized_keys\n' "${VPS_GUARD_FS_ROOT:-}" "$home"
        return 0
        ;;
    esac
  done
  error "v1 只自动管理目标用户 home 内的 .ssh/authorized_keys；当前生效路径为：${configured:-未知}"
  return "$EXIT_CONFLICT"
}

run_as_ssh_user() {
  local user="$1"
  shift
  command_exists runuser || {
    error "缺少 runuser，无法以目标用户权限安全修改密钥文件"
    return "$EXIT_FAILURE"
  }
  runuser -u "$user" -- "$@"
}

path_owner_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

public_key_details() {
  local source="$1"
  local line_count line type blob _comment fingerprint
  [[ -r "$source" && -f "$source" && ! -L "$source" ]] || {
    error "公钥文件不可读或不是普通文件"
    return "$EXIT_USAGE"
  }
  line_count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count+0 }' "$source")"
  [[ "$line_count" -eq 1 ]] || {
    error "公钥无效：文件必须只包含一条公钥"
    return "$EXIT_USAGE"
  }
  line="$(awk 'NF && $1 !~ /^#/ { print; exit }' "$source")"
  read -r type blob _comment <<<"$line"
  case "$type" in
    ssh-ed25519 | sk-ssh-ed25519@openssh.com | ssh-rsa | ecdsa-sha2-nistp256 | \
      ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *)
      error "公钥无效：只接受 OpenSSH 的 Ed25519、FIDO、ECDSA 或 RSA 公钥，且不接受前置 options"
      return "$EXIT_USAGE"
      ;;
  esac
  [[ -n "$blob" && ${#line} -le 8192 ]] || {
    error "公钥无效"
    return "$EXIT_USAGE"
  }
  fingerprint="$(ssh-keygen -E sha256 -lf "$source" 2>/dev/null | awk 'NR == 1 { print $2 }')"
  [[ "$fingerprint" == SHA256:* ]] || {
    error "公钥无效：ssh-keygen 校验失败"
    return "$EXIT_USAGE"
  }
  printf '%s\t%s\t%s\n' "$type" "$blob" "$fingerprint"
}

ensure_auth_proof_enabled() {
  local user="$1"
  local config_path directory candidate backup="" effective
  config_path="$(ssh_hardening_config_path)"
  directory="$(dirname "$config_path")"
  mkdir -p "$directory" || return "$EXIT_FAILURE"
  candidate="$directory/.vps-guard-hardening.$$.tmp"
  if [[ -e "$config_path" ]]; then
    [[ -f "$config_path" && ! -L "$config_path" ]] || {
      error "VPS Guard SSH 加固配置不是安全的普通文件"
      return "$EXIT_CONFLICT"
    }
    backup="$directory/.vps-guard-hardening.$$.backup"
    cp -p "$config_path" "$backup" || return "$EXIT_FAILURE"
    {
      printf 'ExposeAuthInfo yes\nPubkeyAuthentication yes\n'
      awk 'tolower($1) != "exposeauthinfo" && tolower($1) != "pubkeyauthentication" { print }' "$config_path"
    } >"$candidate" || return "$EXIT_FAILURE"
  else
    printf 'ExposeAuthInfo yes\nPubkeyAuthentication yes\n' >"$candidate" || return "$EXIT_FAILURE"
  fi
  chmod 0600 "$candidate" || return "$EXIT_FAILURE"
  mv "$candidate" "$config_path" || return "$EXIT_FAILURE"
  if ! sshd -t || ! effective="$(sshd_effective_for_user "$user")" ||
    [[ "$(sshd_effective_value "$effective" exposeauthinfo)" != "yes" ]] ||
    [[ "$(sshd_effective_value "$effective" pubkeyauthentication)" == "no" ]] ||
    ! reload_sshd_runtime; then
    if [[ -n "$backup" ]]; then
      mv "$backup" "$config_path" || true
    else
      rm -f "$config_path"
    fi
    reload_sshd_runtime >/dev/null 2>&1 || true
    error "无法安全启用 SSH 密钥会话证明，已恢复原配置"
    return "$EXIT_FAILURE"
  fi
  [[ -z "$backup" ]] || rm -f "$backup"
}

write_authorized_key() {
  local user="$1"
  local auth_file="$2"
  local uid="$3"
  local type="$4"
  local blob="$5"
  local fingerprint="$6"
  local ssh_dir existing_fingerprints=""
  ssh_dir="$(dirname "$auth_file")"
  preflight_authorized_keys_target "$auth_file" "$uid" || return $?
  if [[ -f "$auth_file" ]]; then
    existing_fingerprints="$(ssh-keygen -E sha256 -lf "$auth_file" 2>/dev/null | awk '{ print $2 }' || true)"
    if grep -Fqx "$fingerprint" <<<"$existing_fingerprints"; then
      run_as_ssh_user "$user" chmod 0700 "$ssh_dir" || return "$EXIT_FAILURE"
      run_as_ssh_user "$user" chmod 0600 "$auth_file" || return "$EXIT_FAILURE"
      return 10
    fi
  fi
  # shellcheck disable=SC2016 # 脚本正文必须在降权后的 bash 中展开。
  run_as_ssh_user "$user" bash -c '
    set -euo pipefail
    auth_file="$1"; ssh_dir="$2"; key_type="$3"; key_blob="$4"
    if [[ ! -e "$ssh_dir" ]]; then
      mkdir -m 0700 -- "$ssh_dir"
    fi
    [[ -d "$ssh_dir" && ! -L "$ssh_dir" ]]
    chmod 0700 "$ssh_dir"
    temp="$(mktemp "$ssh_dir/.authorized_keys.vps-guard.XXXXXX")"
    trap '\''rm -f -- "$temp"'\'' EXIT
    if [[ -f "$auth_file" && ! -L "$auth_file" ]]; then
      cp -- "$auth_file" "$temp"
      [[ ! -s "$temp" || "$(tail -c 1 "$temp" 2>/dev/null || true)" == "" ]] || printf "\\n" >>"$temp"
    else
      : >"$temp"
    fi
    printf "%s %s vps-guard-managed\\n" "$key_type" "$key_blob" >>"$temp"
    chmod 0600 "$temp"
    mv -f -- "$temp" "$auth_file"
    trap - EXIT
  ' _ "$auth_file" "$ssh_dir" "$type" "$blob" || return "$EXIT_FAILURE"
}

preflight_authorized_keys_target() {
  local auth_file="$1" uid="$2" ssh_dir link_count owner
  ssh_dir="$(dirname "$auth_file")"
  [[ ! -L "$ssh_dir" && ! -L "$auth_file" ]] || {
    error "拒绝写入符号链接形式的 .ssh 或 authorized_keys"
    return "$EXIT_CONFLICT"
  }
  if [[ -e "$auth_file" && ! -f "$auth_file" ]]; then
    error "authorized_keys 不是普通文件"
    return "$EXIT_CONFLICT"
  fi
  if [[ -e "$ssh_dir" ]]; then
    owner="$(path_owner_uid "$ssh_dir")" || owner=""
    [[ "$owner" == "$uid" ]] || {
      error ".ssh 必须由目标用户所有；拒绝以 root 在用户可写目录中修复属主"
      return "$EXIT_CONFLICT"
    }
  fi
  if [[ -f "$auth_file" ]]; then
    owner="$(path_owner_uid "$auth_file")" || owner=""
    [[ "$owner" == "$uid" ]] || {
      error "authorized_keys 必须由目标用户所有；请先从控制台修正属主"
      return "$EXIT_CONFLICT"
    }
    link_count="$(stat -c '%h' "$auth_file" 2>/dev/null || stat -f '%l' "$auth_file" 2>/dev/null || printf 0)"
    if [[ ! "$link_count" =~ ^[0-9]+$ || "$link_count" -ne 1 ]]; then
      error "authorized_keys 存在硬链接或无法确认链接数，拒绝覆盖"
      return "$EXIT_CONFLICT"
    fi
  fi
}

prepare_ssh_enrollment_state() {
  local token="$1" state_dir config_path existed=0 candidate
  state_dir="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")" || return $?
  config_path="$(ssh_hardening_config_path)"
  umask 077
  mkdir -p "$(ssh_enrollment_root)" "$state_dir" || return "$EXIT_FAILURE"
  chmod 0700 "$(ssh_enrollment_root)" "$state_dir" || return "$EXIT_FAILURE"
  if [[ -e "$config_path" ]]; then
    [[ -f "$config_path" && ! -L "$config_path" ]] || {
      error "VPS Guard SSH 加固配置不是安全的普通文件"
      return "$EXIT_CONFLICT"
    }
    cp -p "$config_path" "$state_dir/hardening.conf.before" || return "$EXIT_FAILURE"
    existed=1
  fi
  candidate="$state_dir/.state.$$.tmp"
  if ! printf 'token=%s\nproof_config_existed=%s\nstatus=preparing\n' "$token" "$existed" >"$candidate" ||
    ! chmod 0600 "$candidate" || ! mv "$candidate" "$state_dir/state"; then
    rm -f "$candidate"
    return "$EXIT_FAILURE"
  fi
}

restore_enrollment_proof_config() {
  local state_dir="$1" user="$2" state_file existed config_path candidate
  state_file="$state_dir/state"
  existed="$(read_state_value "$state_file" proof_config_existed | tail -1)"
  config_path="$(ssh_hardening_config_path)"
  case "$existed" in
    1)
      candidate="$(dirname "$config_path")/.vps-guard-hardening.$$.restore"
      cp -p "$state_dir/hardening.conf.before" "$candidate" || return "$EXIT_FAILURE"
      mv "$candidate" "$config_path" || return "$EXIT_FAILURE"
      ;;
    0) rm -f "$config_path" || return "$EXIT_FAILURE" ;;
    *)
      error "SSH 密钥操作的原配置元数据缺失，拒绝猜测恢复"
      return "$EXIT_FAILURE"
      ;;
  esac
  sshd -t && sshd_effective_for_user "$user" >/dev/null && reload_sshd_runtime
}

write_ssh_enrollment_state() {
  local token="$1" user="$2" uid="$3" fingerprint="$4" type="$5" blob="$6"
  local auth_file="$7" source="$8" private_path="$9" imported="${10}" origin="${11}"
  local state_dir existed candidate
  state_dir="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")" || return $?
  existed="$(read_state_value "$state_dir/state" proof_config_existed | tail -1)"
  candidate="$state_dir/.state.$$.tmp"
  if ! printf 'token=%s\nproof_config_existed=%s\nuser=%s\nuid=%s\nfingerprint=%s\nkey_type=%s\nkey_blob=%s\nauthorized_keys=%s\nsource=%s\nprivate_path=%s\nimported=%s\norigin=%s\nstatus=pending\n' \
    "$token" "$existed" "$user" "$uid" "$fingerprint" "$type" "$blob" "$auth_file" "$source" "$private_path" "$imported" "$origin" \
    >"$candidate" || ! chmod 0600 "$candidate" || ! mv "$candidate" "$state_dir/state"; then
    rm -f "$candidate"
    return "$EXIT_FAILURE"
  fi
}

enroll_public_key() {
  with_config_transaction_lock enroll_public_key_unlocked "$@"
}

enroll_public_key_unlocked() {
  local user="$1" source_file="$2" source_kind="$3" token="$4" private_path="${5:-}" confirmed="${6:-0}"
  local cleanup_minutes="${7:-5}"
  local record name uid gid home details type blob fingerprint auth_file origin="" write_status=0 imported=1 enrollment_dir unit
  record="$(ssh_user_record "$user")" || return $?
  IFS=$'\t' read -r name uid gid home <<<"$record"
  details="$(public_key_details "$source_file")" || return $?
  IFS=$'\t' read -r type blob fingerprint <<<"$details"
  auth_file="$(authorized_keys_path_for_user "$user" "$home")" || return $?
  preflight_authorized_keys_target "$auth_file" "$uid" || return $?
  ensure_no_pending_ssh_migration || return $?
  ensure_no_pending_ssh_enrollment || return $?
  if [[ "$confirmed" -ne 1 ]]; then
    printf '将为用户 %s 导入公钥（指纹：%s）。确认？[y/N] ' "$user" "$fingerprint"
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        printf '已取消，未导入公钥。\n'
        return 0
        ;;
    esac
  fi
  prepare_ssh_enrollment_state "$token" || return $?
  enrollment_dir="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")"
  if ! ensure_auth_proof_enabled "$user"; then
    restore_enrollment_proof_config "$enrollment_dir" "$user" >/dev/null 2>&1 || true
    rm -rf "$enrollment_dir"
    return "$EXIT_FAILURE"
  fi
  write_authorized_key "$user" "$auth_file" "$uid" "$type" "$blob" "$fingerprint" || write_status=$?
  if [[ "$write_status" -eq 10 ]]; then
    imported=0
    printf '该公钥已经存在，未重复写入。\n'
  elif [[ "$write_status" -ne 0 ]]; then
    restore_enrollment_proof_config "$enrollment_dir" "$user" >/dev/null 2>&1 || true
    rm -rf "$enrollment_dir"
    return "$write_status"
  fi
  origin="$(detected_ssh_connection)" || origin=""
  if ! write_ssh_enrollment_state "$token" "$user" "$uid" "$fingerprint" "$type" "$blob" \
    "$auth_file" "$source_kind" "$private_path" "$imported" "$origin"; then
    remove_managed_authorized_key "$user" "$auth_file" "$type" "$blob" "$uid" "$imported" >/dev/null 2>&1 || true
    restore_enrollment_proof_config "$enrollment_dir" "$user" >/dev/null 2>&1 || true
    rm -rf "$enrollment_dir"
    return "$EXIT_FAILURE"
  fi
  unit="vps-guard-key-cleanup-$token"
  if ! systemd-run --quiet --unit="$unit" --on-active="${cleanup_minutes}m" --property=Type=oneshot --collect \
    "${VPS_GUARD_COMMAND:-$VPS_GUARD_ROOT/vps-guard.sh}" ssh key discard "$token"; then
    if discard_ssh_key_enrollment "$token" >/dev/null 2>&1; then
      error "无法安排 SSH 密钥操作自动撤销；已立即恢复原配置并删除新增密钥"
    else
      audit_event ssh.key.import failure "token=$token reason=schedule-and-compensation-failed"
      error "自动撤销调度和立即补偿均失败；请保留当前会话并重试：sudo vps-guard ssh key discard $token"
    fi
    return "$EXIT_FAILURE"
  fi
  audit_event ssh.key.import success "token=$token user=$user fingerprint=$fingerprint source=$source_kind duplicate=$((1 - imported))"
  printf 'SSH 密钥等待新会话确认：%s\n' "$token"
  printf '若未确认，将在 %s 分钟后恢复认证证明配置并删除本工具新增的密钥。\n' "$cleanup_minutes"
  printf '请保留当前会话，用该私钥从新终端登录用户 %s，然后执行：sudo vps-guard ssh key confirm %s\n' "$user" "$token"
}

ensure_no_pending_ssh_enrollment() {
  local root state_file status token
  root="$(ssh_enrollment_root)"
  [[ -d "$root" ]] || return 0
  for state_file in "$root"/*/state; do
    [[ -r "$state_file" ]] || continue
    status="$(read_state_value "$state_file" status | tail -1)"
    case "$status" in
      preparing | pending)
        token="$(read_state_value "$state_file" token | tail -1)"
        error "仍有未确认的 SSH 密钥操作：$token"
        error "请从新公钥会话确认、执行 ssh key discard，或等待自动撤销"
        return "$EXIT_CONFLICT"
        ;;
    esac
  done
}

detected_ancestor_environment() {
  local variable="$1"
  local proc_root pid parent entry depth=0 seen="," value=""
  [[ "$variable" =~ ^[A-Z0-9_]+$ ]] || return 1
  value="${!variable:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  proc_root="${VPS_GUARD_PROC_ROOT:-/proc}"
  pid="${VPS_GUARD_PARENT_PID:-$PPID}"
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && "$depth" -lt 16 ]]; do
    [[ "$seen" != *",$pid,"* ]] || break
    seen+="$pid,"
    if [[ -r "$proc_root/$pid/environ" ]]; then
      while IFS= read -r -d '' entry; do
        if [[ "$entry" == "$variable="* ]]; then
          value="${entry#*=}"
          [[ -n "$value" ]] || break
          printf '%s\n' "$value"
          return 0
        fi
      done <"$proc_root/$pid/environ"
    fi
    [[ -r "$proc_root/$pid/status" ]] || break
    parent="$(awk '$1 == "PPid:" { print $2; exit }' "$proc_root/$pid/status")"
    [[ "$parent" =~ ^[0-9]+$ && "$parent" -ne "$pid" ]] || break
    pid="$parent"
    depth=$((depth + 1))
  done
  return 1
}

current_ssh_auth_fingerprints() {
  local auth_path line temp fingerprint found=0
  auth_path="${VPS_GUARD_SSH_USER_AUTH:-}"
  if [[ -z "$auth_path" ]]; then
    auth_path="$(detected_ancestor_environment SSH_USER_AUTH)" || auth_path=""
  fi
  [[ "$auth_path" == /* && "$auth_path" != *$'\n'* && -r "$auth_path" && -f "$auth_path" && ! -L "$auth_path" ]] || {
    error "当前会话没有可验证的 SSH_USER_AUTH；必须使用启用证明后的新 SSH 密钥会话"
    return "$EXIT_CONFLICT"
  }
  temp="$(mktemp "${TMPDIR:-/tmp}/vps-guard-auth-info.XXXXXX")" || return "$EXIT_FAILURE"
  while IFS= read -r line; do
    [[ "$line" == publickey\ * ]] || continue
    printf '%s\n' "${line#publickey }" >"$temp"
    fingerprint="$(ssh-keygen -E sha256 -lf "$temp" 2>/dev/null | awk 'NR == 1 { print $2 }')"
    if [[ "$fingerprint" == SHA256:* ]]; then
      printf '%s\n' "$fingerprint"
      found=1
    fi
  done <"$auth_path"
  rm -f "$temp"
  [[ "$found" -eq 1 ]] || {
    error "当前会话不是可验证的公钥认证会话"
    return "$EXIT_CONFLICT"
  }
}

current_ssh_login_user() {
  local actor="${SUDO_USER:-}"
  if [[ -z "$actor" ]]; then
    actor="$(detected_ancestor_environment USER 2>/dev/null || true)"
    [[ -n "$actor" ]] || actor="$(id -un 2>/dev/null || printf root)"
  fi
  printf '%s\n' "$actor"
}

verify_new_key_session() {
  local expected_user="$1" expected_fingerprint="$2" origin="$3"
  local actor connection fingerprints
  actor="$(current_ssh_login_user)"
  [[ "$actor" == "$expected_user" ]] || {
    error "确认必须来自目标用户 $expected_user 的 SSH 会话；当前用户是 ${actor:-未知}"
    return "$EXIT_CONFLICT"
  }
  connection="$(detected_ssh_connection)" || connection=""
  [[ -n "$connection" && (-z "$origin" || "$connection" != "$origin") ]] || {
    error "必须从不同的新 SSH 会话验证，不能复用开始操作的旧会话"
    return "$EXIT_CONFLICT"
  }
  fingerprints="$(current_ssh_auth_fingerprints)" || return $?
  if [[ -n "$expected_fingerprint" ]] && ! grep -Fqx "$expected_fingerprint" <<<"$fingerprints"; then
    error "当前密钥会话的公钥指纹与待验证密钥不一致"
    return "$EXIT_CONFLICT"
  fi
}

remove_managed_authorized_key() {
  local user="$1" auth_file="$2" type="$3" blob="$4" uid="$5" imported="$6"
  [[ "$imported" == "1" && -f "$auth_file" && ! -L "$auth_file" ]] || return 0
  preflight_authorized_keys_target "$auth_file" "$uid" || return $?
  # shellcheck disable=SC2016 # 脚本正文与 awk 字段必须在降权后的进程中展开。
  run_as_ssh_user "$user" bash -c '
    set -euo pipefail
    auth_file="$1"; key_type="$2"; key_blob="$3"; directory="$(dirname "$auth_file")"
    temp="$(mktemp "$directory/.authorized_keys.vps-guard.XXXXXX")"
    trap '\''rm -f -- "$temp"'\'' EXIT
    awk -v type="$key_type" -v blob="$key_blob" \
      '\''!(($1 == type) && ($2 == blob) && ($3 == "vps-guard-managed")) { print }'\'' \
      "$auth_file" >"$temp"
    chmod 0600 "$temp"
    mv -f -- "$temp" "$auth_file"
    trap - EXIT
  ' _ "$auth_file" "$type" "$blob" || return "$EXIT_FAILURE"
}

confirm_ssh_key_enrollment() {
  local token="$1"
  local state_dir state_file status user uid fingerprint origin private_path unit
  state_dir="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")" || return $?
  state_file="$state_dir/state"
  [[ -r "$state_file" ]] || {
    error "未找到 SSH 密钥操作：$token"
    return "$EXIT_FAILURE"
  }
  status="$(read_state_value "$state_file" status | tail -1)"
  case "$status" in
    verified)
      printf '该 SSH 密钥已经验证。\n'
      return 0
      ;;
    pending) ;;
    *)
      error "SSH 密钥当前状态不能确认：$status"
      return "$EXIT_CONFLICT"
      ;;
  esac
  user="$(read_state_value "$state_file" user | tail -1)"
  uid="$(read_state_value "$state_file" uid | tail -1)"
  fingerprint="$(read_state_value "$state_file" fingerprint | tail -1)"
  origin="$(read_state_value "$state_file" origin | tail -1)"
  verify_new_key_session "$user" "$fingerprint" "$origin" || return $?
  acquire_ssh_operation_lock "$state_dir" || return $?
  status="$(read_state_value "$state_file" status | tail -1)"
  if [[ "$status" != "pending" ]]; then
    release_ssh_operation_lock "$state_dir"
    error "SSH 密钥状态已发生变化：$status"
    return "$EXIT_CONFLICT"
  fi
  private_path="$(read_state_value "$state_file" private_path | tail -1)"
  unit="vps-guard-key-cleanup-$token"
  if [[ -n "$private_path" ]]; then
    if ! run_as_ssh_user "$user" rm -f -- "$private_path" "$private_path.pub"; then
      release_ssh_operation_lock "$state_dir"
      return "$EXIT_FAILURE"
    fi
    run_as_ssh_user "$user" rmdir -- "$(dirname "$private_path")" 2>/dev/null || true
  fi
  if ! printf 'status=verified\nverified=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
    release_ssh_operation_lock "$state_dir"
    return "$EXIT_FAILURE"
  fi
  systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
  release_ssh_operation_lock "$state_dir"
  audit_event ssh.key.confirm success "token=$token user=$user uid=$uid fingerprint=$fingerprint"
  printf 'SSH 密钥已验证；服务器端备用私钥（若有）已删除。\n'
}

show_ssh_key_status() {
  local token="$1" state_file
  state_file="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")/state" || return $?
  [[ -r "$state_file" ]] || {
    error "未找到 SSH 密钥操作：$token"
    return "$EXIT_FAILURE"
  }
  printf 'SSH 密钥令牌：%s\n目标用户：%s\n公钥指纹：%s\n来源：%s\n状态：%s\n' \
    "$token" "$(read_state_value "$state_file" user | tail -1)" \
    "$(read_state_value "$state_file" fingerprint | tail -1)" \
    "$(read_state_value "$state_file" source | tail -1)" \
    "$(read_state_value "$state_file" status | tail -1)"
}

discard_ssh_key_enrollment() {
  local token="$1" state_dir state_file status user_record user uid gid home auth_file type blob imported private_path result unit
  state_dir="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")" || return $?
  state_file="$state_dir/state"
  [[ -r "$state_file" ]] || {
    error "未找到 SSH 密钥操作：$token"
    return "$EXIT_FAILURE"
  }
  acquire_ssh_operation_lock "$state_dir" || return $?
  status="$(read_state_value "$state_file" status | tail -1)"
  if [[ "$status" == "discarded" ]]; then
    release_ssh_operation_lock "$state_dir"
    printf '该 SSH 密钥操作此前已经放弃。\n'
    return 0
  fi
  [[ "$status" == "pending" ]] || {
    release_ssh_operation_lock "$state_dir"
    error "已验证的密钥不会由 discard 自动删除；请人工复核 authorized_keys"
    return "$EXIT_CONFLICT"
  }
  user="$(read_state_value "$state_file" user | tail -1)"
  user_record="$(ssh_user_record "$user")" || {
    result=$?
    release_ssh_operation_lock "$state_dir"
    return "$result"
  }
  IFS=$'\t' read -r user uid gid home <<<"$user_record"
  auth_file="$(read_state_value "$state_file" authorized_keys | tail -1)"
  type="$(read_state_value "$state_file" key_type | tail -1)"
  blob="$(read_state_value "$state_file" key_blob | tail -1)"
  imported="$(read_state_value "$state_file" imported | tail -1)"
  private_path="$(read_state_value "$state_file" private_path | tail -1)"
  remove_managed_authorized_key "$user" "$auth_file" "$type" "$blob" "$uid" "$imported" || {
    result=$?
    release_ssh_operation_lock "$state_dir"
    return "$result"
  }
  if [[ -n "$private_path" ]]; then
    if ! run_as_ssh_user "$user" rm -f -- "$private_path" "$private_path.pub"; then
      release_ssh_operation_lock "$state_dir"
      return "$EXIT_FAILURE"
    fi
    run_as_ssh_user "$user" rmdir -- "$(dirname "$private_path")" 2>/dev/null || true
  fi
  if ! restore_enrollment_proof_config "$state_dir" "$user"; then
    release_ssh_operation_lock "$state_dir"
    error "无法恢复 SSH 认证证明配置；操作保持待处理状态以便重试"
    return "$EXIT_FAILURE"
  fi
  if ! printf 'status=discarded\ndiscarded=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
    release_ssh_operation_lock "$state_dir"
    return "$EXIT_FAILURE"
  fi
  unit="vps-guard-key-cleanup-$token"
  systemctl stop "$unit.timer" 2>/dev/null || true
  release_ssh_operation_lock "$state_dir"
  audit_event ssh.key.discard success "token=$token user=$user"
  printf 'SSH 密钥操作已放弃；本工具新增的公钥和服务器私钥已删除。\n'
}

generate_server_ssh_key() {
  local user="$1" confirmed="$2"
  local record name uid gid home token auth_file export_dir private_path public_path root_dir root_private result=0 ports
  record="$(ssh_user_record "$user")" || return $?
  IFS=$'\t' read -r name uid gid home <<<"$record"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：服务器端备用流程将由 ssh-keygen 在 TTY 中生成带口令的 Ed25519 私钥，导入公钥并安排 10 分钟自动清理；不会写入任何文件。\n'
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    error "服务器端生成必须在交互式终端执行，以便 ssh-keygen 安全读取加密口令"
    return "$EXIT_CONFLICT"
  fi
  printf '警告：这是服务器端备用流程。私钥会短暂存在于 VPS；优先在客户端生成密钥。\n'
  printf '最坏后果：私钥未及时取回或删除会增加凭据泄露风险。\n'
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认继续，并由 ssh-keygen 交互设置强口令？[y/N] '
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        printf '已取消。\n'
        return 0
        ;;
    esac
  fi
  token="key-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
  auth_file="$(authorized_keys_path_for_user "$user" "$home")" || return $?
  preflight_authorized_keys_target "$auth_file" "$uid" || return $?
  # shellcheck disable=SC2016 # 路径检查与创建必须由降权后的目标用户执行。
  run_as_ssh_user "$user" bash -c '
    set -euo pipefail
    ssh_dir="$1"
    if [[ ! -e "$ssh_dir" ]]; then
      mkdir -m 0700 -- "$ssh_dir"
    fi
    [[ -d "$ssh_dir" && ! -L "$ssh_dir" ]]
    chmod 0700 "$ssh_dir"
  ' _ "$(dirname "$auth_file")" || {
    error "无法以目标用户权限准备 .ssh 目录"
    return "$EXIT_FAILURE"
  }
  export_dir="${VPS_GUARD_FS_ROOT:-}$home/.ssh/vps-guard-export-$token"
  private_path="$export_dir/id_ed25519"
  public_path="$private_path.pub"
  umask 077
  mkdir -p "$(ssh_enrollment_root)" || return "$EXIT_FAILURE"
  chmod 0700 "$(ssh_enrollment_root)" || return "$EXIT_FAILURE"
  root_dir="$(mktemp -d "$(ssh_enrollment_root)/.keygen-$token.XXXXXX")" || return "$EXIT_FAILURE"
  root_private="$root_dir/id_ed25519"
  # 不使用 -N：让 ssh-keygen 直接从 TTY 读取两次口令，口令不会进入脚本变量、参数或审计日志。
  if ! ssh-keygen -q -t ed25519 -a 100 -C "vps-guard-$token" -f "$root_private"; then
    rm -rf "$root_dir"
    error "ssh-keygen 生成失败"
    return "$EXIT_FAILURE"
  fi
  if ssh-keygen -y -P '' -f "$root_private" >/dev/null 2>&1; then
    rm -rf "$root_dir"
    error "检测到私钥未加密，已立即删除；请重新执行并设置非空口令"
    return "$EXIT_CONFLICT"
  fi
  # shellcheck disable=SC2016 # $1 由降权后的 bash 读取。
  if ! run_as_ssh_user "$user" mkdir -m 0700 -- "$export_dir" ||
    ! run_as_ssh_user "$user" bash -c 'umask 077; cat >"$1"; chmod 0600 "$1"' _ "$private_path" <"$root_private" ||
    ! run_as_ssh_user "$user" bash -c 'umask 022; cat >"$1"; chmod 0644 "$1"' _ "$public_path" <"$root_private.pub"; then
    run_as_ssh_user "$user" rm -rf -- "$export_dir" >/dev/null 2>&1 || true
    rm -rf "$root_dir"
    error "无法以目标用户权限安全交付临时密钥，已清理生成材料"
    return "$EXIT_FAILURE"
  fi
  enroll_public_key "$user" "$root_private.pub" server "$token" "$private_path" 1 10 || result=$?
  rm -rf "$root_dir"
  if [[ "$result" -ne 0 ]]; then
    run_as_ssh_user "$user" rm -rf -- "$export_dir" >/dev/null 2>&1 || true
    return "$result"
  fi
  ports="$(effective_sshd_ports)" || ports="22"
  ports="${ports%%,*}"
  printf '服务器端备用流程：加密私钥已生成，10 分钟后自动清理。\n'
  printf '请立即在客户端执行：scp -P %s %s@<服务器>:%s ./id_ed25519\n' "$ports" "$user" "$home/.ssh/vps-guard-export-$token/id_ed25519"
  printf '确认后将删除服务器私钥；切勿在终端显示或复制私钥正文。\n'
}

validate_hardening_options() {
  local password="$1" root="$2" empty="$3" tries="$4" grace="$5" invalid=0
  case "$password" in keep | yes | no) ;; *)
    error "PasswordAuthentication 只允许 keep、yes 或 no"
    invalid=1
    ;;
  esac
  case "$root" in keep | yes | prohibit-password | no) ;; *)
    error "PermitRootLogin 只允许 keep、yes、prohibit-password 或 no"
    invalid=1
    ;;
  esac
  case "$empty" in keep | yes | no) ;; *)
    error "PermitEmptyPasswords 只允许 keep、yes 或 no"
    invalid=1
    ;;
  esac
  if [[ "$tries" != "keep" && (! "$tries" =~ ^[0-9]+$ || "$tries" -lt 1 || "$tries" -gt 10) ]]; then
    error "MaxAuthTries 必须是 keep 或 1-10"
    invalid=1
  fi
  if [[ "$grace" != "keep" && (! "$grace" =~ ^[0-9]+$ || "$grace" -lt 10 || "$grace" -gt 120) ]]; then
    error "LoginGraceTime 必须是 keep 或 10-120 秒"
    invalid=1
  fi
  [[ "$invalid" -eq 0 ]] || return "$EXIT_USAGE"
}

verified_key_proof() {
  local token="$1" expected_user="$2" state_file status user
  [[ -n "$token" ]] || {
    error "禁用密码前必须提供已验证的密钥 proof"
    return "$EXIT_CONFLICT"
  }
  state_file="$(ssh_operation_directory "$(ssh_enrollment_root)" "$token")/state" || return $?
  [[ -r "$state_file" ]] || {
    error "未找到密钥 proof：$token"
    return "$EXIT_CONFLICT"
  }
  status="$(read_state_value "$state_file" status | tail -1)"
  user="$(read_state_value "$state_file" user | tail -1)"
  [[ "$status" == "verified" && "$user" == "$expected_user" ]] || {
    error "禁用密码需要目标用户 $expected_user 的已验证密钥 proof"
    return "$EXIT_CONFLICT"
  }
  read_state_value "$state_file" fingerprint | tail -1
}

render_hardening_config() {
  local destination="$1" password="$2" kbd="$3" root="$4" empty="$5" tries="$6" grace="$7"
  {
    printf '# 由 VPS Guard 管理；修改前请先阅读 docs/SSH-HARDENING.md\n'
    printf 'ExposeAuthInfo yes\n'
    printf 'PubkeyAuthentication yes\n'
    printf 'PasswordAuthentication %s\n' "$password"
    printf 'KbdInteractiveAuthentication %s\n' "$kbd"
    printf 'PermitRootLogin %s\n' "$root"
    printf 'PermitEmptyPasswords %s\n' "$empty"
    printf 'MaxAuthTries %s\n' "$tries"
    printf 'LoginGraceTime %s\n' "$grace"
  } >"$destination"
  chmod 0600 "$destination"
}

show_hardening_diff() {
  local current_password="$1" target_password="$2" current_kbd="$3" target_kbd="$4"
  local current_root="$5" target_root="$6" current_empty="$7" target_empty="$8"
  local current_tries="$9" target_tries="${10}" current_grace="${11}" target_grace="${12}"
  printf 'SSH 加固差异\n'
  printf 'PasswordAuthentication：%s -> %s\n' "$current_password" "$target_password"
  printf 'KbdInteractiveAuthentication：%s -> %s\n' "$current_kbd" "$target_kbd"
  printf 'PermitRootLogin：%s -> %s\n' "$current_root" "$target_root"
  printf 'PermitEmptyPasswords：%s -> %s\n' "$current_empty" "$target_empty"
  printf 'MaxAuthTries：%s -> %s\n' "$current_tries" "$target_tries"
  printf 'LoginGraceTime：%s -> %s\n' "$current_grace" "$target_grace"
  printf '所有登录方式变更都将启动自动回滚，并要求目标用户的新公钥会话确认。\n'
  printf '最坏后果：认证配置错误会阻止新的 SSH 登录；请先确认带外控制台可用。\n'
}

write_hardening_transaction_state() {
  local token="$1" user="$2" proof="$3" fingerprint="$4" snapshot="$5" rollback="$6" origin="$7"
  local state_dir
  state_dir="$(ssh_operation_directory "$(ssh_hardening_transaction_root)" "$token")" || return $?
  umask 077
  mkdir -p "$state_dir" || return "$EXIT_FAILURE"
  chmod 0700 "$(ssh_hardening_transaction_root)" "$state_dir" || return "$EXIT_FAILURE"
  printf 'token=%s\nuser=%s\nproof=%s\nfingerprint=%s\nsnapshot=%s\nrollback=%s\norigin=%s\nstatus=applying\n' \
    "$token" "$user" "$proof" "$fingerprint" "$snapshot" "$rollback" "$origin" >"$state_dir/state" || return "$EXIT_FAILURE"
  chmod 0600 "$state_dir/state" || return "$EXIT_FAILURE"
}

hardening_effective_matches() {
  local user="$1" password="$2" kbd="$3" root="$4" empty="$5" tries="$6" grace="$7"
  local effective key expected actual
  effective="$(sshd_effective_for_user "$user")" || return $?
  while IFS=$'\t' read -r key expected; do
    actual="$(sshd_effective_value "$effective" "$key")"
    if [[ "$actual" != "$expected" ]]; then
      error "sshd 生效值不一致：$key 实际为 ${actual:-未知}，期望 $expected"
      return "$EXIT_FAILURE"
    fi
  done <<EOF
passwordauthentication	$password
kbdinteractiveauthentication	$kbd
permitrootlogin	$root
permitemptypasswords	$empty
maxauthtries	$tries
logingracetime	$grace
exposeauthinfo	yes
EOF
}

abort_ssh_hardening() {
  local token="$1" snapshot="$2" rollback_token="$3" reason="$4"
  local state_file
  state_file="$(ssh_operation_directory "$(ssh_hardening_transaction_root)" "$token")/state"
  restore_snapshot "$snapshot" 1 >/dev/null 2>&1 || true
  run_rollback_hook ssh-hardening >/dev/null 2>&1 || true
  confirm_rollback "$rollback_token" 1 >/dev/null 2>&1 || true
  [[ ! -e "$state_file" ]] || printf 'status=failed\nreason=%s\n' "$reason" >>"$state_file"
  audit_event ssh.harden failure "token=$token snapshot=$snapshot reason=$reason"
  error "SSH 加固失败（阶段：$reason），已尝试恢复原配置"
  return "$EXIT_FAILURE"
}

start_ssh_hardening() {
  with_config_transaction_lock start_ssh_hardening_unlocked "$@"
}

start_ssh_hardening_unlocked() {
  local user="$1" proof="$2" password_option="$3" root_option="$4" empty_option="$5"
  local tries_option="$6" grace_option="$7" rollback_minutes="$8" confirmed="$9"
  local record effective current_password current_kbd current_root current_empty current_tries current_grace current_methods
  local target_password target_kbd target_root target_empty target_tries target_grace fingerprint="" origin=""
  local snapshot_output snapshot rollback_output rollback_token token state_file config_path candidate

  ssh_user_record "$user" >/dev/null || return $?
  validate_hardening_options "$password_option" "$root_option" "$empty_option" "$tries_option" "$grace_option" || return $?
  validate_rollback_minutes "$rollback_minutes" || return $?
  effective="$(sshd_effective_for_user "$user")" || return $?
  current_password="$(sshd_effective_value "$effective" passwordauthentication)"
  current_kbd="$(sshd_effective_value "$effective" kbdinteractiveauthentication)"
  current_root="$(sshd_effective_value "$effective" permitrootlogin)"
  current_empty="$(sshd_effective_value "$effective" permitemptypasswords)"
  current_tries="$(sshd_effective_value "$effective" maxauthtries)"
  current_grace="$(sshd_effective_value "$effective" logingracetime)"
  current_methods="$(sshd_effective_value "$effective" authenticationmethods)"
  target_password="$current_password"
  target_kbd="$current_kbd"
  target_root="$current_root"
  target_empty="$current_empty"
  target_tries="$current_tries"
  target_grace="$current_grace"
  [[ "$password_option" == "keep" ]] || target_password="$password_option"
  [[ "$root_option" == "keep" ]] || target_root="$root_option"
  [[ "$empty_option" == "keep" ]] || target_empty="$empty_option"
  [[ "$tries_option" == "keep" ]] || target_tries="$tries_option"
  [[ "$grace_option" == "keep" ]] || target_grace="$grace_option"
  if [[ "$target_password" == "no" ]]; then
    target_kbd=no
    case "$current_methods" in
      any | publickey) ;;
      *)
        error "当前 AuthenticationMethods 为 ${current_methods:-未知}；禁用密码前只支持 any 或单独 publickey，拒绝可能锁死组合认证的配置"
        return "$EXIT_CONFLICT"
        ;;
    esac
    if [[ "$current_password" != "no" || "$current_kbd" != "no" ]]; then
      fingerprint="$(verified_key_proof "$proof" "$user")" || return $?
    elif [[ -n "$proof" ]]; then
      fingerprint="$(verified_key_proof "$proof" "$user")" || return $?
    fi
  elif [[ -n "$proof" ]]; then
    fingerprint="$(verified_key_proof "$proof" "$user")" || return $?
  fi
  if [[ "$user" == "root" && "$target_root" == "no" ]]; then
    error "不能用 root 自己作为确认用户并同时禁止 root 登录；请指定可 sudo 的非 root 用户"
    return "$EXIT_CONFLICT"
  fi
  ensure_standard_ssh_dropin_include || return $?
  ensure_no_pending_ssh_migration || return $?
  ensure_no_pending_ssh_enrollment || return $?
  sshd -t || {
    error "当前 sshd 配置语法检查失败，未开始加固"
    return "$EXIT_FAILURE"
  }
  show_hardening_diff "$current_password" "$target_password" "$current_kbd" "$target_kbd" \
    "$current_root" "$target_root" "$current_empty" "$target_empty" \
    "$current_tries" "$target_tries" "$current_grace" "$target_grace"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：不会写入 SSH 配置、创建快照或启动自动回滚。\n'
    return 0
  fi
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认应用并启动 %s 分钟自动回滚？[y/N] ' "$rollback_minutes"
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        printf '已取消，未修改 SSH 加固配置。\n'
        return 0
        ;;
    esac
  fi
  snapshot_output="$(create_snapshot ssh-before-hardening)" || return $?
  printf '%s\n' "$snapshot_output"
  snapshot="${snapshot_output#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  rollback_output="$(start_rollback "$snapshot" "$rollback_minutes" ssh-hardening)" || return $?
  printf '%s\n' "$rollback_output"
  rollback_token="${rollback_output#*自动回滚已启动：}"
  rollback_token="${rollback_token%%$'\n'*}"
  token="hard-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
  origin="$(detected_ssh_connection)" || origin=""
  write_hardening_transaction_state "$token" "$user" "$proof" "$fingerprint" "$snapshot" "$rollback_token" "$origin" || {
    confirm_rollback "$rollback_token" 1 >/dev/null 2>&1 || true
    return "$EXIT_FAILURE"
  }
  state_file="$(ssh_operation_directory "$(ssh_hardening_transaction_root)" "$token")/state"
  config_path="$(ssh_hardening_config_path)"
  candidate="$(dirname "$config_path")/.vps-guard-hardening.$$.candidate"
  if ! render_hardening_config "$candidate" "$target_password" "$target_kbd" "$target_root" "$target_empty" "$target_tries" "$target_grace" ||
    ! mv "$candidate" "$config_path" || ! sshd -t ||
    ! hardening_effective_matches "$user" "$target_password" "$target_kbd" "$target_root" "$target_empty" "$target_tries" "$target_grace" ||
    ! reload_sshd_runtime; then
    rm -f "$candidate"
    abort_ssh_hardening "$token" "$snapshot" "$rollback_token" apply
    return $?
  fi
  printf 'status=pending\n' >>"$state_file" || {
    abort_ssh_hardening "$token" "$snapshot" "$rollback_token" state-write
    return $?
  }
  audit_event ssh.harden success "token=$token user=$user rollback=$rollback_token"
  printf 'SSH 加固等待新会话确认：%s\n' "$token"
  printf '请保留当前会话，从目标用户 %s 的新公钥会话执行：sudo vps-guard ssh harden confirm %s\n' "$user" "$token"
}

confirm_ssh_hardening() {
  local token="$1" state_dir state_file status user fingerprint origin rollback_token rollback_dir rollback_file rollback_status result
  state_dir="$(ssh_operation_directory "$(ssh_hardening_transaction_root)" "$token")" || return $?
  state_file="$state_dir/state"
  [[ -r "$state_file" ]] || {
    error "未找到 SSH 加固事务：$token"
    return "$EXIT_FAILURE"
  }
  status="$(read_state_value "$state_file" status | tail -1)"
  case "$status" in
    committed)
      printf '该 SSH 加固已经提交。\n'
      return 0
      ;;
    pending) ;;
    *)
      error "SSH 加固当前状态不能确认：$status"
      return "$EXIT_CONFLICT"
      ;;
  esac
  user="$(read_state_value "$state_file" user | tail -1)"
  fingerprint="$(read_state_value "$state_file" fingerprint | tail -1)"
  origin="$(read_state_value "$state_file" origin | tail -1)"
  rollback_token="$(read_state_value "$state_file" rollback | tail -1)"
  verify_new_key_session "$user" "$fingerprint" "$origin" || return $?
  if ! mkdir "$state_dir/lock" 2>/dev/null; then
    error "该 SSH 加固正由另一个进程提交"
    return "$EXIT_CONFLICT"
  fi
  rollback_dir="$(rollback_state_dir "$rollback_token")" || {
    result=$?
    rm -rf "$state_dir/lock"
    return "$result"
  }
  rollback_file="$rollback_dir/state"
  acquire_rollback_lock "$rollback_dir" || {
    result=$?
    rm -rf "$state_dir/lock"
    return "$result"
  }
  rollback_status="$(read_state_value "$rollback_file" status 2>/dev/null | tail -1)"
  if [[ "$rollback_status" != "pending" ]]; then
    release_rollback_lock "$rollback_dir"
    rm -rf "$state_dir/lock"
    error "关联自动回滚已不是等待确认状态：${rollback_status:-未知}"
    return "$EXIT_CONFLICT"
  fi
  if ! confirm_rollback_under_lock "$rollback_token" 1 >/dev/null; then
    release_rollback_lock "$rollback_dir"
    rm -rf "$state_dir/lock"
    error "无法提交 SSH 加固，配置仍受自动回滚保护"
    return "$EXIT_FAILURE"
  fi
  if ! printf 'status=committed\ncommitted=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
    release_rollback_lock "$rollback_dir"
    rm -rf "$state_dir/lock"
    restore_snapshot "$(read_state_value "$state_file" snapshot | tail -1)" 1 >/dev/null 2>&1 || true
    run_rollback_hook ssh-hardening >/dev/null 2>&1 || true
    audit_event ssh.harden.confirm failure "token=$token user=$user reason=state-write"
    error "自动回滚已取消但无法记录提交；已尝试恢复操作前配置"
    return "$EXIT_FAILURE"
  fi
  release_rollback_lock "$rollback_dir"
  rm -rf "$state_dir/lock"
  audit_event ssh.harden.confirm success "token=$token user=$user"
  printf 'SSH 加固已提交，自动回滚已取消。\n'
}

show_ssh_hardening_status() {
  local token="$1" state_file rollback_token rollback_file rollback_status
  state_file="$(ssh_operation_directory "$(ssh_hardening_transaction_root)" "$token")/state" || return $?
  [[ -r "$state_file" ]] || {
    error "未找到 SSH 加固事务：$token"
    return "$EXIT_FAILURE"
  }
  rollback_token="$(read_state_value "$state_file" rollback | tail -1)"
  rollback_file="$(rollback_state_dir "$rollback_token")/state"
  rollback_status="$(read_state_value "$rollback_file" status 2>/dev/null | tail -1)"
  printf 'SSH 加固令牌：%s\n目标用户：%s\n状态：%s\n自动回滚：%s (%s)\n' \
    "$token" "$(read_state_value "$state_file" user | tail -1)" \
    "$(read_state_value "$state_file" status | tail -1)" "$rollback_token" "${rollback_status:-未知}"
}

ssh_inspect_cli() {
  local user=""
  [[ "${1:-}" == "--user" && "$#" -eq 2 ]] || {
    error "用法：vps-guard ssh inspect --user 用户"
    return "$EXIT_USAGE"
  }
  user="$2"
  inspect_ssh_effective_config "$user"
}

ssh_key_cli() {
  local action="${1:-}" user="" source_file="" confirmed=0 token details record home
  case "$action" in
    guide | import | generate-server)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --user)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            user="$2"
            shift 2
            ;;
          --file)
            [[ "$action" == "import" && "$#" -ge 2 ]] || return "$EXIT_USAGE"
            source_file="$2"
            shift 2
            ;;
          --yes)
            [[ "$action" != "guide" ]] || return "$EXIT_USAGE"
            confirmed=1
            shift
            ;;
          *)
            error "ssh key $action 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      [[ -n "$user" ]] || {
        error "ssh key $action 必须指定 --user"
        return "$EXIT_USAGE"
      }
      case "$action" in
        guide) show_client_key_guide "$user" ;;
        import)
          [[ -n "$source_file" ]] || {
            error "ssh key import 必须指定 --file"
            return "$EXIT_USAGE"
          }
          if [[ "$DRY_RUN" -eq 1 ]]; then
            details="$(public_key_details "$source_file")" || return $?
            record="$(ssh_user_record "$user")" || return $?
            IFS=$'\t' read -r _ _ _ home <<<"$record"
            authorized_keys_path_for_user "$user" "$home" >/dev/null || return $?
            printf 'dry-run：将校验并幂等导入用户 %s 的公钥，修正 .ssh/authorized_keys 权限并启用新会话认证证明；不会写入。\n' "$user"
            return 0
          fi
          token="key-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
          enroll_public_key "$user" "$source_file" client "$token" "" "$confirmed"
          ;;
        generate-server) generate_server_ssh_key "$user" "$confirmed" ;;
      esac
      ;;
    confirm | status | discard)
      [[ "$#" -eq 2 ]] || {
        error "用法：vps-guard ssh key $action <密钥令牌>"
        return "$EXIT_USAGE"
      }
      token="$2"
      case "$action" in
        confirm) confirm_ssh_key_enrollment "$token" ;;
        status) show_ssh_key_status "$token" ;;
        discard) discard_ssh_key_enrollment "$token" ;;
      esac
      ;;
    *)
      error "用法：vps-guard ssh key <guide|import|generate-server|confirm|status|discard>"
      return "$EXIT_USAGE"
      ;;
  esac
}

ssh_hardening_cli() {
  local action="${1:-}" user="" proof="" password=keep root=keep empty=keep tries=keep grace=keep
  local rollback_minutes=5 confirmed=0 token changed=0
  case "$action" in
    apply)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --user | --proof | --password-auth | --root-login | --empty-passwords | --max-auth-tries | --login-grace-time | --rollback-minutes)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            case "$1" in
              --user) user="$2" ;;
              --proof) proof="$2" ;;
              --password-auth)
                password="$2"
                changed=1
                ;;
              --root-login)
                root="$2"
                changed=1
                ;;
              --empty-passwords)
                empty="$2"
                changed=1
                ;;
              --max-auth-tries)
                tries="$2"
                changed=1
                ;;
              --login-grace-time)
                grace="$2"
                changed=1
                ;;
              --rollback-minutes) rollback_minutes="$2" ;;
            esac
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            error "ssh harden apply 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      [[ -n "$user" && "$changed" -eq 1 ]] || {
        error "用法：vps-guard ssh harden apply --user 用户 [--proof 密钥令牌] [加固选项]"
        return "$EXIT_USAGE"
      }
      start_ssh_hardening "$user" "$proof" "$password" "$root" "$empty" "$tries" "$grace" "$rollback_minutes" "$confirmed"
      ;;
    confirm | status)
      [[ "$#" -eq 2 ]] || {
        error "用法：vps-guard ssh harden $action <加固令牌>"
        return "$EXIT_USAGE"
      }
      token="$2"
      if [[ "$action" == "confirm" ]]; then
        confirm_ssh_hardening "$token"
      else
        show_ssh_hardening_status "$token"
      fi
      ;;
    *)
      error "用法：vps-guard ssh harden <apply|confirm|status>"
      return "$EXIT_USAGE"
      ;;
  esac
}
