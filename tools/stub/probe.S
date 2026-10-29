/*
 * probe.S — 把内嵌的 UEFI FV 搬到 0x200000，然后跳进 PeilessSec 的入口。
 *
 * 上游 edk2-rk3588 的正常路径是：FIT 把 BL31 载到 0x60000、BL33(我们的 FV)
 * 载到 0x200000，BL31 起来后跳 0x200000 进 EDK2，此时 CPU 在 EL2。这块板的
 * SPL 会验签（`CONFIG_SPL_FIT_SIGNATURE`，即便 FIT 里没有签名值也会 hang），
 * 不能把 FIT 直接写进 uboot 分区，所以这里用一个 stub 复现"BL31 之后"那个
 * 状态：FV 放到 0x200000，寄存器按 BL33 约定清干净，再跳 FV 内的入口。
 *
 * 前面 64 字节是 arm64 Linux Image 头，让 U-Boot 的 booti_setup() 认它。
 * FV 从文件偏移 0x2000 开始，源地址 = 本镜像加载地址 + 0x2000，与加载到哪无关。
 *
 * 加载地址必须高于 0x700000：写入区间是 0x200000..0x700000，而 stub 自己就在
 * 加载地址 + 0x1000 处，低了会被自己搬过去的数据盖掉。U-Boot 里先
 * `setenv kernel_addr_r 0xa000000` 即可。
 */

#ifndef PROBE_WDT
#define PROBE_WDT	1		/* 1 = 跳进固件前武装硬件看门狗；build.sh 的 PROBE_WDT=0 关掉 */
#endif

#define UART_BASE	0xfeb50000
#define UART_THR	0x00
#define UART_LSR	0x14
#define LSR_THRE	0x20
#define FV_ENTRY	0x201400	/* FV + 0x1400，PeilessSec 入口 */

	.section .text.head, "ax"
	.globl _head
_head:
	b	_stub			/* code0 */
	.long	0			/* code1 */
	.quad	0			/* text_offset */
	.quad	_end			/* image_size */
	.quad	0xa			/* flags: LE, 4K 页, 任意放置 */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5（PE offset） */

	.text
	.globl _stub
_stub:
	msr	daifset, #0xf
	mov	x19, x0			/* dtb：下面存进 TPIDRRO_EL0 交给 UniXNURamDiskDxe */

	adr	x0, msg_el
	bl	puts
	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	bl	puthex
	adr	x0, msg_copy
	bl	puts

	/* FV 拷到 0x200000。源 = 加载地址 + 0x2000，总在 0x202000 以上，
	 * 也就是 dst < src，所以必须**从低往高**拷贝（memmove 的规则：
	 * dst<src 正向拷安全，dst>src 才反向）。反过来拷会把还没读的源盖掉。
	 *
	 * adr 的 ±1 MiB 够不到 +0x502000 处的 stub 之外的 FV，所以用
	 * "stub 地址 - 0x500000" 算源地址：sub 的 imm12<<12 能编码 0x500000。 */
	adr	x20, _stub
	sub	x20, x20, #0x500000
	ldr	x21, =_fv_size
	movz	x22, #0x20, lsl #16	/* 0x200000 */
1:	cbz	x21, 2f
	ldr	x4, [x20], #8
	str	x4, [x22], #8
	sub	x21, x21, #8
	b	1b
2:
	/* NV 变量存储区（FD 偏移 0x7C0000..0x7F0000，物理同址）清零。
	 * 上游 FIT 里它是独立的 nvdata 段；这里不给它内容，EDK2 会当成空的
	 * 变量存储重新初始化，比读到随机内存好。 */
	movz	x1, #0x7c, lsl #16
	movz	x2, #0x7f, lsl #16
10:	cmp	x1, x2
	b.hs	11f
	str	xzr, [x1], #8
	b	10b
11:
#if PROBE_WDT
	/* 硬件看门狗：先于固件武装。这块板没有远程电源，SEC/PEI/DXE 早期任何一处
	 * 卡死（比如还没验证过的 EL2→EL1 降级）都会让板子僵在那里，只有复位能救。
	 * 武装后约 89 s 内没人喂就复位，回到 U-Boot；DXE 里的 UniXNUBootWdtDxe
	 * 接手喂狗。写序是这块板实测过的：CR=0 → TORR=0xf → CRR=0x76 → CR=0x9，
	 * 缺 CRR 那一步使能不生效。武装后关不掉，只有复位能清（pitfalls
	 * 91）。放在拷贝和清 NV 之后、跳进固件之前，让整段窗口留给固件启动。 */
	movz	x1, #0xfeaf, lsl #16		/* DW WDT 0xfeaf0000 */
	str	wzr, [x1, #0x00]		/* CR   = 0 */
	mov	w2, #0xf
	str	w2, [x1, #0x04]			/* TORR = 0xf，最长档 */
	mov	w2, #0x76
	str	w2, [x1, #0x0c]			/* CRR  = 0x76，重载计数器 */
	mov	w2, #0x9
	str	w2, [x1, #0x00]			/* CR   = EN | RPL 2 */
	adr	x0, msg_wdt
	bl	puts
#else
	adr	x0, msg_nowdt
	bl	puts
#endif
	adr	x0, msg_jump
	bl	puts

	/* U-Boot 交来的 FDT 地址（里面有 /chosen/linux,initrd-start/end）：
	 * PeilessSec 只在拿到 TransferList 时才动 TPIDRRO_EL0，探针启动从来没有，
	 * 所以这里把地址放进去，UniXNURamDiskDxe 在 DXE 阶段读出来找 payload。 */
	msr	tpidrro_el0, x19

	/* 跳 PeilessSec：按 BL33 约定清寄存器 */
	mov	x0, x19
	mov	x1, #0
	mov	x2, #0
	mov	x3, #0
	movz	x4, #0x20, lsl #16
	movk	x4, #0x1400
	br	x4

/* ---- 16550 轮询输出（U-Boot 已经把这块 UART 初始化好了） ---- */
puts:
	mov	x9, x0
3:	ldrb	w10, [x9], #1
	cbz	w10, 5f
	movz	x11, #(UART_BASE & 0xffff)
	movk	x11, #(UART_BASE >> 16), lsl #16
4:	ldrb	w12, [x11, #UART_LSR]
	tst	w12, #LSR_THRE
	b.eq	4b
	strb	w10, [x11, #UART_THR]
	b	3b
5:	ret

puthex:
	mov	x9, x0
	mov	x10, #4
6:	lsr	x11, x9, x10
	and	x11, x11, #0xf
	cmp	x11, #10
	b.lo	7f
	add	x11, x11, #('a' - 10)
	b	8f
7:	add	x11, x11, #'0'
8:	movz	x12, #(UART_BASE & 0xffff)
	movk	x12, #(UART_BASE >> 16), lsl #16
9:	ldrb	w13, [x12, #UART_LSR]
	tst	w13, #LSR_THRE
	b.eq	9b
	strb	w11, [x12, #UART_THR]
	subs	x10, x10, #4
	b.pl	6b
	ret

msg_el:		.asciz	"\r\nPROBE: EL="
msg_copy:	.asciz	" copying FV to 0x200000\r\n"
msg_jump:	.asciz	"PROBE: jumping to 0x201400\r\n"
/* 只编进实际用到的那一条：make-payload-boot.sh 靠 strings 判断这张镜像是哪种模式 */
#if PROBE_WDT
msg_wdt:	.asciz	"PROBE: DW WDT 0xfeaf0000 armed (TORR 0xf), UniXNUBootWdtDxe takes over feeding\r\n"
#else
msg_nowdt:	.asciz	"PROBE: DW WDT NOT armed (PROBE_WDT=0)\r\n"
#endif

	.section .fv, "a"
	.balign	8
	.globl _fv_start
_fv_start:
	.incbin	"fv.bin"
_fv_end:

	.set	_fv_size, (_fv_end - _fv_start)
