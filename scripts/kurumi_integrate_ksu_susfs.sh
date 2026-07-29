#!/usr/bin/env bash
# Integrate current KernelSU-Next plus SuSFS according to susfs4ksu docs:
#   1) install KernelSU-Next release/tag/branch with setup.sh
#   2) clone susfs4ksu separately
#   3) apply kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch to KernelSU-Next
#   4) copy fs/include payload and apply 50_add_susfs_* common patch
# The step is intentionally non-fatal for the whole workflow: it either writes
# kimg/ksu_susfs_ok or exits 0 and lets packaging omit variant 3.

set +e
set -x

rm -f "$GITHUB_WORKSPACE/kimg/ksu_susfs_ok"
BASE="$(cat "$GITHUB_WORKSPACE/kimg/common_base_commit" 2>/dev/null)"
[ -n "$BASE" ] || { echo "WARN: common baseline missing - skipping KSU+susfs variant"; exit 0; }

git -C common reset --hard "$BASE"
git -C common clean -ffd

bake_ksu_version() {
  KB="$(find . -path '*KernelSU-Next/kernel/Kbuild' -o -path '*KernelSU/kernel/Kbuild' 2>/dev/null | head -1)"
  KSU_REPO="$(dirname "$(dirname "$KB")")"
  KSU_TAG="$(cd "$KSU_REPO" 2>/dev/null && git describe --tags --abbrev=0 2>/dev/null || echo v1.0.0)"
  if [ -n "$KB" ] && [ "${KSU_CNT:-0}" -ge 500 ]; then
    awk -v cnt="$KSU_CNT" -v tag="$KSU_TAG" '
      /^# Check if this is a git repository/ && !injected {
        print "# --- Kurumi: hardcoded version for hermetic Kleaf build (no .git/network) ---"
        print "KSU_GIT_VERSION := " cnt
        print "KSU_GIT_TAG := " tag
        print "KSU_GIT_VERSION_VALID := 1"
        print ""
        injected=1
      }
      { print }
    ' "$KB" > "$KB.ktmp" && mv "$KB.ktmp" "$KB"
    echo "--- Kbuild version block AFTER bake (KSU_GIT_VERSION=$KSU_CNT -> KSU_VERSION=$(expr 30000 + "$KSU_CNT"), tag=$KSU_TAG) ---"
    grep -nE 'Kurumi|KSU_GIT_VERSION|KSU_GIT_TAG|KSU_GIT_VERSION_VALID|KernelSU-Next version' "$KB" || true
  else
    echo "WARN: KernelSU-Next Kbuild not found or count too small (KB='$KB' KSU_CNT='$KSU_CNT') -> version NOT baked."
  fi
}

cat > /tmp/kurumi_repair_namespace.py <<'PY_NS'
from pathlib import Path
import re, sys
p = Path('common/fs/namespace.c')
r = Path('common/fs/namespace.c.rej')
if not p.exists() or not r.exists():
    sys.exit(1)
s = p.read_text(errors='ignore')
rej = r.read_text(errors='ignore')
changed = False
if 'CL_COPY_MNT_NS' not in rej and 'susfs_def.h' not in rej:
    sys.exit(1)
if '#include <linux/susfs_def.h>' not in s:
    if '#include <linux/mnt_idmapping.h>\n' in s:
        s = s.replace('#include <linux/mnt_idmapping.h>\n', '#include <linux/mnt_idmapping.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n', 1)
        changed = True
    else:
        m = re.search(r'(#include <linux/[^>]+>\n)(?=\n|#include "internal.h")', s)
        if m:
            s = s[:m.end()] + '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n' + s[m.end():]
            changed = True
need = []
for token, decl in [
    ('susfs_is_current_ksu_domain(', 'extern bool susfs_is_current_ksu_domain(void);'),
    ('susfs_is_sdcard_android_data_not_decrypted', 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;'),
    ('susfs_is_boot_completed_triggered', 'extern bool susfs_is_boot_completed_triggered;'),
    ('susfs_ksu_mnt_group_ida', 'extern struct ida susfs_ksu_mnt_group_ida;'),
    ('susfs_ksu_mounts', 'extern atomic64_t susfs_ksu_mounts;'),
]:
    if token in s and decl not in s:
        need.append(decl)
if 'CL_COPY_MNT_NS' in s and '#define CL_COPY_MNT_NS BIT(25)' not in s:
    need.append('#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */')
if need:
    block = '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n' + '\n'.join(need) + '\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n'
    anchors = ['static unsigned int m_hash_mask __read_mostly;', 'static struct kmem_cache *mnt_cache __ro_after_init;', 'unsigned int sysctl_mount_max __read_mostly']
    for a in anchors:
        idx = s.find(a)
        if idx >= 0:
            s = s[:idx] + block + s[idx:]
            changed = True
            break
if changed:
    p.write_text(s)
    print('namespace repair: applied')
    sys.exit(0)
print('namespace repair: nothing changed')
sys.exit(1)
PY_NS

cat > /tmp/kurumi_repair_after_susfs.py <<'PY_REPAIR'
from pathlib import Path
import re, sys
root = Path('common')
changed_any = False

ksu_sucompat_bool = False
for sp in (root/'KernelSU-Next/kernel/feature/sucompat.c', root/'KernelSU/kernel/feature/sucompat.c'):
    if sp.exists():
        st = sp.read_text(errors='ignore')
        if 'bool ksu_su_compat_enabled' in st and 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)' not in st:
            ksu_sucompat_bool = True


def rw(path, fn):
    global changed_any
    p = Path(path)
    if not p.exists():
        return
    old = p.read_text(errors='ignore')
    new = fn(old)
    if new != old:
        p.write_text(new)
        changed_any = True
        print('KSU+susfs repair:', p, 'fixed')

# Common namespace safety for android14-6.1 moving include/anchor positions.
def fix_namespace(s):
    if 'CONFIG_KSU_SUSFS' not in s and 'susfs_' not in s:
        return s
    if '#include <linux/susfs_def.h>' not in s and any(x in s for x in ('susfs_is_current_ksu_domain', 'susfs_is_sdcard_android_data_not_decrypted', 'susfs_is_boot_completed_triggered', 'susfs_ksu_mnt_group_ida', 'susfs_ksu_mounts', 'DEFAULT_KSU_MNT_ID')):
        anchor = '#include <linux/mnt_idmapping.h>\n'
        if anchor in s:
            s = s.replace(anchor, anchor + '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n', 1)
    need = []
    pairs = [
        ('susfs_is_current_ksu_domain(', 'extern bool susfs_is_current_ksu_domain(void);'),
        ('susfs_is_sdcard_android_data_not_decrypted', 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;'),
        ('susfs_is_boot_completed_triggered', 'extern bool susfs_is_boot_completed_triggered;'),
        ('susfs_ksu_mnt_group_ida', 'extern struct ida susfs_ksu_mnt_group_ida;'),
        ('susfs_ksu_mounts', 'extern atomic64_t susfs_ksu_mounts;'),
    ]
    for token, decl in pairs:
        if token in s and decl not in s:
            need.append(decl)
    if 'CL_COPY_MNT_NS' in s and '#define CL_COPY_MNT_NS BIT(25)' not in s:
        need.append('#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */')
    if need:
        block = '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n' + '\n'.join(need) + '\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n'
        for anchor in ('static unsigned int m_hash_mask __read_mostly;', 'static struct kmem_cache *mnt_cache __ro_after_init;', 'unsigned int sysctl_mount_max __read_mostly'):
            idx = s.find(anchor)
            if idx >= 0:
                s = s[:idx] + block + s[idx:]
                break
    return s

rw(root/'fs/namespace.c', fix_namespace)

# Current susfs4ksu v2.2.0 uses current_uid() inside susfs_def.h.
# Some translation units include susfs_def.h before linux/cred.h, which turns
# current_uid() into an implicit int and breaks -Werror builds. Patch the copied
# header once after copying the SuSFS payload.
def fix_susfs_def_header(s):
    if 'current_uid().val' in s and '#include <linux/cred.h>' not in s:
        if '#define' in s:
            lines = s.split('\n')
            out = []
            inserted = False
            for line in lines:
                out.append(line)
                if not inserted and line.startswith('#define'):
                    out.append('#include <linux/cred.h>')
                    inserted = True
            return '\n'.join(out)
        return '#include <linux/cred.h>\n' + s
    return s

rw(root/'include/linux/susfs_def.h', fix_susfs_def_header)

# Some susfs4ksu history revisions rename hide-sus-mount APIs. Map only when the
# target API is really present in the copied headers/source.
sus_text = ''
for p in (root/'fs/susfs.c', root/'include/linux/susfs.h', root/'include/linux/susfs_def.h'):
    if p.exists():
        sus_text += p.read_text(errors='ignore') + '\n'

def fix_c_file(s):
    if 'susfs_' not in s and 'CMD_SUSFS_' not in s and 'pr_info(' not in s:
        return s
    # Fix accidental literal newlines inside common pr_info format strings if a prior repair produced them.
    s = s.replace('pr_info("sys_reboot: ppptr: 0x%lx \n",', 'pr_info("sys_reboot: ppptr: 0x%lx\\n",')
    s = s.replace('pr_info("sys_reboot: u_pptr: 0x%llx \n",', 'pr_info("sys_reboot: u_pptr: 0x%llx\\n",')
    s = s.replace('pr_info("sys_reboot: u_ptr: 0x%llx \n",', 'pr_info("sys_reboot: u_ptr: 0x%llx\\n",')
    if 'susfs_set_hide_sus_mnts_for_non_su_procs' in s and 'susfs_set_hide_sus_mnts_for_non_su_procs' not in sus_text and 'susfs_set_hide_sus_mnts_for_all_procs' in sus_text:
        s = s.replace('susfs_set_hide_sus_mnts_for_non_su_procs', 'susfs_set_hide_sus_mnts_for_all_procs')
        s = s.replace('CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS', 'CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS')
    if 'susfs_' in s and '#include <linux/susfs.h>' not in s and ('CMD_SUSFS_' in s or 'susfs_set_' in s or 'susfs_add_' in s):
        m = re.search(r'(\n#include [^\n]+\n)', s)
        if m:
            s = s[:m.end()] + '#include <linux/susfs.h>\n' + s[m.end():]
    return s

for p in list((root/'drivers/kernelsu').rglob('*.c')) + list((root/'KernelSU-Next/kernel').rglob('*.c')) + list((root/'KernelSU/kernel').rglob('*.c')):
    rw(p, fix_c_file)

# Do not include the full SuSFS public header from KernelSU selinux/rules.c.
# It drags a heavy linux/sched/signal.h include path into the SELinux policy
# translation unit and trips clang -Warray-bounds in common/include/linux/signal.h.
# rules.c only needs susfs_set_batch_sid(), which we declare from KernelSU's
# selinux.h in the compatibility bridge.
for p in (root/'drivers/kernelsu/selinux/rules.c',
          root/'KernelSU-Next/kernel/selinux/rules.c',
          root/'KernelSU/kernel/selinux/rules.c'):
    if p.exists():
        rw(p, lambda s: s.replace('#include <linux/susfs.h>\n', ''))

# If the current KernelSU-Next kept sucompat as a bool, adapt the common
# susfs patch sites away from static_branch_* declarations.
if ksu_sucompat_bool:
    for p in list((root/'fs').rglob('*.c')) + list((root/'kernel').rglob('*.c')):
        def conv_sucompat_bool(s):
            s = s.replace('extern struct static_key_true ksu_su_compat_enabled;', 'extern bool ksu_su_compat_enabled;')
            s = s.replace('static_branch_likely(&ksu_su_compat_enabled)', 'likely(ksu_su_compat_enabled)')
            s = s.replace('static_branch_unlikely(&ksu_su_compat_enabled)', 'unlikely(ksu_su_compat_enabled)')
            return s
        rw(p, conv_sucompat_bool)

# Ensure KSU_SUSFS defaults to y for CI non-interactive defconfig.
for kc in list((root/'drivers/kernelsu').rglob('Kconfig')) + list((root/'KernelSU-Next/kernel').glob('Kconfig')) + list((root/'KernelSU/kernel').glob('Kconfig')):
    txt = kc.read_text(errors='ignore')
    if 'config KSU_SUSFS' not in txt:
        continue
    lines = txt.split('\n')
    out = []
    in_blk = False
    for line in lines:
        if re.match(r'\s*config\s+KSU_SUSFS\b', line):
            in_blk = True
        elif re.match(r'\s*config\s+', line) and not re.match(r'\s*config\s+KSU_SUSFS\b', line):
            in_blk = False
        if in_blk and re.match(r'\s*default\s+n\s*$', line):
            line = re.sub(r'default\s+n', 'default y', line)
        out.append(line)
    new = '\n'.join(out)
    if new != txt:
        kc.write_text(new)
        changed_any = True
        print('KSU+susfs repair:', kc, 'KSU_SUSFS default y')

print('KSU+susfs repair pass complete; changed=', changed_any)
PY_REPAIR

cat > /tmp/kurumi_prepare_ksu_susfs_compat.py <<'PY_KSU_COMPAT'
from pathlib import Path
import sys
import re

root = Path('common')
ksu = root / 'KernelSU-Next' / 'kernel'
if not ksu.exists():
    ksu = root / 'KernelSU' / 'kernel'
if not ksu.exists():
    print('KSU+susfs compat: KernelSU kernel dir not found')
    sys.exit(1)

changed = False

def write_if_changed(path: Path, text: str):
    global changed
    old = path.read_text(errors='ignore') if path.exists() else ''
    if old != text:
        path.write_text(text)
        changed = True
        print('KSU+susfs compat:', path, 'updated')

kconfig = ksu / 'Kconfig'
if kconfig.exists():
    txt = kconfig.read_text(errors='ignore')
    if 'config KSU_SUSFS' not in txt:
        block = '''

menu "KernelSU - SUSFS"
config KSU_SUSFS
	bool "KernelSU addon - SUSFS"
	depends on KSU
	depends on THREAD_INFO_IN_TASK
	default y
	help
	  Patch and Enable SUSFS to kernel with KernelSU.

config KSU_SUSFS_SUS_PATH
	bool "Enable to hide suspicious path"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "Enable to hide suspicious mounts"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "Enable to spoof suspicious kstat"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_UNAME
	bool "Enable to spoof uname"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_ENABLE_LOG
	bool "Enable logging susfs log to kernel"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "Enable to automatically hide ksu and susfs symbols from /proc/kallsyms"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "Enable to spoof /proc/bootconfig (gki) or /proc/cmdline (non-gki)"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable to redirect a path to be opened with another path"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MAP
	bool "Enable to hide some mmapped real file from different proc maps interfaces"
	depends on KSU_SUSFS
	default y

endmenu
'''
        pos = txt.rfind('\nendmenu')
        if pos >= 0:
            txt = txt[:pos] + block + txt[pos:]
        else:
            txt += block
        write_if_changed(kconfig, txt)

mk = ksu / 'Makefile'
if mk.exists():
    txt = mk.read_text(errors='ignore')
    if 'SUSFS_VERSION' not in txt:
        add = '''

## For susfs stuff ##
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info )
$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
else
$(info -- You have not integrated susfs in your kernel yet.)
$(info -- Read: https://gitlab.com/simonpunk/susfs4ksu)
endif
'''
        txt = txt.replace('\n# Keep a new line here!!', add + '\n# Keep a new line here!!')
        write_if_changed(mk, txt)

kb = ksu / 'Kbuild'
if kb.exists():
    txt = kb.read_text(errors='ignore')
    if 'kurumi_susfs_compat.o' not in txt:
        txt = txt.replace('kernelsu-objs := core/init.o\n', 'kernelsu-objs := core/init.o\n\nkernelsu-objs += kurumi_susfs_compat.o\n', 1)
        write_if_changed(kb, txt)

compat = ksu / 'kurumi_susfs_compat.c'
compat_src = '#include <linux/cred.h>\n#include <linux/fs.h>\n#include <linux/namei.h>\n#include <linux/printk.h>\n#include <linux/static_key.h>\n#include <linux/string.h>\n#include <linux/types.h>\n#include <linux/uaccess.h>\n#include <linux/binfmts.h>\n#include <linux/uidgid.h>\n#include <linux/slab.h>\n#include <linux/task_work.h>\n#include <linux/utsname.h>\n#include <linux/version.h>\n\n#include "uapi/supercall.h"\n#include "supercall/supercall.h"\n#include "manager/manager_identity.h"\n#include "sulog/event.h"\n#include "selinux/selinux.h"\n\nstruct user_arg_ptr;\nextern void ksu_handle_execveat_ksud(const char *path, struct user_arg_ptr *argv);\nextern uint32_t ksuver_override;\n\nDEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);\nDEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);\n\n__attribute__((weak, cold)) int ksu_handle_input_handle_event(unsigned int *type,\n\t\t\tunsigned int *code, int *value)\n{\n\treturn 0;\n}\n\nint ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n\t\t\tvoid *argv, void *envp, int *flags)\n{\n\tif (filename_ptr && *filename_ptr && (*filename_ptr)->name)\n\t\tksu_handle_execveat_ksud((*filename_ptr)->name, (struct user_arg_ptr *)argv);\n\treturn 0;\n}\n\nint ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n\t\t\tvoid *argv, void *envp, int *flags)\n{\n\treturn 0;\n}\n\nint ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n\t\t\tint *mode, int *flags)\n{\n\treturn 0;\n}\n\nint ksu_handle_stat(int *dfd, struct filename **filename, int *flags)\n{\n\treturn 0;\n}\n\nvoid ksu_handle_sys_read(unsigned int fd) {}\nvoid ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr) {}\n\nint ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)\n{\n\tvoid __user *uarg = arg ? *arg : NULL;\n\tunsigned long reply = (unsigned long)uarg;\n\n\tif (magic1 == KSU_INSTALL_MAGIC1 && magic2 == KSU_INSTALL_MAGIC2) {\n\t\tint fd = ksu_install_fd();\n\t\tif (uarg && copy_to_user(uarg, &fd, sizeof(fd)))\n\t\t\tpr_warn("install fd reply failed\\n");\n\t\treturn 0;\n\t}\n\tif (magic2 == CHANGE_MANAGER_UID) {\n\t\tif (current_uid().val != 0)\n\t\t\treturn 1;\n\t\tksu_set_manager_appid(cmd);\n\t\tif (uarg && cmd == ksu_get_manager_appid() &&\n\t\t    copy_to_user(uarg, &reply, sizeof(reply)))\n\t\t\tpr_warn("manager uid reply failed\\n");\n\t\treturn 0;\n\t}\n\tif (magic2 == GET_SULOG_DUMP_V2) {\n\t\tif (current_uid().val != 0)\n\t\t\treturn 1;\n\t\tif (!ksu_sulog_handle_compat_dump(uarg) && uarg &&\n\t\t    copy_to_user(uarg, &reply, sizeof(reply)))\n\t\t\tpr_warn("sulog dump reply failed\\n");\n\t\treturn 0;\n\t}\n\tif (magic2 == CHANGE_KSUVER) {\n\t\tif (current_uid().val != 0)\n\t\t\treturn 1;\n\t\tksuver_override = cmd;\n\t\tif (uarg && copy_to_user(uarg, &reply, sizeof(reply)))\n\t\t\tpr_warn("ksuver reply failed\\n");\n\t\treturn 0;\n\t}\n\tif (magic2 == CHANGE_SPOOF_UNAME) {\n\t\tchar release_buf[65];\n\t\tchar version_buf[65];\n\t\tstatic char original_release_buf[65];\n\t\tstatic char original_version_buf[65];\n\t\tuint64_t u_pptr = 0, u_ptr = 0;\n\t\tvoid __user **ppptr = (void __user **)uarg;\n\t\tstruct new_utsname *u;\n\t\tif (current_uid().val != 0 || !ppptr)\n\t\t\treturn 1;\n\t\tif (copy_from_user(&u_pptr, ppptr, sizeof(u_pptr)))\n\t\t\treturn 0;\n\t\tif (copy_from_user(&u_ptr, (void __user *)u_pptr, sizeof(u_ptr)))\n\t\t\treturn 0;\n\t\tif (strncpy_from_user(release_buf, (char __user *)u_ptr, sizeof(release_buf)) < 0)\n\t\t\treturn 0;\n\t\trelease_buf[sizeof(release_buf) - 1] = \'\\0\';\n\t\tif (strncpy_from_user(version_buf, (char __user *)(u_ptr + strlen(release_buf) + 1), sizeof(version_buf)) < 0)\n\t\t\treturn 0;\n\t\tversion_buf[sizeof(version_buf) - 1] = \'\\0\';\n\t\tif (original_release_buf[0] == \'\\0\') {\n\t\t\tstruct new_utsname *u_curr = utsname();\n\t\t\tstrscpy(original_release_buf, u_curr->release, sizeof(original_release_buf));\n\t\t\tstrscpy(original_version_buf, u_curr->version, sizeof(original_version_buf));\n\t\t}\n\t\tif (!strcmp(release_buf, "default") || !strcmp(version_buf, "default")) {\n\t\t\tmemcpy(release_buf, original_release_buf, sizeof(release_buf));\n\t\t\tmemcpy(version_buf, original_version_buf, sizeof(version_buf));\n\t\t}\n\t\tu = utsname();\n\t\tdown_write(&uts_sem);\n\t\tstrscpy(u->release, release_buf, sizeof(u->release));\n\t\tstrscpy(u->version, version_buf, sizeof(u->version));\n\t\tup_write(&uts_sem);\n\t\tif (uarg && copy_to_user(uarg, &reply, sizeof(reply)))\n\t\t\tpr_warn("spoof uname reply failed\\n");\n\t\treturn 0;\n\t}\n\treturn 1;\n}\n'
write_if_changed(compat, compat_src)
# Export the KernelSU-Next SELinux-hide internals that the common SuSFS
# selinuxfs/hooks patch references as externs. The upstream SuSFS KSU-side
# patch would do this, but it no longer applies cleanly to current KSU-Next.
selhide = ksu / 'feature' / 'selinux_hide.c'
if selhide.exists():
    txt = selhide.read_text(errors='ignore')
    txt = txt.replace('static bool ksu_selinux_hide_enabled __read_mostly = false;', 'bool ksu_selinux_hide_enabled __read_mostly = false;')
    txt = txt.replace('static bool ksu_selinux_hide_running __read_mostly = false;', 'bool ksu_selinux_hide_running __read_mostly = false;')
    txt = txt.replace('static struct selinux_state fake_state;', 'struct selinux_state fake_state;')
    txt = txt.replace('static DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);', 'DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);')
    txt = txt.replace('static struct page *fake_status = NULL;', 'struct page *fake_status = NULL;')
    txt = re.sub(r'static\s+void\s+initialize_fake_status\s*\(\s*\)', 'void initialize_fake_status(void)', txt)
    write_if_changed(selhide, txt)

# Add the small SELinux/SID helpers normally supplied by the SuSFS KSU-side patch.
selc = ksu / 'selinux' / 'selinux.c'
if selc.exists():
    txt = selc.read_text(errors='ignore')
    if 'u32 susfs_ksu_sid __read_mostly' not in txt:
        txt += '\n\n#ifdef CONFIG_KSU_SUSFS\n#define KERNEL_INIT_DOMAIN "u:r:init:s0"\n#define KERNEL_ZYGOTE_DOMAIN "u:r:zygote:s0"\n#define KERNEL_PRIV_APP_DOMAIN "u:r:priv_app:s0:c512,c768"\n\nu32 susfs_ksu_sid __read_mostly = 0;\nu32 susfs_init_sid __read_mostly = 0;\nu32 susfs_zygote_sid __read_mostly = 0;\nu32 susfs_priv_app_sid __read_mostly = 0;\n\nstatic inline void susfs_set_sid(const char *secctx_name, u32 *out_sid)\n{\n\tint err;\n\tif (!secctx_name || !out_sid)\n\t\treturn;\n\terr = security_secctx_to_secid(secctx_name, strlen(secctx_name), out_sid);\n\tif (err)\n\t\tpr_err("failed setting sid for \'%s\', err: %d\\\\n", secctx_name, err);\n}\n\nbool susfs_is_sid_equal(const struct cred *cred, u32 sid2)\n{\n#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)\n\tconst struct task_security_struct *tsec = selinux_cred(cred);\n#else\n\tconst struct cred_security_struct *tsec = selinux_cred(cred);\n#endif\n\treturn tsec && tsec->sid == sid2;\n}\n\nu32 susfs_get_sid_from_name(const char *secctx_name)\n{\n\tu32 out_sid = 0;\n\tif (secctx_name)\n\t\tsecurity_secctx_to_secid(secctx_name, strlen(secctx_name), &out_sid);\n\treturn out_sid;\n}\n\nu32 susfs_get_current_sid(void) { return current_sid(); }\nbool susfs_is_current_zygote_domain(void) { return unlikely(current_sid() == susfs_zygote_sid); }\nbool susfs_is_current_ksu_domain(void) { return unlikely(current_sid() == susfs_ksu_sid); }\nbool susfs_is_current_init_domain(void) { return unlikely(current_sid() == susfs_init_sid); }\n\nvoid susfs_set_batch_sid(void)\n{\n\tsusfs_set_sid(KERNEL_ZYGOTE_DOMAIN, &susfs_zygote_sid);\n\tsusfs_set_sid(KERNEL_SU_CONTEXT, &susfs_ksu_sid);\n\tsusfs_set_sid(KERNEL_INIT_DOMAIN, &susfs_init_sid);\n\tsusfs_set_sid(KERNEL_PRIV_APP_DOMAIN, &susfs_priv_app_sid);\n}\n#endif /* CONFIG_KSU_SUSFS */\n'
        write_if_changed(selc, txt)

selh = ksu / 'selinux' / 'selinux.h'
if selh.exists():
    txt = selh.read_text(errors='ignore')
    if 'susfs_is_current_ksu_domain' not in txt:
        txt = txt.replace('\n#endif', '\n\n#ifdef CONFIG_KSU_SUSFS\nbool susfs_is_sid_equal(const struct cred *cred, u32 sid2);\nu32 susfs_get_sid_from_name(const char *secctx_name);\nu32 susfs_get_current_sid(void);\nvoid susfs_set_batch_sid(void);\nbool susfs_is_current_zygote_domain(void);\nbool susfs_is_current_ksu_domain(void);\nbool susfs_is_current_init_domain(void);\n#endif\n#endif', 1)
        write_if_changed(selh, txt)

rules = ksu / 'selinux' / 'rules.c'
if rules.exists():
    txt = rules.read_text(errors='ignore')
    if 'susfs_set_batch_sid();' not in txt and 'reset_avc_cache();' in txt:
        txt = txt.replace('reset_avc_cache();', 'reset_avc_cache();\n#ifdef CONFIG_KSU_SUSFS\n\tsusfs_set_batch_sid();\n#endif', 1)
        write_if_changed(rules, txt)

init = ksu / 'core' / 'init.c'
if init.exists():
    txt = init.read_text(errors='ignore')
    if '#include <linux/susfs.h>' not in txt:
        txt = txt.replace('#include <linux/workqueue.h>\n', '#include <linux/workqueue.h>\n#include <linux/susfs.h>\n', 1)
    if 'susfs_init();' not in txt:
        anchor = 'ksu_syscall_hook_init();\n'
        ins = 'ksu_syscall_hook_init();\n\n#ifdef CONFIG_KSU_SUSFS\n\tsusfs_init();\n#endif\n'
        if anchor in txt:
            txt = txt.replace(anchor, ins, 1)
        else:
            txt = txt.replace('ksu_feature_init();\n', '#ifdef CONFIG_KSU_SUSFS\n\tsusfs_init();\n#endif\n\n\tksu_feature_init();\n', 1)
    write_if_changed(init, txt)

for rel in ['hook/setuid_hook.c', 'hook/setuid_hook.h', 'hook/syscall_event_bridge.c']:
    path = ksu / rel
    if not path.exists():
        continue
    txt = path.read_text(errors='ignore')
    txt = txt.replace('int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)',
                      'int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid, uid_t suid)')
    txt = txt.replace('ksu_handle_setresuid(old_uid, current_uid().val);',
                      'ksu_handle_setresuid(old_uid, current_uid().val, current_uid().val);')
    write_if_changed(path, txt)

for pat in ('*.rej', '*.orig'):
    for f in ksu.parent.rglob(pat):
        try:
            f.unlink()
            changed = True
        except FileNotFoundError:
            pass

print('KSU+susfs compat: completed; changed=', changed)
PY_KSU_COMPAT

# 1) Install current KernelSU-Next first.
# For KSU+SuSFS, default to the latest
# tagged release (same cadence as Manager releases). Explicit branch/tag still
# works by setting KSU_SUSFS_REF, e.g. next/stable/dev/vX.Y.Z.
KSU_REQ="${KSU_SUSFS_REF:-latest}"
echo "KSU+susfs: KernelSU-Next request: $KSU_REQ"
if [ -n "$KSU_REQ" ] && [ "$KSU_REQ" != "auto" ] && [ "$KSU_REQ" != "latest" ]; then
  ( cd common && curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSU_REQ" )
else
  ( cd common && curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash )
fi
ksu_rc=$?
if [ "$ksu_rc" != 0 ]; then
  echo "WARN: KernelSU-Next setup failed (ksu_rc=$ksu_rc) - KSU+susfs variant skipped."
  exit 0
fi

KSU_REPO="common/KernelSU-Next"
[ -d "$KSU_REPO" ] || KSU_REPO="common/KernelSU"
[ -d "$KSU_REPO" ] || { echo "WARN: KernelSU repo not found after setup - KSU+susfs variant skipped."; exit 0; }
KSU_CNT="$(git -C "$KSU_REPO" rev-list --count HEAD 2>/dev/null || echo 0)"
KSU_VER="$((30000 + KSU_CNT))"
KSU_TAG="$(git -C "$KSU_REPO" describe --tags --abbrev=0 2>/dev/null || git -C "$KSU_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "KSU+susfs: KernelSU-Next selected tag/ref: $KSU_TAG; commit_count=$KSU_CNT; KSU_VERSION=$KSU_VER"
if [ "${KSU_CNT:-0}" -lt 500 ]; then
  echo "WARN: KernelSU-Next history too shallow ($KSU_CNT) -> driver would report bad version. Skipping KSU+susfs variant."
  exit 0
fi
if [ "$KSU_VER" -lt "${KSU_SUSFS_MIN_VERSION:-33188}" ] && [ "${KSU_SUSFS_ALLOW_OLD:-false}" != true ]; then
  echo "WARN: KernelSU-Next KSU_VERSION=$KSU_VER is below manager minimum ${KSU_SUSFS_MIN_VERSION:-33188}; KSU+susfs variant skipped."
  exit 0
fi

# 2) Clone SuSFS separately. Prefer latest version-bump commit on the branch,
# because upstream README says tag/release tag or a 'Bump version to vX.X.X'
# commit usually patches cleaner than an arbitrary moving HEAD. Explicit
# SUSFS_REF can override this.
rm -rf susfs4ksu
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "${SUSFS_BRANCH:-gki-android14-6.1}" susfs4ksu
sus_clone_rc=$?
if [ "$sus_clone_rc" != 0 ]; then
  echo "WARN: failed to clone susfs4ksu (rc=$sus_clone_rc) - KSU+susfs variant skipped."
  exit 0
fi
SUS_REQ="${SUSFS_REF:-latest-bump}"
if [ -n "$SUS_REQ" ] && [ "$SUS_REQ" != "auto" ] && [ "$SUS_REQ" != "latest" ] && [ "$SUS_REQ" != "latest-bump" ]; then
  git -C susfs4ksu checkout "$SUS_REQ" || { echo "WARN: requested SUSFS_REF '$SUS_REQ' not found - KSU+susfs variant skipped."; exit 0; }
else
  BUMP="$(git -C susfs4ksu log --grep='Bump version to v' -n 1 --format='%H' 2>/dev/null)"
  if [ -n "$BUMP" ]; then
    git -C susfs4ksu checkout "$BUMP"
    echo "KSU+susfs: selected latest susfs4ksu version-bump commit: $(git -C susfs4ksu log -1 --oneline)"
  else
    echo "KSU+susfs: no 'Bump version to vX.X.X' commit found; using branch HEAD: $(git -C susfs4ksu rev-parse --short HEAD)"
  fi
fi

echo "KSU+susfs: using susfs4ksu revision: $(git -C susfs4ksu rev-parse --short HEAD)"
SUS="$PWD/susfs4ksu/kernel_patches"
KSU_PATCH="$SUS/KernelSU/10_enable_susfs_for_ksu.patch"
[ -f "$KSU_PATCH" ] || { echo "WARN: KSU-side SuSFS patch missing: $KSU_PATCH"; exit 0; }

# 3) Apply KSU-side SuSFS patch to the actual KernelSU-Next repository.
(
  cd "$KSU_REPO" && patch -p1 --fuzz=3 --no-backup-if-mismatch < "$KSU_PATCH"
)
ksu_patch_rc=$?
KSU_REJ="$(cd "$KSU_REPO" && find . -name '*.rej' 2>/dev/null | sort)"
if [ "$ksu_patch_rc" != 0 ] || [ -n "$KSU_REJ" ]; then
  echo '=================== KSU-side susfs .rej DUMP ==================='
  for r in $KSU_REJ; do echo "----- $KSU_REPO/$r -----"; sed -n '1,180p' "$KSU_REPO/$r"; done
  echo '================================================================='
  echo "WARN: KSU-side susfs patch did NOT apply cleanly to current KernelSU-Next ($KSU_TAG)."
  echo "WARN: reverting partial KSU-side patch and continuing with Kurumi KSU/SuSFS compatibility bridge instead of skipping variant 3."
  git -C "$KSU_REPO" reset --hard -q HEAD
  git -C "$KSU_REPO" clean -ffd -q
  python3 /tmp/kurumi_prepare_ksu_susfs_compat.py || {
    echo "WARN: KSU+susfs compatibility preparation failed -> variant skipped."
    exit 0
  }
else
  echo "KSU+susfs: KSU-side patch applied cleanly."
fi

grep -Rqs 'config[[:space:]]\+KSU_SUSFS' "$KSU_REPO/kernel" common/drivers/kernelsu 2>/dev/null || {
  echo "WARN: KSU_SUSFS Kconfig symbol not found after KSU-side patch/compat - KSU+susfs variant skipped."
  exit 0
}

# 4) Copy SuSFS common payload and apply the android14-6.1 common patch.
SUS_COMMON_PATCH="$SUS/50_add_susfs_in_gki-android14-6.1.patch"
if [ ! -f "$SUS_COMMON_PATCH" ]; then
  SUS_COMMON_PATCH="$(find "$SUS" -maxdepth 1 -type f \( -name '50_add_susfs_in_gki-android14-6.1.patch' -o -name '50_add_susfs_in_kernel-6.1*.patch' -o -name '50_add_susfs*.patch' \) | head -1)"
fi
[ -f "$SUS_COMMON_PATCH" ] || { echo "WARN: susfs common patch missing for android14-6.1"; exit 0; }
cp -v "$SUS"/fs/* common/fs/ 2>/dev/null
cp -v "$SUS"/include/linux/* common/include/linux/ 2>/dev/null
(
  cd common && patch -p1 --fuzz=3 --no-backup-if-mismatch < "$SUS_COMMON_PATCH"
)
sus_rc=$?
REJ="$(cd common && find . -name '*.rej' 2>/dev/null | sort)"
if [ "$sus_rc" != 0 ] || [ -n "$REJ" ]; then
  echo '=================== common susfs .rej DUMP ==================='
  for r in $REJ; do echo "----- common/$r -----"; sed -n '1,180p' "common/$r"; done
  echo '==============================================================='
  if [ "$REJ" = "./fs/namespace.c.rej" ] && python3 /tmp/kurumi_repair_namespace.py; then
    rm -f common/fs/namespace.c.rej
    REJ="$(cd common && find . -name '*.rej' 2>/dev/null | sort)"
    if [ -z "$REJ" ]; then
      echo "KSU+susfs: repaired known fs/namespace.c hunk reject; continuing."
      sus_rc=0
    fi
  fi
  if [ "$sus_rc" != 0 ] || [ -n "$REJ" ]; then
    echo "WARN: susfs common kernel patch did NOT apply cleanly -> KSU+susfs variant skipped."
    ( cd common && find . -name '*.rej' -delete; find . -name '*.orig' -delete ) 2>/dev/null
    exit 0
  fi
fi

python3 /tmp/kurumi_repair_after_susfs.py || {
  echo "WARN: KSU+susfs post-patch repair failed -> variant skipped."
  exit 0
}

# One more explicit non-interactive enable pass.
for kc in $(grep -rlE 'config[[:space:]]+KSU_SUSFS' "$KSU_REPO/kernel" common/drivers/kernelsu common 2>/dev/null | sort -u); do
  echo "susfs: flipping defaults to y in $kc"
  awk '
    /^[[:space:]]*config[[:space:]]+KSU_SUSFS/ {blk=1}
    /^[[:space:]]*config[[:space:]]/ && $0 !~ /^[[:space:]]*config[[:space:]]+KSU_SUSFS/ {blk=0}
    { if (blk && $0 ~ /^[[:space:]]*default[[:space:]]+n[[:space:]]*$/) sub(/default[[:space:]]+n/,"default y"); print }
  ' "$kc" > "$kc.ktmp" && mv "$kc.ktmp" "$kc"
done

grep -Rqs 'config[[:space:]]\+KSU_SUSFS' "$KSU_REPO/kernel" common/drivers/kernelsu common 2>/dev/null || {
  echo "WARN: KSU_SUSFS Kconfig symbol not present after all patches - KSU+susfs variant skipped."
  exit 0
}

bake_ksu_version

echo "$KSU_TAG" > "$GITHUB_WORKSPACE/kimg/ksu_susfs_ref"
echo "$KSU_VER" > "$GITHUB_WORKSPACE/kimg/ksu_susfs_version"
echo "$KSU_CNT" > "$GITHUB_WORKSPACE/kimg/ksu_susfs_commit_count"
echo ok > "$GITHUB_WORKSPACE/kimg/ksu_susfs_ok"
echo "KSU+susfs integration OK -> building variant 3."
set +x
exit 0
