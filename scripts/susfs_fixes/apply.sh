#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

# 列出当前目录下不属于上游的 .rej（相对路径，已排序）。
# 上游分支可能自带已提交的 .rej（如 android15-6.6-2026-04 的 mm/rmap.c.rej，
# 是上游解决合并冲突时的残留），那不是本补丁的冲突；但 patch 失败时会覆盖同名文件，
# 所以只有「被 git 跟踪且未改动」的才视为上游自带。
# 不在 git 仓库里（本地 verify_context.sh）时 git 命令为空，退回全部 .rej
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "Official"|"FinaSU")
    cd ./KernelSU
    cp "$SUSFS4KSU"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./
    patch -p1 --forward < 10_enable_susfs_for_ksu.patch || true

    cd ..
    ;;
  "Next"|"SukiSU"|"SukiSU(40726)"|"SukiSU(40548)"|"BakaSU")
    echo "Next/SukiSU/SukiSU(40726)/SukiSU(40548)/BakaSU 使用内置 SUSFS 支持"
    ;;
esac

# FinaSU: 10_enable_susfs_for_ksu.patch 与 FinaSU 的分支代码存在上下文差异，
# 部分 hunk 未应用（init.c / selinux_hide.c 等），这里按补丁意图完成缺失的适配：
#   0) selinux_hide.c 回退为原始版本，恢复其依赖的基础模块，并把 SUSFS 内核补丁
#      以 extern 引用的 6 个符号改为全局定义（与 BakaSU 的 __maybe_static 行为一致）
#   1) 移除指向已移出编译列表模块的调用
#   2) 恢复补丁删除、但 FinaSU 其余代码仍在使用的全局变量
#   3) 移除已被补丁整体删除的 ksu_app_profile_init 调用
#   4) 补齐头文件声明、SUSFS 初始化与新架构初始化调用
if [ "$KSU_VARIANT" == "FinaSU" ]; then
  FINASU_KSU="$KERNEL_ROOT/KernelSU/kernel"
  FINASU_INIT="$FINASU_KSU/core/init.c"
  FINASU_KSU_H="$FINASU_KSU/include/ksu.h"
  FINASU_KSI="$FINASU_KSU/runtime/ksud_integration.c"
  if [ ! -f "$FINASU_INIT" ] || [ ! -f "$FINASU_KSU_H" ]; then
    echo "::error::未找到 FinaSU 内核源码文件 (core/init.c / include/ksu.h)" >&2
    exit 1
  fi

  # 0) 回退 selinux_hide.c，并恢复其依赖的基础模块进入编译列表
  if git -C "$KERNEL_ROOT/KernelSU" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$KERNEL_ROOT/KernelSU" checkout -- kernel/feature/selinux_hide.c
    if ! git -C "$KERNEL_ROOT/KernelSU" diff --quiet -- kernel/feature/selinux_hide.c; then
      echo "::error::FinaSU selinux_hide.c 未能回退为原始版本" >&2
      exit 1
    fi
  fi
  if ! grep -q 'hook/lsm_hook.o' "$FINASU_KSU/Kbuild"; then
    sed -i 's|^kernelsu-objs += hook/setuid_hook.o$|kernelsu-objs += hook/setuid_hook.o\nkernelsu-objs += hook/lsm_hook.o\nkernelsu-objs += infra/symbol_resolver.o\n\nifeq ($(CONFIG_ARM64),y)\nkernelsu-objs += hook/arm64/patch_memory.o\nelse ifeq ($(CONFIG_X86_64),y)\nkernelsu-objs += hook/x86_64/patch_memory.o\nelse ifeq ($(CONFIG_RISCV),y)\nkernelsu-objs += hook/riscv64/patch_memory.o\nendif|' "$FINASU_KSU/Kbuild"
  fi

  # 0b) SUSFS 内核补丁在 security/selinux/*.c 中以 extern 引用了这些符号，需与 BakaSU 一致
  #     改为全局定义，否则 ThinLTO 链接阶段会报 undefined symbol。
  #     - 6 个通用符号（>=5.10 用到）：
  #       fake_state / fake_status / fake_status_initialize_key / initialize_fake_status /
  #       ksu_selinux_hide_enabled / ksu_selinux_hide_running
  #     - 3 个 6.6 才用到的函数（android15-6.6 主补丁在 security/selinux/* 中 extern 引用，
  #       5.15/6.1 用不到，所以之前只在 6.6 上暴露为链接失败）：
  #       security_context_to_sid_with_policy / security_sid_to_context_with_policy /
  #       security_compute_av_user_with_policy
  FINASU_SELINUX_HIDE="$FINASU_KSU/feature/selinux_hide.c"
  if grep -q '^static bool ksu_selinux_hide_enabled ' "$FINASU_SELINUX_HIDE"; then
    sed -i \
      -e 's|^static bool ksu_selinux_hide_enabled |bool ksu_selinux_hide_enabled |' \
      -e 's|^static bool ksu_selinux_hide_running |bool ksu_selinux_hide_running |' \
      -e 's|^static struct selinux_state fake_state;|struct selinux_state fake_state;|' \
      -e 's|^static DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);|DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);|' \
      -e 's|^static struct page \*fake_status = NULL;|struct page *fake_status = NULL;\nvoid initialize_fake_status(void);|' \
      -e 's|^static void initialize_fake_status()|void initialize_fake_status(void)|' \
      -e 's|^static int security_context_to_sid_with_policy|int security_context_to_sid_with_policy|' \
      -e 's|^static int security_sid_to_context_with_policy|int security_sid_to_context_with_policy|' \
      -e 's|^static void security_compute_av_user_with_policy|void security_compute_av_user_with_policy|' \
      -e 's|^static void __nocfi security_compute_av_user_with_policy|void __nocfi security_compute_av_user_with_policy|' \
      "$FINASU_SELINUX_HIDE"
  fi

  # 0c) SUSFS 主补丁已在内核侧接管 selinuxfs：security/selinux/selinuxfs.c 把
  #     write_op[] 换成它自己的 my_write_access/my_write_context，security/selinux/hooks.c
  #     注册了 my_setprocattr，并托管 sel_handle_status_ops 的 status 处理。
  #     KSU 侧 selinux_hide.c 若再安装同名运行时 hook（write_op patch / setprocattr LSM hook /
  #     status open hook），两套 hook 会互相覆盖；一旦 KSU 侧 patch 失败，ksu_selinux_hide_running
  #     保持 false，SUSFS 内核代码里 !ksu_selinux_hide_running 的分支就会跳过伪装，
  #     表现为「隐藏 SELinux 失效」。这里按 SUSFS 设计，让 selinux_hide.c 只提供共享符号，
  #     不再安装运行时 hook。
  # selinux_hide 形态检测（在 0c 之前，此时文件已回退为上游原版）：
  #   新形态（preview1+）无 fake_state，0c 不能再注入 fake_state.initialized/policy，校验也跳过 fake_state 项
  NEW_MODEL=0
  if [ -f "$FINASU_SELINUX_HIDE" ] && ! grep -q 'fake_state' "$FINASU_SELINUX_HIDE"; then
    NEW_MODEL=1
  fi
  echo "FinaSU selinux_hide 形态: $([ "$NEW_MODEL" = 1 ] && echo 新 || echo 旧)"

  if ! grep -q 'FINASU_SUSFS_OWNS_SELINUXFS' "$FINASU_SELINUX_HIDE"; then
    python3 - "$FINASU_SELINUX_HIDE" "${NEW_MODEL:-0}" <<'PYEOF'
import sys

path = sys.argv[1]
new_model = (sys.argv[2] == "1")
src = open(path, encoding="utf-8").read()

# enable(): 在安装 write_op/status/setprocattr hook 之前直接返回；
# 旧形态另需保留 <6.6 的 fake_state 设置，新形态没有 fake_state（统一用 backup_sepolicy）
enable_anchor = '    selinux_write_op = find_kernel_symbol_exact("write_op");'
assert src.count(enable_anchor) == 1, "selinux_hide enable anchor not unique"
enable_block = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "    /* FINASU_SUSFS_OWNS_SELINUXFS: SUSFS 已接管 write_op/status/setprocattr */\n"
)
if not new_model:
    enable_block += (
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\n"
        "    fake_state.initialized = true;\n"
        "    fake_state.policy = backup_sepolicy;\n"
        "#endif\n"
    )
enable_block += (
    "    return 0;\n"
    "#endif\n"
)
src = src.replace(enable_anchor, enable_block + enable_anchor, 1)

# unhook(): 没有安装过就不要还原
unhook_anchor = "static void ksu_selinux_hide_unhook()\n{\n"
assert src.count(unhook_anchor) == 1, "selinux_hide unhook anchor not unique"
src = src.replace(unhook_anchor, unhook_anchor + "#ifdef CONFIG_KSU_SUSFS\n    return;\n#endif\n", 1)

# init(): 不再 hook status open（SUSFS 负责）
init_anchor = "    hook_selinux_status_open();\n}"
assert src.count(init_anchor) == 1, "selinux_hide init anchor not unique"
src = src.replace(init_anchor, "#ifndef CONFIG_KSU_SUSFS\n    hook_selinux_status_open();\n#endif\n}", 1)

open(path, "w", encoding="utf-8").write(src)
print("selinux_hide.c: 已按 SUSFS 归属跳过 KSU 侧运行时 hook")
PYEOF
    grep -n 'FINASU_SUSFS_OWNS_SELINUXFS' "$FINASU_SELINUX_HIDE"
  fi

  # 0d) 保持 seccomp「过滤模式」（与 BakaSU 一致）：simonpunk 的 SUSFS KSU 补丁把
  #     setuid_hook.c 里的 ksu_seccomp_allow_cache(__NR_reboot) 改成了无条件 disable_seccomp()，
  #     于是管理器首页 Seccomp 状态显示“未开启”（0）。BakaSU 的做法是 >=5.10 保留过滤模式、
  #     仅把 reboot 加入 seccomp 白名单；这里改回 BakaSU 的逻辑。
  if [ -f "$FINASU_KSU/hook/setuid_hook.c" ] \
    && ! grep -q 'FINASU_SECCOMP_KEEP_FILTER' "$FINASU_KSU/hook/setuid_hook.c" \
    && grep -q '^        disable_seccomp();$' "$FINASU_KSU/hook/setuid_hook.c"; then
    python3 - "$FINASU_KSU/hook/setuid_hook.c" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = "        disable_seccomp();\n"
count = src.count(needle)
if count == 0:
    print("setuid_hook.c: 未发现无条件 disable_seccomp()，跳过")
    sys.exit(0)
repl = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0) /* FINASU_SECCOMP_KEEP_FILTER */\n"
    "        if (current->seccomp.mode == SECCOMP_MODE_FILTER && current->seccomp.filter) {\n"
    "            spin_lock_irq(&current->sighand->siglock);\n"
    "            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);\n"
    "            spin_unlock_irq(&current->sighand->siglock);\n"
    "        }\n"
    "#else\n"
    "        disable_seccomp();\n"
    "#endif\n"
)
src = src.replace(needle, repl)
open(path, "w", encoding="utf-8").write(src)
print("setuid_hook.c: 已将 %d 处 disable_seccomp() 改回 BakaSU 的 seccomp 白名单/过滤模式" % count)
PYEOF
    grep -n 'FINASU_SECCOMP_KEEP_FILTER\|ksu_seccomp_allow_cache(current->seccomp.filter' "$FINASU_KSU/hook/setuid_hook.c"
  fi

  # 0e) 补齐 ksud_integration.c 的 exec 钩子新签名
  #     simonpunk 的补丁把 exec 钩子改成 fd 版：ksud.h 的声明、sucompat.c 的
  #     ksu_handle_execveat() 调用都已是新签名，但 ksud_integration.c 里改写该函数的 hunk
  #     因 FinaSU 多了一行 ksu_feature_apply_forced() 而失败，于是定义仍是旧的
  #     void(const char*, struct user_arg_ptr*) → 「conflicting types for
  #     'ksu_handle_execveat_ksud'」。这里按补丁本意改写为 fd 版并保留 ksu_feature_apply_forced()。
  #     （旧的 ksu_execve_hook_ksud 定义已被补丁删除，其调用点 hook/syscall_event_bridge.c
  #      也已被补丁移出编译列表，所以不再需要。）
  if [ -f "$FINASU_KSI" ] && grep -q '^void ksu_handle_execveat_ksud(const char \*path, struct user_arg_ptr \*argv)' "$FINASU_KSI"; then
    python3 - "$FINASU_KSI" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

old_sig = "void ksu_handle_execveat_ksud(const char *path, struct user_arg_ptr *argv)\n"
if old_sig not in src:
    print("ksud_integration.c: 未找到旧版 ksu_handle_execveat_ksud，跳过")
    sys.exit(0)
start = src.index(old_sig)
end = src.index("\n}\n", start) + len("\n}\n")

new_func = (
    "extern int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user);\n"
    "\n"
    "// IMPORTANT NOTE: the call from execve_handler_pre WON'T provided correct value for envp and flags in GKI version\n"
    "int ksu_handle_execveat_ksud(int *fd, struct filename **filename_ptr,\n"
    "                             struct user_arg_ptr *argv,\n"
    "                             struct user_arg_ptr *envp, int *flags)\n"
    "{\n"
    "    struct filename *filename;\n"
    "    static const char app_process[] = \"/system/bin/app_process\";\n"
    "\n"
    "    /* This applies to versions Android 10+ */\n"
    "    static const char system_bin_init[] = \"/system/bin/init\";\n"
    "\n"
    "    if (!filename_ptr)\n"
    "        return 0;\n"
    "\n"
    "    filename = *filename_ptr;\n"
    "    if (IS_ERR(filename)) {\n"
    "        return 0;\n"
    "    }\n"
    "\n"
    "    if (static_branch_unlikely(&is_init_second_stage_not_executed)) {\n"
    "        // https://cs.android.com/android/platform/superproject/+/android-16.0.0_r2:system/core/init/main.cpp;l=77\n"
    "        if (unlikely(!memcmp(filename->name, system_bin_init, sizeof(system_bin_init) - 1) && argv)) {\n"
    "            char buf[16];\n"
    "            if (check_argv(*argv, 1, \"second_stage\", buf, sizeof(buf))) {\n"
    "                pr_info(\"/system/bin/init second_stage executed\\n\");\n"
    "                ksu_selinux_hide_handle_second_stage();\n"
    "                apply_kernelsu_rules();\n"
    "                cache_sid();\n"
    "                setup_ksu_cred();\n"
    "                ksu_feature_apply_forced();\n"
    "                static_branch_disable(&is_init_second_stage_not_executed);\n"
    "            }\n"
    "        }\n"
    "    }\n"
    "\n"
    "    if (static_branch_unlikely(&is_first_zygote)) {\n"
    "        if (unlikely(!memcmp(filename->name, app_process, sizeof(app_process) - 1) && argv)) {\n"
    "            char buf[16];\n"
    "            if (check_argv(*argv, 1, \"-Xzygote\", buf, sizeof(buf))) {\n"
    "                pr_info(\"exec zygote, /data prepared, second_stage: %d\\n\", !static_key_enabled(&is_init_second_stage_not_executed));\n"
    "                on_post_fs_data();\n"
    "                static_branch_disable(&is_first_zygote);\n"
    "            }\n"
    "        }\n"
    "    }\n"
    "\n"
    "    return 0;\n"
    "}\n"
)

src = src[:start] + new_func + src[end:]
open(path, "w", encoding="utf-8").write(src)
print("ksud_integration.c: 已按补丁本意把 ksu_handle_execveat_ksud 改写为 fd 版签名")
PYEOF
    grep -n '^int ksu_handle_execveat_ksud(int \*fd' "$FINASU_KSI"
  fi

  # 1) 移除已不参与编译的模块的调用（仅剩 syscall hook / syscall hook manager）
  sed -i \
    -e '/^[[:space:]]*ksu_syscall_hook_init();$/d' \
    -e '/^[[:space:]]*ksu_syscall_hook_manager_init();$/d' \
    -e '/^[[:space:]]*ksu_syscall_hook_manager_exit();$/d' \
    "$FINASU_INIT"

  # 1b) 补回 lsm hook 退出调用（补丁删除了它，而该模块已恢复）
  if ! grep -q 'ksu_lsm_hook_exit();' "$FINASU_INIT"; then
    sed -i 's|^[[:space:]]*ksu_selinux_hide_exit();$|    ksu_lsm_hook_exit();\n    ksu_selinux_hide_exit();|' "$FINASU_INIT"
  fi

  # 3) ksu_app_profile_init 已被补丁从 app_profile.c/h 整体删除，去掉残留调用
  if ! grep -q 'void __init ksu_app_profile_init(' "$FINASU_KSU/policy/app_profile.c"; then
    sed -i '/^[[:space:]]*ksu_app_profile_init();$/d' "$FINASU_INIT"
  fi

  # 2) 恢复 ksu_late_loaded / ksu_bundled（补丁从 ksu.h 与 init.c 删除，
  #    但 FinaSU 的 dispatch / selinux_hide / ksud_integration 仍在使用）
  if ! grep -q 'extern bool ksu_late_loaded;' "$FINASU_KSU_H"; then
    sed -i 's|^extern bool ksu_no_custom_rc;$|extern bool ksu_no_custom_rc;\nextern bool ksu_late_loaded;\nextern bool ksu_bundled;|' "$FINASU_KSU_H"
  fi
  if ! grep -q '^bool ksu_late_loaded;' "$FINASU_INIT"; then
    sed -i 's|^struct cred \*ksu_cred;$|struct cred *ksu_cred;\n\nbool ksu_late_loaded;\n\n#ifdef MODULE\nbool ksu_bundled = false;\nmodule_param_named(bundled, ksu_bundled, bool, 0);\n#endif|' "$FINASU_INIT"
  fi

  # 4a) 补齐新架构初始化函数的头文件声明
  if ! grep -q '#include "feature/sucompat.h"' "$FINASU_INIT"; then
    sed -i 's|^#include "feature/avc_spoof.h"$|#include "feature/avc_spoof.h"\n#include "feature/sucompat.h"\n#include "hook/setuid_hook.h"|' "$FINASU_INIT"
  fi

  # 4a2) 补回 lsm_hook 头文件（补丁删除了该 include，而调用已恢复）
  if ! grep -q '#include "hook/lsm_hook.h"' "$FINASU_INIT"; then
    sed -i 's|^#include "hook/setuid_hook.h"$|#include "hook/setuid_hook.h"\n#include "hook/lsm_hook.h"|' "$FINASU_INIT"
  fi

  # 4b) SUSFS 初始化（补丁已在 init.c 顶部加入 susfs.h 头文件）
  if ! grep -q 'susfs_init();' "$FINASU_INIT"; then
    sed -i 's|^[[:space:]]*ksu_feature_init();$|#ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif // #ifdef CONFIG_KSU_SUSFS\n    ksu_feature_init();|' "$FINASU_INIT"
  fi

  # 4c) 原先由 hook/syscall_hook_manager.c 代调用的初始化，改为 init.c 直接调用
  if ! grep -q 'ksu_sucompat_init();' "$FINASU_INIT"; then
    sed -i 's|^[[:space:]]*ksu_supercalls_init();$|    ksu_supercalls_init();\n\n    ksu_sucompat_init();\n\n    ksu_setuid_hook_init();|' "$FINASU_INIT"
  fi

  # 5) 部分应用的补丁会残留少量 unused 代码（如 selinux_hide.c），
  #    GKI 的 -Werror 下放行该告警类别，避免遗留代码阻断编译
  if ! grep -q 'Wno-error=unused-variable' "$FINASU_KSU/Kbuild"; then
    cat >> "$FINASU_KSU/Kbuild" << 'KSU_KBUILD_EOF'

# FinaSU: SUSFS 补丁部分应用后的残留代码允许 unused 类告警
ccflags-y += -Wno-error=unused-variable -Wno-error=unused-function -Wno-error=unused-but-set-variable -Wno-error=unused-const-variable
KSU_KBUILD_EOF
  fi

  # selinux_hide 形态检测：新形态（preview1+ 无 fake_state）需跳过 fake_state 校验
  NEW_MODEL=0
  if [ -f "$FINASU_SELINUX_HIDE" ] && ! grep -q 'fake_state' "$FINASU_SELINUX_HIDE"; then
    NEW_MODEL=1
  fi

  # 结果校验，防止上游代码结构变化后静默失效
  if ! grep -q 'susfs_init();' "$FINASU_INIT" \
    || ! grep -q 'ksu_sucompat_init();' "$FINASU_INIT" \
    || ! grep -q 'ksu_setuid_hook_init();' "$FINASU_INIT" \
    || ! grep -q 'ksu_init_symbol_resolver();' "$FINASU_INIT" \
    || ! grep -q 'ksu_lsm_hook_init();' "$FINASU_INIT" \
    || ! grep -q 'ksu_lsm_hook_exit();' "$FINASU_INIT" \
    || ! grep -q '#include "hook/lsm_hook.h"' "$FINASU_INIT" \
    || ! grep -q '^bool ksu_late_loaded;' "$FINASU_INIT" \
    || ! grep -q 'extern bool ksu_late_loaded;' "$FINASU_KSU_H" \
    || ! grep -q 'hook/lsm_hook.o' "$FINASU_KSU/Kbuild" \
    || ! grep -q 'infra/symbol_resolver.o' "$FINASU_KSU/Kbuild" \
    || ! grep -q '^bool ksu_selinux_hide_enabled ' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^bool ksu_selinux_hide_running ' "$FINASU_SELINUX_HIDE" \
    || ! { [ "${NEW_MODEL:-0}" = 1 ] || grep -q '^struct selinux_state fake_state;' "$FINASU_SELINUX_HIDE"; } \
    || ! grep -q '^DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^struct page \*fake_status = NULL;' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^void initialize_fake_status(void)$' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^int security_context_to_sid_with_policy' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^int security_sid_to_context_with_policy' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^void security_compute_av_user_with_policy' "$FINASU_SELINUX_HIDE" \
    || ! grep -q '^int ksu_handle_execveat_ksud(int \*fd, struct filename \*\*filename_ptr,' "$FINASU_KSI"; then
    echo "::error::FinaSU 适配修复失败，代码结构可能已变化" >&2
    exit 1
  fi
  if grep -qE '^static (int|void) (__nocfi )?security_(context_to_sid_with_policy|sid_to_context_with_policy|compute_av_user_with_policy)' "$FINASU_SELINUX_HIDE"; then
    echo "::error::FinaSU selinux_hide.c 的 security_*_with_policy 仍未全局化（6.6 会链接失败）" >&2
    exit 1
  fi
  if grep -qE 'ksu_syscall_hook_init\(\)|ksu_syscall_hook_manager_(init|exit)\(\)' "$FINASU_INIT"; then
    echo "::error::FinaSU init.c 仍存在指向已移除模块的调用" >&2
    exit 1
  fi
fi

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "临时调整 Android 13 5.15 LTS 头文件上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]]; then
    echo "临时调整 Android 16 6.12 exec.c 上下文"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# ==================== FinaSU 新 selinux_hide 模型适配 ====================
# 自 FinaSU v0.1.0-preview1 起，kernel/feature/selinux_hide.c 换成了 tiann 新形态：
#   移除 fake_state；统一用 backup_sepolicy + security_context_to_sid_with_policy(..., &orig_sid_p, &orig_rc_p)（8 参）；
#   且该函数内部已做“双策略 + 全局 sidtab 同步”（KernelSU #3877/#3873）。
# 此形态下把 SUSFS 主补丁 <6.6 的 SELinux 代码也从 &fake_state 切到 backup_sepolicy + 8 参 _with_policy，
# 并补上权限检查顺序（df03912f）；sidtab 同步由上游 _with_policy 内置，无需外部再移植。
NEW_MODEL=0
FINASU_SELINUX_HIDE="$KERNEL_ROOT/KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$FINASU_SELINUX_HIDE" ] && ! grep -q 'fake_state' "$FINASU_SELINUX_HIDE"; then
  NEW_MODEL=1
fi
if [ "$NEW_MODEL" = 1 ] && [ -f security/selinux/selinuxfs.c ] && grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c; then
  echo "检测到 FinaSU 新 selinux_hide 形态：SUSFS <6.6 的 SELinux 代码切换到 backup_sepolicy + 8 参 _with_policy"
  python3 - <<'PYEOF'
import re as _re, sys as _sys

NEW_FS_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
    "extern int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext, u32 *scontext_len);\n"
    "extern void security_compute_av_user_with_policy(struct selinux_policy *policy, u32 ssid, u32 tsid, u16 tclass, struct av_decision *avd);\n"
)
NEW_HK_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
)

def _sub(path, name, old, new):
    s = open(path, encoding="utf-8", errors="surrogateescape").read()
    n = s.count(old)
    if n != 1:
        print("::warning::%s: %s count=%d (expect 1)" % (path, name, n))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old, new, 1))
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
_sub(fs, "extern", "extern struct selinux_state fake_state;\n", NEW_FS_EXTERNS)
_sub(fs, "ctx", "security_context_to_sid(&fake_state, buf, size, &sid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "sid2ctx", "security_sid_to_context(&fake_state, sid, &canon, &len)",
     "security_sid_to_context_with_policy(backup_sepolicy, sid, &canon, &len)")
_sub(fs, "scon", "security_context_str_to_sid(&fake_state, scon, &ssid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "tcon", "security_context_str_to_sid(&fake_state, tcon, &tsid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "av", "security_compute_av_user(&fake_state, ssid, tsid, tclass, &avd)",
     "security_compute_av_user_with_policy(backup_sepolicy, ssid, tsid, tclass, &avd)")

hk = "security/selinux/hooks.c"
_sub(hk, "extern", "extern struct selinux_state fake_state;\n", NEW_HK_EXTERNS)

# <6.6 形态：多行 resolve(&fake_state, value) -> _with_policy(8 参)
_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
_hs, _n = _re.subn(r"security_context_to_sid\(&fake_state, value, size,\s*\n\s*&sid, GFP_KERNEL\)",
                   "security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
print("%s: setprocattr.ctx <6.6=%d" % (hk, _n))
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)

# >=6.6 形态：把已有的 6 参 _with_policy 调用补成 8 参（新模型签名）
for _lab, _f in (("selinuxfs", fs), ("hooks", hk)):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    _s2, _n2 = _re.subn(r"(security_context_to_sid_with_policy\(backup_sepolicy,[^;]*?, GFP_KERNEL)\)", r"\1, NULL, NULL)", _s)
    if _n2:
        open(_f, "w", encoding="utf-8", errors="surrogateescape").write(_s2)
    print("%s: _with_policy 8-arg normalize=%d" % (_lab, _n2))

_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
# 去掉无条件 SETCURRENT 检查（df03912f）：覆盖 <6.6(&selinux_state) 与 >=6.6(无 state) 两种形态
_removed = False
for _rm in ("\terror = avc_has_perm(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n",
            "\terror = avc_has_perm(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n"):
    if _hs.count(_rm) == 1:
        _hs = _hs.replace(_rm, "", 1)
        _removed = True
        print("%s: rm_early_setcurrent OK" % hk)
        break
if not _removed:
    print("::warning::%s: rm_early_setcurrent not matched" % hk)
# 仅在 backup 解析失败时才检查 SETCURRENT
_seq_done = False
for _old2, _new2, _lab in (
    ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
     "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", "<6.6"),
    ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
     "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", ">=6.6")):
    if _hs.count(_old2) == 1:
        _hs = _hs.replace(_old2, _new2, 1)
        _seq_done = True
        print("%s: seq(%s) OK" % (hk, _lab))
        break
if not _seq_done:
    print("::warning::%s: seq not matched" % hk)
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)
for _f in (fs, hk):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    if "fake_state" in _s:
        _sys.stderr.write("::error::%s 仍有 fake_state 残留\n" % _f)
        _sys.exit(1)
PYEOF
  grep -n 'backup_sepolicy' security/selinux/selinuxfs.c | head -3
  grep -n 'perm_error' security/selinux/hooks.c | head -3
fi

# ==================== 移植 KernelSU 的 SELinux 隐藏侧信道修复（旧 fake_state 形态）====================
# 检测方把 /sys/fs/selinux/{context,access} 与 setprocattr 当 oracle：比对
# 假策略(fake_state)与全局 selinux_state 的 SID、以及权限检查顺序，来识别隐藏。
# SUSFS 主补丁实现的 my_write_context / my_write_access / my_setprocattr 缺这两点，
# 这里按 KernelSU 的做法补齐：
#   - sidtab 同步（KernelSU #3873）：用假策略解析后再同步进全局 sidtab，消除 SID 差异；
#   - 权限检查顺序（KernelSU df03912f）：仅当 backup 解析失败时才做 SETCURRENT 检查。
if [ "${NEW_MODEL:-0}" != 1 ] && [ -f security/selinux/selinuxfs.c ] && grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
  && [ -f security/selinux/hooks.c ] && grep -q 'static int my_setprocattr' security/selinux/hooks.c; then
  python3 - <<'PYEOF'
import re

def sed(path, name, pat, repl):
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    new, n = re.subn(pat, repl, src, count=1)
    if n == 0:
        print("::warning::%s: %s not matched (skip)" % (path, name))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
# my_write_context（<6.6 用 fake_state；>=6.6 用 backup_sepolicy 的 _with_policy 解析）
sed(fs, "ctx(<6.6)", r"(\tlength = security_context_to_sid\(&fake_state, buf, size, &sid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(&selinux_state, buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "ctx(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
# my_write_access scon / tcon
sed(fs, "scon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, scon, &ssid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, scon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "scon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, scon, strlen\(scon\), &ssid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(scon, strlen(scon), &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, tcon, &tsid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, tcon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, tcon, strlen\(tcon\), &tsid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(tcon, strlen(tcon), &tmp_sid, GFP_KERNEL);\n\t}\n")

hk = "security/selinux/hooks.c"
# 去掉无条件 SETCURRENT 检查（<6.6 带 &selinux_state；>=6.6 不带）
sed(hk, "rm_early(<6.6)", r"\terror = avc_has_perm\(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
sed(hk, "rm_early(>=6.6)", r"\terror = avc_has_perm\(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
# 仅在 backup 解析失败时才检查 SETCURRENT，并同步全局 sidtab
sed(hk, "seq+sync(<6.6)", r"(\t\terror = security_context_to_sid\(&fake_state, value, size,\n\t\t\t\t\t\t&sid, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t/* FINASU_SEQ: 仅当 backup 解析失败时才做 SETCURRENT 检查（KernelSU df03912f） */\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(&selinux_state, value, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
sed(hk, "seq+sync(>=6.6)", r"(\t\terror = security_context_to_sid_with_policy\(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t/* FINASU_SEQ: 仅当 backup 解析失败时才做 SETCURRENT 检查（KernelSU df03912f） */\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(str, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
PYEOF
  grep -n 'FINASU_SIDTAB_SYNC' security/selinux/selinuxfs.c | head
  grep -n 'FINASU_SIDTAB_SYNC\|FINASU_SEQ' security/selinux/hooks.c | head
else
  echo "::warning::未找到 SUSFS 的 my_write_context/my_setprocattr，跳过 SELinux 侧信道移植"
fi

# ==================== SUSFS 路径隐藏回退（跨命名空间 / FUSE） ====================
# susfs_add_sus_path（非 loop）在“调用方命名空间”里 kern_path 解析路径；管理器/ksud 常解析不到
# /storage/emulated 这类 FUSE 路径（-ENOENT），于是规则加不进去、路径隐藏失效。
# 这里加回退：解析失败时自动改走 LOOP 机制（内核 workqueue 在 init 命名空间稍后解析并打标记）。
if [ -f fs/susfs.c ] && grep -qF 'void susfs_add_sus_path(void __user **user_info)' fs/susfs.c \
  && ! grep -qF 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c; then
  python3 - <<'PYEOF'
p = "fs/susfs.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
old1 = "void susfs_add_sus_path(void __user **user_info) {"
new1 = "void susfs_add_sus_path_loop(void __user **user_info);\n" + old1
if s.count(old1) != 1:
    print("::warning::fs/susfs.c: susfs_add_sus_path 签名不是预期形态，跳过")
else:
    s = s.replace(old1, new1, 1)
    old2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening file '%s'\\n\", info.target_pathname);\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n")
    new2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening '%s' in current ns, fallback to sus_path_loop\\n\", info.target_pathname);\n"
            "\t\t/* FINASU_SUS_PATH_LOOP_FALLBACK: 调用方命名空间解析不到（常见于 /storage/emulated 等 FUSE 路径）时，\n"
            "\t\t   退回 LOOP 机制，交由内核 workqueue 在 init 命名空间稍后解析并重新打标记 */\n"
            "\t\tsusfs_add_sus_path_loop(user_info);\n"
            "\t\treturn;\n"
            "\t}\n")
    if s.count(old2) != 1:
        print("::warning::fs/susfs.c: susfs_add_sus_path 代码形态不是预期，跳过回退")
    else:
        open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old2, new2, 1))
        print("fs/susfs.c: 已加 SUSFS 路径隐藏 LOOP 回退")
PYEOF
  grep -n 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c | head
else
  echo "::warning::未找到 fs/susfs.c 的 susfs_add_sus_path，跳过路径隐藏回退"
fi

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c; then
  STATFS_USE=$(grep -n 'if (!susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  STATFS_DECL=$(grep -n '^extern int susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  if [[ -n "$STATFS_USE" && -n "$STATFS_DECL" && "$STATFS_DECL" -gt "$STATFS_USE" ]] \
    && grep -q '^static int susfs_statfs_by_dentry(' fs/statfs.c; then
    echo "前移 statfs.c 中 susfs_sus_kstat_spoof_vfs_statfs 的声明"
    sed -i '/^static int susfs_statfs_by_dentry(/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' fs/statfs.c
  fi
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件，上游自带的 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  printf '%s\n' "${SUSFS_REJ_FILES[@]}"
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
    echo "还原 Android 16 6.12 exec.c 临时调整"
    sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi
fi
