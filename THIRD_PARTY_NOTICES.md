# 第三方组件声明

本项目的安装脚本和配置模板使用根目录 `LICENSE` 中的 MIT License。仓库内附带的第三方二进制和数据库不因此变更许可证。

## Mihomo

- 文件：`resources/bin/mihomo-linux-amd64-v2-v1.19.29.gz`
- 上游项目：https://github.com/MetaCubeX/mihomo
- 对应源代码：https://github.com/MetaCubeX/mihomo/tree/v1.19.29
- 许可证：GNU General Public License v3.0
- 许可证正文：https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE

## Country.mmdb

- 文件：`resources/Country.mmdb`
- 上游项目：https://github.com/MetaCubeX/meta-rules-dat
- 更新来源：https://github.com/MetaCubeX/meta-rules-dat/releases/tag/latest
- 上游仓库许可证：GNU General Public License v3.0
- 许可证正文：https://github.com/MetaCubeX/meta-rules-dat/blob/master/LICENSE

资源文件由 `scripts/update_resources.sh` 根据上游 Release 元数据下载并进行 SHA256 校验。重新分发这些文件时，请同时遵守对应上游项目及其数据源的许可证与署名要求。
