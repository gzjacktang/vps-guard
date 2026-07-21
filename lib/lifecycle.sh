#!/usr/bin/env bash

# 生命周期命令严格区分“检查元数据”和“执行本地更新”：运行中的程序永不下载并执行代码。

lifecycle_program_root() {
	printf '%s\n' "${VPS_GUARD_PROGRAM_ROOT:-/usr/local/lib/vps-guard}"
}

lifecycle_command_link() {
	printf '%s\n' "${VPS_GUARD_COMMAND_LINK:-/usr/local/sbin/vps-guard}"
}

lifecycle_config_dir() {
	printf '%s\n' "${VPS_GUARD_CONFIG_DIR:-/etc/vps-guard}"
}

lifecycle_release_api() {
	printf '%s\n' "${VPS_GUARD_RELEASE_API:-https://api.github.com/repos/gzjacktang/vps-guard/releases/latest}"
}

lifecycle_validate_removal_path() {
	local path="$1"
	[[ "$path" == /* && "$path" != / && "$path" != /usr && "$path" != /usr/local && "$path" != /var && "$path" != /etc ]]
}

lifecycle_lock_path() {
	printf '%s\n' "${VPS_GUARD_LIFECYCLE_LOCK:-/run/lock/vps-guard-lifecycle.lock}"
}

lifecycle_transaction_state_is_nonterminal() {
	local state="$1" kind="$2" status count
	[[ -f "$state" && ! -L "$state" && -r "$state" ]] || return 0
	count="$(grep -c '^status=' "$state" || true)"
	[[ "$count" -ge 1 ]] || return 0
	status="$(read_state_value "$state" status | tail -1)"
	if [[ "$kind" == rollback ]]; then
		case "$status" in confirmed | rolled-back) return 1 ;; *) return 0 ;; esac
	else
		case "$status" in verified | discarded) return 1 ;; *) return 0 ;; esac
	fi
}

lifecycle_has_active_transaction() {
	local data_dir directory state units
	data_dir="$(backup_data_dir)"
	for directory in "$data_dir"/rollbacks/*; do
		[[ -e "$directory" || -L "$directory" ]] || continue
		[[ -d "$directory" && ! -L "$directory" ]] || return 0
		state="$directory/state"
		lifecycle_transaction_state_is_nonterminal "$state" rollback && return 0
	done
	for directory in "$data_dir"/ssh-enrollments/*; do
		[[ -e "$directory" || -L "$directory" ]] || continue
		[[ -d "$directory" && ! -L "$directory" ]] || return 0
		state="$directory/state"
		lifecycle_transaction_state_is_nonterminal "$state" enrollment && return 0
	done
	if command_exists systemctl && [[ -z "${VPS_GUARD_FS_ROOT:-}" ]]; then
		units="$(systemctl list-units --all --plain --no-legend 'vps-guard-rollback-*' 2>/dev/null)" || return 0
		[[ -z "$units" ]] || return 0
	fi
	return 1
}

lifecycle_acquire_lock() {
	local lock
	lock="$(lifecycle_lock_path)"
	mkdir -p "$(dirname "$lock")" || return "$EXIT_FAILURE"
	chmod 0700 "$(dirname "$lock")" || return "$EXIT_FAILURE"
	mkdir "$lock" 2>/dev/null || {
		error "另一个安装、更新或卸载事务正在运行"
		return "$EXIT_CONFLICT"
	}
	printf '%s\n' "$$" >"$lock/pid" || {
		rm -rf "$lock"
		return "$EXIT_FAILURE"
	}
	if [[ -e "$(config_transaction_lock_dir)" || -L "$(config_transaction_lock_dir)" ]]; then
		rm -rf "$lock"
		error "安全配置事务正在运行（有进程正在写入配置），请稍后再试"
		return "$EXIT_CONFLICT"
	fi
}

lifecycle_release_lock() {
	rm -rf "$(lifecycle_lock_path)"
}

lifecycle_managed_launcher_is_valid() {
	local command_link program_root current_link signature expected mode owner
	command_link="$(lifecycle_command_link)"
	program_root="$(lifecycle_program_root)"
	current_link="$program_root/current"
	signature='# VPS Guard managed launcher v1'
	[[ -f "$command_link" && ! -L "$command_link" ]] || return 1
	[[ "$(sed -n '1p' "$command_link")" == '#!/usr/bin/env bash' ]] || return 1
	[[ "$(sed -n '2p' "$command_link")" == "$signature" ]] || return 1
	expected="$(printf 'exec %q "$@"' "$current_link/vps-guard.sh")"
	[[ "$(sed -n '3p' "$command_link")" == "$expected" ]] || return 1
	mode="$(file_mode "$command_link")" || return 1
	[[ "$mode" == 755 ]] || return 1
	if [[ "$command_link" == /usr/local/sbin/vps-guard ]]; then
		owner="$(path_owner_uid "$command_link")" || return 1
		[[ "$owner" == 0 ]] || return 1
	fi
}

lifecycle_install_layout_is_valid() {
	local program_root current target version release manifest release_root owner
	program_root="$(lifecycle_program_root)"
	current="$program_root/current"
	[[ -d "$program_root" && ! -L "$program_root" && -L "$current" ]] || return 1
	target="$(readlink "$current")" || return 1
	case "$target" in releases/*) version="${target#releases/}" ;; *) return 1 ;; esac
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ && "$target" == "releases/$version" ]] || return 1
	release="$program_root/$target"
	[[ -d "$release" && ! -L "$release" ]] || return 1
	release="$(cd "$release" && pwd -P)" || return 1
	release_root="$(cd "$program_root/releases" && pwd -P)" || return 1
	case "$release" in "$release_root"/*) ;; *) return 1 ;; esac
	[[ "${release##*/}" == "$version" ]] || return 1
	[[ -f "$release/VERSION" && ! -L "$release/VERSION" && "$(sed -n '1p' "$release/VERSION")" == "$version" ]] || return 1
	manifest="$release/INSTALL-MANIFEST"
	[[ -f "$manifest" && ! -L "$manifest" ]] || return 1
	[[ "$(sed -n 's/^signature=//p' "$manifest")" == vps-guard-managed-install-v1 ]] || return 1
	[[ "$(sed -n 's/^version=//p' "$manifest")" == "$version" ]] || return 1
	[[ -x "$release/vps-guard.sh" && -d "$release/lib" ]] || return 1
	lifecycle_managed_launcher_is_valid || return 1
	if [[ "$program_root" == /usr/local/lib/vps-guard ]]; then
		owner="$(path_owner_uid "$program_root")" || return 1
		[[ "$owner" == 0 ]] || return 1
	fi
}

show_vps_guard_version() {
	printf 'VPS Guard %s\n' "$VPS_GUARD_VERSION"
}

check_for_update() {
	local api metadata tag latest release_url
	api="$(lifecycle_release_api)"
	printf 'VPS Guard 手动更新检查\n当前版本：%s\n' "$VPS_GUARD_VERSION"
	printf '检查地址：%s\n' "$api"
	printf '安全边界：只读取 Release 元数据，不下载或执行脚本。\n'
	command_exists curl || {
		error "缺少 curl；未执行联网检查"
		return "$EXIT_FAILURE"
	}
	metadata="$(curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 15 "$api")" || {
		error "无法读取 Release 元数据"
		return "$EXIT_FAILURE"
	}
	tag="$(printf '%s\n' "$metadata" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	release_url="$(printf '%s\n' "$metadata" | sed -n 's/.*"html_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	latest="${tag#v}"
	[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
		error "Release 元数据未包含可信版本号"
		return "$EXIT_FAILURE"
	}
	printf '最新发布：%s\n' "$latest"
	if [[ "$latest" == "$VPS_GUARD_VERSION" ]]; then
		printf '当前已是最新发布。\n'
		return 0
	fi
	printf '发现不同版本，请人工判断是否升级或降级。\n'
	if [[ "$release_url" == "https://github.com/gzjacktang/vps-guard/releases/tag/v$latest" ]]; then
		printf '发布页面：%s\n' "$release_url"
	fi
	printf '手动更新步骤：下载源码包与 SHA256SUMS；运行 sha256sum -c SHA256SUMS；解压后审阅并执行 sudo ./install.sh --update。\n'
	printf '本命令不会自动下载发布物，也不会执行远程代码。\n'
}

uninstall_vps_guard() (
	local assume_yes="$1" purge_data="$2"
	local program_root command_link data_dir audit_log audit_dir config_dir answer
	local quarantine launcher_backup lock_acquired=0 program_present=0
	program_root="$(lifecycle_program_root)"
	command_link="$(lifecycle_command_link)"
	data_dir="$(backup_data_dir)"
	audit_log="${VPS_GUARD_AUDIT_LOG:-/var/log/vps-guard/audit.log}"
	audit_dir="$(dirname "$audit_log")"
	config_dir="$(lifecycle_config_dir)"
	if ! lifecycle_validate_removal_path "$program_root" || ! lifecycle_validate_removal_path "$command_link"; then
		error "卸载路径不安全，拒绝继续"
		return "$EXIT_CONFLICT"
	fi
	if [[ "$purge_data" -eq 1 ]]; then
		if ! lifecycle_validate_removal_path "$data_dir" || ! lifecycle_validate_removal_path "$audit_log"; then
			error "数据清理路径不安全，拒绝继续"
			return "$EXIT_CONFLICT"
		fi
	fi

	if [[ -e "$program_root" || -L "$program_root" || -e "$command_link" || -L "$command_link" ]]; then
		if ! lifecycle_install_layout_is_valid; then
			error "现有程序布局、manifest 或 launcher 归属不可信，拒绝删除"
			return "$EXIT_CONFLICT"
		fi
		program_present=1
	fi

	printf '将卸载 VPS Guard 程序\n'
	printf '保留系统配置：%s、SSH/nftables/Fail2ban 受管配置\n' "$config_dir"
	if [[ "$purge_data" -eq 1 ]]; then
		printf '危险：还会永久删除快照/事务数据 %s 和审计日志 %s。\n' "$data_dir" "$audit_log"
	else
		printf '保留数据：快照/事务 %s，审计日志 %s\n' "$data_dir" "$audit_log"
	fi
	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf 'dry-run：未删除任何文件。\n'
		return 0
	fi

	if lifecycle_has_active_transaction; then
		printf '警告：存在未完成或状态异常的自动回滚/密钥清理事务，卸载后这些事务将无法自动恢复。\n'
	fi

	if [[ "$assume_yes" -ne 1 ]]; then
		printf '确认卸载？[y/N] '
		IFS= read -r answer || answer=""
		case "$answer" in y | Y | yes | YES) ;; *)
			printf '已取消卸载。\n'
			return 0
			;;
		esac
	fi
	lifecycle_acquire_lock || return $?
	lock_acquired=1
	trap '[[ "$lock_acquired" -ne 1 ]] || lifecycle_release_lock' EXIT INT TERM

	# 锁内复检关闭“展示计划/确认”与实际删除之间的竞态窗口。
	if [[ -e "$program_root" || -L "$program_root" || -e "$command_link" || -L "$command_link" ]]; then
		if ! lifecycle_install_layout_is_valid; then
			error "锁内复检发现安装布局已变化，拒绝删除"
			return "$EXIT_CONFLICT"
		fi
		program_present=1
	elif [[ "$program_present" -eq 1 ]]; then
		error "锁内复检发现程序已被其他进程移除"
		return "$EXIT_CONFLICT"
	fi

	if [[ "$program_present" -eq 1 ]]; then
		quarantine="${program_root}.uninstall.$$"
		launcher_backup="${command_link}.uninstall.$$"
		if [[ -e "$quarantine" || -L "$quarantine" || -e "$launcher_backup" || -L "$launcher_backup" ]]; then
			error "卸载临时路径已存在，拒绝覆盖"
			return "$EXIT_CONFLICT"
		fi
		cp -p "$command_link" "$launcher_backup" || {
			error "无法建立 launcher 恢复副本；未删除程序"
			return "$EXIT_FAILURE"
		}
		if ! mv "$program_root" "$quarantine"; then
			rm -f "$launcher_backup"
			error "无法隔离程序目录；未删除程序"
			return "$EXIT_FAILURE"
		fi
		if ! rm -f "$command_link"; then
			mv "$quarantine" "$program_root" || true
			rm -f "$launcher_backup"
			error "无法删除稳定入口；已尝试恢复程序目录"
			return "$EXIT_FAILURE"
		fi
		if ! rm -rf "$quarantine"; then
			mv "$quarantine" "$program_root" || true
			mv "$launcher_backup" "$command_link" || true
			error "无法清理隔离目录；已尝试恢复安装"
			return "$EXIT_FAILURE"
		fi
		rm -f "$launcher_backup" || {
			error "程序已卸载，但 launcher 临时恢复副本清理失败：$launcher_backup"
			return "$EXIT_FAILURE"
		}
	fi
	if [[ "$purge_data" -eq 1 ]]; then
		if [[ -e "$data_dir" || -L "$data_dir" ]]; then
			rm -rf "$data_dir" || {
				error "程序已卸载，但快照/事务数据清理失败：$data_dir"
				return "$EXIT_FAILURE"
			}
		fi
		if [[ -e "$audit_log" || -L "$audit_log" ]]; then
			rm -f "$audit_log" || {
				error "程序已卸载，但审计日志清理失败：$audit_log"
				return "$EXIT_FAILURE"
			}
		fi
		rmdir "$audit_dir" 2>/dev/null || true
		printf '程序、快照/事务数据和审计日志已删除；系统安全配置仍保留。\n'
	else
		printf '程序已删除；系统配置、快照和日志均已保留。\n'
	fi
)

lifecycle_cli() {
	local action="${1:-}" assume_yes=0 purge_data=0
	shift || true
	case "$action" in
	update-check)
		[[ "$#" -eq 0 ]] || {
			error "用法：vps-guard lifecycle update-check"
			return "$EXIT_USAGE"
		}
		check_for_update
		;;
	uninstall)
		while [[ "$#" -gt 0 ]]; do
			case "$1" in
			--yes) assume_yes=1 ;;
			--purge-data) purge_data=1 ;;
			*)
				error "用法：vps-guard uninstall [--yes] [--purge-data]"
				return "$EXIT_USAGE"
				;;
			esac
			shift
		done
		uninstall_vps_guard "$assume_yes" "$purge_data"
		;;
	*)
		error "用法：vps-guard lifecycle <update-check|uninstall>"
		return "$EXIT_USAGE"
		;;
	esac
}
