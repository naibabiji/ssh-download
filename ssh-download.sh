#!/bin/bash
set -euo pipefail  # 严格模式，避免隐藏错误

# ==================== 配置常量（不可修改）====================
DEFAULT_PORT=22
DEFAULT_USER=root
DEFAULT_DEST="./downloads"
SSH_TIMEOUT=5  # SSH连接超时时间（秒）
# rsync核心参数：-a（归档模式，含-l：保留符号链接）、-v（详细输出）、-h（人类可读）等
RSYNC_OPTIONS=(-avh --progress --checksum --partial --inplace)
# SSH安全配置：accept-new自动接受新主机密钥，拒绝已变更密钥（兼顾安全与便捷）
SSH_COMMON_OPTIONS=(-q -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts")

# ==================== 全局变量 ====================
DOWNLOAD_STARTED=0  # 下载状态标记（防止中断时误删文件）

# ==================== 工具函数 ====================
# 颜色输出
info() { echo -e "\033[34mℹ $1\033[0m"; }
success() { echo -e "\033[32m✓ $1\033[0m"; }
warning() { echo -e "\033[33m⚠ $1\033[0m"; }
error() { echo -e "\033[31m✗ $1\033[0m"; exit 1; }

# 中断信号处理（Ctrl+C）
handle_interrupt() {
  echo -e "\n\033[33m⚠ 检测到用户中断（Ctrl+C）\033[0m";
  
  # 只在下载过程中删除不完整文件
  if [[ $DOWNLOAD_STARTED -eq 1 && -n ${DEST_FULL_PATH:-} && -e "$DEST_FULL_PATH" ]]; then
    info "正在清理不完整的下载文件...";
    rm -rf "$DEST_FULL_PATH";
  fi
  error "下载已取消";
}

# 退出脚本（支持q/Q退出）
exit_script() {
  info "用户取消操作，退出脚本";
  exit 0;
}

# 显示帮助信息
show_help() {
  echo -e "\033[32m===== 通用SSH文件/文件夹下载工具 - 帮助信息 =====\033[0m";
  echo "用法：$0 [选项]";
  echo "选项：";
  echo "  -h/--help  显示帮助信息并退出";
  echo -e "\n功能：";
  echo "  1. 支持断点续传（优先rsync，文件下载失败时用scp备选）";
  echo "  2. 支持文件/文件夹下载，自动校验完整性（大小+MD5）";
  echo "  3. 兼容密码/SSH密钥登录（支持带密码的密钥）";
  echo "  4. 安全SSH配置：自动接受新主机密钥，拒绝已变更密钥";
  echo -e "\n注意：";
  echo "  - 仅支持 IPv4 地址，不支持 IPv6";
  echo "  - 保存到系统目录（如/var、/www）需用 sudo 运行";
  echo "  - 路径含空格、单引号等特殊字符时，脚本会自动转义";
  echo "  - 按 Ctrl+C 中断时，脚本会自动清理残留文件";
  echo "  - 符号链接处理：默认不跟随（rsync -a 模式自带 -l 参数）";
  echo "    - 选择「跟随」时，用 -L 参数覆盖 -l，下载链接指向的真实内容";
  echo "  - scp 备选限制：不支持保留符号链接本身，会自动跟随链接下载内容";
  exit 0;
}

# 校验IPv4格式
validate_ip() {
  local ip=$1;
  if [[ $ip =~ ^q$|^Q$ ]]; then exit_script; fi;
  if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1;
  fi
  for octet in ${ip//./ }; do
    if (( octet < 0 || octet > 255 )); then
      return 1;
    fi
  done
  return 0;
}

# 校验端口（1-65535）
validate_port() {
  local port=$1;
  if [[ $port =~ ^q$|^Q$ ]]; then exit_script; fi;
  if ! [[ $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    return 1;
  fi
  return 0;
}

# 检测命令是否存在
command_exists() {
  command -v "$1" >/dev/null 2>&1;
}

# Shell安全转义路径（统一处理所有路径，支持空格、单引号、特殊字符）
escape_path() {
  printf "%q" "$1";
}

# 规范化路径（相对路径转绝对路径，移除多余斜杠）
normalize_path() {
  local path=$1;
  # 如果是相对路径，转换为绝对路径
  if [[ $path != /* ]]; then
    path="$PWD/$path";
  fi
  # 移除多余的斜杠
  path=$(echo "$path" | sed 's#//*#/#g');
  echo "$path";
}

# 适配系统的MD5命令（返回MD5值）
get_md5() {
  local path=$1;
  local is_remote=$2;  # 1=远程路径，0=本地路径
  local md5_cmd="";

  # 检测MD5命令
  if command_exists md5sum; then
    md5_cmd="md5sum";
  elif command_exists md5; then
    md5_cmd="md5 -r";  # macOS兼容
  else
    echo "";
    return 1;
  fi

  # 执行MD5命令（远程路径通过SSH，本地路径直接执行）
  if (( is_remote == 1 )); then
    local escaped_path=$(escape_path "$path");
    ssh "${SSH_COMMON_OPTIONS[@]}" -p "$SOURCE_PORT" "$SOURCE_USER@$SOURCE_IP" "$md5_cmd $escaped_path" 2>/dev/null | awk '{print $1}';
  else
    local escaped_path=$(escape_path "$path");
    $md5_cmd "$escaped_path" 2>/dev/null | awk '{print $1}';
  fi
}

# 测试SSH连接
test_ssh_connection() {
  local user=$1;
  local ip=$2;
  local port=$3;
  info "测试SSH连接：$user@$ip:$port（超时${SSH_TIMEOUT}秒）...";
  info "提示：如果使用带密码的SSH密钥，后续会提示输入密钥密码，请耐心等待";
  if ssh "${SSH_COMMON_OPTIONS[@]}" -p "$port" "$user@$ip" "exit" 2>/dev/null; then
    success "SSH连接成功！";
    return 0;
  else
    error "SSH连接失败！请检查：\n1. IP/端口是否正确\n2. 用户名是否存在\n3. 服务器防火墙是否放行端口\n4. SSH密钥/密码是否正确";
  fi
}

# 校验远程路径（修复：简化符号链接检测逻辑，提高兼容性）
validate_remote_path() {
  local user=$1;
  local ip=$2;
  local port=$3;
  local path=$4;
  local type=$5;  # 1=文件，2=文件夹
  local follow_link=$6;  # 1=跟随符号链接，0=不跟随

  info "校验远程路径：$path（类型：$( [[ $type -eq 1 ]] && echo "文件" || echo "文件夹" )，跟随符号链接：$( [[ $follow_link -eq 1 ]] && echo "是" || echo "否" )）...";
  
  # 转义远程路径（统一转义）
  local escaped_path=$(escape_path "$path");
  
  # 简化检测逻辑，提高兼容性
  if (( follow_link == 1 )); then
    # 跟随符号链接：检查路径是否存在（不区分类型）
    local exists_cmd="if [ -e $escaped_path ]; then echo 1; else echo 0; fi";
  else
    # 不跟随符号链接：检查路径本身类型
    if (( type == 1 )); then
      # 检测文件：路径存在且是文件或符号链接
      local exists_cmd="if [ -f $escaped_path ] || [ -L $escaped_path ]; then echo 1; else echo 0; fi";
    else
      # 检测文件夹：路径存在且是目录或符号链接
      local exists_cmd="if [ -d $escaped_path ] || [ -L $escaped_path ]; then echo 1; else echo 0; fi";
    fi
  fi

  # 远程执行检测命令（用sh执行，确保兼容性）
  local is_exists=$(ssh "${SSH_COMMON_OPTIONS[@]}" -p "$port" "$user@$ip" "sh -c '$exists_cmd'");
  if [[ $is_exists -ne 1 ]]; then
    error "远程路径不存在：$path";
  fi

  success "远程路径校验通过！";
  return 0;
}

# 检测本地目标是否存在，询问用户处理方式
check_local_target() {
  local local_path=$1;
  local type=$2;  # 1=文件，2=文件夹

  if [[ ! -e $local_path ]]; then
    return 0;  # 不存在，直接继续
  fi

  # 存在时询问用户
  echo -e "\n\033[33m⚠ 本地已存在同名$( [[ $type -eq 1 ]] && echo "文件" || echo "文件夹" )：$local_path\033[0m";
  read -p "请选择操作：[1]覆盖 [2]跳过 [3]退出（默认1）：" -n 1 -r;
  echo -e "\n";
  local choice=${REPLY:-1};

  case $choice in
    1)
      info "用户选择覆盖，正在删除原有$( [[ $type -eq 1 ]] && echo "文件" || echo "文件夹" )...";
      if (( type == 1 )); then
        rm -f "$local_path" || error "删除原有文件失败：$local_path（权限不足？）";
      else
        rm -rf "$local_path" || error "删除原有文件夹失败：$local_path（权限不足？）";
      fi
      ;;
    2)
      error "用户选择跳过，退出下载";
      ;;
    3)
      exit_script;
      ;;
    *)
      info "无效选择，默认覆盖...";
      rm -rf "$local_path" || error "删除原有目标失败：$local_path（权限不足？）";
      ;;
  esac
}

# 检查本地路径是否需要sudo（修复：变量名拼写错误）
check_sudo_need() {
  local target_path=$1;
  # 规范化路径
  local normalized_target=$(normalize_path "$target_path");
  local parent_dir=$(dirname "$normalized_target");
  
  # 确保父目录存在（创建但不检查权限）
  mkdir -p "$parent_dir" 2>/dev/null || true;
  
  # 不需要sudo的情况：1. 当前是root；2. 路径在用户家目录；3. 路径有写权限
  if (( $(id -u) == 0 )); then
    return 0;  # root用户，无需提示
  fi
  if [[ $normalized_target =~ ^$HOME/ ]]; then
    return 0;  # 家目录内，无需提示
  fi
  if [[ -w "$parent_dir" ]]; then
    return 0;  # 父目录有写权限，无需提示
  fi
  # 需要sudo的情况
  warning "本地目标路径 $normalized_target 需要root权限才能写入！";
  read -p "是否用 sudo 重新运行脚本？[Y/n] " -n 1 -r;
  echo -e "\n";
  if [[ $REPLY =~ ^q$|^Q$ ]]; then exit_script; fi;
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    error "请执行：sudo $0（如需帮助，添加 -h 参数）";
  else
    error "权限不足，无法写入目标路径";
  fi
}

# ==================== 主流程 ====================
# 捕捉中断信号（Ctrl+C）
trap handle_interrupt SIGINT;

clear;
echo -e "\033[32m===== 通用SSH文件/文件夹下载工具 =====\033[0m";
echo -e "说明：支持断点续传、文件校验，优先使用rsync，失败用scp备选（仅文件）";
echo -e "输入 q/Q 可随时退出脚本，使用 -h/--help 查看帮助\n";

# 解析命令行参数（支持 -h/--help）
if [[ $# -ge 1 ]]; then
  case $1 in
    -h|--help) show_help ;;
    *) error "无效参数！使用 -h/--help 查看帮助" ;;
  esac
fi

# 1. 输入远程服务器信息
read -p "请输入远程服务器IP：" SOURCE_IP;
while ! validate_ip "$SOURCE_IP"; do
  error "IP格式非法！请输入正确的IPv4地址（比如 192.168.1.1），输入q退出";
  read -p "重新输入远程服务器IP：" SOURCE_IP;
done

read -p "请输入SSH端口（默认 $DEFAULT_PORT，回车跳过）：" SOURCE_PORT;
SOURCE_PORT=${SOURCE_PORT:-$DEFAULT_PORT};
while ! validate_port "$SOURCE_PORT"; do
  error "端口非法！请输入1-65535之间的数字，输入q退出";
  read -p "重新输入SSH端口（默认 $DEFAULT_PORT，回车跳过）：" SOURCE_PORT;
  SOURCE_PORT=${SOURCE_PORT:-$DEFAULT_PORT};
done

read -p "请输入SSH用户名（默认 $DEFAULT_USER，回车跳过）：" SOURCE_USER;
SOURCE_USER=${SOURCE_USER:-$DEFAULT_USER};
if [[ $SOURCE_USER =~ ^q$|^Q$ ]]; then exit_script; fi;

# 新增：检测核心命令是否存在（修复rsync未检测问题）
info "检测核心命令（rsync/scp）...";
if ! command_exists rsync; then
  warning "未找到 rsync 命令（优先下载工具），将仅使用 scp 备选（仅支持文件下载）";
fi
if ! command_exists scp; then
  error "未找到 scp 命令！请先安装 OpenSSH 客户端（Ubuntu: sudo apt install openssh-client；CentOS: sudo yum install openssh-clients）";
fi

# 2. 测试SSH连接
test_ssh_connection "$SOURCE_USER" "$SOURCE_IP" "$SOURCE_PORT";

# 3. 选择是否跟随符号链接
read -p "是否跟随远程符号链接（下载链接指向的真实文件/文件夹）？[Y/n] " -n 1 -r;
echo -e "\n";
if [[ $REPLY =~ ^q$|^Q$ ]]; then exit_script; fi;
FOLLOW_LINK=$([[ $REPLY =~ ^[Yy]$ ]] && echo 1 || echo 0);

# 4. 选择下载类型
echo -e "请选择下载类型：";
echo "1) 单个文件";
echo "2) 整个文件夹";
read -p "输入数字（1/2）：" DOWNLOAD_TYPE;
while [[ ! $DOWNLOAD_TYPE =~ ^[12]$ ]]; do
  if [[ $DOWNLOAD_TYPE =~ ^q$|^Q$ ]]; then exit_script; fi;
  error "输入错误！只能输入1或2，输入q退出";
  read -p "输入数字（1/2）：" DOWNLOAD_TYPE;
done

# 5. 输入并校验远程源路径
read -p "请输入远程源路径（比如 /var/lib/mysql 或 /root/backup.tar.gz）：" SOURCE_PATH;
if [[ -z "$SOURCE_PATH" ]]; then
    error "路径不能为空！";
fi
if [[ $SOURCE_PATH =~ ^q$|^Q$ ]]; then exit_script; fi;
validate_remote_path "$SOURCE_USER" "$SOURCE_IP" "$SOURCE_PORT" "$SOURCE_PATH" "$DOWNLOAD_TYPE" "$FOLLOW_LINK";

# 6. 输入本地目标路径 + 检查sudo需求
read -p "请输入本地保存路径（默认 $DEFAULT_DEST，回车跳过）：" DEST_PATH;
DEST_PATH=${DEST_PATH:-$DEFAULT_DEST};
if [[ $DEST_PATH =~ ^q$|^Q$ ]]; then exit_script; fi;

# 构建完整本地目标路径（保持原文件名/文件夹名）+ 规范化（绝对路径）
DEST_FULL_PATH=$(normalize_path "$DEST_PATH/$(basename "$SOURCE_PATH")");

# 检查本地路径是否需要sudo
check_sudo_need "$DEST_FULL_PATH";

# 确保本地父目录存在
PARENT_DIR=$(dirname "$DEST_FULL_PATH");
mkdir -p "$PARENT_DIR" || error "创建本地目录失败：$PARENT_DIR（权限不足？）";
success "本地目录已准备：$PARENT_DIR";

# 统一转义所有路径（安全处理特殊字符）
escaped_SOURCE_PATH=$(escape_path "$SOURCE_PATH");
escaped_DEST_FULL_PATH=$(escape_path "$DEST_FULL_PATH");

# 7. 明确提示用户最终路径（规范化后显示绝对路径，避免困惑）
echo -e "\n\033[34m📁 路径构建说明：\033[0m";
echo "远程路径：$SOURCE_PATH";
echo "本地目录（规范化后）：$(normalize_path "$DEST_PATH")";
echo "最终保存路径（绝对路径）：$DEST_FULL_PATH";
echo -e "说明：脚本自动保持远程文件/文件夹的原始名称\n";

# 8. 检测本地是否存在同名目标
check_local_target "$DEST_FULL_PATH" "$DOWNLOAD_TYPE";

# 9. 二次确认（显示所有关键信息）
echo -e "\n\033[33m===== 下载信息确认 =====\033[0m";
echo "远程服务器：$SOURCE_USER@$SOURCE_IP:$SOURCE_PORT";
echo "跟随符号链接：$( [[ $FOLLOW_LINK -eq 1 ]] && echo "是" || echo "否" )";
echo "下载类型：$( [[ $DOWNLOAD_TYPE -eq 1 ]] && echo "单个文件" || echo "整个文件夹" )";
echo "远程源路径：$SOURCE_PATH";
echo "本地保存路径：$DEST_FULL_PATH";
read -p "是否开始下载？[Y/n] " -n 1 -r;
echo -e "\n";
if [[ $REPLY =~ ^q$|^Q$ ]]; then exit_script; fi;
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  info "用户取消下载，退出脚本";
  exit 0;
fi

# 10. 构建rsync最终参数（不修改原常量，处理符号链接）
RSYNC_FINAL_OPTIONS=("${RSYNC_OPTIONS[@]}");  # 继承基础参数（-a 含 -l，默认不跟随符号链接）
if (( FOLLOW_LINK == 1 )); then
  RSYNC_FINAL_OPTIONS+=(-L);  # 跟随符号链接：-L 覆盖 -l，下载指向内容
  info "符号链接处理：启用跟随（-L 参数），下载链接指向的真实内容";
else
  info "符号链接处理：默认不跟随（-a 模式自带 -l 参数），下载符号链接本身";
fi

# 11. 执行下载（设置下载状态标记）
DOWNLOAD_STARTED=1;
info "开始下载...（支持断点续传，请勿中断；按Ctrl+C可取消并清理残留）";
SSH_CMD="ssh ${SSH_COMMON_OPTIONS[@]} -p $SOURCE_PORT";

if (( DOWNLOAD_TYPE == 1 )); then
  # 下载单个文件：rsync为主，scp备选（修复：使用正确的目标路径变量）
  if rsync "${RSYNC_FINAL_OPTIONS[@]}" -e "$SSH_CMD" "$SOURCE_USER@$SOURCE_IP:$escaped_SOURCE_PATH" "$escaped_DEST_FULL_PATH"; then
    success "rsync 下载文件成功！";
  else
    warning "rsync 下载失败，尝试用 scp 备选...";
    # 提示scp的符号链接限制
    if (( FOLLOW_LINK == 0 )); then
      warning "⚠ 注意：scp 不支持保留符号链接本身，将自动跟随链接下载真实内容（与您选择的「不跟随」不一致）";
    fi
    # scp目标路径使用完整路径
    if scp "${SSH_COMMON_OPTIONS[@]}" -P "$SOURCE_PORT" -C "$SOURCE_USER@$SOURCE_IP:$escaped_SOURCE_PATH" "$escaped_DEST_FULL_PATH"; then
      success "scp 下载文件成功！";
    else
      error "scp 下载也失败！请检查网络或路径";
    fi
  fi

  # 校验文件完整性（修复：移除主流程中的local关键字）
  info "校验文件完整性...";
  source_size="";
  dest_size="";
  size_check_enabled=1;
  if command_exists du; then
    source_size=$(ssh "${SSH_COMMON_OPTIONS[@]}" -p "$SOURCE_PORT" "$SOURCE_USER@$SOURCE_IP" "du -b $escaped_SOURCE_PATH | cut -f1" 2>/dev/null);
    dest_size=$(du -b "$DEST_FULL_PATH" 2>/dev/null | cut -f1);
  else
    warning "系统缺少 du 命令，跳过文件大小校验";
    size_check_enabled=0;
  fi

  source_md5=$(get_md5 "$SOURCE_PATH" 1);
  dest_md5=$(get_md5 "$DEST_FULL_PATH" 0);
  md5_check_enabled=$([[ -n $source_md5 && -n $dest_md5 ]] && echo 1 || echo 0);

  # 完善校验结果处理（分场景提示）
  if (( size_check_enabled == 1 && md5_check_enabled == 1 )); then
    if [[ $source_size -eq $dest_size && $source_md5 == $dest_md5 ]]; then
      success "✅ 文件完整性校验通过！";
      echo "  - 大小：$(numfmt --to=iec $source_size 2>/dev/null || echo "${source_size} bytes")";
      echo "  - MD5：$source_md5";
    elif [[ $source_size -eq $dest_size && $source_md5 != $dest_md5 ]]; then
      error "❌ 大小匹配但MD5不匹配！文件可能损坏，建议：";
      echo "  1. 重新运行脚本下载";
      echo "  2. 手动校验：";
      echo "     远程：ssh -p $SOURCE_PORT $SOURCE_USER@$SOURCE_IP 'md5sum $(escape_path "$SOURCE_PATH")'";
      echo "     本地：md5sum $(escape_path "$DEST_FULL_PATH")";
    elif [[ $source_size -ne $dest_size && $source_md5 == $dest_md5 ]]; then
      warning "⚠ MD5匹配但大小不匹配（可能是系统du命令兼容性问题），文件大概率可用";
    else
      error "❌ 大小和MD5都不匹配！文件损坏，建议重新下载";
    fi
  elif (( size_check_enabled == 1 && md5_check_enabled == 0 )); then
    if [[ $source_size -eq $dest_size ]]; then
      success "✅ 大小校验通过（MD5命令缺失，跳过MD5校验）";
    else
      error "❌ 大小不匹配！文件损坏，建议重新下载";
    fi
  elif (( size_check_enabled == 0 && md5_check_enabled == 1 )); then
    if [[ $source_md5 == $dest_md5 ]]; then
      success "✅ MD5校验通过（du命令缺失，跳过大小校验）";
    else
      error "❌ MD5不匹配！文件损坏，建议重新下载";
    fi
  else
    warning "⚠ 缺少 du/md5sum 命令，无法进行完整性校验，请手动确认文件可用性";
  fi

else
  # 文件夹下载：目标路径用完整路径（修复：正确的rsync路径格式）
  local rsync_source_path="$SOURCE_USER@$SOURCE_IP:$escaped_SOURCE_PATH";
  if rsync "${RSYNC_FINAL_OPTIONS[@]}" -e "$SSH_CMD" "$rsync_source_path/" "$escaped_DEST_FULL_PATH"; then
    success "rsync 下载文件夹成功！";
  else
    error "rsync 下载文件夹失败！请检查网络或路径";
  fi

  # 校验文件夹完整性（修复：移除主流程中的local关键字）
  info "校验文件夹完整性...";
  source_file_count="";
  dest_file_count="";
  count_check_enabled=1;
  if command_exists find; then
    source_file_count=$(ssh "${SSH_COMMON_OPTIONS[@]}" -p "$SOURCE_PORT" "$SOURCE_USER@$SOURCE_IP" "find $escaped_SOURCE_PATH -type f | wc -l" 2>/dev/null);
    dest_file_count=$(find "$DEST_FULL_PATH" -type f | wc -l 2>/dev/null);
  else
    warning "系统缺少 find 命令，跳过文件夹文件数校验";
    count_check_enabled=0;
  fi

  if (( count_check_enabled == 1 )); then
    if [[ $source_file_count -eq $dest_file_count ]]; then
      success "✅ 文件夹完整性校验通过！（文件总数：$source_file_count）";
    else
      warning "⚠ 文件夹文件总数不匹配（源：$source_file_count，目标：$dest_file_count）";
      echo "  建议手动检查：对比远程和本地文件夹的文件列表";
      echo "  远程：ssh -p $SOURCE_PORT $SOURCE_USER@$SOURCE_IP 'find $(escape_path "$SOURCE_PATH") -type f'";
      echo "  本地：find $(escape_path "$DEST_FULL_PATH") -type f";
    fi
  fi
fi

# 12. 结束提示
echo -e "\n\033[32m===== 下载完成！=====\033[0m";
echo "文件保存位置：$DEST_FULL_PATH";
echo "建议：手动打开文件/文件夹确认是否正常可用～";
exit 0;
