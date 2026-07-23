#!/usr/bin/env bash

# 快速安全配置只编排 nftables 防火墙和 Fail2ban；SSH 变更始终由 SSH 管理负责。

wizard_detect_listening_ports() {
	local protocol="$1" line netid _state _recv _send local_address _peer _rest port ports="" lines ssh_ports
	command_exists ss || return "$EXIT_FAILURE"
	lines="$(ss -H -lntup 2>/dev/null)" || return "$EXIT_FAILURE"
	ssh_ports="$(effective_sshd_ports 2>/dev/null || true)"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		read -r netid _state _recv _send local_address _peer _rest <<<"$line"
		case "$protocol:$netid" in tcp:tcp* | udp:udp*) ;; *) continue ;; esac
		port="${local_address##*:}"
		port="${port//]/}"
		[[ "$port" =~ ^[0-9]+$ ]] || continue
		case "$local_address" in 127.* | '[::1]:'* | '::1:'*) continue ;; esac
		[[ "$protocol" != tcp || ",$ssh_ports," != *",$port,"* ]] || continue
		ports="$(merge_basic_ports "$ports" "$port")"
	done <<<"$lines"
	printf '%s\n' "$ports"
}

wizard_show_details() {
	printf '快速安全配置方案\n'
	printf '1. 标准防护：nftables 入站基线与 Fail2ban 标准策略\n'
	printf '2. 仅 nftables 防火墙：应用入站基线\n'
	printf '3. 仅 Fail2ban：为当前 SSH 端口应用标准封禁策略\n'
	printf 'SSH 端口、密钥与加固请在 SSH 管理中操作；自动回滚也仅在 SSH 管理中提供。\n'
}

wizard_apply() {
	with_config_transaction_lock wizard_apply_unlocked "$@"
}

wizard_apply_unlocked() {
	local plan="$1" tcp_input="$2" udp_input="$3" confirmed="$4"
	local tcp_ports udp_ports existing_tcp="" existing_udp="" advanced_rules="" firewall_candidate="" fail2ban_candidate="" fail2ban_stage=""
	local values findtime maxretry bantime increment maxtime ignoreip current_ip="" snapshot_output snapshot answer result=0 failure_stage=""
	trap 'rm -f "$firewall_candidate" "$fail2ban_candidate" "$fail2ban_stage"; trap - RETURN' RETURN
	case "$plan" in standard | firewall | fail2ban) ;; *)
		error "方案只允许 standard、firewall 或 fail2ban"
		return "$EXIT_USAGE"
		;;
	esac
	tcp_ports="$(normalize_basic_ports "$tcp_input")" || {
		error "TCP 业务端口格式无效"
		return "$EXIT_USAGE"
	}
	udp_ports="$(normalize_basic_ports "$udp_input")" || {
		error "UDP 业务端口格式无效"
		return "$EXIT_USAGE"
	}

	if [[ "$plan" == standard || "$plan" == firewall ]]; then
		require_nft_command || return $?
		ensure_firewall_scope_owned_or_free || return $?
		require_firewall_write_preflight || return $?
		if [[ -r "$(firewall_state_path)" && "$(firewall_state_value enabled)" == 1 ]]; then
			existing_tcp="$(firewall_state_value tcp_ports)"
			existing_udp="$(firewall_state_value udp_ports)"
			advanced_rules="$(firewall_advanced_state_records)" || return $?
		fi
		tcp_ports="$(merge_basic_ports "$existing_tcp" "$tcp_ports")"
		udp_ports="$(merge_basic_ports "$existing_udp" "$udp_ports")"
		firewall_candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-wizard-firewall.XXXXXX")" || return "$EXIT_FAILURE"
		render_firewall_ruleset "$firewall_candidate" "$(current_ssh_ports)" "$tcp_ports" "$udp_ports" "$advanced_rules" || result=$?
		[[ "$result" -eq 0 ]] && validate_firewall_candidate "$firewall_candidate" || result=$?
		[[ "$result" -eq 0 ]] || {
			error "向导防火墙候选配置校验失败"
			return "$result"
		}
	fi
	if [[ "$plan" == standard || "$plan" == fail2ban ]]; then
		fail2ban_is_installed || {
			show_fail2ban_install_plan
			error "请先单独安装 Fail2ban，再运行快速向导"
			return "$EXIT_CONFLICT"
		}
		ensure_fail2ban_config_owned_or_absent || return $?
		values="$(fail2ban_preset_values standard)" || return $?
		IFS=$'\t' read -r findtime maxretry bantime increment maxtime <<<"$values"
		current_ip="$(current_management_ip 2>/dev/null || true)"
		ignoreip="$(normalize_ignore_ips "$current_ip")" || return $?
		fail2ban_candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-wizard-fail2ban.XXXXXX")" || return "$EXIT_FAILURE"
		render_fail2ban_config "$fail2ban_candidate" "$(effective_sshd_ports)" "$findtime" "$maxretry" "$bantime" "$increment" "$maxtime" "$ignoreip" || result=$?
		[[ "$result" -eq 0 ]] && validate_fail2ban_candidate "$fail2ban_candidate" || result=$?
		[[ "$result" -eq 0 ]] || {
			error "向导 Fail2ban 候选配置校验失败"
			return "$result"
		}
	fi
	printf '快速安全配置统一差异与风险摘要\n方案：%s\n' "$plan"
	[[ "$plan" == fail2ban ]] && printf 'nftables 防火墙：保持不变\n' || printf 'nftables 防火墙：入站默认拒绝；TCP %s；UDP %s\n' "${tcp_ports:-无}" "${udp_ports:-无}"
	[[ "$plan" == firewall ]] && printf 'Fail2ban：保持不变\n' || printf 'Fail2ban：standard；SSH 端口 %s；白名单 %s\n' "$(effective_sshd_ports)" "$ignoreip"
	printf 'SSH 配置：保持不变。自动回滚仅在 SSH 管理中可用。\n'
	[[ "$DRY_RUN" -ne 1 ]] || {
		printf 'dry-run：不会写配置或重载服务。\n'
		return 0
	}
	if [[ "$confirmed" -ne 1 ]]; then
		printf '确认一次性应用上述配置？[y/N] '
		IFS= read -r answer || answer=""
		case "$answer" in y | Y | yes | YES) ;; *)
			printf '已取消，未修改任何配置。\n'
			return 0
			;;
		esac
	fi
	snapshot_output="$(create_snapshot "wizard-before-$plan")" || return $?
	printf '%s\n' "$snapshot_output"
	snapshot="${snapshot_output#*快照已创建：}"
	snapshot="${snapshot%%$'\n'*}"
	if [[ -n "$firewall_candidate" ]]; then
		failure_stage=firewall-write
		install_firewall_configuration "$firewall_candidate" "$(current_ssh_ports)" "$tcp_ports" "$udp_ports" "$advanced_rules" || result=$?
	fi
	if [[ "$result" -eq 0 && -n "$fail2ban_candidate" ]]; then
		failure_stage=fail2ban-write
		fail2ban_stage="$(stage_fail2ban_candidate "$fail2ban_candidate")" && mv "$fail2ban_stage" "$(fail2ban_config_path)" || result=$?
	fi
	if [[ "$result" -eq 0 && "$plan" != fail2ban ]]; then
		failure_stage=firewall-runtime
		reload_firewall_runtime || result=$?
	fi
	if [[ "$result" -eq 0 && "$plan" != firewall ]]; then
		failure_stage=fail2ban-runtime
		reload_fail2ban_runtime || result=$?
	fi
	if [[ "$result" -ne 0 ]]; then
		restore_snapshot "$snapshot" 1 || true
		[[ "$plan" == fail2ban ]] || reload_firewall_runtime || true
		[[ "$plan" == firewall ]] || reload_fail2ban_runtime || true
		error "快速安全配置部分应用失败（阶段：${failure_stage}），已尝试恢复起始状态"
		return "$EXIT_FAILURE"
	fi
	audit_event wizard.apply success "plan=$plan snapshot=$snapshot"
	printf '快速安全配置已应用；SSH 配置未变更，未创建自动回滚。\n'
}

wizard_cli() {
	local action="${1:-}" plan="" tcp_ports="" udp_ports="" confirmed=0
	case "$action" in
	details)
		[[ "$#" -eq 1 ]] || return "$EXIT_USAGE"
		wizard_show_details
		;;
	apply)
		shift
		while [[ "$#" -gt 0 ]]; do
			case "$1" in
			--plan)
				[[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
				plan="$2"
				shift 2
				;;
			--tcp)
				[[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
				tcp_ports="$2"
				shift 2
				;;
			--udp)
				[[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
				udp_ports="$2"
				shift 2
				;;
			--ssh-port | --rollback-minutes)
				error "快速安全配置不支持 $1；请在 SSH 管理中执行 SSH 变更和自动回滚"
				return "$EXIT_USAGE"
				;;
			--yes)
				confirmed=1
				shift
				;;
			*)
				error "wizard apply 未知参数：$1"
				return "$EXIT_USAGE"
				;;
			esac
		done
		[[ -n "$plan" ]] || {
			error "必须指定 --plan standard|firewall|fail2ban"
			return "$EXIT_USAGE"
		}
		wizard_apply "$plan" "$tcp_ports" "$udp_ports" "$confirmed"
		;;
	*)
		error "用法：vps-guard wizard <details|apply>"
		return "$EXIT_USAGE"
		;;
	esac
}

show_quick_security_menu() {
	local choice plan tcp_detected udp_detected tcp_ports udp_ports advanced
	while true; do
		printf '快速安全配置\n1. 标准防护（推荐）\n2. 仅 nftables 防火墙\n3. 仅 Fail2ban\n4. 查看方案详情\n0. 返回主菜单\n请选择：'
		IFS= read -r choice || return 0
		case "$choice" in 0) return 0 ;; 4)
			wizard_show_details
			continue
			;;
		1) plan=standard ;; 2) plan=firewall ;; 3) plan=fail2ban ;; *)
			printf '无效选项，请重新输入。\n'
			continue
			;;
		esac
		tcp_ports=""
		udp_ports=""
		if [[ "$plan" != fail2ban ]]; then
			tcp_detected="$(wizard_detect_listening_ports tcp 2>/dev/null || true)"
			udp_detected="$(wizard_detect_listening_ports udp 2>/dev/null || true)"
			printf '检测到监听 TCP：%s\n开放 TCP 业务端口（留空采用检测值）：' "${tcp_detected:-无}"
			IFS= read -r tcp_ports || return 0
			printf '检测到监听 UDP：%s\n开放 UDP 业务端口（留空采用检测值）：' "${udp_detected:-无}"
			IFS= read -r udp_ports || return 0
			tcp_ports="${tcp_ports:-$tcp_detected}"
			udp_ports="${udp_ports:-$udp_detected}"
		fi
		while true; do
			printf '高级设置\n1. nftables 防火墙高级规则\n2. Fail2ban 管理\n3. 继续应用（默认）\n0. 返回主菜单\n请选择：'
			IFS= read -r advanced || return 0
			case "${advanced:-3}" in
			1) show_firewall_menu ;;
			2) show_fail2ban_menu ;;
			3) break ;;
			0) return 0 ;;
			*) printf '无效选项。\n' ;;
			esac
		done
		wizard_apply "$plan" "$tcp_ports" "$udp_ports" 0 || true
	done
}
