#!/usr/bin/env bash

backup_data_dir() {
  printf '%s\n' "${VPS_GUARD_DATA_DIR:-/var/lib/vps-guard}"
}

backup_fs_root() {
  printf '%s\n' "${VPS_GUARD_FS_ROOT:-}"
}

snapshot_retention() {
  local configured="${VPS_GUARD_BACKUP_RETENTION:-}"
  local settings_file
  settings_file="$(backup_data_dir)/settings"
  if [[ -z "$configured" && -r "$settings_file" ]]; then
    configured="$(sed -n 's/^retention=//p' "$settings_file" | tail -1)"
  fi
  configured="${configured:-10}"
  [[ "$configured" =~ ^[0-9]+$ && "$configured" -ge 1 && "$configured" -le 100 ]] || configured=10
  printf '%s\n' "$configured"
}

prune_snapshots() {
  local backups_dir="$1"
  local retention snapshot remove_count index snapshot_listing
  local snapshots=()
  retention="$(snapshot_retention)"
  if ! snapshot_listing="$(find "$backups_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*.tmp' -print | sort)"; then
    return "$EXIT_FAILURE"
  fi
  while IFS= read -r snapshot; do
    [[ -n "$snapshot" ]] || continue
    snapshots+=("$snapshot")
  done <<<"$snapshot_listing"
  remove_count=$((${#snapshots[@]} - retention))
  if [[ "$remove_count" -gt 0 ]]; then
    for ((index = 0; index < remove_count; index++)); do
      rm -rf "${snapshots[$index]}" || return "$EXIT_FAILURE"
    done
  fi
}

managed_paths() {
  local paths_file="${VPS_GUARD_MANAGED_PATHS_FILE:-}"

  if [[ -n "$paths_file" && -r "$paths_file" ]]; then
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$paths_file"
    return 0
  fi

  printf '%s\n' \
    '/etc/ssh/sshd_config' \
    '/etc/ssh/sshd_config.d' \
    '/etc/nftables.conf' \
    '/etc/nftables.d/vps-guard.nft' \
    '/etc/vps-guard/firewall.conf' \
    '/etc/fail2ban/jail.d/vps-guard.local'
}

file_mode() {
  local path="$1"
  stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path"
}

file_checksum() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

validate_managed_path() {
  local path="$1"
  [[ "$path" == /* && "$path" != *'/../'* && "$path" != */.. && "$path" != *$'\t'* && "$path" != *$'\n'* ]]
}

manifest_has_file() {
  local manifest="$1"
  local wanted="$2"
  awk -F '\t' -v wanted="$wanted" '$1 == wanted && $2 == "file" { found=1 } END { exit !found }' "$manifest"
}

expanded_managed_files() {
  local managed_listing="$1"
  local fs_root managed_path source_path found found_listing
  fs_root="$(backup_fs_root)"
  while IFS= read -r managed_path; do
    [[ -n "$managed_path" ]] || continue
    validate_managed_path "$managed_path" || {
      error "受管路径不安全：$managed_path"
      return "$EXIT_USAGE"
    }
    source_path="$fs_root$managed_path"
    if [[ -f "$source_path" ]]; then
      printf '%s\n' "$managed_path"
    elif [[ -d "$source_path" ]]; then
      if ! found_listing="$(find "$source_path" -type f -print | sort)"; then
        error "无法遍历受管目录：$managed_path"
        return "$EXIT_FAILURE"
      fi
      while IFS= read -r found; do
        [[ -n "$found" ]] || continue
        printf '%s\n' "${found#"$fs_root"}"
      done <<<"$found_listing"
    fi
  done <<<"$managed_listing"
}

create_snapshot() {
  local label="$1"
  local data_dir backups_dir snapshot_id temp_dir final_dir fs_root
  local managed_path source_path relative_path mode checksum managed_listing expanded_files
  local file_count=0

  if [[ -z "$label" || "$label" == *$'\t'* || "$label" == *$'\n'* || "$label" == */* ]]; then
    error "快照标签不能为空，且不能包含斜杠、制表符或换行"
    return "$EXIT_USAGE"
  fi

  data_dir="$(backup_data_dir)"
  backups_dir="$data_dir/backups"
  snapshot_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
  final_dir="$backups_dir/$snapshot_id"
  temp_dir="$backups_dir/.${snapshot_id}.tmp"
  fs_root="$(backup_fs_root)"

  if ! managed_listing="$(managed_paths)"; then
    [[ "$DRY_RUN" -eq 1 ]] || audit_event snapshot.create failure "reason=read-managed-paths"
    error "无法读取受管路径配置"
    return "$EXIT_FAILURE"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：将创建快照，标签：%s\n' "$label"
    while IFS= read -r managed_path; do
      [[ -n "$managed_path" ]] || continue
      printf '将备份：%s\n' "$managed_path"
    done <<<"$managed_listing"
    return 0
  fi

  umask 077
  if ! mkdir -p "$backups_dir" || ! chmod 0700 "$data_dir" "$backups_dir"; then
    audit_event snapshot.create failure "reason=prepare-storage"
    error "无法准备快照目录"
    return "$EXIT_FAILURE"
  fi
  if ! rm -rf "$temp_dir" || ! mkdir -p "$temp_dir/files" ||
    ! : >"$temp_dir/manifest.tsv" || ! : >"$temp_dir/roots.tsv"; then
    rm -rf "$temp_dir" || true
    audit_event snapshot.create failure "reason=prepare-snapshot"
    error "无法准备快照临时目录或清单"
    return "$EXIT_FAILURE"
  fi

  # 对快照时不存在的受管文件也记录状态，回滚时才能撤销后续新建配置。
  while IFS= read -r managed_path; do
    [[ -n "$managed_path" ]] || continue
    validate_managed_path "$managed_path" || {
      rm -rf "$temp_dir" || true
      audit_event snapshot.create failure "path=$managed_path reason=unsafe-path"
      error "受管路径不安全：$managed_path"
      return "$EXIT_USAGE"
    }
    source_path="$fs_root$managed_path"
    if [[ -d "$source_path" ]]; then
      if ! printf '%s\tdir\n' "$managed_path" >>"$temp_dir/roots.tsv"; then
        rm -rf "$temp_dir" || true
        audit_event snapshot.create failure "path=$managed_path reason=write-roots"
        error "无法写入快照根清单"
        return "$EXIT_FAILURE"
      fi
    elif [[ -f "$source_path" ]]; then
      if ! printf '%s\tfile\n' "$managed_path" >>"$temp_dir/roots.tsv"; then
        rm -rf "$temp_dir" || true
        audit_event snapshot.create failure "path=$managed_path reason=write-roots"
        error "无法写入快照根清单"
        return "$EXIT_FAILURE"
      fi
    else
      if ! printf '%s\tmissing\n' "$managed_path" >>"$temp_dir/roots.tsv" ||
        ! printf '%s\tmissing\t-\t-\n' "$managed_path" >>"$temp_dir/manifest.tsv"; then
        rm -rf "$temp_dir" || true
        audit_event snapshot.create failure "path=$managed_path reason=write-manifest"
        error "无法写入快照清单"
        return "$EXIT_FAILURE"
      fi
    fi
  done <<<"$managed_listing"

  if ! expanded_files="$(expanded_managed_files "$managed_listing")"; then
    rm -rf "$temp_dir" || true
    audit_event snapshot.create failure "reason=traverse"
    error "无法展开受管文件列表"
    return "$EXIT_FAILURE"
  fi

  while IFS= read -r managed_path; do
    [[ -n "$managed_path" ]] || continue
    if ! validate_managed_path "$managed_path"; then
      rm -rf "$temp_dir" || true
      audit_event snapshot.create failure "path=$managed_path reason=unsafe-path"
      error "受管路径不安全：$managed_path"
      return "$EXIT_USAGE"
    fi
    source_path="$fs_root$managed_path"
    [[ -e "$source_path" ]] || continue
    [[ -f "$source_path" ]] || continue
    relative_path="${managed_path#/}"
    if ! mkdir -p "$temp_dir/files/$(dirname "$relative_path")" ||
      ! cp -p "$source_path" "$temp_dir/files/$relative_path"; then
      rm -rf "$temp_dir" || true
      audit_event snapshot.create failure "path=$managed_path reason=copy"
      error "无法复制受管配置：$managed_path"
      return "$EXIT_FAILURE"
    fi
    if ! mode="$(file_mode "$source_path")" || ! checksum="$(file_checksum "$source_path")"; then
      rm -rf "$temp_dir" || true
      audit_event snapshot.create failure "path=$managed_path reason=metadata"
      error "无法读取配置元数据：$managed_path"
      return "$EXIT_FAILURE"
    fi
    if ! printf '%s\tfile\t%s\t%s\n' "$managed_path" "$mode" "$checksum" >>"$temp_dir/manifest.tsv"; then
      rm -rf "$temp_dir" || true
      audit_event snapshot.create failure "path=$managed_path reason=write-manifest"
      error "无法写入快照清单"
      return "$EXIT_FAILURE"
    fi
    file_count=$((file_count + 1))
  done <<<"$expanded_files"

  if ! printf 'id=%s\ncreated=%s\nlabel=%s\nfiles=%s\n' \
    "$snapshot_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$label" "$file_count" >"$temp_dir/meta"; then
    rm -rf "$temp_dir" || true
    audit_event snapshot.create failure "snapshot=$snapshot_id reason=write-meta"
    error "无法写入快照元数据"
    return "$EXIT_FAILURE"
  fi
  if ! mv "$temp_dir" "$final_dir"; then
    rm -rf "$temp_dir" || true
    audit_event snapshot.create failure "snapshot=$snapshot_id reason=commit"
    error "无法提交快照"
    return "$EXIT_FAILURE"
  fi
  if ! prune_snapshots "$backups_dir"; then
    audit_event snapshot.create failure "snapshot=$snapshot_id reason=retention-cleanup"
    error "快照已创建，但旧快照清理失败"
    return "$EXIT_FAILURE"
  fi
  audit_event snapshot.create success "snapshot=$snapshot_id files=$file_count"
  printf '快照已创建：%s\n标签：%s\n文件：%s\n' "$snapshot_id" "$label" "$file_count"
}

list_snapshots() {
  local backups_dir snapshot meta id label files
  backups_dir="$(backup_data_dir)/backups"

  if [[ ! -d "$backups_dir" ]]; then
    printf '暂无快照。\n'
    return 0
  fi

  for snapshot in "$backups_dir"/*; do
    [[ -d "$snapshot" && -r "$snapshot/meta" ]] || continue
    meta="$snapshot/meta"
    id="$(sed -n 's/^id=//p' "$meta")"
    label="$(sed -n 's/^label=//p' "$meta")"
    files="$(sed -n 's/^files=//p' "$meta")"
    printf '%s  标签：%s  文件：%s\n' "$id" "$label" "$files"
  done
}

snapshot_directory() {
  local snapshot_id="$1"
  if [[ -z "$snapshot_id" || "$snapshot_id" == *[!A-Za-z0-9._-]* ]]; then
    error "快照 ID 不合法"
    return "$EXIT_USAGE"
  fi
  printf '%s/backups/%s\n' "$(backup_data_dir)" "$snapshot_id"
}

diff_snapshot() {
  local snapshot_id="$1"
  local snapshot_dir fs_root path kind mode expected_checksum current_path current_checksum root_path root_kind found found_listing
  local changes=0

  snapshot_dir="$(snapshot_directory "$snapshot_id")" || return $?
  if [[ ! -r "$snapshot_dir/manifest.tsv" ]]; then
    audit_event snapshot.restore failure "snapshot=$snapshot_id reason=manifest-unreadable"
    error "快照不存在或清单不可读：$snapshot_id"
    return "$EXIT_FAILURE"
  fi
  fs_root="$(backup_fs_root)"

  while IFS=$'\t' read -r path kind mode expected_checksum; do
    current_path="$fs_root$path"
    if [[ "$kind" == "missing" ]]; then
      if [[ -e "$current_path" || -L "$current_path" ]]; then
        printf '新增：%s\n' "$path"
        changes=$((changes + 1))
      fi
      continue
    fi
    [[ "$kind" == "file" ]] || continue
    if [[ ! -f "$current_path" ]]; then
      printf '已缺失：%s\n' "$path"
      changes=$((changes + 1))
      continue
    fi
    current_checksum="$(file_checksum "$current_path")"
    if [[ "$current_checksum" != "$expected_checksum" ]]; then
      printf '已更改：%s\n' "$path"
      changes=$((changes + 1))
    fi
  done <"$snapshot_dir/manifest.tsv"

  if [[ -r "$snapshot_dir/roots.tsv" ]]; then
    while IFS=$'\t' read -r root_path root_kind; do
      [[ "$root_kind" == "dir" && -d "$fs_root$root_path" ]] || continue
      if ! found_listing="$(find "$fs_root$root_path" -type f -print | sort)"; then
        error "无法遍历受管目录：$root_path"
        return "$EXIT_FAILURE"
      fi
      while IFS= read -r found; do
        [[ -n "$found" ]] || continue
        path="${found#"$fs_root"}"
        if ! manifest_has_file "$snapshot_dir/manifest.tsv" "$path"; then
          printf '新增：%s\n' "$path"
          changes=$((changes + 1))
        fi
      done <<<"$found_listing"
    done <"$snapshot_dir/roots.tsv"
  fi

  if [[ "$changes" -eq 0 ]]; then
    printf '当前配置与快照一致。\n'
  fi
}

restore_snapshot() {
  local snapshot_id="$1"
  local confirmed="$2"
  local snapshot_dir fs_root path kind mode expected_checksum saved_file target stage original root_path root_kind found found_listing
  local index rollback_index
  local paths=() stages=() originals=()

  snapshot_dir="$(snapshot_directory "$snapshot_id")" || return $?
  if [[ ! -r "$snapshot_dir/manifest.tsv" ]]; then
    error "快照不存在或清单不可读：$snapshot_id"
    return "$EXIT_FAILURE"
  fi
  fs_root="$(backup_fs_root)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：将从快照 %s 恢复以下路径：\n' "$snapshot_id"
    while IFS=$'\t' read -r path kind mode expected_checksum; do
      if [[ "$kind" == "file" ]]; then
        printf '将恢复：%s\n' "$path"
      elif [[ "$kind" == "missing" && (-e "$fs_root$path" || -L "$fs_root$path") ]]; then
        printf '将删除：%s\n' "$path"
      fi
    done <"$snapshot_dir/manifest.tsv"
    if [[ -r "$snapshot_dir/roots.tsv" ]]; then
      while IFS=$'\t' read -r root_path root_kind; do
        [[ "$root_kind" == "dir" && -d "$fs_root$root_path" ]] || continue
        if ! found_listing="$(find "$fs_root$root_path" -type f -print | sort)"; then
          error "无法遍历受管目录：$root_path"
          return "$EXIT_FAILURE"
        fi
        while IFS= read -r found; do
          [[ -n "$found" ]] || continue
          path="${found#"$fs_root"}"
          manifest_has_file "$snapshot_dir/manifest.tsv" "$path" || printf '将删除：%s\n' "$path"
        done <<<"$found_listing"
      done <"$snapshot_dir/roots.tsv"
    fi
    return 0
  fi

  if [[ "$confirmed" -ne 1 ]]; then
    printf '警告：恢复会覆盖当前受管配置。确认恢复？[y/N] '
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        printf '已取消恢复。\n'
        return 0
        ;;
    esac
  fi

  # 先验证并准备全部临时文件，避免校验失败时只恢复一部分。
  while IFS=$'\t' read -r path kind mode expected_checksum; do
    if [[ "$kind" == "missing" ]]; then
      target="$fs_root$path"
      if [[ -d "$target" ]]; then
        audit_event snapshot.restore failure "snapshot=$snapshot_id path=$path reason=refuse-directory-delete"
        error "拒绝删除快照后新增的目录：$path"
        return "$EXIT_FAILURE"
      fi
      paths+=("$target")
      stages+=("__REMOVE__")
      continue
    fi
    [[ "$kind" == "file" ]] || continue
    validate_managed_path "$path" || {
      audit_event snapshot.restore failure "snapshot=$snapshot_id path=$path reason=unsafe-path"
      error "快照包含不安全路径：$path"
      return "$EXIT_FAILURE"
    }
    saved_file="$snapshot_dir/files/${path#/}"
    if [[ ! -f "$saved_file" || "$(file_checksum "$saved_file")" != "$expected_checksum" ]]; then
      audit_event snapshot.restore failure "snapshot=$snapshot_id path=$path reason=checksum"
      error "快照文件校验失败：$path"
      return "$EXIT_FAILURE"
    fi
    target="$fs_root$path"
    if ! mkdir -p "$(dirname "$target")"; then
      audit_event snapshot.restore failure "snapshot=$snapshot_id path=$path reason=prepare-target"
      error "无法准备恢复目录：$path"
      return "$EXIT_FAILURE"
    fi
    stage="$(dirname "$target")/.vps-guard-stage.$$.${#paths[@]}"
    if ! cp -p "$saved_file" "$stage" || ! chmod "$mode" "$stage"; then
      rm -f "$stage" || true
      audit_event snapshot.restore failure "snapshot=$snapshot_id path=$path reason=prepare-file"
      error "无法准备恢复文件：$path"
      return "$EXIT_FAILURE"
    fi
    paths+=("$target")
    stages+=("$stage")
  done <"$snapshot_dir/manifest.tsv"

  # 目录快照是精确集合：快照后新增的普通文件也纳入原子删除计划。
  if [[ -r "$snapshot_dir/roots.tsv" ]]; then
    while IFS=$'\t' read -r root_path root_kind; do
      [[ "$root_kind" == "dir" && -d "$fs_root$root_path" ]] || continue
      if ! found_listing="$(find "$fs_root$root_path" -type f -print | sort)"; then
        for stage in "${stages[@]}"; do
          if [[ "$stage" != "__REMOVE__" ]]; then
            rm -f "$stage" || true
          fi
        done
        audit_event snapshot.restore failure "snapshot=$snapshot_id path=$root_path reason=traverse"
        error "无法遍历受管目录：$root_path"
        return "$EXIT_FAILURE"
      fi
      while IFS= read -r found; do
        [[ -n "$found" ]] || continue
        path="${found#"$fs_root"}"
        if ! manifest_has_file "$snapshot_dir/manifest.tsv" "$path"; then
          validate_managed_path "$path" || return "$EXIT_FAILURE"
          paths+=("$found")
          stages+=("__REMOVE__")
        fi
      done <<<"$found_listing"
    done <"$snapshot_dir/roots.tsv"
  fi

  for index in "${!paths[@]}"; do
    target="${paths[$index]}"
    stage="${stages[$index]}"
    original="$(dirname "$target")/.vps-guard-original.$$.${index}"
    originals+=("")
    if [[ -e "$target" ]]; then
      if ! mv "$target" "$original"; then
        for ((rollback_index = index - 1; rollback_index >= 0; rollback_index--)); do
          rm -f "${paths[$rollback_index]}" || true
          if [[ -n "${originals[rollback_index]}" ]]; then
            mv "${originals[rollback_index]}" "${paths[rollback_index]}" || true
          fi
        done
        for ((rollback_index = index; rollback_index < ${#stages[@]}; rollback_index++)); do
          if [[ "${stages[rollback_index]}" != "__REMOVE__" ]]; then
            rm -f "${stages[rollback_index]}" || true
          fi
        done
        audit_event snapshot.restore failure "snapshot=$snapshot_id path=$target reason=stage-current"
        error "无法暂存当前配置：$target"
        return "$EXIT_FAILURE"
      fi
      originals[index]="$original"
    fi
    if [[ "$stage" == "__REMOVE__" ]]; then
      continue
    fi
    if ! mv "$stage" "$target"; then
      if [[ -n "${originals[index]}" ]]; then
        mv "${originals[index]}" "$target" || true
      fi
      for ((rollback_index = index - 1; rollback_index >= 0; rollback_index--)); do
        rm -f "${paths[$rollback_index]}" || true
        if [[ -n "${originals[rollback_index]}" ]]; then
          mv "${originals[rollback_index]}" "${paths[rollback_index]}" || true
        fi
      done
      error "恢复失败，已回退先前文件"
      audit_event snapshot.restore failure "snapshot=$snapshot_id path=$target reason=commit"
      return "$EXIT_FAILURE"
    fi
  done

  for original in "${originals[@]}"; do
    if [[ -n "$original" ]] && ! rm -f "$original"; then
      audit_event snapshot.restore failure "snapshot=$snapshot_id path=$original reason=cleanup"
      error "配置已恢复，但无法清理临时文件：$original"
      return "$EXIT_FAILURE"
    fi
  done
  audit_event snapshot.restore success "snapshot=$snapshot_id files=${#paths[@]}"
  printf '快照恢复完成：%s\n' "$snapshot_id"
}

backup_cli() {
  local action="${1:-}"
  local label="manual"

  case "$action" in
    create)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --label)
            [[ "$#" -ge 2 ]] || {
              error "--label 需要一个值"
              return "$EXIT_USAGE"
            }
            label="$2"
            shift 2
            ;;
          *)
            error "backup create 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      create_snapshot "$label"
      ;;
    list)
      [[ "$#" -eq 1 ]] || {
        error "backup list 不接受额外参数"
        return "$EXIT_USAGE"
      }
      list_snapshots
      ;;
    diff)
      [[ "$#" -eq 2 ]] || {
        error "用法：vps-guard backup diff <快照ID>"
        return "$EXIT_USAGE"
      }
      diff_snapshot "$2"
      ;;
    restore)
      [[ "$#" -ge 2 && "$#" -le 3 ]] || {
        error "用法：vps-guard backup restore <快照ID> [--yes]"
        return "$EXIT_USAGE"
      }
      if [[ "$#" -eq 3 && "$3" != "--yes" ]]; then
        error "backup restore 未知参数：$3"
        return "$EXIT_USAGE"
      fi
      restore_snapshot "$2" "$([[ "${3:-}" == "--yes" ]] && printf 1 || printf 0)"
      ;;
    retention)
      if [[ "$#" -eq 1 ]]; then
        printf '快照保留数量：%s\n' "$(snapshot_retention)"
      elif [[ "$#" -eq 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 1 && "$2" -le 100 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          printf 'dry-run：将快照保留数量设置为 %s。\n' "$2"
        else
          umask 077
          mkdir -p "$(backup_data_dir)"
          printf 'retention=%s\n' "$2" >"$(backup_data_dir)/settings"
          printf '快照保留数量已设置为：%s\n' "$2"
        fi
      else
        error "用法：vps-guard backup retention [1-100]"
        return "$EXIT_USAGE"
      fi
      ;;
    *)
      error "用法：vps-guard backup <create|list|diff|restore|retention>"
      return "$EXIT_USAGE"
      ;;
  esac
}
