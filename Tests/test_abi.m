// 锁死 imp_implementationWithBlock 在 arm64 上的摆位：垫片能不能取到实参、取到的是不是那一个。
//
// 为什么要有这个文件：上一版把每个站点都套进同一个「宽块」（self、_cmd 之后声明 6 个 void *），
// 再在块里按下标取 delegate。穿梭 0.0.1 上 [ATAdManager loadADWithPlacementID:extra:delegate:]
// 当场 objc_retain 到一个野指针（崩溃报告：libobjc objc_retain+16 ← dylib+31760 ← 该发送点），
// App 启动即闪退。实测原因是运行时根本不把 _cmd 下发给块：块拿到的第 2 个形参就是第 1 个实参，
// 于是宽块里每一个槽位都比表里的下标少一格，最后一格读的是脏寄存器。
//
// 所以 Engine/ZNAHooks.m 的写法是：块只声明它真正要用的那几位（显式站点表统一只带 self），
// 第一个形参是接收者，之后依次是第 1..n 个实参，需要选择子的地方在装钩子时捕获。
// 声明多了会把脏寄存器当对象用，声明少了只是够不着后面的参数 —— 少是安全的，多不是。
// 本探针把这个约定当成断言跑一遍：哪天运行时改了摆位，CI 先红，而不是用户那边先闪退。
//
// 只给 CI 的主机步骤用（clang -framework Foundation），不参与 iOS 打包。
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define SLOT_COUNT 9

static void *gSlots[SLOT_COUNT];
static long gToken[6];  // 只当指针用的靶子，不是对象，块里也不解引用，脏寄存器也崩不了
static int failures;

#define DIRTY ((void *)-1)

// 生产写法：声明 self + 恰好 n 个形参，第 i 个实参抄进 gSlots[1 + i]。
#define CAP_ARGS(...)                                                    \
    do {                                                                 \
        void *raw[] = { __VA_ARGS__ };                                   \
        for (int i = 0; i < (int)(sizeof(raw) / sizeof(raw[0])); i++)    \
            gSlots[1 + i] = raw[i];                                      \
    } while (0)

// A 族：块字面量直接当形参传给 imp_implementationWithBlock。
static IMP directIMP(unsigned int n) {
    switch (n) {
        case 0:
            return imp_implementationWithBlock(^void(id self) { gSlots[0] = (__bridge void *)self; });
        case 1:
            return imp_implementationWithBlock(^void(id self, void *a0) {
                gSlots[0] = (__bridge void *)self;
                CAP_ARGS(a0);
            });
        case 2:
            return imp_implementationWithBlock(^void(id self, void *a0, void *a1) {
                gSlots[0] = (__bridge void *)self;
                CAP_ARGS(a0, a1);
            });
        case 3:
            return imp_implementationWithBlock(^void(id self, void *a0, void *a1, void *a2) {
                gSlots[0] = (__bridge void *)self;
                CAP_ARGS(a0, a1, a2);
            });
        case 4:
            return imp_implementationWithBlock(^void(id self, void *a0, void *a1, void *a2, void *a3) {
                gSlots[0] = (__bridge void *)self;
                CAP_ARGS(a0, a1, a2, a3);
            });
        case 5:
            return imp_implementationWithBlock(
                ^void(id self, void *a0, void *a1, void *a2, void *a3, void *a4) {
                    gSlots[0] = (__bridge void *)self;
                    CAP_ARGS(a0, a1, a2, a3, a4);
                });
        default:
            return imp_implementationWithBlock(
                ^void(id self, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
                    gSlots[0] = (__bridge void *)self;
                    CAP_ARGS(a0, a1, a2, a3, a4, a5);
                });
    }
}

// B 族：块先落到局部变量里、由全局持有，再把变量交给 imp_implementationWithBlock ——
// ZNAHooks.m 里的 ZNAKeep(block) 就是这个形状，两种写法都得测。
static id gKept[16];
static unsigned int gKeptCount;

static void keepBlock(id block) {
    if (gKeptCount < sizeof(gKept) / sizeof(gKept[0])) gKept[gKeptCount++] = block;
}

static IMP indirectIMP(unsigned int n) {
    void (^b0)(id) = ^void(id self) { gSlots[0] = (__bridge void *)self; };
    void (^b1)(id, void *) = ^void(id self, void *a0) {
        gSlots[0] = (__bridge void *)self;
        CAP_ARGS(a0);
    };
    void (^b2)(id, void *, void *) = ^void(id self, void *a0, void *a1) {
        gSlots[0] = (__bridge void *)self;
        CAP_ARGS(a0, a1);
    };
    void (^b3)(id, void *, void *, void *) = ^void(id self, void *a0, void *a1, void *a2) {
        gSlots[0] = (__bridge void *)self;
        CAP_ARGS(a0, a1, a2);
    };
    void (^b4)(id, void *, void *, void *, void *) =
        ^void(id self, void *a0, void *a1, void *a2, void *a3) {
            gSlots[0] = (__bridge void *)self;
            CAP_ARGS(a0, a1, a2, a3);
        };
    void (^b5)(id, void *, void *, void *, void *, void *) =
        ^void(id self, void *a0, void *a1, void *a2, void *a3, void *a4) {
            gSlots[0] = (__bridge void *)self;
            CAP_ARGS(a0, a1, a2, a3, a4);
        };
    void (^b6)(id, void *, void *, void *, void *, void *, void *) =
        ^void(id self, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
            gSlots[0] = (__bridge void *)self;
            CAP_ARGS(a0, a1, a2, a3, a4, a5);
        };
    id block = NULL;
    switch (n) {
        case 0: block = b0; break;
        case 1: block = b1; break;
        case 2: block = b2; break;
        case 3: block = b3; break;
        case 4: block = b4; break;
        case 5: block = b5; break;
        default: block = b6; break;
    }
    keepBlock(block);
    return imp_implementationWithBlock(block);
}

static SEL selFor(unsigned int n, unsigned int tag) {
    char buf[64];
    int used = snprintf(buf, sizeof(buf), "t%u", tag * 10 + n);
    for (unsigned int i = 0; i < n; i++) buf[used + i] = ':';
    buf[used + n] = '\0';
    return sel_getUid(buf);
}

// App 里的方法编码是 clang 生成的带字节偏移形式（v40@0:8@16@24@32），照抄这种形状才有意义。
static char *encodingFor(unsigned int n, char *buf, size_t size) {
    snprintf(buf, size, "v%u@0:8", 16 + 8 * n);
    for (unsigned int i = 0; i < n; i++) {
        char part[16];
        snprintf(part, sizeof(part), "@%u", 16 + 8 * i);
        strcat(buf, part);
    }
    return buf;
}

// '.' 谁都不像，'S' 是接收者，'C' 是选择子，'0'..'5' 是第几个靶子，'-' 是块里没声明的槽位。
static void describe(id target, SEL sel) {
    printf("    slots: ");
    for (int i = 0; i < SLOT_COUNT; i++) {
        char c = '.';
        if (gSlots[i] == DIRTY) {
            c = '-';
        } else if (gSlots[i] == (__bridge void *)target) {
            c = 'S';
        } else if (gSlots[i] == (void *)sel) {
            c = 'C';
        } else {
            for (int k = 0; k < 6; k++) {
                if (gSlots[i] == (void *)&gToken[k]) c = (char)('0' + k);
            }
        }
        putchar(c);
    }
    printf("\n");
    fflush(stdout);
}

static void invoke(id target, SEL sel, unsigned int n) {
    void *a[6] = { NULL };
    for (unsigned int i = 0; i < n; i++) a[i] = (void *)&gToken[i];
    typedef void (*Fn)(id, SEL, void *, void *, void *, void *, void *, void *);
    ((Fn)objc_msgSend)(target, sel, a[0], a[1], a[2], a[3], a[4], a[5]);
}

// 装一个 n 个实参的方法、调一次、逐槽核对。返回 0 表示这一档完全符合生产写法。
static int probe(IMP (*make)(unsigned int), id target, unsigned int n, unsigned int tag) {
    char enc[64];
    SEL sel = selFor(n, tag);
    for (int i = 0; i < SLOT_COUNT; i++) gSlots[i] = DIRTY;
    if (!class_addMethod([target class], sel, make(n), encodingFor(n, enc, sizeof(enc)))) {
        printf("  n=%u tag=%u addMethod failed\n", n, tag);
        return 1;
    }
    invoke(target, sel, n);

    int bad = 0;
    if (gSlots[0] != (__bridge void *)target) {
        printf("  n=%u BAD receiver\n", n);
        bad++;
    }
    for (unsigned int i = 0; i < n; i++) {
        if (gSlots[1 + i] != (void *)&gToken[i]) {
            printf("  n=%u BAD argument %u\n", n, i);
            bad++;
        }
    }
    for (int i = (int)n; i < SLOT_COUNT - 1; i++) {
        if (gSlots[1 + i] != DIRTY) {
            printf("  n=%u slot %d written by a block that declared no such parameter\n", n, 1 + i);
            bad++;
        }
    }
    printf("  n=%u enc=%s receiver=%d selectorDelivered=%d\n", n, enc,
           gSlots[0] == (__bridge void *)target, gSlots[1] == (void *)sel);
    describe(target, sel);
    fflush(stdout);
    return bad;
}

int main(void) {
    setbuf(stdout, NULL);  // 万一又被段错误带走，至少留下已经测出来的那几行
    @autoreleasepool {
        for (int i = 0; i < 6; i++) gToken[i] = 1000 + i;
        Class cls = objc_allocateClassPair(NSObject.class, "ZNAAbiHost", 0);
        objc_registerClassPair(cls);
        id target = [[cls alloc] init];

        printf("== A: exact-arity block, literal passed straight ==\n");
        for (unsigned int n = 0; n <= 6; n++) failures += probe(directIMP, target, n, n);

        printf("== B: exact-arity block, stored in a variable first ==\n");
        for (unsigned int n = 0; n <= 6; n++) failures += probe(indirectIMP, target, n, 10 + n);

        printf("%s\n", failures ? "ABI MISMATCH: shims do not receive arguments the way "
                                  "Engine/ZNAHooks.m assumes"
                                : "ABI ok: block params are (receiver, arg1..argn); _cmd is not delivered");
        return failures ? 1 : 0;
    }
}
