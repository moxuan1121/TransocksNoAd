// 证明 imp_implementationWithBlock 在 arm64 上把方法的实参摆进块里的哪个位置。
//
// 上一版用一个「宽块」（self、_cmd 之后声明 6 个 void *）套所有站点，再在块里按下标取
// delegate。穿梭 3.4.0 上 [ATAdManager loadADWithPlacementID:extra:delegate:]（3 个实参）
// 当场 objc_retain 到一个野指针（崩溃报告：libobjc objc_retain+16 ← dylib+31760 ← 该发送点）。
// 到底是「多声明的参数读到脏寄存器」还是「整体错位一格」，只有跑一遍才知道，所以在主机
// （同为 arm64、同一套 libobjc 闭包实现）上把两种块形各测一遍。
//
// 结论决定了 Engine/TNAHooks.m 的写法：垫片块只声明目标方法真实拥有的那几个参数（0..6 一族），
// 于是每个槽位都是调用方传进来的真对象，按下标取 delegate 才安全。
//
// 只给 CI 的主机步骤用（clang -framework Foundation），不参与 iOS 打包。
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *gSlots[8];
static id gE[6];
static id gKept[64];  // 块必须活得比建它的那个函数久，否则跳进已经失效的栈块就是段错误
static unsigned int gKeptCount;
static int failures;

static IMP keepBlock(id block) {
    gKept[gKeptCount++] = [block copy];
    return imp_implementationWithBlock(gKept[gKeptCount - 1]);
}

static Class host(void) {
    static Class cls;
    if (!cls) {
        cls = objc_allocateClassPair(NSObject.class, "TNAAbiHost", 0);
        objc_registerClassPair(cls);
    }
    return cls;
}

// 块只负责把每个槽位的原始位样抄进 gSlots，一个字节都不解引用：脏寄存器也就能读出个假地址，
// 不会在测量过程中把进程搞崩。'-' 一位表示块里没声明这一位。
#define CAPTURE_HEAD                      \
    gSlots[0] = (__bridge void *)self;    \
    gSlots[1] = (void *)_cmd;             \
    for (int i = 2; i < 8; i++) gSlots[i] = (void *)-1;

static IMP wideIMP(void) {
    gKept[gKeptCount++] =
        [^(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
            gSlots[0] = (__bridge void *)self;
            gSlots[1] = (void *)_cmd;
            gSlots[2] = a0; gSlots[3] = a1; gSlots[4] = a2;
            gSlots[5] = a3; gSlots[6] = a4; gSlots[7] = a5;
        } copy];
    return imp_implementationWithBlock(gKept[gKeptCount - 1]);
}

static IMP exactIMP(unsigned int n) {
    switch (n) {
        case 0:
            return keepBlock(^void(id self, SEL _cmd) { CAPTURE_HEAD });
        case 1:
            return keepBlock(^void(id self, SEL _cmd, void *a0) {
                CAPTURE_HEAD gSlots[2] = a0;
            });
        case 2:
            return keepBlock(^void(id self, SEL _cmd, void *a0, void *a1) {
                CAPTURE_HEAD gSlots[2] = a0; gSlots[3] = a1;
            });
        case 3:
            return keepBlock(^void(id self, SEL _cmd, void *a0, void *a1, void *a2) {
                CAPTURE_HEAD gSlots[2] = a0; gSlots[3] = a1; gSlots[4] = a2;
            });
        case 4:
            return keepBlock(^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3) {
                CAPTURE_HEAD gSlots[2] = a0; gSlots[3] = a1; gSlots[4] = a2; gSlots[5] = a3;
            });
        case 5:
            return keepBlock(^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4) {
                CAPTURE_HEAD gSlots[2] = a0; gSlots[3] = a1; gSlots[4] = a2; gSlots[5] = a3; gSlots[6] = a4;
            });
        case 6:
            return keepBlock(^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4,
                                   void *a5) {
                CAPTURE_HEAD gSlots[2] = a0; gSlots[3] = a1; gSlots[4] = a2; gSlots[5] = a3; gSlots[6] = a4;
                gSlots[7] = a5;
            });
        default:
            return NULL;
    }
}

static SEL selFor(unsigned int n, unsigned int tag) {
    char buf[64];
    int used = snprintf(buf, sizeof(buf), "t%u", tag * 10 + n);
    for (unsigned int i = 0; i < n; i++) buf[used + i] = ':';
    buf[used + n] = '\0';
    return sel_getUid(buf);
}

// 真机上的编码是带字节偏移的（v32@0:8@16@24），clang 生成的就是这种；不带偏移的裸写法运行时
// 也能认。两种都测，免得只在其中一种形状上成立。
static char *encodingFor(unsigned int n, unsigned int tag, char *buf, size_t size) {
    if (tag % 2) {
        int used = snprintf(buf, size, "v@:");
        for (unsigned int i = 0; i < n; i++) buf[used + i] = '@';
        buf[used + n] = '\0';
    } else {
        snprintf(buf, size, "v%u@0:8", 16 + 8 * n);
        for (unsigned int i = 0; i < n; i++) {
            char part[16];
            snprintf(part, sizeof(part), "@%u", 16 + 8 * i);
            strcat(buf, part);
        }
    }
    return buf;
}

// 八个槽各装着什么：'.' 谁都不像，'0'..'5' 是第几个标记对象，'S' 是接收者，'C' 是 _cmd，
// '-' 是块里根本没声明这一位。
static void *gWantSelf;
static SEL gWantCmd;

static void describe(void) {
    printf("    slots: ");
    for (int i = 0; i < 8; i++) {
        char c = '.';
        if (gSlots[i] == (void *)-1) {
            c = '-';
        } else if (gSlots[i] == gWantSelf) {
            c = 'S';
        } else if (gSlots[i] == (void *)gWantCmd) {
            c = 'C';
        } else {
            for (int k = 0; k < 6; k++) {
                if (gSlots[i] == (__bridge void *)gE[k]) c = (char)('0' + k);
            }
        }
        printf("%c", c);
    }
    printf("\n");
    fflush(stdout);
}

static void callWith(id target, SEL sel, unsigned int n) {
    gWantSelf = (__bridge void *)target;
    gWantCmd = sel;
    void *a[6] = { NULL };
    for (unsigned int i = 0; i < n; i++) a[i] = (__bridge void *)gE[i];
    typedef void (*Fn)(id, SEL, void *, void *, void *, void *, void *, void *);
    ((Fn)objc_msgSend)(target, sel, a[0], a[1], a[2], a[3], a[4], a[5]);
}

static void probeExact(id target, unsigned int n, unsigned int tag) {
    char enc[64];
    SEL sel = selFor(n, tag);
    for (int i = 0; i < 8; i++) gSlots[i] = NULL;
    IMP imp = exactIMP(n);
    if (!imp) { printf("  n=%u tag=%u no IMP\n", n, tag); failures++; return; }
    if (!class_addMethod([target class], sel, imp, encodingFor(n, tag, enc, sizeof(enc)))) {
        printf("  n=%u tag=%u addMethod failed\n", n, tag);
        failures++;
        return;
    }
    callWith(target, sel, n);
    unsigned int matched = 0;
    for (unsigned int i = 0; i < n; i++)
        if (gSlots[2 + i] == (__bridge void *)gE[i]) matched++;
    printf("  n=%u tag=%u enc=%s self=%d cmd=%d args=%u/%u\n", n, tag, enc,
           gSlots[0] == (__bridge void *)gWantSelf, gSlots[1] == (void *)sel, matched, n);
    describe();
    if (matched != n || gSlots[0] != (__bridge void *)gWantSelf || gSlots[1] != (void *)sel) failures++;
}

int main(void) {
    setbuf(stdout, NULL);  // 段错误也留得住已经测出来的那一行
    @autoreleasepool {
        for (int i = 0; i < 6; i++) gE[i] = [NSNumber numberWithInteger:1000 + i];
        Class cls = host();
        id target = [[cls alloc] init];
        char enc[64];

        // 只是记录，不作断言：宽块到底偏几格、脏在哪一位，看清了就说明为什么不能用它。
        printf("== wide block (6 void * slots) over methods of arity 0..6 -- informational ==\n");
        for (unsigned int n = 0; n <= 6; n++) {
            SEL sel = selFor(n, 0);
            for (int i = 0; i < 8; i++) gSlots[i] = NULL;
            if (!class_addMethod(cls, sel, wideIMP(), encodingFor(n, 0, enc, sizeof(enc)))) {
                printf("  n=%u addMethod failed\n", n);
                continue;
            }
            callWith(target, sel, n);
            unsigned int matched = 0;
            for (unsigned int i = 0; i < n; i++)
                if (gSlots[2 + i] == (__bridge void *)gE[i]) matched++;
            printf("  n=%u enc=%s args-matched=%u/%u\n", n, enc, matched, n);
            describe();
        }

        printf("== exact-arity block: every argument must land on its own index ==\n");
        for (unsigned int n = 0; n <= 6; n++) probeExact(target, n, 1);
        for (unsigned int n = 0; n <= 6; n++) probeExact(target, n, 2);

        printf("%s\n", failures ? "ABI FAILURES" : "ABI ok: exact-arity blocks map every argument");
        return failures ? 1 : 0;
    }
}
