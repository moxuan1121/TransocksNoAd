// 证明 imp_implementationWithBlock 在 arm64 上把方法的实参摆进块里的哪个位置。
//
// 上一版用一个「宽块」（self、_cmd 之后声明 6 个 void *）套所有站点，再在块里按下标取
// delegate。穿梭 3.4.0 上 [ATAdManager loadADWithPlacementID:extra:delegate:]（3 个实参）
// 当场 objc_retain 到一个野指针（崩溃报告：libobjc objc_retain+16 ← dylib+31760 ← 该发送点）。
// 到底是「多声明的参数读到脏寄存器」还是「整体错位一格」，只有跑一遍才知道，所以在主机
// （同为 arm64、同一套 libobjc 闭包实现）上把两种块形各测一遍。
//
// 只给 CI 的主机步骤用（clang -framework Foundation），不参与 iOS 打包。
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *gSlots[8];
static id gE[6];
static int failures;

static Class host(void) {
    static Class cls;
    if (!cls) {
        cls = objc_allocateClassPair(NSObject.class, "TNAAbiHost", 0);
        objc_registerClassPair(cls);
    }
    return cls;
}

static IMP wideIMP(void) {
    void (^block)(id, SEL, void *, void *, void *, void *, void *, void *) =
        ^(id self, SEL _cmd, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
            void *slots[8] = { (__bridge void *)self, (void *)_cmd, a0, a1, a2, a3, a4, a5 };
            for (int i = 0; i < 8; i++) gSlots[i] = slots[i];
        };
    return imp_implementationWithBlock(block);
}

static IMP exactIMP(unsigned int n) {
    void (^b0)(id, SEL) = ^(id self, SEL _cmd) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = gSlots[3] = gSlots[4] = gSlots[5] = gSlots[6] = gSlots[7] = (void *)-1;
    };
    void (^b1)(id, SEL, id) = ^(id self, SEL _cmd, id a0) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = (__bridge void *)a0;
        gSlots[3] = gSlots[4] = gSlots[5] = gSlots[6] = gSlots[7] = (void *)-1;
    };
    void (^b2)(id, SEL, id, id) = ^(id self, SEL _cmd, id a0, id a1) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = (__bridge void *)a0; gSlots[3] = (__bridge void *)a1;
        gSlots[4] = gSlots[5] = gSlots[6] = gSlots[7] = (void *)-1;
    };
    void (^b3)(id, SEL, id, id, id) = ^(id self, SEL _cmd, id a0, id a1, id a2) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = (__bridge void *)a0; gSlots[3] = (__bridge void *)a1; gSlots[4] = (__bridge void *)a2;
        gSlots[5] = gSlots[6] = gSlots[7] = (void *)-1;
    };
    void (^b4)(id, SEL, id, id, id, id) = ^(id self, SEL _cmd, id a0, id a1, id a2, id a3) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = (__bridge void *)a0; gSlots[3] = (__bridge void *)a1; gSlots[4] = (__bridge void *)a2;
        gSlots[5] = (__bridge void *)a3; gSlots[6] = gSlots[7] = (void *)-1;
    };
    void (^b5)(id, SEL, id, id, id, id, id) = ^(id self, SEL _cmd, id a0, id a1, id a2, id a3, id a4) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = (__bridge void *)a0; gSlots[3] = (__bridge void *)a1; gSlots[4] = (__bridge void *)a2;
        gSlots[5] = (__bridge void *)a3; gSlots[6] = (__bridge void *)a4; gSlots[7] = (void *)-1;
    };
    void (^b6)(id, SEL, id, id, id, id, id, id) =
        ^(id self, SEL _cmd, id a0, id a1, id a2, id a3, id a4, id a5) {
        gSlots[0] = (__bridge void *)self; gSlots[1] = (void *)_cmd;
        gSlots[2] = (__bridge void *)a0; gSlots[3] = (__bridge void *)a1; gSlots[4] = (__bridge void *)a2;
        gSlots[5] = (__bridge void *)a3; gSlots[6] = (__bridge void *)a4; gSlots[7] = (__bridge void *)a5;
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

static char *encodingFor(unsigned int n, char *buf, size_t size) {
    int used = snprintf(buf, size, "v@:");
    for (unsigned int i = 0; i < n; i++) buf[used + i] = '@';
    buf[used + n] = '\0';
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
}

static void callWith(id target, SEL sel, unsigned int n) {
    gWantSelf = (__bridge void *)target;
    gWantCmd = sel;
    void *a[6] = { NULL };
    for (unsigned int i = 0; i < n; i++) a[i] = (__bridge void *)gE[i];
    typedef void (*Fn)(id, SEL, void *, void *, void *, void *, void *, void *);
    ((Fn)objc_msgSend)(target, sel, a[0], a[1], a[2], a[3], a[4], a[5]);
}

int main(void) {
    @autoreleasepool {
        for (int i = 0; i < 6; i++) gE[i] = [NSNumber numberWithInteger:1000 + i];
        Class cls = host();
        id target = [[cls alloc] init];
        char enc[32];

        printf("== wide block: one 6-pointer block over methods of arity 1..6 ==\n");
        for (unsigned int n = 1; n <= 6; n++) {
            SEL sel = selFor(n, 0);
            for (int i = 0; i < 8; i++) gSlots[i] = NULL;
            class_addMethod(cls, sel, wideIMP(), encodingFor(n, enc, sizeof(enc)));
            callWith(target, sel, n);
            unsigned int matched = 0;
            for (unsigned int i = 0; i < n; i++)
                if (gSlots[2 + i] == (__bridge void *)gE[i]) matched++;
            printf("  n=%u receiver-in-slot0=%d cmd-in-slot1=%d args-matched=%u/%u\n", n,
                   gSlots[0] == (__bridge void *)target, gSlots[1] == (void *)sel, matched, n);
            describe();
        }

        printf("== exact-arity block: every argument must land on its own index ==\n");
        for (unsigned int n = 0; n <= 6; n++) {
            SEL sel = selFor(n, 1);
            for (int i = 0; i < 8; i++) gSlots[i] = NULL;
            if (!class_addMethod(cls, sel, exactIMP(n), encodingFor(n, enc, sizeof(enc)))) {
                printf("  n=%u addMethod failed\n", n);
                failures++;
                continue;
            }
            callWith(target, sel, n);
            if (gSlots[0] != (__bridge void *)target) { failures++; printf("  n=%u BAD self\n", n); }
            if (gSlots[1] != (void *)sel) { failures++; printf("  n=%u BAD _cmd\n", n); }
            for (unsigned int i = 0; i < n; i++) {
                if (gSlots[2 + i] != (__bridge void *)gE[i]) {
                    failures++;
                    printf("  n=%u BAD arg %u\n", n, i);
                }
            }
            printf("  n=%u ", n);
            describe();
        }
        printf("%s\n", failures ? "ABI FAILURES" : "ABI ok: exact-arity blocks map every argument");
        return failures ? 1 : 0;
    }
}
