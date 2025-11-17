# SSH文件/文件夹下载工具

一个功能强大的Bash脚本，用于通过SSH安全地下载远程服务器上的文件和文件夹。支持断点续传、完整性校验和多种安全特性。

> **AI辅助开发说明**: 此项目代码由AI辅助生成，经过人工测试和优化，确保代码质量和实用性。

## 🌟 特性

- **断点续传**: 优先使用rsync，失败时自动切换到scp备选方案
- **完整性校验**: 自动校验文件大小和MD5，确保下载完整性
- **符号链接处理**: 可选择跟随或不跟随符号链接
- **安全SSH配置**: 自动接受新主机密钥，拒绝已变更密钥
- **交互式操作**: 友好的命令行交互界面
- **错误处理**: 完善的错误处理和清理机制
- **跨平台兼容**: 支持Linux和macOS系统

## 📦 依赖要求

- Bash 4.0+
- SSH客户端
- rsync（推荐）或scp
- 基础工具：du, find, md5sum/md5

## 🚀 快速开始

### 1. 下载脚本

```bash
# 克隆仓库
git clone https://github.com/naibabiji/ssh-download.git
cd ssh-download

# 或直接下载脚本
wget https://raw.githubusercontent.com/naibabiji/ssh-download/main/ssh-download.sh
chmod +x ssh-download.sh
```

### 2. 运行脚本

```bash
./ssh-download.sh
```

### 3. 查看帮助

```bash
./ssh-download.sh -h
```

## 📖 使用方法

### 基本使用流程

1. **输入服务器信息**: IP地址、SSH端口、用户名
2. **测试连接**: 脚本自动测试SSH连接
3. **选择下载类型**: 文件或文件夹
4. **设置符号链接处理**: 跟随或不跟随
5. **指定路径**: 远程源路径和本地保存路径
6. **确认下载**: 显示完整信息后确认
7. **自动下载**: 使用rsync/scp进行下载
8. **完整性校验**: 自动校验下载结果

### 命令行参数

```bash
# 显示帮助信息
./ssh-download.sh -h
./ssh-download.sh --help
```

### 示例

```bash
# 下载远程文件
./ssh-download.sh
# 输入: 192.168.1.100
# 输入: 22
# 输入: root
# 选择: 文件
# 输入: /var/log/syslog
# 输入: ./downloads

# 下载远程文件夹
./ssh-download.sh
# 输入: 192.168.1.100
# 输入: 22
# 输入: root
# 选择: 文件夹
# 输入: /var/www/html
# 输入: ./backups
```

## 🔧 技术细节

### 核心功能

- **rsync优先**: 使用rsync的归档模式，支持断点续传
- **scp备选**: rsync失败时自动切换到scp
- **安全转义**: 自动处理路径中的特殊字符
- **权限检查**: 自动检测是否需要sudo权限
- **中断处理**: Ctrl+C中断时自动清理不完整文件

### 符号链接处理

- **不跟随模式**: 下载符号链接本身（默认）
- **跟随模式**: 下载符号链接指向的真实内容

### 完整性校验

- **文件校验**: 大小比较 + MD5校验
- **文件夹校验**: 文件数量比较
- **兼容性**: 自动适配不同系统的命令差异

## 🛡️ 安全特性

- **SSH安全配置**: 使用`StrictHostKeyChecking=accept-new`
- **连接超时**: 默认5秒连接超时
- **路径转义**: 防止路径注入攻击
- **权限控制**: 自动检测和提示权限需求

## 📁 项目结构

```
ssh-download/
├── ssh-download.sh    # 主脚本文件
├── README.md         # 项目说明文档
└── LICENSE           # 开源许可证
```

## 🤝 贡献指南

欢迎提交Issue和Pull Request来改进这个项目！

### 开发环境设置

```bash
# 克隆项目
git clone https://github.com/naibabiji/ssh-download.git
cd ssh-download

# 测试脚本
./ssh-download.sh -h
```

### 代码规范

- 使用Bash严格模式：`set -euo pipefail`
- 遵循ShellCheck规范
- 添加详细的注释说明
- 保持代码简洁和可读性

## 📄 许可证

本项目采用MIT许可证。详见[LICENSE](LICENSE)文件。

## 🙏 致谢

感谢所有为这个项目做出贡献的开发者！

---

**项目地址**: https://github.com/naibabiji/ssh-download

**问题反馈**: 请在GitHub Issues中提交问题报告
