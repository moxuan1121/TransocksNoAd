#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdatomic.h>
#import <string.h>
#import "TNAPattern.h"

static os_log_t TNALogger(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.moxuan.transocksnoad", "ads"); });
    return logger;
}

static NSMutableArray<NSString *> *TNAJournal(void) {
    static NSMutableArray *journal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ journal = [NSMutableArray new]; });
    return journal;
}

static NSTimeInterval TNALaunchUptime = 0;

// 挂上格式检查：这些日志是下次真机迭代唯一的依据，写错一个占位符就是白跑一轮。
static void TNALog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void TNALog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"+%7.3f %@",
                      NSProcessInfo.processInfo.systemUptime - TNALaunchUptime, message];
    os_log(TNALogger(), "%{public}@", line);
    @synchronized(TNAJournal()) {
        [TNAJournal() addObject:line];
        if (TNAJournal().count > 2500) [TNAJournal() removeObjectsInRange:NSMakeRange(0, TNAJournal().count - 2500)];
    }
}

static void TNAFlushLog(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TransocksNoAd.log"];
    NSArray<NSString *> *snapshot;
    @synchronized(TNAJournal()) {
        snapshot = [TNAJournal() copy];
    }
    [[snapshot componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSMutableArray<id> *TNAKeepAlive(void) {
    static NSMutableArray *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSMutableArray new]; });
    return kept;
}

// imp_implementationWithBlock 造出来的 IMP 只要块对象活着就行，而它没有任何地方持有，
// 所以统一挂进这个数组：一放出去就没人管的话，下次 GC 时代码页就飞了。
static void TNAKeep(id object) {
    @synchronized(TNAKeepAlive()) {
        [TNAKeepAlive() addObject:object];
    }
}

// 开屏 pass 在主线程、全量 pass 在后台队列，两边同时在加。
static _Atomic NSUInteger TNAActionCount = 0;
static _Atomic NSUInteger TNAHookedCount = 0;

static NSError *TNABlockedError(void) {
    return [NSError errorWithDomain:@"TransocksNoAd" code:2001
                           userInfo:@{ NSLocalizedDescriptionKey : @"ad suppressed by TransocksNoAd" }];
}

#pragma mark - runtime helpers

// 只挂目标类自己实现的方法：class_getInstanceMethod 会顺着父类找，拿到继承方法就等于改了父类，
// 而 GAD*/AT* 的父类往往是好几个广告对象共用（GADFullScreenAd 就是插屏和激励的基类）。
static Method TNAOwnMethod(Class cls, SEL sel, BOOL classMethod) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

// 返回类型必须是我们能安全伪造的标量/对象。结构体、位域一类一律拒绝。
static BOOL TNAReturnKind(const char *encoding, char *out) {
    if (!encoding || !*encoding) return NO;
    *out = encoding[0];
    switch (encoding[0]) {
        case 'v': case '@': case '#': case '*': case '^': case 'B': case 'c': case 'i': case 's':
        case 'l': case 'q': case 'I': case 'S': case 'L': case 'Q': case 'f': case 'd':
            return YES;
        default:
            return NO;
    }
}

// 走完一段完整类型编码（结构体/联合/位域/限定符都可能带子类型），连同后面那个字节偏移一起消费掉
// —— 这个二进制里的编码是带偏移的（v24@0:8@16），不跳数字就会把 '2' 当成参数类型。
static size_t TNASkipType(const char *p) {
    size_t consumed = 0;
    for (;;) {
        switch (p[consumed]) {
            case 'n': case 'N': case 'o': case 'O': case 'r': case 'R': case 'V':
                consumed++;
                continue;
            default:
                break;
        }
        break;
    }
    char head = p[consumed];
    if (head == '\0') return consumed;
    consumed++;
    if (head == '{' || head == '(') {
        char close = head == '{' ? '}' : ')';
        int depth = 1;
        while (p[consumed] && depth) {
            if (p[consumed] == head) depth++;
            else if (p[consumed] == close) depth--;
            consumed++;
        }
    } else if (head == '[') {
        while (p[consumed] && p[consumed] != ']') consumed++;
        consumed++;
        return consumed + TNASkipType(p + consumed);
    } else if (head == 'b') {  // 位域：'b' + 位数
        while (p[consumed] >= '0' && p[consumed] <= '9') consumed++;
    }
    while (p[consumed] >= '0' && p[consumed] <= '9') consumed++;  // 偏移
    return consumed;
}

// 对象形参：'@'，块字面量写成 '@?'，后面都跟着一个字节偏移。
static BOOL TNASkipObjectType(const char **p) {
    if (**p != '@') return NO;
    (*p)++;
    if (**p == '?') (*p)++;
    while (**p >= '0' && **p <= '9') (*p)++;
    return YES;
}

// 只有「实参全是对象」的方法才能按下标取 delegate：arm64 上 double 和结构体走的是另一套寄存器，
// 按 void* 下标去数会错位；而 C 指针、SEL 又不是对象，对它们做 isKindOfClass: 直接崩。
// 不满足这个形状的站点当场放弃（留一行日志，换 SDK 版本时能看出漏了什么）。
static BOOL TNAArgsAllPortable(Method method, unsigned int *argumentCount) {
    const char *encoding = method_getTypeEncoding(method);
    unsigned int count = method_getNumberOfArguments(method);
    if (argumentCount) *argumentCount = count;
    if (!encoding || count < 2 || count > 8) return NO;  // 垫片块最多带到第 7 个实参
    const char *p = encoding + TNASkipType(encoding);  // 返回类型 + 偏移
    if (!TNASkipObjectType(&p)) return NO;  // self
    if (*p != ':') return NO;  // _cmd
    p++;
    while (*p >= '0' && *p <= '9') p++;
    for (unsigned int i = 2; i < count; i++) {
        if (!TNASkipObjectType(&p)) return NO;
    }
    return *p == '\0';
}

#pragma mark - skip button

// 只认「跳过」：这类按钮按下后广告会走 SDK 自己的关闭分支，宿主 App 拿得到回调。
// 「关闭」一类的不点——它可能属于业务弹窗，而且误触广告比广告本身更糟。
static BOOL TNAMatchSkipText(NSString *text) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keywords = @[ @"跳过", @"skip" ]; });
    if (text.length == 0) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower rangeOfString:keyword].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL TNALooksLikeSkip(UIControl *control) {
    if ([control isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)control;
        if (TNAMatchSkipText(button.currentTitle) || TNAMatchSkipText(button.currentAttributedTitle.string)) return YES;
    }
    if (control.allTargets.count == 0) return NO;
    return TNAMatchSkipText(control.accessibilityLabel) || TNAMatchSkipText(control.accessibilityValue);
}

// 广度优先找广告自带的跳过按钮，限定在这块广告视图内部，避免点到业务界面的同名按钮。
static NSUInteger TNATrySkipInView(UIView *root) {
    static const NSUInteger TNAMaxNodes = 400;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger tapped = 0, visited = 0;
    while (queue.count && visited < TNAMaxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view != root && [view isKindOfClass:UIControl.class] && TNALooksLikeSkip((UIControl *)view)) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            tapped++;
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return tapped;
}

static const void *TNASkipStateKey = &TNASkipStateKey;

// 跳过按钮往往要等广告素材到位才建出来，所以按节流重试几次，而不是一次定终身。
static void TNASkipIfNeeded(UIView *view, NSString *className) {
    if (!view) return;
    NSMutableArray *state = objc_getAssociatedObject(view, TNASkipStateKey);
    if (!state) {
        state = [NSMutableArray arrayWithObjects:@0, @0, nil];
        objc_setAssociatedObject(view, TNASkipStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    static const NSInteger TNAMaxSkipAttempts = 6;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([state[0] integerValue] >= TNAMaxSkipAttempts || now - [state[1] doubleValue] < 0.5) return;
    state[0] = @([state[0] integerValue] + 1);
    state[1] = @(now);
    NSUInteger tapped = TNATrySkipInView(view);
    if (tapped) {
        state[0] = @(TNAMaxSkipAttempts);
        TNALog(@"skip-button %@ x%lu", className, (unsigned long)tapped);
    }
}

// 广告视图常被复用（热启动第二次起就是同一个对象），所以只要它又变成可见的，
// 就重置跳过重试的配额，让它重新有机会按下跳过。
static void TNAHideAndSkip(UIView *view, NSString *className) {
    if (!view) return;
    if (!view.isHidden) {
        objc_setAssociatedObject(view, TNASkipStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.hidden = YES;
    view.alpha = 0;
    TNASkipIfNeeded(view, className);
}

#pragma mark - defuse

static void TNAReleaseViewController(UIViewController *vc) {
    UIViewController *presenter = vc.presentingViewController;
    if (presenter.presentedViewController == vc) {
        [presenter dismissViewControllerAnimated:NO completion:nil];
        return;
    }
    UINavigationController *nav = vc.navigationController;
    if (nav.viewControllers.count > 1 && nav.viewControllers.lastObject == vc) {
        [nav popViewControllerAnimated:NO];
    }
}

static void TNADefuse(id target) {
    if (!target) return;
    NSString *className = NSStringFromClass(object_getClass(target));
    BOOL splash = TNAIsSplashLikeName(className.UTF8String);
    void (^work)(void) = ^{
        TNAActionCount++;
        if ([target isKindOfClass:UIWindow.class]) {
            TNAHideAndSkip(target, className);
            TNALog(@"defuse window %@", className);
        } else if ([target isKindOfClass:UIViewController.class]) {
            UIViewController *vc = target;
            if (vc.isViewLoaded) TNAHideAndSkip(vc.view, className);
            // 兜底：插屏可能没有自动关闭，宽限期后替它离场，别让用户对着一个看不见的模态。
            // 开屏的宽限期给足，倒计时跑完 SDK 会自己关，抢先销毁反而拿不到回调。
            NSTimeInterval grace = splash ? 8 : 1.2;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(grace * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               TNAReleaseViewController(vc);
                           });
            TNALog(@"defuse vc %@ splash=%d", className, splash);
        } else if ([target isKindOfClass:UIView.class]) {
            UIView *view = target;
            TNAHideAndSkip(view, className);
            // 开屏视图留在视图树里，SDK 的倒计时和关闭回调才能继续跑；其它广告直接摘掉。
            if (!splash && view.superview) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [view removeFromSuperview];
                });
            }
            TNALog(@"defuse view %@ splash=%d", className, splash);
        }
        if ((TNAActionCount % 25) == 0) TNAFlushLog();
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// 转发垫片也按实参个数分族，而且只到 1 个为止：块声明几位，原实现就从哪几位取值。声明多了会把
// 脏寄存器转发给原实现（willMoveToWindow: 收到一个假 window 就是崩溃），声明少了才会原样丢弃。
// 槽位一律用 void *：垫片不关心它们是什么类型，ARC 也就不会去 retain 一个指针槽位。
#define TNADefuse0(RET)                                             \
    (^RET(id self, SEL _cmd) {                                      \
        RET result = ((RET (*)(id, SEL))original)(self, _cmd);      \
        TNADefuse(self);                                            \
        return result;                                              \
    })
#define TNADefuse1(RET)                                                         \
    (^RET(id self, SEL _cmd, void *a0) {                                        \
        RET result = ((RET (*)(id, SEL, void *))original)(self, _cmd, a0);      \
        TNADefuse(self);                                                        \
        return result;                                                          \
    })

static IMP TNADefuseIMP(IMP original, char returnType, unsigned int realArgs) {
    if (realArgs > 1) return NULL;
    BOOL one = realArgs == 1;
    id block = nil;
    if (returnType == 'v') {
        if (one) {
            void (^b)(id, SEL, void *) = ^void(id self, SEL _cmd, void *a0) {
                ((void (*)(id, SEL, void *))original)(self, _cmd, a0);
                TNADefuse(self);
            };
            block = (id)b;
        } else {
            void (^b)(id, SEL) = ^void(id self, SEL _cmd) {
                ((void (*)(id, SEL))original)(self, _cmd);
                TNADefuse(self);
            };
            block = (id)b;
        }
    } else if (returnType == '@' || returnType == '#' || returnType == '*' || returnType == '^') {
        block = one ? (id)TNADefuse1(id) : (id)TNADefuse0(id);
    } else if (returnType == 'f') {
        block = one ? (id)TNADefuse1(float) : (id)TNADefuse0(float);
    } else if (returnType == 'd') {
        block = one ? (id)TNADefuse1(double) : (id)TNADefuse0(double);
    } else {
        block = one ? (id)TNADefuse1(NSInteger) : (id)TNADefuse0(NSInteger);
    }
    TNAKeep(block);
    return imp_implementationWithBlock(block);
}

#pragma mark - defuse installation

static void TNAInstallIn(Class cls) {
    for (BOOL classMethod = NO;; classMethod = YES) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Method method = methods[i];
            SEL selector = method_getName(method);
            if (!TNAIsPresentationSelector(sel_getName(selector))) continue;
            char returnType = 'v';
            const char *encoding = method_getTypeEncoding(method);
            if (!TNAReturnKind(encoding, &returnType)) continue;
            // 转发垫片最多带 1 个实参；更宽的方法一律不动。
            unsigned int arguments = method_getNumberOfArguments(method);
            if (arguments > 3) continue;
            IMP original = method_getImplementation(method);
            IMP replacement = TNADefuseIMP(original, returnType, arguments - 2);
            if (!replacement || original == replacement) continue;
            method_setImplementation(method, replacement);
            TNAHookedCount++;
            TNALog(@"defuse-hook %@[%@ %@] %s", classMethod ? @"+@" : @"-", NSStringFromClass(cls),
                   NSStringFromSelector(selector), encoding);
        }
        free(methods);
        if (classMethod) break;
    }
}

static NSMutableSet<NSString *> *TNAVisited(void) {
    static NSMutableSet *visited;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ visited = [NSMutableSet new]; });
    return visited;
}

// 已经「有定论」的显式站点：类已经注册了，缺哪个方法就是真缺，不必每轮补扫再试一遍。
// 只有整个类还没注册进来时才重试（Swift 那批广告转发类要等第一次用到的时候才 realized）。
static NSMutableSet<NSString *> *TNASettledSites(void) {
    static NSMutableSet *settled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settled = [NSMutableSet new]; });
    return settled;
}

static BOOL TNASiteSettled(NSString *key) {
    @synchronized(TNASettledSites()) {
        if ([TNASettledSites() containsObject:key]) return YES;
        [TNASettledSites() addObject:key];
    }
    return NO;
}

// 只处理 App 自带可执行文件与内嵌框架里的类，系统框架一律跳过。
static BOOL TNAClassIsAppOwned(Class cls) {
    const char *image = class_getImageName(cls);
    return image && strstr(image, ".app/");
}

static void TNAInstallAll(NSString *pass, BOOL launchOnly);
static void TNAInstallExplicitSites(NSString *pass);

static void TNAInstallAll(NSString *pass, BOOL launchOnly) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger scanned = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (launchOnly ? !TNAIsLaunchClassName(name) : !TNAIsInterestingClassName(name)) continue;
        if (!TNAClassIsAppOwned(classes[i])) continue;
        NSString *key = @(name);
        @synchronized(TNAVisited()) {
            // 先占名再挂，重复的 pass 和并发的两条 pass 都不会把方法套两层。
            if ([TNAVisited() containsObject:key]) continue;
            [TNAVisited() addObject:key];
        }
        scanned++;
        TNAInstallIn(classes[i]);
    }
    free(classes);
    TNALog(@"pass %@: %u classes, %lu candidates, %lu hooks in %.0f ms", pass, count, (unsigned long)scanned,
           (unsigned long)TNAHookedCount, (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    // 显式站点表跟着每轮补扫重试：类要等第一次用到才注册，构造函数里只跑一次会漏。
    if (!launchOnly) TNAInstallExplicitSites(pass);
    TNAFlushLog();
}

#pragma mark - overlay probe

// App 自己的信息流/角标广告位不一定带广告 SDK 的类名，光靠类名猜会漏。所以每秒瞄一眼界面层，
// 把新冒出来的 App 自有视图记进日志：下一份日志就能直接点名是谁弹的，再决定挂谁。只记不拦。
static NSHashTable<UIView *> *TNASeenViews(void) {
    static NSHashTable *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSHashTable weakObjectsHashTable]; });
    return seen;
}

static BOOL TNALooksLikeOverlayHost(NSString *className) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[ @"Vip", @"Remind", @"Prompt", @"Upgrade", @"Dialog", @"Popup", @"Alert", @"Toast", @"Tip",
                     @"Ad", @"Ads" ];
    });
    for (NSString *marker in markers) {
        if ([className rangeOfString:marker].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *TNAViewText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return ((UILabel *)view).text;
    if ([view isKindOfClass:UIButton.class]) return ((UIButton *)view).currentTitle;
    if ([view isKindOfClass:UIControl.class]) return ((UIControl *)view).accessibilityLabel;
    return nil;
}

static void TNAScanOverlays(void) {
    static BOOL baselined = NO;
    BOOL report = baselined;
    baselined = YES;
    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [queue addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    NSUInteger visited = 0;
    while (queue.count && visited < 900) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        [queue addObjectsFromArray:view.subviews];
        BOOL fresh = ![TNASeenViews() containsObject:view];
        [TNASeenViews() addObject:view];
        if (!fresh || !report) continue;
        if (view.isHidden || view.alpha < 0.05 || !view.window) continue;
        if (!TNAClassIsAppOwned(view.class)) continue;
        NSString *className = NSStringFromClass(view.class);
        // 直接挂在窗口上的新视图一律记（弹窗都这么干）；藏在页面深处的只记名字像推广的。
        if (![view.superview isKindOfClass:UIWindow.class] && !TNALooksLikeOverlayHost(className)) continue;
        NSString *text = TNAViewText(view);
        TNALog(@"overlay %@ frame=%@ text=%@", className, NSStringFromCGRect(view.frame), text ?: @"-");
    }
    if (report) TNAFlushLog();
}

#pragma mark - explicit sites

typedef NS_ENUM(NSUInteger, TNATerminal) {
    TNATerminalNone = 0,   // 只吞掉调用，不补回调（原生广告回填没有等待方，吞掉即可）
    TNATerminalAd1,        // [delegate sel:self]
    TNATerminalSelfErr2,   // [delegate sel:self error:e]
    TNATerminalPidExtra2,  // [delegate sel:pid extra:@{}]
    TNATerminalPidErr2,    // [delegate sel:pid error:e]
    TNATerminalPidErr3,    // [delegate sel:pid error:e extra:@{}]
};

typedef struct {
    const char *cls;
    const char *sel;
    const char *delegateGetter;  // 非空则 delegate = [self delegateGetter]，否则取第 delegateArg 个实参
    unsigned char delegateArg;   // ObjC 参数序号：self=0、_cmd=1、第一个实参=2
    const char *terminalSel;
    TNATerminal terminal;
} TNASuppressSite;

// 屏蔽的是「这次请求/这次展示」，但终态回调一定补上——穿梭的开屏和插屏都是等回调往下走的流程，
// 把 load*/show* 直接挂成空实现就是把 App 卡死在启动页（上一版在向日葵上踩过的坑）。
static const TNASuppressSite TNASuppressSites[] = {
    // TopOn/AnyThink：第一个实参是 placementID，delegate 在不同版本里的参数位置不同，逐个标出。
    { "ATAdManager", "loadADWithPlacementID:extra:delegate:", NULL, 4,
      "didFailToLoadADWithPlacementID:error:", TNATerminalPidErr2 },
    { "ATAdManager", "loadADWithPlacementID:extra:delegate:containerView:", NULL, 4,
      "didFailToLoadADWithPlacementID:error:", TNATerminalPidErr2 },
    { "ATAdManager", "loadADWithPlacementID:extra:delegate:mediaVideoContainerView:viewController:", NULL, 4,
      "didFailToLoadADWithPlacementID:error:", TNATerminalPidErr2 },
    { "ATAdManager", "showSplashWithPlacementID:scene:window:delegate:", NULL, 5,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showSplashWithPlacementID:scene:window:extra:delegate:", NULL, 6,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showSplashWithPlacementID:scene:window:inViewController:delegate:", NULL, 6,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showSplashWithPlacementID:scene:window:inViewController:extra:delegate:", NULL, 7,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showSplashWithPlacementID:config:window:inViewController:extra:delegate:", NULL, 7,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showNormalSplashWithPlacementID:window:inViewController:delegate:splash:extra:", NULL, 5,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showNativeSplashWithPlacementID:splash:window:inViewController:delegate:extra:", NULL, 6,
      "splashDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showInterstitialWithPlacementID:inViewController:delegate:", NULL, 4,
      "interstitialDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showInterstitialWithPlacementID:scene:inViewController:delegate:", NULL, 5,
      "interstitialDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showInterstitialWithPlacementID:showConfig:inViewController:delegate:nativeMixViewBlock:",
      NULL, 5, "interstitialDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATAdManager", "showInterstitialWithPlacementID:scene:inViewController:delegate:nativeMixViewBlock:",
      NULL, 5, "interstitialDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATInterstitialAutoAdManager", "showAutoLoadInterstitialWithPlacementID:inViewController:delegate:", NULL, 4,
      "interstitialDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    { "ATInterstitialAutoAdManager", "showAutoLoadInterstitialWithPlacementID:scene:inViewController:delegate:",
      NULL, 5, "interstitialDidCloseForPlacementID:extra:", TNATerminalPidExtra2 },
    // 优量汇：delegate 是广告对象自己的属性，取 [self delegate]。
    { "GDTSplashAd", "loadAd", "delegate", 0, "splashAdClosed:", TNATerminalAd1 },
    { "GDTSplashAd", "loadFullScreenAd", "delegate", 0, "splashAdClosed:", TNATerminalAd1 },
    { "GDTSplashAd", "loadAdAndShowInWindow:", "delegate", 0, "splashAdClosed:", TNATerminalAd1 },
    { "GDTSplashAd", "loadAdAndShowInWindow:withBottomView:", "delegate", 0, "splashAdClosed:", TNATerminalAd1 },
    { "GDTSplashAd", "loadAdAndShowInWindow:withBottomView:skipView:", "delegate", 0, "splashAdClosed:",
      TNATerminalAd1 },
    { "GDTSplashAd", "loadAdAndShowFullScreenInWindow:withLogoImage:skipView:", "delegate", 0, "splashAdClosed:",
      TNATerminalAd1 },
    { "GDTSplashAd", "showAdInWindow:withBottomView:skipView:", "delegate", 0, "splashAdClosed:", TNATerminalAd1 },
    { "GDTSplashAd", "showFullScreenAdInWindow:withLogoImage:skipView:", "delegate", 0, "splashAdClosed:",
      TNATerminalAd1 },
    { "GDTSplashAd", "showAdInWindow:adProviderView:skipView:", "delegate", 0, "splashAdClosed:", TNATerminalAd1 },
    { "GDTUnifiedInterstitialAd", "loadAd", "delegate", 0, "unifiedInterstitialFailToLoadAd:error:",
      TNATerminalSelfErr2 },
    { "GDTUnifiedInterstitialAd", "loadFullScreenAd", "delegate", 0, "unifiedInterstitialFailToLoadAd:error:",
      TNATerminalSelfErr2 },
    { "GDTUnifiedInterstitialAd", "presentAdFromRootViewController:", "delegate", 0,
      "unifiedInterstitialFailToPresent:error:", TNATerminalSelfErr2 },
    { "GDTUnifiedInterstitialAd", "presentFullScreenAdFromRootViewController:", "delegate", 0,
      "unifiedInterstitialFailToPresent:error:", TNATerminalSelfErr2 },
    // AdMob：全屏内容的 delegate 是对象自己的属性，失败回调是 SDK 协议里本就有的那条。
    { "GADInterstitialAd", "presentFromRootViewController:", "fullScreenContentDelegate", 0,
      "ad:didFailToPresentFullScreenContentWithError:", TNATerminalSelfErr2 },
    { "GADAppOpenAd", "presentFromRootViewController:", "fullScreenContentDelegate", 0,
      "ad:didFailToPresentFullScreenContentWithError:", TNATerminalSelfErr2 },
    { "GADAdLoader", "loadRequest:", "delegate", 0, "adLoader:didFailToReceiveAdWithError:", TNATerminalSelfErr2 },
    { "GADAdLoader", "loadRequestWithTarget:", "delegate", 0, "adLoader:didFailToReceiveAdWithError:",
      TNATerminalSelfErr2 },
    // 原生广告位没有等待方，吞掉回填即可（App 自己的 AdMob 原生转发类）。
    { "_TtC13Transocks_iOS18GADNativeAdAdapter", "adLoader:didReceiveNativeAd:", NULL, 0, NULL,
      TNATerminalNone },
};

// 「有没有广告」的问询一律回 NO：App 侧的排期逻辑读到 NO 就自己走无广告分支，
// 比等展示出来再摘视图干净得多，也不牵扯任何回调。
static const char *TNAGateNoSites[][2] = {
    { "ATAdManager", "splashReadyForPlacementID:" },
    { "ATAdManager", "splashReadyForPlacementID:sendTK:" },
    { "ATAdManager", "splashReadyWithoutLogForPlacementID:sendTK:" },
    { "ATAdManager", "splashReadyForPlacementID:showConfig:caller:splash:extraInfo:sendTK:" },
    { "ATAdManager", "interstitialReadyForPlacementID:" },
    { "ATAdManager", "interstitialReadyForPlacementID:sendTK:" },
    { "ATAdManager", "interstitialReadyForPlacementID:showConfig:caller:interstitial:extraInfo:sendTK:" },
    { "ATAdManager", "nativeAdReadyForPlacementID:" },
    { "ATAdManager", "nativeAdReadyForPlacementID:sendTK:" },
    { "ATAdManager", "bannerAdReadyForPlacementID:" },
    { "ATAdManager", "bannerAdReadyForPlacementID:sendTK:" },
    { "ATAdManager", "bannerReadyForPlacementID:caller:banner:sendTK:" },
    { "ATAdManager", "bannerReadyForPlacementID:caller:banner:sendTK:scene:extraInfo:" },
    { "ATAdManager", "adReadyForPlacementID:" },
    { "ATAdManager", "adReadyForPlacementID:sendTK:" },
    { "ATAdManager", "adReadyForPlacementID:caller:context:" },
    { "ATAdManager", "adReadyForPlacementID:scene:caller:context:" },
    { "ATAdManager", "adReadyForPlacementID:scene:caller:sendTK:context:" },
    { "ATAdManager", "unionReadyForPlacementID:" },
    { "ATAdManager", "unionReadyForPlacementID:sendTK:" },
    { "ATAdManager", "unionReadyForPlacementID:showConfig:caller:ad:extraInfo:sendTK:" },
    { "GDTSplashAd", "isAdValid" },
    { "GDTUnifiedInterstitialAd", "isAdValid" },
    { "GDTUnifiedBannerView", "isAdValid" },
};

// 取广告对象的入口一律回 nil：拿不到 offer/banner 视图，信息流和 banner 位就一直是空的。
static const char *TNAGateNilSites[][2] = {
    { "ATAdManager", "getSplashValidAdsForPlacementID:" },
    { "ATAdManager", "getInterstitialValidAdsForPlacementID:" },
    { "ATAdManager", "getNativeValidAdsForPlacementID:" },
    { "ATAdManager", "getBannerValidAdsForPlacementID:" },
    { "ATAdManager", "getAdValidAdsForPlacementID:" },
    { "ATAdManager", "unionGetAdValidAdsForPlacementID:" },
    { "ATAdManager", "getNativeAdOfferWithPlacementID:" },
    { "ATAdManager", "getNativeAdOfferWithPlacementID:config:" },
    { "ATAdManager", "getNativeAdOfferWithPlacementID:scene:" },
    { "ATAdManager", "getNativeAdOfferWithPlacementID:showConfig:" },
    { "ATAdManager", "retrieveBannerViewForPlacementID:" },
    { "ATAdManager", "retrieveBannerViewForPlacementID:config:" },
    { "ATAdManager", "retrieveBannerViewForPlacementID:extra:" },
    { "ATAdManager", "retrieveBannerViewForPlacementID:scene:" },
    { "ATAdManager", "retrieveBannerViewForPlacementID:config:nativeMixBannerViewBlock:" },
    { "ATAdManager", "retrieveBannerViewForPlacementID:scene:nativeMixBannerViewBlock:" },
    { "ATAdManager", "mediaVideoObjectWithPlacementID:showConfig:delegate:" },
    { "ATAdManager", "getMediaVideoValidAdsForPlacementID:" },
    { "ATAdManager", "offerWithPlacementID:error:refresh:" },
};

static void TNAFireTerminal(id delegate, const TNASuppressSite *site, id adObject, NSString *placementID) {
    if (!delegate || !site->terminalSel) return;
    SEL terminal = sel_getUid(site->terminalSel);
    if (![delegate respondsToSelector:terminal]) {
        TNALog(@"terminal missing %@@%@", @(site->terminalSel), NSStringFromClass([delegate class]));
        return;
    }
    NSError *error = TNABlockedError();
    // extra 一律给空字典而不是 nil：Swift 会把 SDK 头文件里没标 nullability 的 NSDictionary 导成
    // 非可选字典，传 nil 过去在桥接处直接崩。placementID 同理兜一个空串。
    switch (site->terminal) {
        case TNATerminalAd1:
            ((void (*)(id, SEL, id))objc_msgSend)(delegate, terminal, adObject);
            break;
        case TNATerminalSelfErr2:
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, terminal, adObject, error);
            break;
        case TNATerminalPidExtra2:
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, terminal, placementID, @{});
            break;
        case TNATerminalPidErr2:
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, terminal, placementID, error);
            break;
        case TNATerminalPidErr3:
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, terminal, placementID, error, @{});
            break;
        default:
            break;
    }
}

static void TNASuppressRun(const TNASuppressSite *site, SEL delegateGetter, id self, const id *args,
                           unsigned int count) {
    id delegate = nil;
    if (delegateGetter) {
        delegate = ((id (*)(id, SEL))objc_msgSend)(self, delegateGetter);
    } else if (site->delegateArg >= 2 && site->delegateArg - 2 < count) {
        delegate = args[site->delegateArg - 2];
    }
    id first = count ? args[0] : nil;
    // placementID 一律是第一个实参；不是字符串就说明 SDK 换了签名，回空串即可（终态回调宁少勿崩）。
    NSString *placementID = [first isKindOfClass:NSString.class] ? (NSString *)first : @"";
    atomic_fetch_add_explicit(&TNAActionCount, 1, memory_order_relaxed);
    TNALog(@"suppress -[%@ %@] delegate=%@", NSStringFromClass(object_getClass(self)), @(site->sel),
           delegate ? NSStringFromClass([delegate class]) : @"-");
    TNAFireTerminal(delegate, site, self, placementID);
}

// 块的实参个数必须和目标方法一字不差。imp_implementationWithBlock 的闭包按「块自己的签名」搬寄存器，
// 多声明的那几位拿到的是脏寄存器，一旦当成对象用（bridge 成 id 就 objc_retain）直接 SIGSEGV——
// 上一版一个宽块通吃所有站点，开屏的 loadADWithPlacementID:extra:delegate: 就是这么把 App 打崩的。
// 反过来少声明是安全的（多出来的寄存器没人读），所以按实参个数 0..6 分族，逐族各写一块。
// 站点表已保证 self/_cmd 之外的实参全是对象（TNAArgsAllPortable），这些槽位才敢声明成 id。
static IMP TNASuppressIMP(const TNASuppressSite *site, SEL delegateGetter, unsigned int realArgs) {
    id block = nil;
    switch (realArgs) {
        case 0:
            block = (id) ^void(id self, SEL _cmd) {
                TNASuppressRun(site, delegateGetter, self, NULL, 0);
            };
            break;
        case 1:
            block = (id) ^void(id self, SEL _cmd, id a0) {
                id args[] = { a0 };
                TNASuppressRun(site, delegateGetter, self, args, 1);
            };
            break;
        case 2:
            block = (id) ^void(id self, SEL _cmd, id a0, id a1) {
                id args[] = { a0, a1 };
                TNASuppressRun(site, delegateGetter, self, args, 2);
            };
            break;
        case 3:
            block = (id) ^void(id self, SEL _cmd, id a0, id a1, id a2) {
                id args[] = { a0, a1, a2 };
                TNASuppressRun(site, delegateGetter, self, args, 3);
            };
            break;
        case 4:
            block = (id) ^void(id self, SEL _cmd, id a0, id a1, id a2, id a3) {
                id args[] = { a0, a1, a2, a3 };
                TNASuppressRun(site, delegateGetter, self, args, 4);
            };
            break;
        case 5:
            block = (id) ^void(id self, SEL _cmd, id a0, id a1, id a2, id a3, id a4) {
                id args[] = { a0, a1, a2, a3, a4 };
                TNASuppressRun(site, delegateGetter, self, args, 5);
            };
            break;
        case 6:
            block = (id) ^void(id self, SEL _cmd, id a0, id a1, id a2, id a3, id a4, id a5) {
                id args[] = { a0, a1, a2, a3, a4, a5 };
                TNASuppressRun(site, delegateGetter, self, args, 6);
            };
            break;
        default:
            return NULL;
    }
    TNAKeep(block);
    return imp_implementationWithBlock(block);
}

// 网关块一个实参都不声明：它只伪造返回值，读到的寄存器一个也不用。声明得比目标方法少是安全的，
// 多出来的实参没人碰；反过来多声明就会把脏寄存器当参数用（见 TNASuppressIMP 的注释）。
static IMP TNAGateNoIMP(void) {
    static IMP cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL (^block)(id, SEL) = ^BOOL(id self, SEL _cmd) {
            (void)self; (void)_cmd;
            atomic_fetch_add_explicit(&TNAActionCount, 1, memory_order_relaxed);
            return NO;
        };
        TNAKeep(block);
        cached = imp_implementationWithBlock(block);
    });
    return cached;
}

static IMP TNAGateNilIMP(void) {
    static IMP cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *(^block)(id, SEL) = ^void *(id self, SEL _cmd) {
            (void)self; (void)_cmd;
            atomic_fetch_add_explicit(&TNAActionCount, 1, memory_order_relaxed);
            return NULL;
        };
        TNAKeep((id)block);
        cached = imp_implementationWithBlock(block);
    });
    return cached;
}

// 返回类型是标量（BOOL/NSInteger/…）还是对象，决定了这个站点能不能伪造返回值。
static BOOL TNAGateShapeOK(char returnType, BOOL wantsNO) {
    if (wantsNO) {
        return returnType == 'B' || returnType == 'c' || returnType == 'i' || returnType == 's' ||
               returnType == 'l' || returnType == 'q' || returnType == 'I' || returnType == 'S' ||
               returnType == 'L' || returnType == 'Q';
    }
    return returnType == '@' || returnType == '#' || returnType == '*' || returnType == '^';
}

static IMP TNAPickGateIMP(BOOL wantsNO) { return wantsNO ? TNAGateNoIMP() : TNAGateNilIMP(); }

static void TNAInstallSite(const TNASuppressSite *site) {
    if (site->delegateGetter && site->delegateArg) {  // 表里写错了：两种取法只能选一种
        TNALog(@"site misconfigured -[%@ %@]", @(site->cls), @(site->sel));
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%s %s", site->cls, site->sel];
    Class cls = NSClassFromString(@(site->cls));
    if (!cls) return;  // 类还没注册进来，下一轮补扫再来
    if (TNASiteSettled(key)) return;
    SEL sel = sel_getUid(site->sel);
    Method method = TNAOwnMethod(cls, sel, NO) ?: TNAOwnMethod(cls, sel, YES);
    if (!method) {
        TNALog(@"site absent -[%@ %@]", @(site->cls), @(site->sel));
        return;
    }
    char returnType = 'v';
    const char *encoding = method_getTypeEncoding(method);
    if (!TNAReturnKind(encoding, &returnType) || returnType != 'v') {
        TNALog(@"site refused return=%s -[%@ %@]", encoding ?: "", @(site->cls),
               @(site->sel));
        return;
    }
    unsigned int arguments = 0;
    if (!TNAArgsAllPortable(method, &arguments)) {
        TNALog(@"site refused arg-shape -[%@ %@] %s", @(site->cls), @(site->sel),
               encoding ?: "");
        return;
    }
    if (!site->delegateGetter && site->delegateArg >= arguments) {
        // 参数下标越界，多半是 SDK 换了签名。
        TNALog(@"site refused delegate arg %u >= %u -[%@ %@]", (unsigned)site->delegateArg,
               arguments, @(site->cls), @(site->sel));
        return;
    }
    IMP replacement = TNASuppressIMP(site, site->delegateGetter ? sel_getUid(site->delegateGetter) : NULL,
                                     arguments - 2);
    IMP original = method_getImplementation(method);
    if (!replacement || original == replacement) return;
    method_setImplementation(method, replacement);
    TNAHookedCount++;
    TNALog(@"site-hook -[%@ %@]", @(site->cls), @(site->sel));
}

static void TNAInstallGateSites(const char *sites[][2], size_t count, BOOL wantsNO) {
    for (size_t i = 0; i < count; i++) {
        Class cls = NSClassFromString(@(sites[i][0]));
        if (!cls) continue;  // 类还没注册进来，下一轮补扫再来
        NSString *key = [NSString stringWithFormat:@"gate %s %s", sites[i][0], sites[i][1]];
        if (TNASiteSettled(key)) continue;
        SEL sel = sel_getUid(sites[i][1]);
        Method method = TNAOwnMethod(cls, sel, NO) ?: TNAOwnMethod(cls, sel, YES);
        if (!method) {
            TNALog(@"gate absent -[%@ %@]", @(sites[i][0]), @(sites[i][1]));
            continue;
        }
        char returnType = 'v';
        const char *encoding = method_getTypeEncoding(method);
        if (!TNAReturnKind(encoding, &returnType)) continue;
        if (method_getNumberOfArguments(method) > 10) continue;
        if (!TNAGateShapeOK(returnType, wantsNO)) {
            TNALog(@"gate refused return=%s -[%@ %@]", encoding ?: "", @(sites[i][0]),
                   @(sites[i][1]));
            continue;
        }
        IMP replacement = TNAPickGateIMP(wantsNO);
        IMP original = method_getImplementation(method);
        if (!replacement || original == replacement) continue;
        method_setImplementation(method, replacement);
        TNAHookedCount++;
        TNALog(@"gate-hook %@[%@ %@] %s", wantsNO ? @"NO" : @"nil", @(sites[i][0]),
               @(sites[i][1]), encoding ?: "");
    }
}

#pragma mark - custom boot ad

// 自绘开屏：穿梭自己下发的启动图（CustomBootAd.nib），不属于任何广告 SDK，也没有等回调的流程，
// 所以让这块盖布一挂上窗口就藏起来。App 的倒计时和 dismissAdsView 照跑，流程不受影响。
// 每轮补扫都要重新查：构造函数跑到的时候这个 Swift 类可能还没注册，缓存住就再也挂不上了。
static Class TNACustomBootAdClass(void) {
    Class cls = NSClassFromString(@"_TtC13Transocks_iOS12CustomBootAd");
    return cls ?: NSClassFromString(@"Transocks_iOS.CustomBootAd");
}

static void TNAHideBootAdView(id view) {
    if (![view isKindOfClass:UIView.class]) return;
    ((UIView *)view).hidden = YES;
    ((UIView *)view).alpha = 0;
}

static IMP TNAHideOnWindowIMP(IMP original, Class cls) {
    void (^block)(id, SEL) = ^(id self, SEL _cmd) {
        if (original) {
            ((void (*)(id, SEL))original)(self, _cmd);
        } else {
            // 类自己没有实现 didMoveToWindow，补一个就必须把消息转给父类，
            // 否则 UIView 那半截（层级、绘制准备）被我们吞掉了。
            struct objc_super superInfo = { .receiver = self, .super_class = class_getSuperclass(cls) };
            ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, _cmd);
        }
        if (!((UIView *)self).isHidden) {
            TNAActionCount++;
            TNALog(@"hide CustomBootAd on window");
        }
        TNAHideBootAdView(self);
    };
    TNAKeep(block);
    return imp_implementationWithBlock(block);
}

static void TNAInstallBootAdHooks(void) {
    if (TNASiteSettled(@"bootad")) return;
    Class cls = TNACustomBootAdClass();
    if (!cls) return;  // 类还没注册进来，下一轮补扫再来
    SEL sel = @selector(didMoveToWindow);
    Method own = TNAOwnMethod(cls, sel, NO);
    IMP replacement = TNAHideOnWindowIMP(own ? method_getImplementation(own) : NULL, cls);
    if (!replacement) return;
    if (own) {
        method_setImplementation(own, replacement);
        TNAHookedCount++;
        TNALog(@"boot-ad-hook didMoveToWindow (wrapped)");
        return;
    }
    // 补不上就算了：退而去改继承来的 UIView.didMoveToWindow 会把全 App 的视图都藏掉。
    if (class_addMethod(cls, sel, replacement, "v@:")) {
        TNAHookedCount++;
        TNALog(@"boot-ad-hook didMoveToWindow (added)");
    } else {
        TNALog(@"boot-ad-hook refused");
    }
}

#pragma mark - entry

static dispatch_queue_t TNAInstallQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.moxuan.transocksnoad.install", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static void TNAInstallExplicitSites(NSString *pass) {
    TNAInstallGateSites(TNAGateNoSites, sizeof(TNAGateNoSites) / sizeof(TNAGateNoSites[0]), YES);
    TNAInstallGateSites(TNAGateNilSites, sizeof(TNAGateNilSites) / sizeof(TNAGateNilSites[0]), NO);
    for (size_t i = 0; i < sizeof(TNASuppressSites) / sizeof(TNASuppressSites[0]); i++) {
        TNAInstallSite(&TNASuppressSites[i]);
    }
    TNAInstallBootAdHooks();
    TNALog(@"explicit pass %@ done", pass);
    TNAFlushLog();
}

// 启动窗口：这之前的补扫全部交给下面的定时任务，最后一次落在 40 s。
static const NSTimeInterval TNAStartupWindow = 45;

__attribute__((constructor)) static void TransocksNoAdEntry(void) {
    @autoreleasepool {
        TNALaunchUptime = NSProcessInfo.processInfo.systemUptime;
        TNALog(@"TransocksNoAd attached to %@ / %@", NSProcessInfo.processInfo.processName,
               NSBundle.mainBundle.bundleIdentifier);
        TNAInstallAll(@"launch", YES);
        TNAInstallExplicitSites(@"launch");
        // 主线程每秒扫一遍界面层，把新出现的 App 自有视图记进日志，先认出来才能屏蔽。
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            TNAScanOverlays();
        }];
        // 广告视图类大多要等第一次请求广告时才注册，所以要反复补扫；热启动回前台同理。
        for (NSNumber *delay in @[ @0.2, @2, @5, @15, @(TNAStartupWindow - 5) ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           TNAInstallQueue(), ^{
                               TNAInstallAll(@"full", NO);
                           });
        }
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                    object:nil
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification *note) {
                                                                      NSTimeInterval age =
                                                                          NSProcessInfo.processInfo.systemUptime -
                                                                          TNALaunchUptime;
                                                                      if (age < TNAStartupWindow) {
                                                                          TNALog(@"skip active pass at +%0.0fs (startup window)", age);
                                                                          // 这条之后没有 pass 会再刷盘，不主动 flush 就等于没写。
                                                                          TNAFlushLog();
                                                                          return;
                                                                      }
                                                                      dispatch_async(TNAInstallQueue(), ^{
                                                                          TNAInstallAll(@"active", NO);
                                                                      });
                                                                  }];
        TNAKeep(observer);
    }
}
