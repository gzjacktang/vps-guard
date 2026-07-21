#!/usr/bin/env bash

ssh_managed_config_path() {
	printf '%s/etc/ssh/sshd_config.d/00-vps-guard-port.conf\n' "${VPS_GUARD_FS_ROOT:-}"
}

ssh_managed_state_path() {
	printf '%s/etc/vps-guard/ssh.conf\n' "${VPS_GUARD_FS_ROOT:-}"
}

ssh_migration_root() {
	printf '%s/ssh-migrations\n' "$(backup_data_dir)"
}

ssh_migration_directory() {
	local token="$1"
	validate_rollback_token "$token" || {
		error "SSH 迁移令牌不合法"
		return "$EXIT_USAGE"
	}
	printf '%s/%s\n' "$(ssh_migration_root)" "$token"
}

latest_pending_ssh_migration_token() {
	local root state_file status token=""
	root="$(ssh_migration_root)"
	[[ -d "$root" ]] || return 1
	for state_file in "$root"/*/state; do
		[[ -r "$state_file" ]] || continue
		status="$(read_state_value "$state_file" status | tail -1)"
		case "$status" in applying | pending)
			token="$(basename "$(dirname "$state_file")")"
			;;
		esac
	done
	[[ -n "$token" ]] || return 1
	printf '%s\n' "$token"
}

validate_single_ssh_port() {
	local normalized
	normalized="$(normalize_basic_ports "$1")" || return "$EXIT_USAGE"
	[[ -n "$normalized" && "$normalized" != *,* ]] || return "$EXIT_USAGE"
	printf '%s\n' "$normalized"
}

detected_ssh_connection() {
	local connection proc_root pid parent entry depth=0 seen=","
	connection="${VPS_GUARD_SSH_CONNECTION:-${SSH_CONNECTION:-}}"
	if [[ -n "$connection" ]]; then
		printf '%s\n' "$connection"
		return 0
	fi

	# sudo 默认会清理 SSH_CONNECTION。只沿本次命令的父进程链恢复它，
	# 避免扫描其他登录会话，也避免要求用户使用可能扩大环境注入面的 sudo -E。
	proc_root="${VPS_GUARD_PROC_ROOT:-/proc}"
	pid="${VPS_GUARD_PARENT_PID:-$PPID}"
	while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && "$depth" -lt 16 ]]; do
		[[ "$seen" != *",$pid,"* ]] || break
		seen+="$pid,"
		if [[ -r "$proc_root/$pid/environ" ]]; then
			while IFS= read -r -d '' entry; do
				if [[ "$entry" == SSH_CONNECTION=* ]]; then
					connection="${entry#SSH_CONNECTION=}"
					[[ -n "$connection" ]] || break
					printf '%s\n' "$connection"
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

verified_ssh_session_port() {
	local connection client_ip client_port server_ip server_port extra
	connection="${1:-}"
	if [[ -z "$connection" ]]; then
		connection="$(detected_ssh_connection)" || connection=""
	fi
	[[ -n "$connection" ]] || {
		error "当前不是可验证的 SSH 会话；请通过 SSH 登录后执行"
		return "$EXIT_CONFLICT"
	}
	read -r client_ip client_port server_ip server_port extra <<<"$connection"
	if [[ -n "${extra:-}" || -z "${client_ip:-}" || -z "${server_ip:-}" ||
		! "${client_port:-}" =~ ^[0-9]+$ || ! "${server_port:-}" =~ ^[0-9]+$ ||
		"$server_port" -lt 1 || "$server_port" -gt 65535 ]]; then
		error "无法解析当前 SSH_CONNECTION，拒绝猜测验证入口"
		return "$EXIT_CONFLICT"
	fi
	printf '%s\n' "$server_port"
}

ssh_port_is_listening() {
	local wanted="$1"
	local listing endpoint
	command_exists ss || {
		error "缺少 ss 命令，无法检查新端口是否被占用"
		return "$EXIT_CONFLICT"
	}
	if ! listing="$(ss -H -ltn 2>/dev/null)"; then
		error "无法读取 TCP 监听端口，拒绝迁移 SSH"
		return "$EXIT_CONFLICT"
	fi
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		endpoint="$(awk '{ print $4 }' <<<"$line")"
		[[ "$endpoint" == *":$wanted" ]] && return 0
	done <<<"$listing"
	return 1
}

ssh_socket_activation_enabled() {
	systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

sshd_port_is_listening() {
	local wanted="$1"
	local listing endpoint socket_activation=0
	ssh_socket_activation_enabled && socket_activation=1
	if ! listing="$(ss -H -ltnp 2>/dev/null)"; then
		error "无法验证 sshd 监听端口"
		return "$EXIT_CONFLICT"
	fi
	while IFS= read -r line; do
		if [[ "$line" != *sshd* && ! ("$socket_activation" -eq 1 && "$line" == *systemd*) ]]; then
			continue
		fi
		endpoint="$(awk '{ print $4 }' <<<"$line")"
		[[ "$endpoint" == *":$wanted" ]] && return 0
	done <<<"$listing"
	return 1
}

verify_sshd_transition_listeners() {
	local expected_ports="$1"
	local port old_ifs="$IFS"
	IFS=,
	for port in $expected_ports; do
		if ! sshd_port_is_listening "$port"; then
			IFS="$old_ifs"
			error "sshd 重载后没有监听计划端口：$port"
			return "$EXIT_FAILURE"
		fi
	done
	IFS="$old_ifs"
}

verify_sshd_committed_listeners() {
	local new_port="$1"
	local old_ports="$2"
	local port old_ifs="$IFS"
	verify_sshd_transition_listeners "$new_port" || return $?
	IFS=,
	for port in $old_ports; do
		[[ "$port" == "$new_port" ]] && continue
		if sshd_port_is_listening "$port"; then
			IFS="$old_ifs"
			error "sshd 重载后旧端口仍在监听：$port"
			return "$EXIT_FAILURE"
		fi
	done
	IFS="$old_ifs"
}

ensure_no_pending_ssh_migration() {
	local root state_file status rollback_token rollback_file rollback_status token kind
	local roots=("$(ssh_migration_root)" "$(ssh_hardening_transaction_root)")
	for root in "${roots[@]}"; do
		[[ -d "$root" ]] || continue
		kind="SSH 迁移"
		[[ "$root" != "$(ssh_hardening_transaction_root)" ]] || kind="SSH 加固"
		for state_file in "$root"/*/state; do
			[[ -r "$state_file" ]] || continue
			status="$(read_state_value "$state_file" status | tail -1)"
			case "$status" in
			applying | pending)
				rollback_token="$(read_state_value "$state_file" rollback | tail -1)"
				rollback_file="$(rollback_state_dir "$rollback_token")/state"
				rollback_status="$(read_state_value "$rollback_file" status 2>/dev/null | tail -1)"
				case "$rollback_status" in
				pending | running)
					token="$(read_state_value "$state_file" token | tail -1)"
					error "仍有未提交的 $kind：$token"
					error "请从新的已验证 SSH 会话确认，或等待自动回滚"
					return "$EXIT_CONFLICT"
					;;
				esac
				;;
			esac
		done
	done
}

ensure_standard_ssh_dropin_include() {
	local main
	main="${VPS_GUARD_FS_ROOT:-}/etc/ssh/sshd_config"
	[[ -r "$main" ]] || {
		error "无法读取 /etc/ssh/sshd_config"
		return "$EXIT_CONFLICT"
	}
	if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf([[:space:]]|$)' "$main"; then
		error "sshd_config 未启用标准 sshd_config.d/*.conf 包含路径"
		error "拒绝猜测非标准 Include；请先从控制台检查 SSH 配置"
		return "$EXIT_CONFLICT"
	fi
}

disable_unmanaged_ssh_port_directives() {
	local main directory managed file temp mode
	local files=()
	main="${VPS_GUARD_FS_ROOT:-}/etc/ssh/sshd_config"
	directory="${VPS_GUARD_FS_ROOT:-}/etc/ssh/sshd_config.d"
	managed="$(ssh_managed_config_path)"
	[[ -f "$main" ]] && files+=("$main")
	if [[ -d "$directory" ]]; then
		for file in "$directory"/*.conf; do
			[[ -f "$file" && "$file" != "$managed" ]] || continue
			files+=("$file")
		done
	fi

	for file in "${files[@]}"; do
		if ! grep -Eqi '^[[:space:]]*Port[[:space:]]+[0-9]+' "$file"; then
			continue
		fi
		temp="$(dirname "$file")/.vps-guard-ssh.$$.tmp"
		mode="$(file_mode "$file")" || return "$EXIT_FAILURE"
		if ! awk '
      /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/ {
        print "# vps-guard disabled original port: " $0
        next
      }
      { print }
    ' "$file" >"$temp" || ! chmod "$mode" "$temp" || ! mv "$temp" "$file"; then
			rm -f "$temp" || true
			return "$EXIT_FAILURE"
		fi
	done
}

write_managed_ssh_ports() {
	local ports="$1"
	local config_path state_path port
	config_path="$(ssh_managed_config_path)"
	state_path="$(ssh_managed_state_path)"
	mkdir -p "$(dirname "$config_path")" "$(dirname "$state_path")" || return "$EXIT_FAILURE"
	umask 077
	: >"$config_path" || return "$EXIT_FAILURE"
	while IFS= read -r port || [[ -n "$port" ]]; do
		[[ -n "$port" ]] || continue
		printf 'Port %s\n' "$port" >>"$config_path" || return "$EXIT_FAILURE"
	done < <(printf '%s' "$ports" | tr ',' '\n')
	chmod 0600 "$config_path" || return "$EXIT_FAILURE"
	printf 'managed=1\nports=%s\n' "$ports" >"$state_path" || return "$EXIT_FAILURE"
	chmod 0700 "$(dirname "$state_path")" || return "$EXIT_FAILURE"
	chmod 0600 "$state_path" || return "$EXIT_FAILURE"
}

install_ssh_migration_ports() {
	local ports="$1"
	# 先停用原始 Port 指令，再由一个自有 drop-in 同时声明旧、新端口；提交时只需原子缩减这个文件。
	disable_unmanaged_ssh_port_directives && write_managed_ssh_ports "$ports"
}

reload_sshd_runtime() {
	command_exists sshd || {
		error "缺少 sshd，无法校验或重载 SSH"
		return "$EXIT_FAILURE"
	}
	sshd -t || {
		error "sshd 配置语法检查失败"
		return "$EXIT_FAILURE"
	}
	# Ubuntu 24.04+ 默认由 ssh.socket 和生成器读取 Port；只 reload ssh.service 不会更新监听套接字。
	if ssh_socket_activation_enabled; then
		if systemctl daemon-reload && systemctl restart ssh.socket; then
			return 0
		fi
		error "无法重新生成并重启 ssh.socket"
		return "$EXIT_FAILURE"
	fi
	if systemctl reload ssh 2>/dev/null; then
		return 0
	fi
	if systemctl reload sshd 2>/dev/null; then
		return 0
	fi
	error "无法平滑重载 ssh/sshd 服务"
	return "$EXIT_FAILURE"
}

show_ssh_migration_summary() {
	local old_ports="$1"
	local new_port="$2"
	local transition_ports
	transition_ports="$(merge_basic_ports "$old_ports" "$new_port")"
	printf 'SSH 端口两阶段迁移摘要\n'
	printf '当前端口：%s\n' "$old_ports"
	printf '迁移期间端口：%s\n' "$transition_ports"
	printf '提交后端口：%s\n' "$new_port"
	printf '防火墙：迁移期间同步保留旧端口并开放新端口\n'
	printf '只有从新端口 %s 建立的 SSH 会话才能确认；本机监听检查不能替代。\n' "$new_port"
	printf '最坏后果：SSH 连接中断，VPS 可能暂时失联。\n'
	printf '操作前确认云控制台、串行控制台或救援模式可用。\n'
}

write_ssh_migration_state() {
	local token="$1"
	local snapshot="$2"
	local rollback="$3"
	local old_ports="$4"
	local new_port="$5"
	local state_dir
	state_dir="$(ssh_migration_directory "$token")" || return $?
	umask 077
	mkdir -p "$state_dir" || return "$EXIT_FAILURE"
	chmod 0700 "$(ssh_migration_root)" "$state_dir" || return "$EXIT_FAILURE"
	printf 'token=%s\nsnapshot=%s\nrollback=%s\nold_ports=%s\nnew_port=%s\nstatus=applying\n' \
		"$token" "$snapshot" "$rollback" "$old_ports" "$new_port" >"$state_dir/state" || return "$EXIT_FAILURE"
	chmod 0600 "$state_dir/state" || return "$EXIT_FAILURE"
}

abort_ssh_migration() {
	local token="$1"
	local snapshot="$2"
	local rollback_token="$3"
	local reason="$4"
	local state_file
	state_file="$(ssh_migration_directory "$token")/state"
	restore_snapshot "$snapshot" 1 >/dev/null 2>&1 || true
	run_rollback_hook ssh-firewall >/dev/null 2>&1 || true
	confirm_rollback "$rollback_token" 1 >/dev/null 2>&1 || true
	[[ ! -e "$state_file" ]] || printf 'status=failed\nreason=%s\n' "$reason" >>"$state_file"
	audit_event ssh.migrate failure "token=$token snapshot=$snapshot reason=$reason"
	error "SSH 迁移失败（阶段：${reason}），已尝试恢复原 SSH 与防火墙配置"
	return "$EXIT_FAILURE"
}

start_ssh_port_migration() {
	with_config_transaction_lock start_ssh_port_migration_unlocked "$@"
}

start_ssh_port_migration_unlocked() {
	local requested_port="$1"
	local rollback_minutes="$2"
	local confirmed="$3"
	local allow_console="${4:-0}"
	local reset_mode="${5:-0}"
	local new_port old_ports session_connection session_port transition_ports snapshot_output snapshot_id
	local rollback_output rollback_token token state_file effective_after

	validate_rollback_minutes "$rollback_minutes" || return $?
	if ! new_port="$(validate_single_ssh_port "$requested_port")"; then
		error "SSH 端口必须是 1-65535 的单个端口"
		return "$EXIT_USAGE"
	fi
	old_ports="$(effective_sshd_ports)" || return $?
	session_connection="$(detected_ssh_connection)" || session_connection=""
	if [[ -n "$session_connection" ]]; then
		session_port="$(verified_ssh_session_port "$session_connection")" || return $?
		if [[ ",$old_ports," != *",$session_port,"* ]]; then
			error "当前 SSH 会话端口 $session_port 不在 sshd 生效端口 $old_ports 中"
			return "$EXIT_CONFLICT"
		fi
	elif [[ "$allow_console" -ne 1 ]]; then
		verified_ssh_session_port >/dev/null
		return $?
	else
		printf '恢复模式：当前无 SSH_CONNECTION，将依赖控制台与自动回滚保护。\n'
	fi
	if [[ ",$old_ports," == *",$new_port,"* ]]; then
		if [[ "$reset_mode" -eq 1 && "$old_ports" == "$new_port" ]]; then
			printf 'SSH 已仅使用端口 %s，无需重置。\n' "$new_port"
			return 0
		fi
		if [[ "$reset_mode" -ne 1 ]]; then
			error "端口 $new_port 已在 sshd 生效配置中，不能作为新迁移目标"
			return "$EXIT_CONFLICT"
		fi
	fi
	if [[ ",$old_ports," != *",$new_port,"* ]] && ssh_port_is_listening "$new_port"; then
		error "端口 $new_port 已被监听，拒绝覆盖现有服务"
		return "$EXIT_CONFLICT"
	else
		local listen_status=$?
		[[ "$listen_status" -eq 1 ]] || return "$listen_status"
	fi
	ensure_no_pending_ssh_migration || return $?
	ensure_no_pending_ssh_enrollment || return $?
	ensure_standard_ssh_dropin_include || return $?
	sshd -t || {
		error "当前 sshd 配置语法检查失败，未开始迁移"
		return "$EXIT_FAILURE"
	}

	transition_ports="$(merge_basic_ports "$old_ports" "$new_port")"
	show_ssh_migration_summary "$old_ports" "$new_port"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf 'dry-run：不会写入 SSH、防火墙或启动自动回滚。\n'
		return 0
	fi
	if [[ "$confirmed" -ne 1 ]]; then
		printf '确认开始迁移并启动 %s 分钟自动回滚？[y/N] ' "$rollback_minutes"
		IFS= read -r answer
		case "$answer" in
		y | Y | yes | YES) ;;
		*)
			printf '已取消，未修改 SSH 或防火墙。\n'
			return 0
			;;
		esac
	fi

	snapshot_output="$(create_snapshot ssh-before-migration)" || return $?
	printf '%s\n' "$snapshot_output"
	snapshot_id="${snapshot_output#*快照已创建：}"
	snapshot_id="${snapshot_id%%$'\n'*}"
	rollback_output="$(start_rollback "$snapshot_id" "$rollback_minutes" ssh-firewall)" || {
		error "无法安排 SSH 自动回滚，未写入配置"
		return "$EXIT_FAILURE"
	}
	printf '%s\n' "$rollback_output"
	rollback_token="${rollback_output#*自动回滚已启动：}"
	rollback_token="${rollback_token%%$'\n'*}"
	token="ssh-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
	write_ssh_migration_state "$token" "$snapshot_id" "$rollback_token" "$old_ports" "$new_port" || {
		confirm_rollback "$rollback_token" 1 >/dev/null 2>&1 || true
		return "$EXIT_FAILURE"
	}
	state_file="$(ssh_migration_directory "$token")/state"

	if ! install_ssh_migration_ports "$transition_ports" || ! sshd -t; then
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" syntax
		return $?
	fi
	effective_after="$(effective_sshd_ports)" || {
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" effective-config
		return $?
	}
	if [[ "$effective_after" != "$transition_ports" ]]; then
		error "sshd 生效端口与迁移计划不一致：实际 ${effective_after:-无}，期望 $transition_ports"
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" effective-config
		return $?
	fi
	if ! apply_managed_firewall_ssh_ports "$transition_ports" || ! sync_fail2ban_ssh_ports "$transition_ports"; then
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" firewall-apply
		return $?
	fi
	if ! reload_sshd_runtime; then
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" ssh-reload
		return $?
	fi
	if ! verify_sshd_transition_listeners "$transition_ports"; then
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" listener-check
		return $?
	fi

	if ! printf 'status=pending\n' >>"$state_file"; then
		abort_ssh_migration "$token" "$snapshot_id" "$rollback_token" state-write
		return $?
	fi
	audit_event ssh.migrate success "token=$token old=$old_ports new=$new_port rollback=$rollback_token"
	printf 'SSH 迁移等待新会话确认。\n'
	printf '请保留当前会话，从新终端执行：ssh -p %s <用户>@<服务器>\n' "$new_port"
	printf '新会话登录后进入菜单：SSH 管理 → 端口管理 → 从新端口确认\n'
}

confirm_ssh_port_migration() {
	local token="$1"
	local state_dir state_file status new_port old_ports snapshot rollback_token rollback_dir rollback_file rollback_status session_port effective_after result
	state_dir="$(ssh_migration_directory "$token")" || return $?
	state_file="$state_dir/state"
	[[ -r "$state_file" ]] || {
		error "未找到 SSH 迁移：$token"
		return "$EXIT_FAILURE"
	}
	status="$(read_state_value "$state_file" status | tail -1)"
	case "$status" in
	committed)
		printf '该 SSH 迁移已经提交，无需重复确认。\n'
		return 0
		;;
	pending) ;;
	*)
		error "SSH 迁移当前状态不能确认：$status"
		return "$EXIT_CONFLICT"
		;;
	esac
	new_port="$(read_state_value "$state_file" new_port | tail -1)"
	old_ports="$(read_state_value "$state_file" old_ports | tail -1)"
	snapshot="$(read_state_value "$state_file" snapshot | tail -1)"
	rollback_token="$(read_state_value "$state_file" rollback | tail -1)"
	session_port="$(verified_ssh_session_port)" || return $?
	if [[ "$session_port" != "$new_port" ]]; then
		error "确认必须来自新端口 $new_port 的 SSH 会话；当前会话端口是 $session_port"
		return "$EXIT_CONFLICT"
	fi
	rollback_file="$(rollback_state_dir "$rollback_token")/state"
	rollback_status="$(read_state_value "$rollback_file" status 2>/dev/null | tail -1)"
	if [[ "$rollback_status" != "pending" ]]; then
		error "关联自动回滚已不是等待确认状态：${rollback_status:-未知}"
		error "拒绝在回滚已执行或正在执行后重新应用 SSH 迁移"
		return "$EXIT_CONFLICT"
	fi
	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf 'dry-run：已验证当前会话来自新端口 %s；不会关闭旧端口或取消回滚。\n' "$new_port"
		return 0
	fi
	if ! mkdir "$state_dir/lock" 2>/dev/null; then
		error "该 SSH 迁移正由另一个进程提交"
		return "$EXIT_CONFLICT"
	fi
	rollback_dir="$(rollback_state_dir "$rollback_token")" || {
		result=$?
		rm -rf "$state_dir/lock"
		return "$result"
	}
	acquire_rollback_lock "$rollback_dir" || {
		result=$?
		rm -rf "$state_dir/lock"
		return "$result"
	}
	# 与定时任务共用回滚锁，并在锁内复查；超时恢复与新会话提交只能有一个获胜。
	rollback_status="$(read_state_value "$rollback_file" status 2>/dev/null | tail -1)"
	if [[ "$rollback_status" != "pending" ]]; then
		release_rollback_lock "$rollback_dir"
		rm -rf "$state_dir/lock"
		error "关联自动回滚已不是等待确认状态：${rollback_status:-未知}"
		error "拒绝在回滚已执行或正在执行后重新应用 SSH 迁移"
		return "$EXIT_CONFLICT"
	fi

	if ! write_managed_ssh_ports "$new_port" || ! sshd -t; then
		release_rollback_lock "$rollback_dir"
		rm -rf "$state_dir/lock"
		abort_ssh_migration "$token" "$snapshot" "$rollback_token" commit-syntax
		return $?
	fi
	effective_after="$(effective_sshd_ports)" || true
	if [[ "$effective_after" != "$new_port" ]] || ! reload_sshd_runtime ||
		! verify_sshd_committed_listeners "$new_port" "$old_ports" ||
		! apply_managed_firewall_ssh_ports "$new_port" || ! sync_fail2ban_ssh_ports "$new_port" ||
		! confirm_rollback_under_lock "$rollback_token" 1 >/dev/null; then
		release_rollback_lock "$rollback_dir"
		rm -rf "$state_dir/lock"
		abort_ssh_migration "$token" "$snapshot" "$rollback_token" commit-apply
		return $?
	fi
	if ! printf 'status=committed\ncommitted=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
		release_rollback_lock "$rollback_dir"
		rm -rf "$state_dir/lock"
		abort_ssh_migration "$token" "$snapshot" "$rollback_token" commit-state-write
		return $?
	fi
	release_rollback_lock "$rollback_dir"
	rm -rf "$state_dir/lock"
	audit_event ssh.confirm success "token=$token old=$old_ports new=$new_port"
	printf 'SSH 端口迁移已提交：当前端口 %s，旧端口 %s 已从 sshd 与 nftables 防火墙移除。\n' "$new_port" "$old_ports"
}

show_ssh_migration_status() {
	local token="$1"
	local state_file status rollback_token rollback_file rollback_status
	state_file="$(ssh_migration_directory "$token")/state" || return $?
	[[ -r "$state_file" ]] || {
		error "未找到 SSH 迁移：$token"
		return "$EXIT_FAILURE"
	}
	status="$(read_state_value "$state_file" status | tail -1)"
	rollback_token="$(read_state_value "$state_file" rollback | tail -1)"
	rollback_file="$(rollback_state_dir "$rollback_token")/state"
	rollback_status="$(read_state_value "$rollback_file" status 2>/dev/null | tail -1)"
	printf 'SSH 迁移令牌：%s\n状态：%s\n旧端口：%s\n新端口：%s\n自动回滚：%s (%s)\n' \
		"$token" "$status" "$(read_state_value "$state_file" old_ports | tail -1)" \
		"$(read_state_value "$state_file" new_port | tail -1)" "$rollback_token" "${rollback_status:-未知}"
}

show_ssh_restore_dry_run() {
	local snapshot_id="$1"
	local source_dir fs_root path kind mode checksum root_path root_kind found found_listing
	source_dir="$(snapshot_directory "$snapshot_id")" || return $?
	[[ -r "$source_dir/manifest.tsv" ]] || {
		error "快照不存在或清单不可读：$snapshot_id"
		return "$EXIT_FAILURE"
	}
	fs_root="$(backup_fs_root)"
	printf 'dry-run：将从快照 %s 选择性恢复 SSH：\n' "$snapshot_id"
	while IFS=$'\t' read -r path kind mode checksum; do
		case "$path" in
		/etc/ssh/sshd_config | /etc/ssh/sshd_config.d/* | /etc/vps-guard/ssh.conf | \
			/etc/nftables.d/vps-guard.nft | /etc/vps-guard/firewall.conf) ;;
		*) continue ;;
		esac
		if [[ "$kind" == "file" ]]; then
			printf '将恢复：%s\n' "$path"
		elif [[ "$kind" == "missing" && (-e "$fs_root$path" || -L "$fs_root$path") ]]; then
			printf '将删除：%s\n' "$path"
		fi
	done <"$source_dir/manifest.tsv"
	if [[ -r "$source_dir/roots.tsv" ]]; then
		while IFS=$'\t' read -r root_path root_kind; do
			[[ "$root_path" == "/etc/ssh/sshd_config.d" &&
				("$root_kind" == "dir" || "$root_kind" == "missing") &&
				-d "$fs_root$root_path" ]] || continue
			found_listing="$(find "$fs_root$root_path" -type f -print | sort)" || return "$EXIT_FAILURE"
			while IFS= read -r found; do
				[[ -n "$found" ]] || continue
				path="${found#"$fs_root"}"
				manifest_has_file "$source_dir/manifest.tsv" "$path" || printf '将删除：%s\n' "$path"
			done <<<"$found_listing"
		done <"$source_dir/roots.tsv"
	fi
}

create_ssh_restore_view() {
	local snapshot_id="$1"
	local source_dir temp_id temp_dir path kind mode checksum saved_file
	source_dir="$(snapshot_directory "$snapshot_id")" || return $?
	[[ -r "$source_dir/manifest.tsv" ]] || {
		error "快照不存在或清单不可读：$snapshot_id"
		return "$EXIT_FAILURE"
	}
	temp_id=".ssh-restore-$$-$RANDOM.tmp"
	temp_dir="$(backup_data_dir)/backups/$temp_id"
	umask 077
	mkdir -p "$temp_dir/files" || return "$EXIT_FAILURE"
	: >"$temp_dir/manifest.tsv"
	while IFS=$'\t' read -r path kind mode checksum; do
		case "$path" in
		/etc/ssh/sshd_config | /etc/ssh/sshd_config.d/* | /etc/vps-guard/ssh.conf | \
			/etc/nftables.d/vps-guard.nft | /etc/vps-guard/firewall.conf) ;;
		*) continue ;;
		esac
		printf '%s\t%s\t%s\t%s\n' "$path" "$kind" "$mode" "$checksum" >>"$temp_dir/manifest.tsv" || return "$EXIT_FAILURE"
		if [[ "$kind" == "file" ]]; then
			saved_file="$source_dir/files/${path#/}"
			mkdir -p "$temp_dir/files/$(dirname "${path#/}")" || return "$EXIT_FAILURE"
			cp -p "$saved_file" "$temp_dir/files/${path#/}" || return "$EXIT_FAILURE"
		fi
	done <"$source_dir/manifest.tsv"
	if [[ -r "$source_dir/roots.tsv" ]]; then
		# 通用恢复拒绝递归删除目录；把“当时不存在”转换为空的精确目录集合，只删除当前 drop-in。
		awk -F '\t' '$1 == "/etc/ssh/sshd_config.d" && ($2 == "dir" || $2 == "missing") { print $1 "\tdir" }' \
			"$source_dir/roots.tsv" >"$temp_dir/roots.tsv" || return "$EXIT_FAILURE"
	fi
	printf '%s\n' "$temp_id"
}

restore_ssh_from_snapshot() {
	with_config_transaction_lock restore_ssh_from_snapshot_unlocked "$@"
}

restore_ssh_from_snapshot_unlocked() {
	local target_snapshot="$1"
	local rollback_minutes="$2"
	local confirmed="$3"
	local view_id view_dir current_output current_snapshot rollback_output rollback_token
	validate_rollback_minutes "$rollback_minutes" || return $?
	snapshot_directory "$target_snapshot" >/dev/null || return $?
	ensure_no_pending_ssh_migration || return $?
	ensure_no_pending_ssh_enrollment || return $?

	printf 'SSH 快照恢复摘要\n'
	printf '目标快照：%s\n' "$target_snapshot"
	printf '范围：SSH 配置、SSH 配置及受管 nftables 规则\n'
	printf '不会恢复 Fail2ban、日志、密钥或其他第三方配置。\n'
	printf '最坏后果：旧配置可能不再接受当前登录方式，VPS 可能暂时失联。\n'
	printf '操作前确认云控制台、串行控制台或救援模式可用。\n'
	if [[ "$DRY_RUN" -eq 1 ]]; then
		show_ssh_restore_dry_run "$target_snapshot"
		return $?
	fi
	view_id="$(create_ssh_restore_view "$target_snapshot")" || return $?
	view_dir="$(backup_data_dir)/backups/$view_id"
	if [[ "$confirmed" -ne 1 ]]; then
		printf '确认恢复并启动 %s 分钟自动回滚？[y/N] ' "$rollback_minutes"
		IFS= read -r answer
		case "$answer" in
		y | Y | yes | YES) ;;
		*)
			rm -rf "$view_dir"
			printf '已取消，未恢复 SSH。\n'
			return 0
			;;
		esac
	fi

	current_output="$(create_snapshot ssh-before-restore)" || {
		rm -rf "$view_dir"
		return "$EXIT_FAILURE"
	}
	printf '%s\n' "$current_output"
	current_snapshot="${current_output#*快照已创建：}"
	current_snapshot="${current_snapshot%%$'\n'*}"
	rollback_output="$(start_rollback "$current_snapshot" "$rollback_minutes" ssh-restore)" || {
		rm -rf "$view_dir"
		return "$EXIT_FAILURE"
	}
	printf '%s\n' "$rollback_output"
	rollback_token="${rollback_output#*自动回滚已启动：}"
	rollback_token="${rollback_token%%$'\n'*}"
	if ! restore_snapshot "$view_id" 1 || ! reconcile_firewall_include_line || ! run_rollback_hook ssh-restore; then
		rm -rf "$view_dir"
		restore_snapshot "$current_snapshot" 1 >/dev/null 2>&1 || true
		run_rollback_hook ssh-restore >/dev/null 2>&1 || true
		confirm_rollback "$rollback_token" 1 >/dev/null 2>&1 || true
		audit_event ssh.restore failure "snapshot=$target_snapshot rollback=$rollback_token"
		error "SSH 快照恢复失败，已尝试恢复操作前配置"
		return "$EXIT_FAILURE"
	fi
	rm -rf "$view_dir"
	audit_event ssh.restore success "snapshot=$target_snapshot rollback=$rollback_token"
	printf 'SSH 快照已恢复。请从新 SSH 会话验证，确认正常后执行 rollback confirm %s。\n' "$rollback_token"
}

ssh_cli() {
	local action="${1:-}"
	local port="" rollback_minutes=5 confirmed=0 token snapshot
	case "$action" in
	inspect)
		shift
		ssh_inspect_cli "$@"
		;;
	key)
		shift
		ssh_key_cli "$@"
		;;
	harden)
		shift
		ssh_hardening_cli "$@"
		;;
	migrate | reset-port-22)
		shift
		[[ "$action" != "reset-port-22" ]] || port=22
		while [[ "$#" -gt 0 ]]; do
			case "$1" in
			--port)
				[[ "$action" == "migrate" && "$#" -ge 2 ]] || return "$EXIT_USAGE"
				port="$2"
				shift 2
				;;
			--rollback-minutes)
				[[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
				rollback_minutes="$2"
				shift 2
				;;
			--yes)
				confirmed=1
				shift
				;;
			*)
				error "ssh $action 未知参数：$1"
				return "$EXIT_USAGE"
				;;
			esac
		done
		[[ -n "$port" ]] || {
			error "用法：vps-guard ssh migrate --port 端口 [--rollback-minutes 3|5|10] [--yes]"
			return "$EXIT_USAGE"
		}
		if [[ "$action" == "reset-port-22" ]]; then
			printf '警告：重置到 22 会改变当前 SSH 入口，并可能让标准端口暴露给公网扫描。\n'
		fi
		if [[ "$action" == "reset-port-22" ]]; then
			start_ssh_port_migration "$port" "$rollback_minutes" "$confirmed" 1 1
		else
			start_ssh_port_migration "$port" "$rollback_minutes" "$confirmed"
		fi
		;;
	confirm | status)
		token="${2:-}"
		if [[ -z "$token" ]]; then
			token="$(latest_pending_ssh_migration_token 2>/dev/null || true)"
			[[ -n "$token" ]] || {
				error "当前无待确认的 SSH 迁移"
				return "$EXIT_FAILURE"
			}
		fi
		if [[ "$action" == "confirm" ]]; then
			confirm_ssh_port_migration "$token"
		else
			show_ssh_migration_status "$token"
		fi
		;;
	restore)
		shift
		snapshot="${1:-}"
		[[ -n "$snapshot" ]] || {
			error "用法：vps-guard ssh restore <快照ID> [--rollback-minutes 3|5|10] [--yes]"
			return "$EXIT_USAGE"
		}
		shift
		while [[ "$#" -gt 0 ]]; do
			case "$1" in
			--rollback-minutes)
				[[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
				rollback_minutes="$2"
				shift 2
				;;
			--yes)
				confirmed=1
				shift
				;;
			*)
				error "ssh restore 未知参数：$1"
				return "$EXIT_USAGE"
				;;
			esac
		done
		restore_ssh_from_snapshot "$snapshot" "$rollback_minutes" "$confirmed"
		;;
	*)
		error "用法：vps-guard ssh <inspect|key|harden|migrate|confirm|status|reset-port-22|restore>"
		return "$EXIT_USAGE"
		;;
	esac
}
