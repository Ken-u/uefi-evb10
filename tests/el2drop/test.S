//
//  QEMU 上验证 UniXNUHelper.S 的 EL2 -> EL1 降级（汇编的就是真正的那个文件）。
//
//  在 EL2 启动（-M virt,virtualization=on），先把关键寄存器设成「最坏情况」，
//  调用 ArmPlatformPeiBootAction，再在 EL1 里逐项验证。任何陷入 EL2 的访问都会被
//  EL2 向量捕获并报错退出。也能在 EL1 启动（-M virt）：此时降级函数应当原样返回。
//
//  输出走 PL011 (0x09000000)，结果用 semihosting 退出码：0 = 全过。
//

#define ASM_PFX(name)      name
#define _ASM_TYPE(Name)    .type Name, %function
#define AARCH64_BTI(x)
#include <AsmMacroLib.h>

#define UART_BASE_HI   0x0900          // 0x09000000

// GICv3 系统寄存器，数字写法（和 UniXNUHelper.S 一样，避免老 binutils 不认名字）
#define ICC_SRE_EL1     S3_0_C12_C12_5
#define ICC_PMR_EL1     S3_0_C4_C6_0
#define ICC_IGRPEN1_EL1 S3_0_C12_C12_7
#define ICC_IAR1_EL1    S3_0_C12_C12_0
#define ICC_EOIR1_EL1   S3_0_C12_C12_1
#define ICC_SRE_EL2     S3_4_C12_C9_5

        .macro  PUTS label
        adr     x0, \label
        bl      puts
        .endm

        // 标志位由调用者在宏之前设好；宏本身不改变它们之前就分支
        .macro  CHECK name, cond
        b.\cond .Lok\@
        add     x24, x24, #1
        adr     x0, s_fail
        bl      puts
        adr     x0, \name
        bl      puts
        adr     x0, s_nl
        bl      puts
        b       .Ldone\@
.Lok\@:
        adr     x0, s_ok
        bl      puts
        adr     x0, \name
        bl      puts
        adr     x0, s_nl
        bl      puts
.Ldone\@:
        .endm

        .section .text.boot, "ax"
        .global _start
_start:
        mov     x24, xzr                    // 失败计数
        mrs     x25, CurrentEL
        lsr     x25, x25, #2                // 入口 EL
        PUTS    s_banner
        mov     x0, x25
        bl      puthex
        PUTS    s_nl

        mrs     x26, midr_el1               // 真值（EL2 / EL1 启动都读得到）
        mrs     x27, mpidr_el1

        cmp     x25, #2
        b.ne    .Lstage_el1

        // ---- 在 EL2：布置最坏情况 --------------------------------------
        adr     x0, el2_vectors
        msr     vbar_el2, x0
        // HCR_EL2：TGE|TSC|AMO|IMO|FMO，故意不带 RW（bit31）——这正是 sweet 那条线
        // 「eret 之后第一条指令就未定义」的原因。
        movz    x0, #0x0808, lsl #16        // TGE(bit27) | TSC(bit19)
        movk    x0, #0x0038                 // AMO|IMO|FMO
        msr     hcr_el2, x0
        mov     x0, #0x3fff                 // CPTR_EL2：TFP(bit10) 在内，EL1 用 FP 会陷入
        msr     cptr_el2, x0
        msr     cnthctl_el2, xzr            // EL1 访问物理计数器/计时器会陷入
        movz    x0, #0x1000, lsl #16
        msr     cntvoff_el2, x0             // 虚拟计数器偏移 0x10000000
        movz    x0, #0xdead, lsl #16
        msr     vpidr_el2, x0
        movk    x0, #1
        msr     vmpidr_el2, x0
        mov     x0, #0x0360                 // MDCR_EL2：TDA|TDE|TPM|TPMCR
        msr     mdcr_el2, x0
        msr     ICC_SRE_EL2, xzr            // SRE=0 Enable=0：EL1 访问 ICC_* 会陷入
        isb
        PUTS    s_note_sre
        mrs     x0, ICC_SRE_EL2             // 读回：投毒是否真的生效（模型可能不让清）
        bl      puthex
        PUTS    s_nl
        PUTS    s_calling
        bl      ArmPlatformPeiBootAction    // 与 PeilessSec 入口一样：bl，没有栈
        // 返回到这里时必须已经在 EL1

.Lstage_el1:
        PUTS    s_returned
        // ---- 在 EL1：逐项验证 -------------------------------------------
        mrs     x0, CurrentEL
        lsr     x0, x0, #2
        cmp     x0, #1
        CHECK   s_t_el1, eq

        mrs     x0, midr_el1
        cmp     x0, x26
        CHECK   s_t_midr, eq
        mrs     x0, mpidr_el1
        cmp     x0, x27
        CHECK   s_t_mpidr, eq

        cmp     x25, #2
        b.ne    .Lskip_sctlr
        mrs     x0, sctlr_el1               // 只有真的降过级才由它写
        movz    x1, #0x30d0, lsl #16
        movk    x1, #0x0800
        cmp     x0, x1
        CHECK   s_t_sctlr, eq
.Lskip_sctlr:

        adr     x0, stack_top
        mov     sp, x0                      // SP_EL1

        // FP/SIMD 不陷入
        mov     x0, #(3 << 20)
        msr     cpacr_el1, x0
        isb
        fmov    d0, #1.0
        fadd    d0, d0, d0
        fmov    d1, #2.0
        fcmp    d0, d1
        CHECK   s_t_fp, eq

        // PMU 寄存器不陷入
        mrs     x0, pmcr_el0
        cmp     xzr, xzr
        CHECK   s_t_pmu, eq

        // 计数器：CNTFRQ 非零；虚拟计数器没有偏移
        mrs     x0, cntfrq_el0
        cmp     x0, #0
        CHECK   s_t_cntfrq, ne
        mrs     x2, cntvct_el0              // 先读 vct，再读 pct：pct - vct >= 0
        mrs     x1, cntpct_el0
        sub     x3, x1, x2
        movz    x4, #0x10, lsl #16          // 0x100000 ticks 的容差
        cmp     x3, x4
        CHECK   s_t_cntvoff, lo

        // GICv3 系统寄存器接口
        mrs     x0, ICC_SRE_EL1
        and     x1, x0, #1
        cmp     x1, #1
        CHECK   s_t_sre, eq
        orr     x0, x0, #1
        msr     ICC_SRE_EL1, x0
        isb
        mov     x0, #0xff
        msr     ICC_PMR_EL1, x0
        mov     x0, #1
        msr     ICC_IGRPEN1_EL1, x0
        isb

        // GIC 分发器 / 重分发器（QEMU virt：GICD 0x08000000，GICR 0x080A0000）
        movz    x20, #0x0800, lsl #16
        movz    x21, #0x080a, lsl #16
        add     x22, x21, #0x10000          // SGI_base
        mov     w0, #0x13                   // ARE | EnableGrp1 | EnableGrp0
        str     w0, [x20]
        ldr     w0, [x21, #0x14]            // GICR_WAKER
        bic     w0, w0, #2                  // ProcessorSleep = 0
        str     w0, [x21, #0x14]
        mov     x19, #0x100000
.Lwake:
        ldr     w0, [x21, #0x14]
        tbz     w0, #2, .Lawake             // ChildrenAsleep == 0
        subs    x19, x19, #1
        b.ne    .Lwake
.Lawake:
        ldr     w0, [x22, #0x80]            // IGROUPR0：PPI 30 -> Group 1
        orr     w0, w0, #(1 << 30)
        str     w0, [x22, #0x80]
        mov     w0, #0x80
        strb    w0, [x22, #(0x400 + 30)]    // IPRIORITYR30
        mov     w0, #(1 << 30)
        str     w0, [x22, #0x100]           // ISENABLER0：PPI 30

        // EL1 物理计时器中断必须被送到 EL1（HCR_EL2.IMO 已被清掉才会这样）
        adr     x0, el1_vectors
        msr     vbar_el1, x0
        isb
        adr     x1, irq_flag
        str     xzr, [x1]
        mrs     x0, cntfrq_el0
        mov     x2, #1000
        udiv    x0, x0, x2                  // 1 ms
        msr     cntp_tval_el0, x0
        mov     x0, #1                      // ENABLE，不屏蔽
        msr     cntp_ctl_el0, x0
        isb
        msr     daifclr, #2                 // 放开 IRQ
        mov     x19, #0x4000000
.Lspin:
        ldr     x0, [x1]
        cbnz    x0, .Lgot
        subs    x19, x19, #1
        b.ne    .Lspin
.Lgot:
        msr     daifset, #2
        ldr     x0, [x1]
        cmp     x0, #30
        CHECK   s_t_irq, eq
        PUTS    s_irqid
        ldr     x0, [x1]
        bl      puthex
        PUTS    s_nl

        cmp     x24, #0
        b.ne    .Lfailed
        PUTS    s_pass
        mov     x0, #0
        b       do_exit
.Lfailed:
        PUTS    s_failed
        mov     x0, #1
        b       do_exit

// ---------------------------------------------------------------- 异常处理
        .balign 0x800
el2_vectors:
        .org    el2_vectors + 0x200
        b       trap_el2                    // 当前 EL SPx sync
        .org    el2_vectors + 0x280
        b       trap_el2                    // 当前 EL SPx IRQ
        .org    el2_vectors + 0x400
        b       trap_el2                    // 低 EL (AArch64) sync：EL1 的访问被陷入到这里
        .org    el2_vectors + 0x480
        b       trap_el2_irq                // 低 EL IRQ：IRQ 被路由到 EL2（HCR_EL2.IMO 没清）
        .org    el2_vectors + 0x800

        .balign 0x800
el1_vectors:
        .org    el1_vectors + 0x200
        b       trap_el1                    // 当前 EL SPx sync
        .org    el1_vectors + 0x280
        b       el1_irq                     // 当前 EL SPx IRQ
        .org    el1_vectors + 0x800

el1_irq:
        mrs     x16, ICC_IAR1_EL1
        adr     x17, irq_flag
        str     x16, [x17]
        msr     ICC_EOIR1_EL1, x16
        msr     cntp_ctl_el0, xzr
        isb
        eret

trap_el2:
        PUTS    s_trap2
        mrs     x0, esr_el2
        bl      puthex
        PUTS    s_elr
        mrs     x0, elr_el2
        bl      puthex
        PUTS    s_nl
        mov     x0, #2
        b       do_exit
trap_el2_irq:
        PUTS    s_trap2irq
        mov     x0, #3
        b       do_exit
trap_el1:
        PUTS    s_trap1
        mrs     x0, esr_el1
        bl      puthex
        PUTS    s_elr
        mrs     x0, elr_el1
        bl      puthex
        PUTS    s_nl
        mov     x0, #4
        b       do_exit

// ---------------------------------------------------------------- 工具函数
// semihosting SYS_EXIT_EXTENDED(0x20)：参数块 {ADP_Stopped_ApplicationExit, 退出码}
do_exit:
        adr     x1, sh_block
        movz    x2, #0x2, lsl #16
        movk    x2, #0x0026
        str     x2, [x1]
        str     x0, [x1, #8]
        mov     x0, #0x20
        hlt     #0xf000
        b       .

// x0 = NUL 结尾字符串；只用 x9/x10，不用栈
puts:
        movz    x9, #UART_BASE_HI, lsl #16
1:      ldrb    w10, [x0], #1
        cbz     w10, 2f
        strb    w10, [x9]
        b       1b
2:      ret

// x0 = 64 位值，打印 0x + 16 位十六进制；只用 x9-x12
puthex:
        movz    x9, #UART_BASE_HI, lsl #16
        mov     w10, #'0'
        strb    w10, [x9]
        mov     w10, #'x'
        strb    w10, [x9]
        mov     x11, #60
1:      lsr     x12, x0, x11
        and     x12, x12, #0xf
        cmp     x12, #10
        b.lt    2f
        add     x12, x12, #('a' - '0' - 10)
2:      add     x12, x12, #'0'
        strb    w12, [x9]
        subs    x11, x11, #4
        b.ge    1b
        ret

// ---------------------------------------------------------------- 被测代码
#include "UniXNUHelper.S"

// ---------------------------------------------------------------- 数据
        .section .rodata, "a"
s_banner:   .asciz "el2drop test: entry EL = "
s_calling:  .asciz "calling ArmPlatformPeiBootAction\n"
s_note_sre: .asciz "note: ICC_SRE_EL2 after poisoning (SRE=bit0 Enable=bit3) = "
s_returned: .asciz "returned\n"
s_ok:       .asciz "  ok   "
s_fail:     .asciz "  FAIL "
s_nl:       .asciz "\n"
s_irqid:    .asciz "  irq id = "
s_elr:      .asciz "  ELR = "
s_trap2:    .asciz "TRAP TO EL2 (should never happen after the drop): ESR_EL2 = "
s_trap2irq: .asciz "IRQ ROUTED TO EL2 (HCR_EL2.IMO not cleared)\n"
s_trap1:    .asciz "UNEXPECTED EXCEPTION AT EL1: ESR_EL1 = "
s_pass:     .asciz "TEST PASS\n"
s_failed:   .asciz "TEST FAIL\n"
s_t_el1:    .asciz "CurrentEL == 1"
s_t_midr:   .asciz "MIDR_EL1 at EL1 == real MIDR (VPIDR_EL2 set)"
s_t_mpidr:  .asciz "MPIDR_EL1 at EL1 == real MPIDR (VMPIDR_EL2 set)"
s_t_sctlr:  .asciz "SCTLR_EL1 == 0x30d00800 (MMU/cache off)"
s_t_fp:     .asciz "FP/SIMD not trapped (CPTR_EL2)"
s_t_pmu:    .asciz "PMU registers not trapped (MDCR_EL2)"
s_t_cntfrq: .asciz "CNTFRQ_EL0 != 0 (CNTHCTL_EL2 lets EL1 use the counter)"
s_t_cntvoff: .asciz "CNTVOFF_EL2 == 0 (virtual counter has no offset)"
s_t_sre:    .asciz "ICC_SRE_EL1.SRE == 1 (ICC_SRE_EL2 SRE/Enable set)"
s_t_irq:    .asciz "EL1 physical timer IRQ (PPI 30) delivered at EL1"

        .section .data, "aw"
        .balign 8
irq_flag:   .quad 0
sh_block:   .quad 0, 0

        .section .bss, "aw"
        .balign 16
        .space  0x4000
stack_top:
