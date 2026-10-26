# customize.sh —— 由 Magisk / KernelSU 安装器在刷入阶段执行
# 只做两件事：机型提示 + 权限修正

ui_print "- k90_cpuctl $(grep_prop version "$MODPATH/module.prop")"

DEVICE=$(getprop ro.product.device)
MODEL=$(getprop ro.product.model)
ui_print "- 当前设备: $MODEL / $DEVICE"

# 档位表是按 myron（SM8850）的两簇频点 + KGSL 18 档 GPU 等级写死的。
# 机型不符时不中止安装，因为写入不存在的频点会被内核丢弃，最多是档位无效。
case "$DEVICE" in
    myron) ;;
    *)
        ui_print "! 本模块的档位表是为 Redmi K90 Pro Max / myron 校准的"
        ui_print "! 当前设备 ($DEVICE) 的集群划分、频点或 GPU 节点可能不同"
        ui_print "! 安装不会损坏设备, 但档位可能无效"
        ui_print "! 3 秒后继续，若要中止请现在断开"
        sleep 3
        ;;
esac

ui_print "- 修正文件权限"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/service.sh"   0 0 0755
set_perm "$MODPATH/action.sh"    0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/webroot/cgi-bin/api.cgi" 0 0 0755

ui_print "- 安装完成，重启后在管理器点「操作」按钮即可打开界面"
