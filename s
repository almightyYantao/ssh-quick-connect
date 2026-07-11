#!/usr/bin/env bash
# s — 极简 SSH 连接管理器（基于标准 ~/.ssh/config）
#
#   s                         交互选择器：直接打机器名/IP 模糊搜索连，或选 ▸分组 浏览（fzf）
#   s <别名>                  连接（自动判断密钥/密码登录）
#   s add                     交互式添加一台主机（支持密钥 / 密码）
#   s add <别名> <user@host> [-p PORT] [-i KEYFILE] [--pass] [-d "描述"] [-g 组]
#   s rm <别名>               删除一台主机（含 Keychain 里的密码）
#   s set <别名/通配符> host|user|port|group|desc <值>   改字段（支持 lbc-* 批量）
#   s desc <别名/通配符> [描述…]   设置/修改描述（留空则清除；支持批量）
#   s group <别名/通配符> [组名]   设置/修改分组（留空则移出；支持 lbc-* 批量）
#   s root <别名> [on|off]    开/关"登录后自动 sudo -i 切 root"（缺省=toggle）
#   s passwd <别名>           修改密码登录主机在 Keychain 里的密码
#   s put [-r] <本地…> <别名:路径>      上传文件（密码机自动走 sshpass）
#   s get [-r] <别名:路径> <本地>       下载文件
#   s ping [别名/通配符…]     TCP 连通性检查；不带参数=全部，如 s ping lbc-* fn
#   s pick                    fzf 模糊选机并连接
#   s fwd <别名> <spec…>      端口转发，如 s fwd it-clickhouse-hk-01 8123
#   s run <选择器> <命令…>    批量执行，如 s run 'it-iai-*' 'uptime'
#   s ls                      列出所有主机（按分组分区显示）
#   s edit                    用 $EDITOR 打开 ~/.ssh/config
#   s cp <别名>               把本机公钥拷到该主机（把密码登录升级成免密）
#   s export [文件]           把所有主机+密码打成加密备份包（默认 ~/s-backup.enc）
#   s import <文件>           在新机器上解密恢复（已存在的别名跳过，不覆盖）
#
# 说明：
#   - 别名直接写进 ~/.ssh/config，所以原生 `ssh <别名>` 也能用。
#   - 密码登录的密码存进 macOS Keychain（service=ssh-s-tool），不落明文；连接时用 sshpass 喂入。
#   - 密码标记：Host 块里加一行 `  #s-auth password`（ssh 会忽略 # 开头的行）。

set -euo pipefail

CONFIG="$HOME/.ssh/config"
KC_SERVICE="ssh-s-tool"

# ---- 颜色 ----
if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
  # 霓虹真彩（HUD 科技感）：CY 青 / GN 绿 / AM 琥珀 / MG 品红 / RU 分隔线灰
  CY=$'\033[38;2;60;235;235m'; GN=$'\033[38;2;120;245;150m'
  AM=$'\033[38;2;245;190;90m'; MG=$'\033[38;2;255;90;170m'
  RU=$'\033[38;2;70;95;110m'
else
  B=""; G=""; Y=""; C=""; R=""; D=""; N=""
  CY=""; GN=""; AM=""; MG=""; RU=""
fi
err()  { printf "%s✗%s %s\n" "$R" "$N" "$*" >&2; }
info() { printf "%s•%s %s\n" "$C" "$N" "$*"; }

# 终端显示宽度（ASCII=1，中文=2）。原理：纯 ASCII+3字节中文时 宽度=(字符数+字节数)/2
dwidth() { local s="$1" c b; c=${#s}; local LC_ALL=C; b=${#s}; echo $(( (c + b) / 2 )); }
# 把字符串按显示宽度右补空格；$1=串 $2=目标宽度
pad() { local s="$1" w="$2" n; n=$(( w - $(dwidth "$s") )); (( n < 0 )) && n=0; printf "%s%*s" "$s" "$n" ""; }

ensure_config() {
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh" 2>/dev/null || true
  [ -f "$CONFIG" ] || { : >"$CONFIG"; }
  chmod 600 "$CONFIG" 2>/dev/null || true
}

# 该别名是否已存在（精确匹配 Host 行的第一个 token）
host_exists() { # $1=alias
  awk -v a="$1" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      for (i=2;i<=NF;i++) if ($i==a) { found=1; exit }
    }
    END { exit(found?0:1) }
  ' "$CONFIG" 2>/dev/null
}

# 取某别名某字段（HostName/User/Port），大小写不敏感
host_field() { # $1=alias $2=field
  awk -v a="$1" -v f="$2" '
    BEGIN { fl=tolower(f) }
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      inblk=0
      for (i=2;i<=NF;i++) if ($i==a) inblk=1
      next
    }
    inblk && tolower($1)==fl { print $2; exit }
  ' "$CONFIG" 2>/dev/null
}

# 该别名是否标记为密码登录
is_password_auth() { # $1=alias
  awk -v a="$1" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      inblk=0
      for (i=2;i<=NF;i++) if ($i==a) inblk=1
      next
    }
    inblk && $1=="#s-auth" && $2=="password" { found=1; exit }
    END { exit(found?0:1) }
  ' "$CONFIG" 2>/dev/null
}

# 该别名是否标记为"登录后自动 sudo -i"
is_auto_root() { # $1=alias
  awk -v a="$1" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      inblk=0
      for (i=2;i<=NF;i++) if ($i==a) inblk=1
      next
    }
    inblk && $1=="#s-root" && $2=="yes" { found=1; exit }
    END { exit(found?0:1) }
  ' "$CONFIG" 2>/dev/null
}

# 取某别名的描述（可能为空）
host_desc() { # $1=alias
  awk -v a="$1" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      inblk=0
      for (i=2;i<=NF;i++) if ($i==a) inblk=1
      next
    }
    inblk && $1=="#s-desc" {
      line=$0; sub(/^[[:space:]]*#s-desc[[:space:]]*/,"",line); print line; exit
    }
  ' "$CONFIG" 2>/dev/null
}

# 取某别名的分组（可能为空）
host_group() { # $1=alias
  awk -v a="$1" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      inblk=0
      for (i=2;i<=NF;i++) if ($i==a) inblk=1
      next
    }
    inblk && $1=="#s-group" {
      line=$0; sub(/^[[:space:]]*#s-group[[:space:]]*/,"",line); print line; exit
    }
  ' "$CONFIG" 2>/dev/null
}

# ---- Keychain ----
kc_set() { security add-generic-password -U -s "$KC_SERVICE" -a "$1" -w "$2" >/dev/null 2>&1; }
kc_get() { security find-generic-password -s "$KC_SERVICE" -a "$1" -w 2>/dev/null || true; }
kc_del() { security delete-generic-password -s "$KC_SERVICE" -a "$1" >/dev/null 2>&1 || true; }

# 打印单台主机的表格行（$1=别名）
print_host_row() {
  local alias="$1" local_host user port desc acolor aname roottag
  local_host="$(host_field "$alias" HostName)"; [ -z "$local_host" ] && local_host="$alias"
  user="$(host_field "$alias" User)"; [ -z "$user" ] && user="(默认)"
  port="$(host_field "$alias" Port)"; [ -z "$port" ] && port="22"
  desc="$(host_desc "$alias")"
  if is_password_auth "$alias"; then acolor="$Y"; aname="密码"; else acolor="$G"; aname="密钥"; fi
  roottag=""
  is_auto_root "$alias" && roottag="${G}⇒root${N} "
  printf "%s%s%s %s %s %s%s%s %b%s%s%s\n" \
    "$C" "$(pad "$alias" 20)" "$N" \
    "$(pad "${user}@${local_host}" 24)" \
    "$(pad "$port" 6)" \
    "$acolor" "$(pad "$aname" 6)" "$N" \
    "$roottag" "$D" "$desc" "$N"
}

# 按出现顺序列出所有分组（无分组的主机归到末尾的“未分组”）
all_groups() {
  local a g
  # 显式分组，按首次出现顺序去重
  # 注意：本循环是管道左侧，循环体末句不能以求值为假的命令收尾，
  # 否则 while 子 shell 退出码=1，配合 pipefail+set -e 会误杀整个函数，故用 if。
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    g="$(host_group "$a")"
    if [ -n "$g" ]; then echo "$g"; fi
  done < <(all_aliases) | awk '!seen[$0]++'
  # 只要有一台没分组，就把“未分组”放最后（管道会开子 shell，故单独判断）
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    [ -z "$(host_group "$a")" ] && { echo "未分组"; break; }
  done < <(all_aliases)
}

cmd_list() {
  ensure_config
  if ! grep -qE '^[[:space:]]*[Hh]ost[[:space:]]' "$CONFIG" 2>/dev/null; then
    info "还没有任何主机，用 ${B}s add${N} 添加一台。"
    return 0
  fi
  local header
  header="$(printf "%s%s %s %s %s %s%s" "$B" \
    "$(pad 别名 20)" "$(pad 目标 24)" "$(pad 端口 6)" "$(pad 登录 6)" "描述" "$N")"
  local g a hg first=1
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    printf "\n%s%s▊ %s%s\n" "$B" "$C" "$g" "$N"
    printf "%s\n" "$header"
    while IFS= read -r a; do
      [ -z "$a" ] && continue
      hg="$(host_group "$a")"; [ -z "$hg" ] && hg="未分组"
      [ "$hg" = "$g" ] && print_host_row "$a"
    done < <(all_aliases)
  done < <(all_groups)
}

cmd_connect() { # $1=alias, 其余透传给 ssh
  ensure_config
  local alias="$1"; shift || true
  if ! host_exists "$alias"; then
    err "未找到别名：${alias}（用 ${B}s${N} 查看全部，或 ${B}s add${N} 添加）"
    exit 1
  fi
  # 登录后是否自动 sudo -i 切 root（仅在不带额外命令时生效）
  local auto_root=0
  is_auto_root "$alias" && [ $# -eq 0 ] && auto_root=1

  if is_password_auth "$alias"; then
    local pw; pw="$(kc_get "$alias")"
    if [ -z "$pw" ]; then
      err "别名 $alias 标记为密码登录，但 Keychain 里没有密码。用 ${B}s rm $alias${N} 后重新 ${B}s add${N}。"
      exit 1
    fi
    # accept-new：首次连接自动接受新主机密钥（sshpass 无法回答交互提示，否则会以退出码 6 秒退）；
    # 主机密钥若变更仍会拒绝，安全性可接受。
    local sshopts=(-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new)
    if [ "$auto_root" = 1 ]; then
      # 用同一个密码喂给 sudo（base64 传输，避开特殊字符/引号问题）；
      # sudo -v 缓存凭据后再 exec sudo -i 进交互 root shell；喂密码失败则回退为手动输入。
      local b64; b64="$(printf '%s' "$pw" | base64 | tr -d '\n')"
      exec env SSHPASS="$pw" sshpass -e ssh "${sshopts[@]}" -t "$alias" \
        "echo $b64 | base64 -d 2>/dev/null | sudo -S -v 2>/dev/null; exec sudo -i"
    elif [ $# -eq 0 ]; then
      # 交互式登录：sshpass 下必须显式 -t，否则远端不分配伪终端、shell 秒退
      exec env SSHPASS="$pw" sshpass -e ssh "${sshopts[@]}" -t "$alias"
    else
      exec env SSHPASS="$pw" sshpass -e ssh "${sshopts[@]}" "$alias" "$@"
    fi
  else
    if [ "$auto_root" = 1 ]; then
      exec ssh -t "$alias" sudo -i
    else
      exec ssh "$alias" "$@"
    fi
  fi
}

# 追加一个 Host 块到 config
append_host() { # alias host user port keyfile is_pass desc auto_root group
  local alias="$1" host="$2" user="$3" port="$4" keyfile="$5" is_pass="$6" desc="${7:-}" auto_root="${8:-0}" group="${9:-}"
  {
    printf "\nHost %s\n" "$alias"
    [ -n "$group" ] && printf "  #s-group %s\n" "$group"
    [ -n "$desc" ] && printf "  #s-desc %s\n" "$desc"
    [ "$auto_root" = "1" ] && printf "  #s-root yes\n"
    printf "  HostName %s\n" "$host"
    [ -n "$user" ] && printf "  User %s\n" "$user"
    [ -n "$port" ] && [ "$port" != "22" ] && printf "  Port %s\n" "$port"
    if [ "$is_pass" = "1" ]; then
      printf "  #s-auth password\n"
    elif [ -n "$keyfile" ]; then
      printf "  IdentityFile %s\n" "$keyfile"
      printf "  IdentitiesOnly yes\n"
    fi
  } >>"$CONFIG"
  chmod 600 "$CONFIG" 2>/dev/null || true
}

cmd_add() {
  ensure_config
  local alias="" target="" user="" host="" port="22" keyfile="" is_pass=0 desc="" auto_root=0 group=""

  # 非交互：s add <别名> <user@host> [-p PORT] [-i KEY] [--pass] [-d "描述"] [-g 组]
  if [ $# -ge 2 ]; then
    alias="$1"; target="$2"; shift 2
    if [[ "$target" == *@* ]]; then user="${target%@*}"; host="${target#*@}"; else host="$target"; fi
    while [ $# -gt 0 ]; do
      case "$1" in
        -p|--port) port="$2"; shift 2 ;;
        -i|--identity) keyfile="$2"; shift 2 ;;
        --pass|--password) is_pass=1; shift ;;
        -d|--desc|--description) desc="$2"; shift 2 ;;
        -g|--group) group="$2"; shift 2 ;;
        --root) auto_root=1; shift ;;
        *) err "未知参数: $1"; exit 1 ;;
      esac
    done
  else
    # 交互式
    printf "%s别名%s (连接时敲的短名，如 hz / db1): " "$B" "$N"; read -r alias
    [ -z "$alias" ] && { err "别名不能为空"; exit 1; }
    printf "%s主机%s (IP 或域名): " "$B" "$N"; read -r host
    [ -z "$host" ] && { err "主机不能为空"; exit 1; }
    printf "%s用户%s [root]: " "$B" "$N"; read -r user; [ -z "$user" ] && user="root"
    printf "%s端口%s [22]: " "$B" "$N"; read -r port; [ -z "$port" ] && port="22"
    printf "%s分组%s (可留空，如 生产/测试/香港): " "$B" "$N"; read -r group
    printf "%s描述%s (可留空): " "$B" "$N"; read -r desc
    printf "%s登录方式%s  1) 密钥(默认)  2) 密码 : " "$B" "$N"; read -r m
    if [ "$m" = "2" ]; then
      is_pass=1
    else
      printf "%s指定私钥%s (留空=用默认 ~/.ssh/id_*): " "$B" "$N"; read -r keyfile
    fi
    printf "%s登录后自动 sudo -i 切 root?%s [y/N]: " "$B" "$N"; read -r r
    [[ "$r" =~ ^[Yy] ]] && auto_root=1
  fi

  if host_exists "$alias"; then
    err "别名 $alias 已存在。先 ${B}s rm $alias${N} 再加，或换个别名。"
    exit 1
  fi

  local pw=""
  if [ "$is_pass" = "1" ]; then
    printf "%s密码%s (输入时不显示): " "$B" "$N"
    read -rs pw; echo
    [ -z "$pw" ] && { err "密码不能为空"; exit 1; }
  fi

  append_host "$alias" "$host" "$user" "$port" "$keyfile" "$is_pass" "$desc" "$auto_root" "$group"
  [ "$is_pass" = "1" ] && kc_set "$alias" "$pw"

  echo
  if [ "$is_pass" = "1" ]; then
    printf "%s✓%s 已添加 %s%s%s（密码登录，密码存于 Keychain）\n" "$G" "$N" "$C" "$alias" "$N"
  else
    printf "%s✓%s 已添加 %s%s%s（密钥登录）\n" "$G" "$N" "$C" "$alias" "$N"
  fi
  printf "  现在可以：%ss %s%s\n" "$B" "$alias" "$N"
}

cmd_rm() {
  ensure_config
  local alias="${1:-}"
  [ -z "$alias" ] && { err "用法：s rm <别名>"; exit 1; }
  if ! host_exists "$alias"; then err "未找到别名：$alias"; exit 1; fi

  local tmp; tmp="$(mktemp)"
  # 删除从 `Host <alias>`（且该行只有这一个别名）到下一个 Host 行/EOF 之间的块
  awk -v a="$alias" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      drop=0
      if (NF==2 && $2==a) drop=1
    }
    !drop { print }
  ' "$CONFIG" >"$tmp"
  # 收拾多余空行
  awk 'NF||p{print} {p=NF}' "$tmp" >"$CONFIG"
  rm -f "$tmp"
  chmod 600 "$CONFIG" 2>/dev/null || true

  kc_del "$alias"
  printf "%s✓%s 已删除 %s%s%s\n" "$G" "$N" "$C" "$alias" "$N"
}

cmd_cp() { # 把公钥拷到主机，升级为免密
  ensure_config
  local alias="${1:-}"
  [ -z "$alias" ] && { err "用法：s cp <别名>"; exit 1; }
  if ! host_exists "$alias"; then err "未找到别名：$alias"; exit 1; fi
  if is_password_auth "$alias"; then
    local pw; pw="$(kc_get "$alias")"
    info "用密码把公钥拷到 $alias …"
    env SSHPASS="$pw" sshpass -e ssh-copy-id \
      -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "$alias"
    info "拷贝完成。如需从此免密，可 ${B}s edit${N} 删掉该主机的 ${B}#s-auth password${N} 行（并保留 IdentityFile）。"
  else
    ssh-copy-id "$alias"
  fi
}

cmd_passwd() { # 更新某别名在 Keychain 里的密码
  ensure_config
  local alias="${1:-}"
  [ -z "$alias" ] && { err "用法：s passwd <别名>"; exit 1; }
  if ! host_exists "$alias"; then err "未找到别名：$alias"; exit 1; fi
  if ! is_password_auth "$alias"; then
    err "$alias 不是密码登录的主机（没有 #s-auth password 标记）。"
    exit 1
  fi
  local pw; printf "%s新密码%s (输入时不显示): " "$B" "$N"; read -rs pw; echo
  [ -z "$pw" ] && { err "密码不能为空"; exit 1; }
  kc_set "$alias" "$pw"
  printf "%s✓%s 已更新 %s%s%s 的密码\n" "$G" "$N" "$C" "$alias" "$N"
}

cmd_desc() { # 设置/修改/清除描述：s desc <别名/通配符> [描述…]（支持 lbc-* 或 a,b,c 批量）
  ensure_config
  local sel="${1:-}"; shift || true
  [ -z "$sel" ] && { err "用法：s desc <别名/通配符> <描述>（描述留空则清除）"; exit 1; }
  local desc="$*"
  local -a targets=(); local a
  while IFS= read -r a; do [ -n "$a" ] && targets+=("$a"); done < <(expand_selector "$sel")
  [ ${#targets[@]} -eq 0 ] && exit 1   # expand_aliases 已逐个报过"没有匹配"，此处静默退出
  local tmp alias
  for alias in "${targets[@]}"; do
    tmp="$(mktemp)"
    awk -v a="$alias" -v d="$desc" '
      /^[[:space:]]*[Hh]ost[[:space:]]/ {
        intgt = (NF==2 && $2==a) ? 1 : 0
        print
        if (intgt && d!="") print "  #s-desc " d
        next
      }
      intgt && $1=="#s-desc" { next }   # 丢掉目标块里的旧描述行
      { print }
    ' "$CONFIG" >"$tmp"
    mv "$tmp" "$CONFIG"
    if [ -n "$desc" ]; then
      printf "%s✓%s %s%s%s 的描述：%s\n" "$G" "$N" "$C" "$alias" "$N" "$desc"
    else
      printf "%s✓%s 已清除 %s%s%s 的描述\n" "$G" "$N" "$C" "$alias" "$N"
    fi
  done
  chmod 600 "$CONFIG" 2>/dev/null || true
}

cmd_group() { # 设置/修改/清除分组：s group <别名/通配符> [组名]（支持 lbc-* 或 a,b,c 批量）
  ensure_config
  local sel="${1:-}"; shift || true
  [ -z "$sel" ] && { err "用法：s group <别名/通配符> <组名>（组名留空则移出分组）"; exit 1; }
  local group="$*"
  local -a targets=(); local a
  while IFS= read -r a; do [ -n "$a" ] && targets+=("$a"); done < <(expand_selector "$sel")
  [ ${#targets[@]} -eq 0 ] && exit 1   # expand_aliases 已逐个报过"没有匹配"，此处静默退出
  local tmp alias
  for alias in "${targets[@]}"; do
    tmp="$(mktemp)"
    awk -v a="$alias" -v g="$group" '
      /^[[:space:]]*[Hh]ost[[:space:]]/ {
        intgt = (NF==2 && $2==a) ? 1 : 0
        print
        if (intgt && g!="") print "  #s-group " g
        next
      }
      intgt && $1=="#s-group" { next }   # 丢掉目标块里的旧分组行
      { print }
    ' "$CONFIG" >"$tmp"
    mv "$tmp" "$CONFIG"
    if [ -n "$group" ]; then
      printf "%s✓%s %s%s%s 归入分组：%s\n" "$G" "$N" "$C" "$alias" "$N" "$group"
    else
      printf "%s✓%s 已把 %s%s%s 移出分组\n" "$G" "$N" "$C" "$alias" "$N"
    fi
  done
  chmod 600 "$CONFIG" 2>/dev/null || true
}

cmd_root() { # 开/关"登录后自动 sudo -i"：s root <别名> [on|off]，缺省=toggle
  ensure_config
  local alias="${1:-}" want="${2:-}"
  [ -z "$alias" ] && { err "用法：s root <别名> [on|off]"; exit 1; }
  if ! host_exists "$alias"; then err "未找到别名：$alias"; exit 1; fi
  local on=0
  case "$want" in
    on|yes|1)  on=1 ;;
    off|no|0)  on=0 ;;
    "")        if is_auto_root "$alias"; then on=0; else on=1; fi ;;  # toggle
    *) err "参数只能是 on / off"; exit 1 ;;
  esac
  local tmp; tmp="$(mktemp)"
  awk -v a="$alias" -v on="$on" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      intgt = (NF==2 && $2==a) ? 1 : 0
      print
      if (intgt && on=="1") print "  #s-root yes"
      next
    }
    intgt && $1=="#s-root" { next }   # 丢掉目标块里的旧标记
    { print }
  ' "$CONFIG" >"$tmp"
  mv "$tmp" "$CONFIG"; chmod 600 "$CONFIG" 2>/dev/null || true
  if [ "$on" = "1" ]; then
    printf "%s✓%s %s%s%s 登录后将自动 %ssudo -i%s 切 root\n" "$G" "$N" "$C" "$alias" "$N" "$B" "$N"
  else
    printf "%s✓%s %s%s%s 已关闭自动 sudo -i\n" "$G" "$N" "$C" "$alias" "$N"
  fi
}

# scp 传输：自动识别参数里的 <别名>:路径，密码机走 sshpass，密钥机走原生 scp
# 用法：s put [-r] <本地…> <别名:远程路径>   /   s get [-r] <别名:远程路径> <本地>
cmd_scp() {
  ensure_config
  [ $# -lt 2 ] && { err "用法：s put <本地…> <别名:路径>  或  s get <别名:路径> <本地>"; exit 1; }
  local a cand host_alias=""
  for a in "$@"; do
    if [[ "$a" == *:* ]]; then
      cand="${a%%:*}"
      if host_exists "$cand"; then host_alias="$cand"; break; fi
    fi
  done
  [ -z "$host_alias" ] && { err "参数里没找到已知别名（格式应为 别名:远程路径）"; exit 1; }
  if is_password_auth "$host_alias"; then
    local pw; pw="$(kc_get "$host_alias")"
    [ -z "$pw" ] && { err "$host_alias 是密码登录但 Keychain 无密码"; exit 1; }
    exec env SSHPASS="$pw" sshpass -e scp \
      -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "$@"
  else
    exec scp "$@"
  fi
}

# 修改字段：s set <别名/通配符> <host|user|port|group|desc> <值>（支持 lbc-* 或 a,b,c 批量）
cmd_set() {
  ensure_config
  local sel="${1:-}" field="${2:-}"; shift 2 2>/dev/null || true
  local value="$*"
  [ -z "$sel" ] || [ -z "$field" ] || [ -z "$value" ] && { err "用法：s set <别名/通配符> <host|user|port|group|desc> <值>"; exit 1; }
  # group/desc 本质是注释标记，直接复用现成命令（它们自己会展开选择器）
  case "$field" in
    group|grp|组)   cmd_group "$sel" "$value"; return ;;
    desc|描述|note) cmd_desc "$sel" "$value"; return ;;
  esac
  local directive
  case "$field" in
    host|hostname|ip|HostName) directive="HostName" ;;
    user|User)                 directive="User" ;;
    port|Port)                 directive="Port" ;;
    *) err "字段只能是 host / user / port / group / desc"; exit 1 ;;
  esac
  local -a targets=(); local a
  while IFS= read -r a; do [ -n "$a" ] && targets+=("$a"); done < <(expand_selector "$sel")
  [ ${#targets[@]} -eq 0 ] && exit 1   # expand_aliases 已逐个报过"没有匹配"，此处静默退出
  local tmp alias
  for alias in "${targets[@]}"; do
    tmp="$(mktemp)"
    awk -v a="$alias" -v d="$directive" -v v="$value" '
      BEGIN { dl=tolower(d) }
      /^[[:space:]]*[Hh]ost[[:space:]]/ {
        intgt = (NF==2 && $2==a) ? 1 : 0
        print
        if (intgt) print "  " d " " v
        next
      }
      intgt && tolower($1)==dl { next }   # 丢掉目标块里的旧值
      { print }
    ' "$CONFIG" >"$tmp"
    mv "$tmp" "$CONFIG"
    printf "%s✓%s %s%s%s 的 %s 已设为 %s\n" "$G" "$N" "$C" "$alias" "$N" "$directive" "$value"
  done
  chmod 600 "$CONFIG" 2>/dev/null || true
}

# 所有别名（一行一个）
all_aliases() {
  awk '/^[[:space:]]*[Hh]ost[[:space:]]/ { for (i=2;i<=NF;i++) print $i }' "$CONFIG" 2>/dev/null | grep -vE '[*?]'
}

# 把参数（别名或通配符如 lbc-*）展开成实际别名列表；无参数=全部
expand_aliases() {
  local -a out=(); local pat alias matched
  if [ $# -eq 0 ]; then all_aliases; return 0; fi
  for pat in "$@"; do
    matched=0
    while IFS= read -r alias; do
      [ -z "$alias" ] && continue
      case "$alias" in $pat) out+=("$alias"); matched=1 ;; esac
    done < <(all_aliases)
    [ "$matched" = 0 ] && err "没有匹配的别名：$pat"
  done
  # 去重并保持顺序（空数组在 bash3.2+set -u 下要用 +扩展 兜底）
  [ ${#out[@]} -eq 0 ] && return 0
  printf "%s\n" "${out[@]}" | awk '!seen[$0]++'
}

# 把选择器（支持通配符 lbc-* 和逗号 a,b,c）展开成实际别名列表（逐行）
expand_selector() { # $1=选择器
  local -a pats=(); local IFS_OLD="$IFS"; IFS=','; read -ra pats <<< "$1"; IFS="$IFS_OLD"
  expand_aliases "${pats[@]}"
}

# 连通性检查：s ping [别名/通配符…]（不带参数=全部）
cmd_ping() {
  ensure_config
  local -a targets=()
  while IFS= read -r a; do [ -n "$a" ] && targets+=("$a"); done < <(expand_aliases "$@")
  [ ${#targets[@]} -eq 0 ] && { err "没有可检查的主机"; exit 1; }
  printf "%s%s %s %s%s\n" "$B" "$(pad 别名 20)" "$(pad 目标 26)" "状态" "$N"
  local alias local_host port st
  for alias in "${targets[@]}"; do
    local_host="$(host_field "$alias" HostName)"; [ -z "$local_host" ] && local_host="$alias"
    port="$(host_field "$alias" Port)"; [ -z "$port" ] && port="22"
    if nc -z -G 3 "$local_host" "$port" >/dev/null 2>&1; then
      st="${G}● 在线${N}"
    else
      st="${R}○ 离线${N}"
    fi
    printf "%s%s%s %s %b\n" "$C" "$(pad "$alias" 20)" "$N" "$(pad "${local_host}:${port}" 26)" "$st"
  done
}

# fzf 模糊选机并连接：s pick
cmd_pick() {
  ensure_config
  command -v fzf >/dev/null 2>&1 || { err "未安装 fzf（brew install fzf）"; exit 1; }
  local line alias
  line="$(all_aliases | while IFS= read -r a; do
      [ -z "$a" ] && continue
      printf "%s\t%s@%s\t%s\n" "$a" "$(host_field "$a" User)" "$(host_field "$a" HostName)" "$(host_desc "$a")"
    done | column -t -s $'\t' | fzf --height=40% --reverse --prompt='ssh> ' --header='选机器回车连接（Esc 取消）' || true)"
  [ -z "$line" ] && exit 0
  alias="${line%% *}"
  cmd_connect "$alias"
}

# 列出某分组下的别名（$1="全部主机"=全部；"未分组"=没有分组标记的；其它=该组）
hosts_in_group() {
  local want="$1" a g
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    if [ "$want" = "全部主机" ]; then echo "$a"; continue; fi
    g="$(host_group "$a")"; [ -z "$g" ] && g="未分组"
    if [ "$g" = "$want" ]; then echo "$a"; fi   # 用 if：本函数常作管道左侧，见 all_groups 注释
  done < <(all_aliases)
}

# 统一的 fzf 样式（无边框/无分隔线，尽量清爽；青色指针+高亮）
_FZF() {
  # 高度约 24 行（含提示/表头）≈ 一页 20 台，多了自动滚动翻页；霓虹 HUD 配色
  fzf --ansi --layout=reverse --height=24 --scroll-off=2 \
      --no-separator --border=none --info=inline \
      --pointer='▶' --prompt='◤ ' \
      --color='bg:-1,bg+:-1,fg:#8aa0aa,fg+:#e8fbff,hl:#7ef28a,hl+:#39ff14,pointer:#38ebeb,prompt:#38ebeb,marker:#ff5aaa,info:#4a5560,header:#4a5560,gutter:-1' \
      "$@"
}

# 机器行（缩进挂在分组标题下）。别名霓虹着色（青=密钥/琥珀=密码），目标灰，描述更暗。
# 不加行首符号，避免整列连成竖条。
menu_host_row() {
  local a="$1" u h d ac
  u="$(host_field "$a" User)"; [ -z "$u" ] && u="(默认)"
  h="$(host_field "$a" HostName)"; [ -z "$h" ] && h="$a"
  d="$(host_desc "$a")"
  if is_password_auth "$a"; then ac="$AM"; else ac="$CY"; fi
  printf 'H\t%s\t    %s%s%s %s%s%s %s%s%s\n' \
    "$a" "$ac" "$(pad "$a" 18)" "$N" "$RU" "$(pad "${u}@${h}" 26)" "$N" "$D" "$d" "$N"
}

# 分组标题行（HUD 风）：大写霓虹组名 + 横向填充线 ── 补到定宽 + 暗色台数。
# 横线是水平的，不会像竖条那样碍眼。
menu_group_header() {
  local g="$1" cnt name w rule
  cnt="$(hosts_in_group "$g" | grep -c . || true)"
  name="$(printf '%s' "$g" | tr '[:lower:]' '[:upper:]')"
  w=$(( 44 - $(dwidth "$name") )); (( w < 2 )) && w=2
  rule="$(printf '%*s' "$w" '' | tr ' ' '─')"
  printf 'G\t%s\t%s%s%s %s%s%s %s%s台%s\n' \
    "$g" "$B$CY" "$name" "$N" "$RU" "$rule" "$N" "$D" "$cnt" "$N"
}

# 展开的分组树：分组标题 + 缩进机器，全部显示（供 fzf 模糊过滤/滚动翻页）
menu_tree() {
  local g a
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    menu_group_header "$g"
    while IFS= read -r a; do
      [ -z "$a" ] && continue
      menu_host_row "$a"
    done < <(hosts_in_group "$g")
  done < <(all_groups)
}

# 从 fzf 选中的一行里取出别名（第 2 个 tab 字段）
_sel_alias() { local s="${1#*$'\t'}"; printf '%s' "${s%%$'\t'*}"; }

# 交互选择入口（裸 s）：展开的分组树，全部显示；打字模糊过滤，↑↓/PgUp·PgDn 翻页。
# 回车落在机器上=直接连；落在分组标题上=只看该组（Esc 返回）。窗口高度受限，超出即滚动。
cmd_menu() {
  ensure_config
  if ! grep -qE '^[[:space:]]*[Hh]ost[[:space:]]' "$CONFIG" 2>/dev/null; then
    info "还没有任何主机，用 ${B}s add${N} 添加一台。"; return 0
  fi
  # 没有 fzf 或非交互终端时，退回普通列表
  if ! command -v fzf >/dev/null 2>&1 || [ ! -t 0 ] || [ ! -t 1 ]; then
    cmd_list; return 0
  fi
  local sel type key alias
  while true; do
    clear
    sel="$( menu_tree | _FZF --delimiter='\t' --with-nth=3.. \
              --header='⌁ 打字 过滤　↵ 连接/展开　⇅ PgDn 翻页　⎋ 退出' \
              || true )"
    [ -z "$sel" ] && exit 0
    type="${sel%%$'\t'*}"; key="$(_sel_alias "$sel")"
    if [ "$type" = "H" ]; then
      cmd_connect "$key"; break
    fi
    # 回车落在分组标题 → 只看该组机器（Esc 返回）
    sel="$( while IFS= read -r a; do [ -n "$a" ] && menu_host_row "$a"; done < <(hosts_in_group "$key") \
            | _FZF --delimiter='\t' --with-nth=3.. --prompt="◤ ${key} ▶ " \
                   --header='↵ 连接　⎋ 返回上一层' || true )"
    [ -z "$sel" ] && continue
    cmd_connect "$(_sel_alias "$sel")"; break
  done
}

# 端口转发：s fwd <别名> <spec…>；spec = 本地:远端主机:远端口，或简写 端口(=端口:localhost:端口)
cmd_fwd() {
  ensure_config
  local alias="${1:-}"; shift || true
  [ -z "$alias" ] && { err "用法：s fwd <别名> <本地端口|本地:远端主机:远端口> …"; exit 1; }
  if ! host_exists "$alias"; then err "未找到别名：$alias"; exit 1; fi
  [ $# -eq 0 ] && { err "至少给一个转发规则，如 8123 或 15432:10.0.0.5:5432"; exit 1; }
  local spec; local -a lopts=()
  for spec in "$@"; do
    case "$spec" in
      *:*:*) lopts+=(-L "$spec") ;;                    # 完整 本地:主机:远端口
      *:*)   lopts+=(-L "$spec") ;;                    # 本地:远端口（ssh 会补 localhost）
      *)     lopts+=(-L "$spec:localhost:$spec") ;;    # 简写：同号端口
    esac
  done
  info "隧道建立中（${alias}）：$* —— 保持此窗口，${B}Ctrl-C${N} 断开"
  if is_password_auth "$alias"; then
    local pw; pw="$(kc_get "$alias")"
    exec env SSHPASS="$pw" sshpass -e ssh -N \
      -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
      "${lopts[@]}" "$alias"
  else
    exec ssh -N "${lopts[@]}" "$alias"
  fi
}

# 批量执行：s run <选择器> <命令…>；选择器可逗号分隔多个别名/通配符
cmd_run() {
  ensure_config
  local sel="${1:-}"; shift || true
  [ -z "$sel" ] || [ $# -eq 0 ] && { err "用法：s run <别名/通配符[,…]> <命令…>，如 s run 'lbc-*' uptime"; exit 1; }
  local cmd="$*"
  # 逗号切成多个 pattern
  local -a pats=(); local IFS_OLD="$IFS"; IFS=','; read -ra pats <<< "$sel"; IFS="$IFS_OLD"
  local -a targets=()
  while IFS= read -r a; do [ -n "$a" ] && targets+=("$a"); done < <(expand_aliases "${pats[@]}")
  [ ${#targets[@]} -eq 0 ] && { err "没有可执行的主机"; exit 1; }
  local alias ok=0 fail=0 rc
  for alias in "${targets[@]}"; do
    printf "\n%s%s─── %s ───%s\n" "$B" "$C" "$alias" "$N"
    rc=0
    if is_password_auth "$alias"; then
      local pw; pw="$(kc_get "$alias")"
      if env SSHPASS="$pw" sshpass -e ssh \
        -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
        -o ConnectTimeout=10 "$alias" "$cmd"; then rc=0; else rc=$?; fi
    else
      if ssh -o BatchMode=yes -o ConnectTimeout=10 "$alias" "$cmd"; then rc=0; else rc=$?; fi
    fi
    if [ "$rc" -eq 0 ]; then ok=$((ok+1)); else fail=$((fail+1)); printf "%s✗ %s 执行失败(退出码 %s)%s\n" "$R" "$alias" "$rc" "$N"; fi
  done
  printf "\n%s完成%s：%s成功 %d%s，%s失败 %d%s\n" "$B" "$N" "$G" "$ok" "$N" "$R" "$fail" "$N"
}

cmd_edit() { ensure_config; "${EDITOR:-vi}" "$CONFIG"; }

# 从指定文件里抽出某别名的完整 Host 块（$1=文件 $2=别名）
block_of() {
  awk -v a="$2" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      if (inblk) exit                       # 遇到下一个 Host 行就停
      inblk = (NF==2 && $2==a) ? 1 : 0
    }
    inblk { print }
  ' "$1" 2>/dev/null
}

# 列出某文件里所有非通配符别名（$1=文件）
aliases_of() {
  awk '/^[[:space:]]*[Hh]ost[[:space:]]/ { for (i=2;i<=NF;i++) print $i }' "$1" 2>/dev/null | grep -vE '[*?]'
}

# 读一个口令（可选二次确认）：结果写到全局 __PASS
read_pass() { # $1=提示 $2=confirm(1/0)
  local p1 p2
  printf "%s%s%s: " "$B" "$1" "$N" >&2; read -rs p1; echo >&2
  [ -z "$p1" ] && { err "口令不能为空"; exit 1; }
  if [ "${2:-0}" = "1" ]; then
    printf "%s再输一次确认%s: " "$B" "$N" >&2; read -rs p2; echo >&2
    [ "$p1" != "$p2" ] && { err "两次输入不一致"; exit 1; }
  fi
  __PASS="$p1"
}

# s export [文件]：把所有 s 管的主机块 + Keychain 密码打成一个加密备份包
cmd_export() {
  ensure_config
  local out="${1:-$HOME/s-backup.enc}"
  local plain; plain="$(mktemp)"
  local n_host=0 n_pass=0 alias pw
  {
    printf "#S-BACKUP v1\n"
    printf "#S-CONFIG-BEGIN\n"
    while IFS= read -r alias; do
      [ -z "$alias" ] && continue
      block_of "$CONFIG" "$alias"
      printf "\n"
      n_host=$((n_host+1))
    done < <(all_aliases)
    printf "#S-CONFIG-END\n"
    printf "#S-PASS-BEGIN\n"
    while IFS= read -r alias; do
      [ -z "$alias" ] && continue
      is_password_auth "$alias" || continue
      pw="$(kc_get "$alias")"
      [ -z "$pw" ] && continue
      printf "%s\t%s\n" "$alias" "$(printf '%s' "$pw" | base64 | tr -d '\n')"
      n_pass=$((n_pass+1))
    done < <(all_aliases)
    printf "#S-PASS-END\n"
  } >"$plain"

  if [ "$n_host" -eq 0 ]; then
    rm -f "$plain"; err "没有可导出的主机。"; exit 1
  fi

  local __PASS; read_pass "设置备份口令（恢复时要用，请记牢）" 1
  # 口令走进程替换的 fd，不进 argv / 环境变量
  if ! openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -in "$plain" -out "$out" -pass file:<(printf '%s' "$__PASS"); then
    rm -f "$plain"; err "加密失败。"; exit 1
  fi
  rm -f "$plain"
  chmod 600 "$out" 2>/dev/null || true
  printf "%s✓%s 已导出 %d 台主机（其中 %d 台含密码）→ %s%s%s\n" \
    "$G" "$N" "$n_host" "$n_pass" "$C" "$out" "$N"
  printf "  这个文件+口令=全部服务器凭据，请妥善保管。恢复：%ss import %s%s\n" "$B" "$out" "$N"
}

# s import <文件>：解密恢复主机块（已存在别名跳过）+ 写回 Keychain 密码
cmd_import() {
  ensure_config
  local in="${1:-}"
  [ -z "$in" ] && { err "用法：s import <备份文件>"; exit 1; }
  [ -f "$in" ] || { err "文件不存在：$in"; exit 1; }

  local __PASS; read_pass "输入备份口令" 0
  local plain; plain="$(mktemp)"
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -in "$in" -out "$plain" -pass file:<(printf '%s' "$__PASS") 2>/dev/null; then
    rm -f "$plain"; err "解密失败（口令错误或文件损坏）。"; exit 1
  fi
  if [ "$(head -1 "$plain")" != "#S-BACKUP v1" ]; then
    rm -f "$plain"; err "不是有效的 s 备份文件。"; exit 1
  fi

  # 拆出 config 段和 pass 段
  local cfg pass; cfg="$(mktemp)"; pass="$(mktemp)"
  awk '/^#S-CONFIG-BEGIN$/{c=1;next} /^#S-CONFIG-END$/{c=0} c' "$plain" >"$cfg"
  awk '/^#S-PASS-BEGIN$/{p=1;next} /^#S-PASS-END$/{p=0} p' "$plain" >"$pass"
  rm -f "$plain"

  local added=0 skipped=0 alias
  while IFS= read -r alias; do
    [ -z "$alias" ] && continue
    if host_exists "$alias"; then
      info "跳过已存在别名：$alias"; skipped=$((skipped+1)); continue
    fi
    { printf "\n"; block_of "$cfg" "$alias"; } >>"$CONFIG"
    added=$((added+1))
  done < <(aliases_of "$cfg")
  chmod 600 "$CONFIG" 2>/dev/null || true

  # 只给这次真正新增的别名写回密码（已存在的不动其 Keychain）
  local n_pw=0 b64 pw
  while IFS=$'\t' read -r alias b64; do
    [ -z "$alias" ] && continue
    host_exists "$alias" || continue
    is_password_auth "$alias" || continue
    kc_get "$alias" >/dev/null 2>&1 && continue   # 本机已有密码就不覆盖
    pw="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
    [ -z "$pw" ] && continue
    kc_set "$alias" "$pw"; n_pw=$((n_pw+1))
  done <"$pass"
  rm -f "$cfg" "$pass"

  printf "%s✓%s 导入完成：新增 %s%d%s 台，跳过 %d 台，写回密码 %d 条\n" \
    "$G" "$N" "$G" "$added" "$N" "$skipped" "$n_pw"
}

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    menu)      cmd_menu ;;
    ls|list)   cmd_list ;;
    add)       shift; cmd_add "$@" ;;
    rm|del|remove) shift; cmd_rm "$@" ;;
    cp|copy-id)    shift; cmd_cp "$@" ;;
    passwd|pw) shift; cmd_passwd "$@" ;;
    desc)      shift; cmd_desc "$@" ;;
    group|grp) shift; cmd_group "$@" ;;
    root)      shift; cmd_root "$@" ;;
    put|get|scp) shift; cmd_scp "$@" ;;
    set)       shift; cmd_set "$@" ;;
    ping)      shift; cmd_ping "$@" ;;
    pick|p)    cmd_pick ;;
    fwd|tunnel|forward) shift; cmd_fwd "$@" ;;
    run|exec)  shift; cmd_run "$@" ;;
    edit)      cmd_edit ;;
    export|backup)  shift; cmd_export "$@" ;;
    import|restore) shift; cmd_import "$@" ;;
    -h|--help|help) usage ;;
    "")        cmd_menu ;;
    *)         cmd_connect "$@" ;;  # 其它一律当别名连接
  esac
}
main "$@"
