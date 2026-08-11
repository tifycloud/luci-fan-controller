# luci-app-ax9000-fan

AX9000 风扇控制器的低资源 LuCI 25.12 面板。安装后菜单位于“系统 → AX9000
风扇”。状态仅通过 ACL 允许的固定 `/usr/libexec/ax9000-fan-status` 程序读取；
配置保存走原生 UCI form/view 流程，由核心 init 的 reload trigger 重新加载。

参见安装到设备上的 `/usr/share/ax9000-fan/README`，了解 UCI 字段、校验规则和
故障保护约束。
