// SPDX-License-Identifier: GPL-2.0
/*
 * hp_raw —— HP OMEN BIOS WMI 原始命令探针（8D3F / OMEN 16-am0xxx）
 *
 * 为什么要它：DSDT 里 \_SB.WMID.HWMC 把 HP 的所有固件命令统一成
 *	COMD(0x01=BIOS Read / 0x02=BIOS Write / 0x20008=GM 系列) + CMDT(命令号)
 *	+ 数据缓冲。hp-wmi 驱动只暴露了它自己认识的那几个，
 *	OMEN 的 CPU/GPU 功耗相关命令（0x1A/0x21/0x22/0x28/0x31/0x4C...）拿不到。
 *	这个模块提供一条原始通道，用来把 AML 里列出的命令全部读一遍。
 *
 * ABI 完全照抄 omen_wmi_boost 的 hp_gm_query()（同一份 WMAA 输入包格式）。
 *
 * sysfs: /sys/kernel/hp_raw/
 *	query       WO   "COMD CMDT OUTSIZE [hexdata]"  → 执行一次
 *	result      RO   上次回包的十六进制 + 长度
 *	last_error  RO   上次的返回码/错误
 *	allow_write WO   写 1 才允许 COMD=0x02（默认禁止：写 EC 有变砖风险）
 *	dsm         WO   "FUNC [hexdata...]" → 调 \_SB.NPCF._DSM（HP 的 CPU PL 入口）
 *	dsm_result  RO   上次 _DSM 返回的 hexdump
 *	ecram       WO   "[偏移] [字节数]" → 直读 EC RAM（只读，走 ACPI EC 驱动）
 *	ecram_result RO 上次 EC RAM 读数的结果
 *	ecwrite     WO   "偏移 值" → 直写 EC RAM 单字节（需 allow_write=1）
 *	peek        WO   "偏移 [字节数]" → 读 GNVS
 *	phys        WO   "物理地址 [偏移] [字节数]" → 读任意 SystemMemory（只读）
 *
 * 风险：写命令会真的打到 EC/SMM。allow_write 只是防止手滑，不是安全边界。
 */
#include <linux/acpi.h>
#include <linux/io.h>
#include <linux/kobject.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/sysfs.h>

#define DRV_NAME	"hp_raw"
#define HPWMI_BIOS_GUID	"5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
#define HPWMI_SIGNATURE	0x55434553		/* "SECU" */

#define CMD_READ	0x00000001
#define CMD_WRITE	0x00000002
#define CMD_GM		0x00020008

#define MAX_RESULT	4096

struct bios_args {
	u32 signature;
	u32 command;
	u32 commandtype;
	u32 datasize;
	u8 data[];
};

struct bios_return {
	u32 sigpass;
	u32 return_code;
};

/* AML 审计结论（dsdt.dsl 里逐条看过）：
 * 真只读（只读 EC 字段/回复包，不碰硬件）：
 *   GM 0x21 0x23 0x26 0x28 0x2A
 * 有副作用，必须 allow_write=1 才放行：
 *   GM 0x10(EC0.OMCC=1) 0x12(FFFS) 0x1A(HPCM + DTPC→NPCF.*) 0x22(NPCF.CTGP/DBAC/DBDC)
 *   GM 0x27(FFFS) 0x29(ECL1/ECL2/ECL4 ← CPU PL 的真正入口！) 0x2E(SRP1/SRP2)
 * COMD=1（BIOS Read）走 EC mailbox，会给 EC 发命令，风险中等，单独放行。
 */
static int is_audited_read(u32 comd, u32 cmdt)
{
	if (comd == CMD_READ)
		return 1;
	if (comd == CMD_GM) {
		switch (cmdt) {
		case 0x21: case 0x23: case 0x26: case 0x28: case 0x2A:
			return 1;
		default:
			return 0;
		}
	}
	if (comd == CMD_WRITE)
		return 0;
	/* 其它 COMD（如 0x20002 电池类）一律按写处理 */
	return 0;
}

static DEFINE_MUTEX(raw_lock);
static bool allow_write;
static char result_hex[MAX_RESULT * 3 + 64];
static char err_str[160] = "none";
static u8 last_comd, last_cmdt;

module_param(allow_write, bool, 0644);
MODULE_PARM_DESC(allow_write, "允许 COMD=0x02 写命令（默认 N，写 EC 有变砖风险）");

/* AML 的 WMAA 有 5 个方法号，按返回缓冲大小选（同 omen_wmi_boost） */
static int encode_method_id(int outsize)
{
	if (outsize > 4096)
		return -EINVAL;
	if (outsize > 1024)
		return 5;
	if (outsize > 128)
		return 4;
	if (outsize > 4)
		return 3;
	if (outsize > 0)
		return 2;
	return 1;
}

static int raw_query(u32 comd, u32 cmdt, const u8 *in, int insize,
		     u8 *out, int outsize)
{
	struct acpi_buffer input, output = { ACPI_ALLOCATE_BUFFER, NULL };
	struct bios_args *args;
	union acpi_object *obj = NULL;
	struct bios_return *rsp;
	size_t args_sz;
	acpi_status ast;
	int mid, padded_in, out_len, ret = 0;

	mid = encode_method_id(outsize);
	if (mid < 0)
		return mid;

	padded_in = max(insize, 128);
	args_sz = struct_size(args, data, padded_in);
	args = kzalloc(args_sz, GFP_KERNEL);
	if (!args)
		return -ENOMEM;

	args->signature = HPWMI_SIGNATURE;
	args->command = comd;
	args->commandtype = cmdt;
	args->datasize = insize;
	if (insize > 0)
		memcpy(args->data, in, insize);

	input.length = args_sz;
	input.pointer = args;

	ast = wmi_evaluate_method(HPWMI_BIOS_GUID, 0, mid, &input, &output);
	if (ACPI_FAILURE(ast)) {
		ret = -EIO;
		pr_err("%s: WMI comd=0x%x cmdt=0x%x 调用失败: %s\n",
		       DRV_NAME, comd, cmdt, acpi_format_exception(ast));
		snprintf(err_str, sizeof(err_str), "AE:%s (comd=0x%x cmdt=0x%x)",
			 acpi_format_exception(ast), comd, cmdt);
		goto out;
	}

	obj = output.pointer;
	if (!obj || obj->type != ACPI_TYPE_BUFFER ||
	    obj->buffer.length < sizeof(*rsp)) {
		ret = -EINVAL;
		snprintf(err_str, sizeof(err_str), "回包格式异常 type=%d len=%d",
			 obj ? obj->type : -1,
			 obj ? obj->buffer.length : -1);
		goto out;
	}

	rsp = (struct bios_return *)obj->buffer.pointer;
	if (rsp->return_code) {
		ret = -EIO;
		snprintf(err_str, sizeof(err_str),
			 "固件返回码 0x%x (comd=0x%x cmdt=0x%x)%s",
			 rsp->return_code, comd, cmdt,
			 rsp->return_code == 0x03 ? " = 未知命令" :
			 rsp->return_code == 0x04 ? " = 未知命令类型" : "");
		goto out;
	}

	out_len = 0;
	if (outsize) {
		out_len = min_t(int, outsize,
				(int)obj->buffer.length - (int)sizeof(*rsp));
		if (out_len > 0) {
			memcpy(out, (u8 *)rsp + sizeof(*rsp), out_len);
			if (out_len < outsize)
				memset(out + out_len, 0, outsize - out_len);
		} else {
			out_len = 0;
		}
	}
	snprintf(err_str, sizeof(err_str), "ok (comd=0x%x cmdt=0x%x, %d 字节)",
		 comd, cmdt, out_len);

out:
	kfree(obj);
	kfree(args);
	return ret;
}

static ssize_t query_store(struct kobject *kobj, struct kobj_attribute *attr,
			   const char *buf, size_t count)
{
	u32 comd, cmdt, outsize = 8;
	static u8 out[MAX_RESULT];
	u8 in[128] = { 0 };
	int insize = 0, ret = -EINVAL;
	char *copy, *p, *tok;
	size_t i;

	copy = kstrdup(buf, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	p = copy;

	tok = strsep(&p, " \t\n");
	if (!tok || kstrtou32(tok, 0, &comd)) { ret = -EINVAL; goto free; }
	tok = strsep(&p, " \t\n");
	if (!tok || kstrtou32(tok, 0, &cmdt)) { ret = -EINVAL; goto free; }
	tok = strsep(&p, " \t\n");
	if (tok && *tok) {
		if (kstrtou32(tok, 0, &outsize)) { ret = -EINVAL; goto free; }
		if (outsize > MAX_RESULT) { ret = -E2BIG; goto free; }
	}
	if (!is_audited_read(comd, cmdt) && !allow_write) {
		ret = -EPERM;
		snprintf(err_str, sizeof(err_str),
			 "非只读命令被拦 (comd=0x%x cmdt=0x%x)：确认后再 echo 1 > allow_write",
			 comd, cmdt);
		goto free;
	}

	while ((tok = strsep(&p, " \t\n")) != NULL) {
		unsigned long v;
		if (!*tok)
			continue;
		if (kstrtoul(tok, 16, &v) || v > 0xff || insize >= (int)sizeof(in)) {
			ret = -EINVAL;
			goto free;
		}
		in[insize++] = (u8)v;
	}

	last_comd = (u8)comd;
	last_cmdt = (u8)cmdt;
	ret = raw_query(comd, cmdt, in, insize, out, outsize);
	if (ret < 0)
		goto free;

	/* hex 结果：游标式拼接，别拿 scnprintf 的返回值当偏移 */
	{
		char *q = result_hex;
		int n = sizeof(result_hex), w;

		w = scnprintf(q, n, "%02x %02x |", comd, cmdt);
		q += w; n -= w;
		for (i = 0; i < (size_t)outsize && n > 4; i++) {
			w = scnprintf(q, n, "%02x ", out[i]);
			q += w; n -= w;
		}
	}
	pr_info("%s: comd=0x%02x cmdt=0x%02x -> %*ph\n",
		DRV_NAME, comd, cmdt, min_t(int, outsize, 64), out);
	ret = count;
free:
	kfree(copy);
	if (ret < 0)
		pr_warn("%s: comd=0x%x cmdt=0x%x 失败: %s\n",
			DRV_NAME, comd, cmdt, err_str);
	return ret < 0 ? ret : count;
}
static struct kobj_attribute attr_query =
	__ATTR(query, 0200, NULL, query_store);

static ssize_t result_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	return sysfs_emit(buf, "%s\n", result_hex[0] ? result_hex : "(空)");
}
static struct kobj_attribute attr_result = __ATTR_RO(result);

static ssize_t last_error_show(struct kobject *kobj, struct kobj_attribute *attr,
			       char *buf)
{
	return sysfs_emit(buf, "%s\n", err_str);
}
static struct kobj_attribute attr_last_error = __ATTR_RO(last_error);

static ssize_t design_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	u8 d[16] = { 0 };
	int ret;

	mutex_lock(&raw_lock);
	ret = raw_query(CMD_GM, 0x28, NULL, 0, d, sizeof(d));
	mutex_unlock(&raw_lock);
	if (ret)
		return sysfs_emit(buf, "GM28 失败: %s\n", err_str);

	/* d[0] 是 EC 认定的适配器瓦数（DSDT GM28 里的表） */
	return sysfs_emit(buf,
		"adapter=%u W  byte1=%u byte2=0x%02x(%u) byte3=%u byte4=0x%02x "
		"PL4V=%u byte7=%u byte8=%u byte9=%u\n",
		d[0], d[1], d[2], d[2], d[3], d[4], d[5], d[7], d[8], d[9]);
}
static struct kobj_attribute attr_design = __ATTR_RO(design);

/* ---- GNVS（固件的 PL 影子变量，AML 里从不赋值 → SMM/BIOS 写的） ---------- */

/* DSDT: OperationRegion (GNVS, SystemMemory, 0x6C447000, 0x0D1B)
 * Field 偏移（由 dsdt.dsl 逐位算出，见 acpi/gnvs_offsets.json）：
 *   0x2F4 PLCS(8)   SPL1/RPL1 的开关：PLCS!=0 时 GUAM 才会把 PLVL 写进 Punit
 *   0x2F5 PLVL(16)  固件保存的 CPU PL1 目标值（SPL1: PPL1 = PLVL * (PWRU<<2) / 1000）
 *   0x00B PWRS(8)   电源/适配器状态
 *   0x000 OSYS(16)  子系统 ID（不是机型 ID！）
 */
#define GNVS_PLCS	0x2F4
#define GNVS_PLVL	0x2F5
#define GNVS_PWRS	0x00B
#define GNVS_OSYS	0x000

/* 机型 ID（SYID = 0x103C8D3F）不在 GNVS 里：
 *   dsdt.dsl:3679 OperationRegion (EXBU, SystemMemory, 0x6C543018, 0x1008)
 *   dsdt.dsl:138006 Field (EXBU) { Offset(0x800) MPPP 8, SAPS 8, SYID 32 }
 *   → SYID 在 EXBU + 0x802，32 位小端
 */
#define EXBU_BASE_DEFAULT	0x6C543018UL
#define EXBU_SYID		0x802
#define HP_SYID_8D3F		0x103C8D3F

static unsigned long exbu_base = EXBU_BASE_DEFAULT;
module_param(exbu_base, ulong, 0644);
MODULE_PARM_DESC(exbu_base, "EXBU 物理基址（DSDT OperationRegion EXBU）");

static unsigned long gnvs_base = 0x6C447000;
static unsigned int gnvs_len = 0x0D1B;
module_param(gnvs_base, ulong, 0644);
MODULE_PARM_DESC(gnvs_base, "GNVS 物理基址（DSDT OperationRegion GNVS）");
module_param(gnvs_len, uint, 0644);

static char peek_hex[3 * 128 + 16];

static ssize_t gnvs_show(struct kobject *kobj, struct kobj_attribute *attr,
			 char *buf)
{
	void __iomem *g;
	u16 osys, plvl;
	u8 plcs, pwrs;
	u32 syid = 0;
	int n = 0, i;

	if (!gnvs_base)
		return sysfs_emit(buf, "gnvs_base=0，已禁用\n");
	g = memremap(gnvs_base, gnvs_len, MEMREMAP_WB);
	if (!g)
		return sysfs_emit(buf, "memremap 0x%lx+%x 失败\n",
				  gnvs_base, gnvs_len);

	osys = readw(g + GNVS_OSYS);
	pwrs = readb(g + GNVS_PWRS);
	plcs = readb(g + GNVS_PLCS);
	plvl = readw(g + GNVS_PLVL);

	if (exbu_base) {
		void __iomem *e = memremap(exbu_base, 0x1008, MEMREMAP_WB);

		if (e) {
			for (i = 0; i < 4; i++)
				syid |= (u32)readb(e + EXBU_SYID + i) << (8 * i);
			memunmap(e);
		}
	}

	n += sysfs_emit_at(buf, n, "OSYS=0x%04x（子系统 ID） PWRS=0x%02x\n",
			   osys, pwrs);
	n += sysfs_emit_at(buf, n, "SYID=0x%08x（EXBU+0x802） %s\n", syid,
			   syid == HP_SYID_8D3F ? "= 8D3F ✔" : "≠ 0x103C8D3F ⚠");
	n += sysfs_emit_at(buf, n, "PLCS=%u PLVL=%u (0x%04x)\n", plcs, plvl, plvl);
	n += sysfs_emit_at(buf, n, "PLVL 邻域 0x2E0-0x31F:\n");
	for (i = 0x2E0; i < 0x320 && i < (int)gnvs_len; i += 16) {
		int j;

		n += sysfs_emit_at(buf, n, "  %03x:", i);
		for (j = 0; j < 16; j++)
			n += sysfs_emit_at(buf, n, " %02x", readb(g + i + j));
		n += sysfs_emit_at(buf, n, "\n");
	}
	if (syid != HP_SYID_8D3F)
		n += sysfs_emit_at(buf, n,
			"⚠ SYID 不是 0x103C8D3F：GNVS/EXBU 基址可能不对（换了 BIOS/"
			"内存布局），用 DSDT 里 OperationRegion 的实际地址覆盖 "
			"gnvs_base / exbu_base\n");
	memunmap(g);
	return n;
}
static struct kobj_attribute attr_gnvs = __ATTR_RO(gnvs);

/* ------------------------------------------------------------------ *
 * NPCF._DSM —— HP 自己的「CPU 功率预算」入口
 *   ssdt11.dsl:1455 Device (NPCF) 在 Scope (\_SB) 里 → 路径 \_SB.NPCF
 *   :1511 Method (_DSM,4) → ToUUID("36b49710-2483-11e7-9598-0800200c9a66")
 *         → If (Arg1 == 0x0200) → Switch (Arg2)
 *   :1543 func#0  返回支持位图 07 03 00 00 → 只声明 0,1,2,8,9
 *   :1566 func#2  读 EC0.HPCM/OPAT 算 ATPP/ACBT/AMAT/AMIT（GPU 共享预算）
 *   :1940 func#8  读 EC0.BVLB/BVHB 返回 TGP 表（只读）
 *   :1968 func#9  ★ CreateDWordField(Arg3,0x03,CPTD)
 *                   EC0.NPL1 = CPTD/1000；EC0.NPL2 = NPL1*125/100
 *                   然后 SSMP = 0x77（SystemIO 0xB2 → SMI，让 EC 立刻应用）
 *   :1858 func#5  INC5=3/4 时写 NPCF.CUSL/CUCT（有状态副作用）
 * 因此：func 9（SMI + 写 EC）和 func 5（写 NPCF 状态）必须 allow_write=1，
 *       其余都只读放行。
 * ------------------------------------------------------------------ */

#define NPCF_REV	0x0200

/* 36b49710-2483-11e7-9598-0800200c9a66 的 ACPI 线格式（前 3 组小端） */
static const u8 nvpcf_uuid[16] = {
	0x10, 0x97, 0xb4, 0x36, 0x83, 0x24, 0xe7, 0x11,
	0x95, 0x98, 0x08, 0x00, 0x20, 0x0c, 0x9a, 0x66,
};

static char dsm_path[64] = "\\_SB.NPCF";
module_param_string(dsm_path, dsm_path, sizeof(dsm_path), 0644);
MODULE_PARM_DESC(dsm_path, "NPCF 设备的 ACPI 路径（默认 \\_SB.NPCF）");

/* Arg3 默认长度：func#2 里 CreateField(Arg3,0xB2,..) 要 >= 23 字节，
 * func#7 要 25 字节，func#9 的 CPTD 在 [3..6]。32 字节的零缓冲足够。 */
#define DSM_DEFAULT_ARG3	32
#define DSM_MAX_ARG3		256

/* ec_read()/ec_write() 声明在 <linux/acpi.h>（drivers/acpi/ec.c 导出），不要手写 extern */

static char dsm_hex[DSM_MAX_ARG3 * 3 + 128];

static int dsm_is_readonly(u64 func)
{
	/* 9 打 SMI(0xB2) 并写 EC；5 会写 NPCF.CUSL/CUCT */
	return func != 9 && func != 5;
}

static void dsm_format(u64 func, const struct acpi_buffer *out)
{
	const union acpi_object *o = out->pointer;
	int n, i, len;

	if (!o) {
		snprintf(dsm_hex, sizeof(dsm_hex), "func=%llu 返回空(无对象)\n", func);
		return;
	}

	switch (o->type) {
	case ACPI_TYPE_INTEGER:
		snprintf(dsm_hex, sizeof(dsm_hex),
			 "func=%llu INTEGER 0x%llx (%llu)\n", func,
			 o->integer.value, o->integer.value);
		break;
	case ACPI_TYPE_BUFFER:
		len = o->buffer.length;
		n = snprintf(dsm_hex, sizeof(dsm_hex),
			     "func=%llu BUFFER %d 字节\n", func, len);
		for (i = 0; i < len && n < (int)sizeof(dsm_hex) - 8; i++)
			n += scnprintf(dsm_hex + n, sizeof(dsm_hex) - n,
				       "%02x ", o->buffer.pointer[i]);
		if (n < (int)sizeof(dsm_hex) - 2)
			n += scnprintf(dsm_hex + n, sizeof(dsm_hex) - n, "\n");
		break;
	default:
		snprintf(dsm_hex, sizeof(dsm_hex),
			 "func=%llu 返回类型 %d（非 buffer/integer）\n",
			 func, o->type);
		break;
	}
}

static int dsm_call(u64 func, const u8 *data, int datalen)
{
	struct acpi_object_list args;
	union acpi_object argv[4];
	struct acpi_buffer out = { ACPI_ALLOCATE_BUFFER, NULL };
	u8 uuid[16];
	u8 *arg3 = NULL;
	acpi_handle handle;
	acpi_status ast;
	int alen, ret = 0;

	dsm_hex[0] = '\0';
	memcpy(uuid, nvpcf_uuid, sizeof(uuid));
	alen = datalen > 0 ? datalen : DSM_DEFAULT_ARG3;
	if (alen > DSM_MAX_ARG3)
		return -E2BIG;
	arg3 = kzalloc(alen, GFP_KERNEL);
	if (!arg3)
		return -ENOMEM;
	if (datalen > 0)
		memcpy(arg3, data, datalen);

	ast = acpi_get_handle(NULL, dsm_path, &handle);
	if (ACPI_FAILURE(ast)) {
		ret = -ENODEV;
		snprintf(dsm_hex, sizeof(dsm_hex),
			 "acpi_get_handle(%s) 失败: %s\n", dsm_path,
			 acpi_format_exception(ast));
		goto out;
	}

	argv[0].type = ACPI_TYPE_BUFFER;
	argv[0].buffer.length = sizeof(uuid);
	argv[0].buffer.pointer = uuid;
	argv[1].type = ACPI_TYPE_INTEGER;
	argv[1].integer.value = NPCF_REV;
	argv[2].type = ACPI_TYPE_INTEGER;
	argv[2].integer.value = func;
	argv[3].type = ACPI_TYPE_BUFFER;
	argv[3].buffer.length = alen;
	argv[3].buffer.pointer = arg3;
	args.count = 4;
	args.pointer = argv;

	mutex_lock(&raw_lock);
	ast = acpi_evaluate_object(handle, "_DSM", &args, &out);
	mutex_unlock(&raw_lock);
	if (ACPI_FAILURE(ast)) {
		ret = -EIO;
		snprintf(dsm_hex, sizeof(dsm_hex),
			 "%s._DSM(func=%llu) 调用失败: %s\n", dsm_path, func,
			 acpi_format_exception(ast));
		goto out;
	}

	dsm_format(func, &out);
	pr_info("%s: dsm func=%llu -> %s", DRV_NAME, func, dsm_hex);
out:
	kfree(out.pointer);
	kfree(arg3);
	if (ret < 0)
		snprintf(err_str, sizeof(err_str), "%s", dsm_hex);
	else
		snprintf(err_str, sizeof(err_str), "ok (dsm func=%llu)", func);
	return ret;
}

static ssize_t dsm_store(struct kobject *kobj, struct kobj_attribute *attr,
			 const char *buf, size_t count)
{
	u8 in[DSM_MAX_ARG3];
	int insize = 0, ret;
	u64 func = 0;
	char *copy, *p, *tok;

	copy = kstrdup(buf, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	p = copy;
	tok = strsep(&p, " \t\n");
	if (!tok || kstrtou64(tok, 0, &func)) {
		kfree(copy);
		return -EINVAL;
	}
	if (!dsm_is_readonly(func) && !allow_write) {
		kfree(copy);
		snprintf(err_str, sizeof(err_str),
			 "_DSM func=%llu 会写 EC/打 SMI，被拦：确认后 echo 1 > allow_write",
			 func);
		return -EPERM;
	}
	while ((tok = strsep(&p, " \t\n")) != NULL) {
		unsigned long v;

		if (!*tok)
			continue;
		if (kstrtoul(tok, 16, &v) || v > 0xff || insize >= DSM_MAX_ARG3) {
			kfree(copy);
			return -EINVAL;
		}
		in[insize++] = (u8)v;
	}
	ret = dsm_call(func, in, insize);
	kfree(copy);
	return ret < 0 ? ret : (ssize_t)count;
}
static struct kobj_attribute attr_dsm = __ATTR(dsm, 0200, NULL, dsm_store);

static ssize_t dsm_result_show(struct kobject *kobj, struct kobj_attribute *attr,
			       char *buf)
{
	return sysfs_emit(buf, "%s",
			  dsm_hex[0] ? dsm_hex : "(空，先 echo <func> [hex...] > dsm)\n");
}
static struct kobj_attribute attr_dsm_result = __ATTR_RO(dsm_result);

/* ---- EC RAM 直读/直写（EC 里的 CPU PL 真值） ---------------------------- */

struct ec_name {
	u8 off;
	const char *name;
};

/* EC0.ERAM 里和功耗相关的字段（dsdt.dsl:138298 起的 Field (ERAM)） */
static const struct ec_name ec_known[] = {
	{ 0x29, "NPL1" }, { 0x2A, "NPL2" },
	{ 0x34, "SRP1" }, { 0x35, "SRP2" },
	{ 0x37, "ECL1" }, { 0x38, "ECL2" }, { 0x39, "ECL4" },
	{ 0x3A, "EL1R" }, { 0x3B, "EL2R" }, { 0x3C, "EL4R" },
	{ 0x48, "TNT3" }, { 0x52, "ECLS" }, { 0x95, "HPCM" },
	{ 0xA3, "ADPH" }, { 0xE9, "DTMT" }, { 0xEA, "PL12" },
	{ 0xEB, "ETMT" }, { 0xEC, "FFFS" },
};

static char ec_hex[64 * 6 + 1024];

static ssize_t ecram_store(struct kobject *kobj, struct kobj_attribute *attr,
			   const char *buf, size_t count)
{
	unsigned int off = 0x29, nby = 0, i;
	char *copy, *p, *tok;
	int n = 0, rc;

	copy = kstrdup(buf, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	p = copy;
	tok = strsep(&p, " \t\n");
	if (tok && *tok && kstrtouint(tok, 0, &off)) {
		kfree(copy);
		return -EINVAL;
	}
	tok = strsep(&p, " \t\n");
	if (tok && *tok && kstrtouint(tok, 0, &nby)) {
		kfree(copy);
		return -EINVAL;
	}
	kfree(copy);
	if (off > 0xFF)
		return -EINVAL;
	if (nby > 64)
		nby = 64;

	ec_hex[0] = '\0';
	n += snprintf(ec_hex + n, sizeof(ec_hex) - n, "EC RAM 已知功耗字段:\n");
	for (i = 0; i < ARRAY_SIZE(ec_known); i++) {
		u8 v = 0;
		rc = ec_read(ec_known[i].off, &v);
		n += snprintf(ec_hex + n, sizeof(ec_hex) - n,
			      "  0x%02x %-4s = %3u 0x%02x%s\n", ec_known[i].off,
			      ec_known[i].name, rc ? 0 : v, rc ? 0 : v,
			      rc ? " (读失败)" : "");
	}
	if (nby) {
		n += snprintf(ec_hex + n, sizeof(ec_hex) - n, "0x%02x 起 %u 字节:\n",
			      off, nby);
		for (i = 0; i < nby && off + i <= 0xFF; i++) {
			u8 v = 0;

			rc = ec_read(off + i, &v);
			n += snprintf(ec_hex + n, sizeof(ec_hex) - n, " %02x",
				      rc ? 0 : v);
			if ((i % 16) == 15)
				n += snprintf(ec_hex + n, sizeof(ec_hex) - n, "\n");
		}
		n += snprintf(ec_hex + n, sizeof(ec_hex) - n, "\n");
	}
	snprintf(err_str, sizeof(err_str), "ok (ecram)");
	return count;
}
static struct kobj_attribute attr_ecram = __ATTR(ecram, 0200, NULL, ecram_store);

static ssize_t ecram_result_show(struct kobject *kobj,
				 struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s",
			  ec_hex[0] ? ec_hex :
			  "(空，先 echo \"0x29 16\" > ecram)\n");
}
static struct kobj_attribute attr_ecram_result = __ATTR_RO(ecram_result);

static ssize_t ecwrite_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	unsigned int off, val;
	char *copy, *p, *tok;
	int rc;

	if (!allow_write) {
		snprintf(err_str, sizeof(err_str),
			 "直写 EC RAM 需要 allow_write=1");
		return -EPERM;
	}
	copy = kstrdup(buf, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	p = copy;
	tok = strsep(&p, " \t\n");
	if (!tok || kstrtouint(tok, 0, &off)) {
		kfree(copy);
		return -EINVAL;
	}
	tok = strsep(&p, " \t\n");
	if (!tok || kstrtouint(tok, 0, &val)) {
		kfree(copy);
		return -EINVAL;
	}
	kfree(copy);
	if (off > 0xFF || val > 0xFF)
		return -EINVAL;
	rc = ec_write((u8)off, (u8)val);
	snprintf(err_str, sizeof(err_str), "%s (ec_write 0x%02x=0x%02x rc=%d)",
		 rc ? "失败" : "ok", off, val, rc);
	return rc ? -EIO : (ssize_t)count;
}
static struct kobj_attribute attr_ecwrite = __ATTR(ecwrite, 0200, NULL, ecwrite_store);

static ssize_t peek_store(struct kobject *kobj, struct kobj_attribute *attr,
			  const char *buf, size_t count)
{
	unsigned long off;
	unsigned int nby = 16, i;
	void __iomem *g;
	char *p, *tok, *copy;
	int w = 0;

	copy = kstrdup(buf, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	p = copy;
	tok = strsep(&p, " \t\n");
	if (!tok || kstrtoul(tok, 0, &off)) { kfree(copy); return -EINVAL; }
	tok = strsep(&p, " \t\n");
	if (tok && *tok) {
		if (kstrtouint(tok, 0, &nby)) { kfree(copy); return -EINVAL; }
	}
	if (nby > 128) nby = 128;
	if (off + nby > gnvs_len) { kfree(copy); return -E2BIG; }

	g = memremap(gnvs_base, gnvs_len, MEMREMAP_WB);
	if (!g) { kfree(copy); return -EIO; }
	for (i = 0; i < nby; i++) {
		w += scnprintf(peek_hex + w, sizeof(peek_hex) - w, "%02x ",
			       readb(g + off + i));
	}
	memunmap(g);
	kfree(copy);
	pr_info("%s: peek 0x%lx+%u\n", DRV_NAME, off, nby);
	return count;
}
static struct kobj_attribute attr_peek = __ATTR(peek, 0200, NULL, peek_store);

static ssize_t peek_result_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s\n", peek_hex[0] ? peek_hex : "(空，先 echo <偏移> [长度] > peek)");
}
static struct kobj_attribute attr_peek_result = __ATTR_RO(peek_result);

/* 通用物理内存只读 dump："<物理地址> [偏移] [字节数]"
 * 用途：ssdt9 的 \_SB.PNVS（SystemMemory 0x6C481000, 0xAA 字节）里存着
 *       Intel DPTF 的 CPU 功率表：PL10/PL11/PL12 = PL1，PL20/PL21/PL22 = PL2，
 *       CTCx / TARx / PPCx = 时间常数 / tau / 百分比。这是 BIOS 配的“预算”，只读。
 */
#define PHYS_MAX	256
static char phys_hex[PHYS_MAX * 3 + 64];

static ssize_t phys_store(struct kobject *kobj, struct kobj_attribute *attr,
			  const char *buf, size_t count)
{
	unsigned long addr = 0, page;
	unsigned int off = 0, nby = 64, i;
	void __iomem *m;
	char *p, *tok, *copy;
	int w = 0;

	copy = kstrdup(buf, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	p = copy;
	tok = strsep(&p, " \t\n");
	if (!tok || *tok == '\0' || kstrtoul(tok, 0, &addr)) {
		kfree(copy);
		return -EINVAL;
	}
	tok = strsep(&p, " \t\n");
	if (tok && *tok && kstrtouint(tok, 0, &off)) {
		kfree(copy);
		return -EINVAL;
	}
	tok = strsep(&p, " \t\n");
	if (tok && *tok && kstrtouint(tok, 0, &nby)) {
		kfree(copy);
		return -EINVAL;
	}
	kfree(copy);

	if (!addr || nby == 0 || nby > PHYS_MAX || off > 0x1FFF)
		return -EINVAL;
	page = addr & PAGE_MASK;
	m = memremap(page, PAGE_SIZE * 2, MEMREMAP_WB);
	if (!m) {
		snprintf(err_str, sizeof(err_str), "memremap 0x%lx 失败", page);
		return -EIO;
	}
	if ((addr - page) + off + nby > PAGE_SIZE * 2) {
		memunmap(m);
		snprintf(err_str, sizeof(err_str),
			 "越界：addr-page=%lu off=%u nby=%u 超过 2 页",
			 addr - page, off, nby);
		return -E2BIG;
	}

	phys_hex[0] = '\0';
	w += snprintf(phys_hex + w, sizeof(phys_hex) - w,
		      "phys 0x%lx +0x%x, %u 字节\n", addr, off, nby);
	for (i = 0; i < nby; i++) {
		w += snprintf(phys_hex + w, sizeof(phys_hex) - w, "%02x ",
			      readb(m + (addr - page) + off + i));
		if ((i % 16) == 15)
			w += snprintf(phys_hex + w, sizeof(phys_hex) - w, "\n");
	}
	memunmap(m);
	snprintf(err_str, sizeof(err_str), "ok (phys 0x%lx +0x%x)", addr, off);
	pr_info("%s: phys 0x%lx +0x%x %u\n", DRV_NAME, addr, off, nby);
	return count;
}
static struct kobj_attribute attr_phys = __ATTR(phys, 0200, NULL, phys_store);

static ssize_t phys_result_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s", phys_hex[0] ? phys_hex :
			  "(空，先 echo \"0x6C481000 0 0xAA\" > phys)\n");
}
static struct kobj_attribute attr_phys_result = __ATTR_RO(phys_result);

static struct attribute *hp_raw_attrs[] = {
	&attr_query.attr,
	&attr_result.attr,
	&attr_last_error.attr,
	&attr_design.attr,
	&attr_gnvs.attr,
	&attr_peek.attr,
	&attr_peek_result.attr,
	&attr_phys.attr,
	&attr_phys_result.attr,
	&attr_dsm.attr,
	&attr_dsm_result.attr,
	&attr_ecram.attr,
	&attr_ecram_result.attr,
	&attr_ecwrite.attr,
	NULL,
};
ATTRIBUTE_GROUPS(hp_raw);

static struct kobject *hp_raw_kobj;

static int __init hp_raw_init(void)
{
	if (!wmi_has_guid(HPWMI_BIOS_GUID)) {
		pr_err("%s: 找不到 HP BIOS WMI GUID %s\n", DRV_NAME, HPWMI_BIOS_GUID);
		return -ENODEV;
	}
	hp_raw_kobj = kobject_create_and_add(DRV_NAME, kernel_kobj);
	if (!hp_raw_kobj)
		return -ENOMEM;
	if (sysfs_create_groups(hp_raw_kobj, hp_raw_groups)) {
		kobject_put(hp_raw_kobj);
		return -EIO;
	}
	pr_info("%s: /sys/kernel/%s/{query,result,design,gnvs,peek,peek_result,"
		"dsm,dsm_result,ecram,ecram_result,ecwrite,allow_write}\n",
		DRV_NAME, DRV_NAME);
	return 0;
}

static void __exit hp_raw_exit(void)
{
	sysfs_remove_groups(hp_raw_kobj, hp_raw_groups);
	kobject_put(hp_raw_kobj);
}

module_init(hp_raw_init);
module_exit(hp_raw_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("HP OMEN raw WMI BIOS-command probe (board 8D3F)");
