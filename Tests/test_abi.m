// 证明 imp_implementationWithBlock 在 arm64 上把方法的实参摆进块里的哪个位置。
//
// 上一版用一个「宽块」（self、_cmd 之后声明 6 个 void *）套所有站点，再在块里按下标取
// delegate。穿梭 3.4.0 上 [ATAdManager loadADWithPlacementID:extra:delegate:] 当场
// objc_retain 到一个野指针（崩溃报告：libobjc objc_retain+16 ← dylib+31760 ← 该发送点）。
// 反汇编那块垫片：它把 x1..x7 依次存进 slots[0..6]，也就是按「标准块调用约定」
// （x0=block、x1=self、x2=_cmd、x3…=实参）被调用的。
//
// 本探针测出两种写法各自落到哪一档，结论决定 Engine/TNAHooks.m 的写法：
//   A 族：块字面量直接当形参传给 imp_implementationWithBlock；
//   B 族：块先存进变量（TNAKeep(block)）再传 —— 上一版闪退的写法。
//
// 只给 CI 的主机步骤用（clang -framework Foundation），不参与 iOS 打包。
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *gSlots[8];
static long gToken[6];  // 只当指针用的靶子，不是对象，块里也不解引用，脏寄存器也崩不了
static void *gWantSelf;
static SEL gWantCmd;
static int failures;

// 把 self/_cmd 之后的每个形参原样抄进 gSlots[2..]。用 void * 形参：ARC 不会 retain 指针槽位，
// 于是「摆位」这件事可以在没有任何对象语义的前提下安全测量。
#define CAP_HEAD                  \
    gSlots[0] = (__bridge void *)self; \
    gSlots[1] = (void *)_cmd;

#define CAP_TAIL(...)                                                                 \
    do {                                                                              \
        void *raw[] = { __VA_ARGS__ };                                                \
        for (int i = 0; i < (int)(sizeof(raw) / sizeof(raw[0])); i++) gSlots[2 + i] = raw[i]; \
    } while (0)

// A 族：块字面量直传，clang 有机会按 IMP 调用约定生成。
static IMP directIMP(unsigned int n) {
    switch (n) {
        case 0:
            return imp_implementationWithBlock(^void(id self, SEL _cmd) { CAP_HEAD });
        case 1:
            return imp_implementationWithBlock(^void(id self, SEL _cmd, void *a0) {
                CAP_HEAD CAP_TAIL(a0);
            });
        case 2:
            return imp_implementationWithBlock(^void(id self, SEL _cmd, void *a0, void *a1) {
                CAP_HEAD CAP_TAIL(a0, a1);
            });
        case 3:
            return imp_implementationWithBlock(^void(id self, SEL _cmd, void *a0, void *a1, void *a2) {
                CAP_HEAD CAP_TAIL(a0, a1, a2);
            });
        case 4:
            return imp_implementationWithBlock(
                ^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3) {
                    CAP_HEAD CAP_TAIL(a0, a1, a2, a3);
                });
        case 5:
            return imp_implementationWithBlock(
                ^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4) {
                    CAP_HEAD CAP_TAIL(a0, a1, a2, a3, a4);
                });
        default:
            return imp_implementationWithBlock(
                ^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
                    CAP_HEAD CAP_TAIL(a0, a1, a2, a3, a4, a5);
                });
    }
}

// B 族：块先落到局部变量里再生成 IMP。
static IMP indirectIMP(unsigned int n) {
    void (^b0)(id, SEL) = ^void(id self, SEL _cmd) { CAP_HEAD };
    void (^b1)(id, SEL, void *) = ^void(id self, SEL _cmd, void *a0) { CAP_HEAD CAP_TAIL(a0); };
    void (^b2)(id, SEL, void *, void *) =
        ^void(id self, SEL _cmd, void *a0, void *a1) { CAP_HEAD CAP_TAIL(a0, a1); };
    void (^b3)(id, SEL, void *, void *, void *) =
        ^void(id self, SEL _cmd, void *a0, void *a1, void *a2) { CAP_HEAD CAP_TAIL(a0, a1, a2); };
    void (^b4)(id, SEL, void *, void *, void *, void *) =
        ^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3) {
            CAP_HEAD CAP_TAIL(a0, a1, a2, a3);
        };
    void (^b5)(id, SEL, void *, void *, void *, void *, void *) =
        ^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4) {
            CAP_HEAD CAP_TAIL(a0, a1, a2, a3, a4);
        };
    void (^b6)(id, SEL, void *, void *, void *, void *, void *, void *) =
        ^void(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
            CAP_HEAD CAP_TAIL(a0, a1, a2, a3, a4, a5);
        };
    switch (n) {
        case 0: return imp_implementationWithBlock(b0);
        case 1: return imp_implementationWithBlock(b1);
        case 2: return imp_implementationWithBlock(b2);
        case 3: return imp_implementationWithBlock(b3);
        case 4: return imp_implementationWithBlock(b4);
        case 5: return imp_implementationWithBlock(b5);
        default: return imp_implementationWithBlock(b6);
    }
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

static void describe(void) {
    printf("    slots: ");
    for (int i = 0; i < 8; i++) {
        char c = '.';
        if (gSlots[i] == gWantSelf) c = 'S';
        else if (gSlots[i] == (void *)gWantCmd) c = 'C';
        else {
            for (int k = 0; k < 6; k++) {
                if (gSlots[i] == (void *)&gToken[k]) c = (char)('0' + k);
            }
        }
        putchar(c);
    }
    printf("\n");
    fflush(stdout);
}

// 返回第一个靶子出现的槽位下标（-1 表示没找到），顺带检查后续靶子是否连续。
static int probe(IMP (*make)(unsigned int), id target, unsigned int n, unsigned int tag) {
    char enc[64];
    SEL sel = selFor(n, tag);
    for (int i = 0; i < 8; i++) gSlots[i] = NULL;
    if (!class_addMethod([target class], sel, make(n), encodingFor(n, enc, sizeof(enc)))) {
        printf("  n=%u tag=%u addMethod failed\n", n, tag);
        failures++;
        return -1;
    }
    gWantSelf = (__bridge void *)target;
    gWantCmd = sel;
    void *a[6] = { NULL };
    for (unsigned int i = 0; i < n; i++) a[i] = (void *)&gToken[i];
    typedef void (*Fn)(id, SEL, void *, void *, void *, void *, void *, void *);
    ((Fn)objc_msgSend)(target, sel, a[0], a[1], a[2], a[3], a[4], a[5]);
    int base = -1;
    for (int i = 0; i < 8; i++) {
        if (gSlots[i] == (void *)&gToken[0]) { base = i; break; }
    }
    unsigned int matched = 0;
    if (base >= 0) {
        for (unsigned int i = 0; i < n && base + (int)i < 8; i++)
            if (gSlots[base + i] == (void *)&gToken[i]) matched++;
    }
    printf("  n=%u enc=%s self=%d cmd=%d argbase=%d args=%u/%u\n", n, enc,
           gSlots[0] == gWantSelf, gSlots[1] == (void *)sel, base, matched, n);
    describe();
    fflush(stdout);
    return base;
}

int main(void) {
    setbuf(stdout, NULL);  // 万一又被段错误带走，至少留下已经测出来的那几行
    @autoreleasepool {
        Class cls = objc_allocateClassPair(NSObject.class, "TNAAbiHost", 0);
        objc_registerClassPair(cls);
        id target = [[cls alloc] init];

        printf("== A: block literal passed straight to imp_implementationWithBlock ==\n");
        int baseA = -1, selfA = 0;
        for (unsigned int n = 1; n <= 6; n++) {
            int b = probe(directIMP, target, n, n);
            if (b >= 0) baseA = b;
            if (gSlots[0] == (__bridge void *)target) selfA++;
        }
        printf("== B: block stored in a variable first (the shape from the crashing build) ==\n");
        int baseB = -1, selfB = 0;
        for (unsigned int n = 1; n <= 6; n++) {
            int b = probe(indirectIMP, target, n, 10 + n);
            if (b >= 0) baseB = b;
            if (gSlots[0] == (__bridge void *)target) selfB++;
        }

        printf("A: receiver ok in %d/6, first argument at slot %d\n", selfA, baseA);
        printf("B: receiver ok in %d/6, first argument at slot %d\n", selfB, baseB);
        if (baseA < 0 || selfA != 6) {
            printf("ABI FAILURES: shims no longer receive the receiver\n");
            return 1;
        }
        printf("ABI ok: A maps args at slot %d, B maps args at slot %d\n", baseA, baseB);
        return 0;
    }
}
