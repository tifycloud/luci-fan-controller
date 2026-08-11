# 构建与验证

## OpenWrt 25.12.5 legacy IPK（opkg）

当前交付目标是传统 opkg 使用的 IPK，不交付 APK。生产构建固定使用
官方 qualcommax/ipq807x SDK，并明确关闭 OpenWrt 的 APK 包格式：

- SDK：openwrt-sdk-25.12.5-qualcommax-ipq807x_gcc-14.3.0_musl.Linux-x86_64.tar.zst
- SHA-256：7aabdda8607c372cb0fd526f0eede2f680ae7d95a4758a38bbb49381e5c97621
- 容器平台：Linux/amd64
- 包格式：legacy IPK（debian-binary、control.tar.gz、data.tar.gz）

macOS 或 Linux 安装 Docker 后运行：

~~~sh
make ipk
~~~

脚本会校验 SDK、使用 SDK 自带的固定 feeds 版本、编译两个 IPK、检查
外层/内层 gzip-tar、控制元数据、已安装文件和 SHA-256，并生成：

~~~text
dist/ax9000-fan-control_1.0.0-r4_all.ipk
dist/luci-app-ax9000-fan_1.0.0-r1_all.ipk
dist/SHA256SUMS
dist/*.sha256
dist/BUILD-INFO
dist/BUILD-DEPENDENCIES
~~~

核心包当前发布为 r4（LuCI 仍为 r1）。r4 在保留 r3 的 OpenWrt 25.12
`procd.sh` `_procd_open_instance` 参数位移兼容性修复、动态控制器发现和
满速安全门禁基础上，移除 procd stdout/stderr 捕获参数。服务日志由
`logger` 负责，避免目标固件为捕获输出注入 `libsetlbf.so`，从而干扰控制器
初始化或满速写入。r3 修复的已绑定 EMC2301/EMC2305 位于非默认 I2C 总线
误报仍保留：只接受真实
`/sys/devices/i2c-<bus>/<bus>-002f` 客户端，并要求寄存器精确读回、PWM 255
读回和正 RPM 后才进入控制循环；寄存器写入或身份校验失败则保持满速并失败
重试。固定 `i2c-0/0-002f` 仅作为无已绑定客户端时的回退。

构建缓存位于 .cache/ 与 Docker named volume；构建过程只写本地工作区，
不会连接、安装或修改路由器。

## 产物检查

~~~sh
make inspect
~~~

检查器只接受上述两个 IPK，拒绝 APK、额外包和符号链接，并严格验证：

1. IPK 外层只有 ./debian-binary、./control.tar.gz、./data.tar.gz；
2. debian-binary 内容精确为 2.0，两个内层归档均为 gzip-tar 且无绝对路径、
   .. 路径或重复成员；
3. control 的 Package、Version、Architecture、Depends 与项目预期一致；
4. 核心与 LuCI 的关键文件存在、不是符号链接且权限正确；
5. SHA256SUMS 和每个 .ipk.sha256 都只对应这两个 IPK，并且实际校验通过。

## 与当前路由器的兼容边界

两个包的 Architecture 都是 all，所以包本身没有针对 CPU 的私有二进制。
但是核心包依赖 kmod-*、i2c-tools 等运行时包；这些依赖和内核模块**不会
打包在本交付物中**。安装前必须确认当前 Kwrt/OpenWrt 的以下信息与构建目标
完全匹配：

- opkg print-architecture 的架构层级；
- uname -r 对应的内核 ABI；
- 当前固件的 distfeeds.conf/软件源版本；
- kmod-hwmon-emc2305、kmod-hwmon-core、kmod-thermal、kmod-i2c-core
  和 kmod-regmap-i2c 等依赖是否来自同一固件构建。

Architecture: all 不等于可以跨固件或跨内核混装。不要把本目录的 IPK 与
APK 系统、不同内核版本，或不匹配的第三方 feed 混装；opkg 发现依赖版本
或内核 ABI 不匹配时应停止安装。由于当前构建环境没有读取路由器系统版本，
本地 SDK 验证不能替代维护窗口中的目标机验收。

## 源码复用

如果要在另一套完全匹配的 OpenWrt/Kwrt Buildroot 中重编译，把
`controller/` 和 `luci/` 分别复制到其 `package/ax9000-fan-control/` 与
`package/luci-app-ax9000-fan/` 后编译：

~~~sh
make package/ax9000-fan-control/compile V=s
make package/luci-app-ax9000-fan/compile V=s
~~~

必须在目标固件自己的 SDK、目标、内核 ABI 和 feeds 中完成，不要从本目录
复制任何 kmod 二进制。

## 测试

~~~sh
make test
~~~

测试覆盖配置边界、3 °C 回差、低温读数、延迟出现的 hwmon、禁用模式满速
保护、缺失温度源、缺失转速、零转速保护、无效 SHA、HTTPS 降级防护、缺失
LuCI 包、设备型号门禁、安装/卸载钩子、LuCI ACL/菜单/固定状态命令以及
JavaScript/JSON/Shell 语法。完成构建后还应运行 make inspect 检查实际 IPK。
安装器与历史测试中的 APK 分支仅作向后兼容回归，不改变正式产物、文档和
make inspect 的 IPK-only 门禁。
