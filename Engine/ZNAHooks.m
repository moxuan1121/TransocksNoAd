#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdatomic.h>
#import <string.h>
#import "ZNAPattern.h"

static os_log_t ZNALogger(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.moxuan.zoomablenoad", "ads"); });
    return logger;
}

static NSMutableArray<NSString *> *ZNAJournal(void) {
    static NSMutableArray *journal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ journal = [NSMutableArray new]; });
    return journal;
}

static NSTimeInterval ZNALaunchUptime = 0;

// 挂上格式检查：这些日志是下次真机迭代唯一的依据，写错一个占位符就是白跑一轮。
static void ZNALog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// 只数写了多少条，不数数组长度：数组到 2500 条就截断，长度看不出这一轮有没有新内容。
static _Atomic NSUInteger ZNALogSeq = 0;

static void ZNALog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"+%7.3f %@",
                      NSProcessInfo.processInfo.systemUptime - ZNALaunchUptime, message];
    os_log(ZNALogger(), "%{public}@", line);
    atomic_fetch_add_explicit(&ZNALogSeq, 1, memory_order_relaxed);
    @synchronized(ZNAJournal()) {
        [ZNAJournal() addObject:line];
        if (ZNAJournal().count > 2500) [ZNAJournal() removeObjectsInRange:NSMakeRange(0, ZNAJournal().count - 2500)];
    }
}

// 沙盒里取不出来的日志等于没写，所以一次写盘同时往所有可能的地方各写一份：
// App 容器 Documents 这一份最关键 —— Zoomable 开了 UIFileSharingEnabled，不用越狱文件管理器、
// 在系统「文件」App 里就能直接看到。哪个路径先写成功就记进日志，下次只看那一个地方。
static NSArray<NSString *> *ZNALogPaths(void) {
    static NSArray<NSString *> *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *home = NSHomeDirectory();
        paths = @[
            [home stringByAppendingPathComponent:@"Documents/ZoomableNoAd.log"],
            [home stringByAppendingPathComponent:@"Library/Caches/ZoomableNoAd.log"],
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"ZoomableNoAd.log"],
            @"/private/tmp/ZoomableNoAd.log",
            @"/var/tmp/ZoomableNoAd.log",
            @"/var/mobile/Media/ZoomableNoAd.log",
            @"/var/mobile/Media/Documents/ZoomableNoAd.log",
        ];
    });
    return paths;
}

// 第一次成功写盘落在了哪条路径；一条都没写成就是 @"(none)"，构造函数会原样记进日志。
static NSString *ZNALogWrittenPath = nil;

static void ZNAFlushLog(void) {
    NSArray<NSString *> *snapshot;
    @synchronized(ZNAJournal()) {
        snapshot = [ZNAJournal() copy];
    }
    NSString *text = [snapshot componentsJoinedByString:@"\n"];
    for (NSString *path in ZNALogPaths()) {
        NSError *error = nil;
        if ([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            if (!ZNALogWrittenPath) ZNALogWrittenPath = path;
            continue;
        }
        // 目录不存在是常态（沙盒里 tmp 一套各有出入），但哪条路被沙盒挡了值得留一行 ——
        // 只在还没写成过的时候报，避免每次落盘都往日志里塞同一批噪音。
        if (!ZNALogWrittenPath) ZNALog(@"log write refused %@ (code %ld)", path, (long)error.code);
    }
    if (!ZNALogWrittenPath) ZNALogWrittenPath = @"(none)";
}

static NSMutableArray<id> *ZNAKeepAlive(void) {
    static NSMutableArray *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSMutableArray new]; });
    return kept;
}

// imp_implementationWithBlock 造出来的 IMP 只要块对象活着就行，而它没有任何地方持有，
// 所以统一挂进这个数组：一放出去就没人管的话，下次 GC 时代码页就飞了。
static void ZNAKeep(id object) {
    @synchronized(ZNAKeepAlive()) {
        [ZNAKeepAlive() addObject:object];
    }
}

// 开屏 pass 在主线程、全量 pass 在后台队列，两边同时在加。
static _Atomic NSUInteger ZNAActionCount = 0;
static _Atomic NSUInteger ZNAHookedCount = 0;

static NSError *ZNABlockedError(void) {
    return [NSError errorWithDomain:@"ZoomableNoAd" code:2001
                           userInfo:@{ NSLocalizedDescriptionKey : @"ad suppressed by ZoomableNoAd" }];
}

#pragma mark - runtime helpers

// 只挂目标类自己实现的方法：class_getInstanceMethod 会顺着父类找，拿到继承方法就等于改了父类，
// 而 GAD*/GAM* 的父类往往是好几个广告对象共用（GADFullScreenAd 就是插屏、开屏、激励的基类）。
static Method ZNAOwnMethod(Class cls, SEL sel, BOOL classMethod) {
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
static BOOL ZNAReturnKind(const char *encoding, char *out) {
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

#pragma mark - skip button

// 只认「跳过」：这类按钮按下后广告会走 SDK 自己的关闭分支，宿主 App 拿得到回调。
// 「关闭」一类的不点——它可能属于业务弹窗，而且误触广告比广告本身更糟。
static BOOL ZNAMatchSkipText(NSString *text) {
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

static BOOL ZNALooksLikeSkip(UIControl *control) {
    if ([control isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)control;
        if (ZNAMatchSkipText(button.currentTitle) || ZNAMatchSkipText(button.currentAttributedTitle.string)) return YES;
    }
    if (control.allTargets.count == 0) return NO;
    return ZNAMatchSkipText(control.accessibilityLabel) || ZNAMatchSkipText(control.accessibilityValue);
}

// 广度优先找广告自带的跳过按钮，限定在这块广告视图内部，避免点到业务界面的同名按钮。
static NSUInteger ZNATrySkipInView(UIView *root) {
    static const NSUInteger ZNAMaxNodes = 400;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger tapped = 0, visited = 0;
    while (queue.count && visited < ZNAMaxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view != root && [view isKindOfClass:UIControl.class] && ZNALooksLikeSkip((UIControl *)view)) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            tapped++;
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return tapped;
}

static const void *ZNASkipStateKey = &ZNASkipStateKey;

// 跳过按钮往往要等广告素材到位才建出来，所以按节流重试几次，而不是一次定终身。
static void ZNASkipIfNeeded(UIView *view, NSString *className) {
    if (!view) return;
    NSMutableArray *state = objc_getAssociatedObject(view, ZNASkipStateKey);
    if (!state) {
        state = [NSMutableArray arrayWithObjects:@0, @0, nil];
        objc_setAssociatedObject(view, ZNASkipStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    static const NSInteger ZNAMaxSkipAttempts = 6;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([state[0] integerValue] >= ZNAMaxSkipAttempts || now - [state[1] doubleValue] < 0.5) return;
    state[0] = @([state[0] integerValue] + 1);
    state[1] = @(now);
    NSUInteger tapped = ZNATrySkipInView(view);
    if (tapped) {
        state[0] = @(ZNAMaxSkipAttempts);
        ZNALog(@"skip-button %@ x%lu", className, (unsigned long)tapped);
    }
}

// 广告视图常被复用（热启动第二次起就是同一个对象），所以只要它又变成可见的，
// 就重置跳过重试的配额，让它重新有机会按下跳过。
static void ZNAHideAndSkip(UIView *view, NSString *className) {
    if (!view) return;
    if (!view.isHidden) {
        objc_setAssociatedObject(view, ZNASkipStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.hidden = YES;
    view.alpha = 0;
    ZNASkipIfNeeded(view, className);
}

#pragma mark - defuse

static void ZNAReleaseViewController(UIViewController *vc) {
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

static void ZNADefuse(id target) {
    if (!target) return;
    NSString *className = NSStringFromClass(object_getClass(target));
    BOOL splash = ZNAIsSplashLikeName(className.UTF8String);
    void (^work)(void) = ^{
        ZNAActionCount++;
        if ([target isKindOfClass:UIWindow.class]) {
            ZNAHideAndSkip(target, className);
            ZNALog(@"defuse window %@", className);
        } else if ([target isKindOfClass:UIViewController.class]) {
            UIViewController *vc = target;
            if (vc.isViewLoaded) ZNAHideAndSkip(vc.view, className);
            // 兜底：插屏可能没有自动关闭，宽限期后替它离场，别让用户对着一个看不见的模态。
            // 开屏的宽限期给足，倒计时跑完 SDK 会自己关，抢先销毁反而拿不到回调。
            NSTimeInterval grace = splash ? 8 : 1.2;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(grace * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               ZNAReleaseViewController(vc);
                           });
            ZNALog(@"defuse vc %@ splash=%d", className, splash);
        } else if ([target isKindOfClass:UIView.class]) {
            UIView *view = target;
            ZNAHideAndSkip(view, className);
            // 开屏视图留在视图树里，SDK 的倒计时和关闭回调才能继续跑；其它广告直接摘掉。
            if (!splash && view.superview) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [view removeFromSuperview];
                });
            }
            ZNALog(@"defuse view %@ splash=%d", className, splash);
        }
        if ((ZNAActionCount % 25) == 0) ZNAFlushLog();
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// 转发垫片也按实参个数分族，而且同样没有 _cmd 这一位（见 ZNASuppressIMP 上方的实测结论）：选择子
// 在装钩子的时候从 Method 里取好、由闭包捕获，再转发给原实现。块声明几位，原实现就从哪几位取值，
// 多声明一位就会把脏寄存器当成参数转下去（willMoveToWindow: 收到一个假 window 就是崩溃）。
// 只到 1 个实参为止：更宽的方法形参类型无从判断，一律不动。
// 槽位一律用 void *：垫片不认识也不需要认识它们是什么类型，ARC 不会去 retain 一个指针槽位。
#define ZNADefuse0(RET)                                         \
    (^RET(id self) {                                            \
        RET result = ((RET (*)(id, SEL))original)(self, cmd);   \
        ZNADefuse(self);                                        \
        return result;                                          \
    })
#define ZNADefuse1(RET)                                                     \
    (^RET(id self, void *a0) {                                              \
        RET result = ((RET (*)(id, SEL, void *))original)(self, cmd, a0);   \
        ZNADefuse(self);                                                    \
        return result;                                                      \
    })

static IMP ZNADefuseIMP(IMP original, SEL cmd, char returnType, unsigned int realArgs) {
    if (realArgs > 1) return NULL;
    BOOL one = realArgs == 1;
    id block = nil;
    if (returnType == 'v') {
        if (one) {
            void (^b)(id, void *) = ^void(id self, void *a0) {
                ((void (*)(id, SEL, void *))original)(self, cmd, a0);
                ZNADefuse(self);
            };
            block = (id)b;
        } else {
            void (^b)(id) = ^void(id self) {
                ((void (*)(id, SEL))original)(self, cmd);
                ZNADefuse(self);
            };
            block = (id)b;
        }
    } else if (returnType == '@' || returnType == '#' || returnType == '*' || returnType == '^') {
        block = one ? (id)ZNADefuse1(id) : (id)ZNADefuse0(id);
    } else if (returnType == 'f') {
        block = one ? (id)ZNADefuse1(float) : (id)ZNADefuse0(float);
    } else if (returnType == 'd') {
        block = one ? (id)ZNADefuse1(double) : (id)ZNADefuse0(double);
    } else {
        block = one ? (id)ZNADefuse1(NSInteger) : (id)ZNADefuse0(NSInteger);
    }
    ZNAKeep(block);
    return imp_implementationWithBlock(block);
}

#pragma mark - defuse installation

static void ZNAInstallIn(Class cls) {
    for (BOOL classMethod = NO;; classMethod = YES) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Method method = methods[i];
            SEL selector = method_getName(method);
            if (!ZNAIsPresentationSelector(sel_getName(selector))) continue;
            char returnType = 'v';
            const char *encoding = method_getTypeEncoding(method);
            if (!ZNAReturnKind(encoding, &returnType)) continue;
            // 转发垫片最多带 1 个实参；更宽的方法一律不动。
            unsigned int arguments = method_getNumberOfArguments(method);
            if (arguments > 3) continue;
            IMP original = method_getImplementation(method);
            IMP replacement = ZNADefuseIMP(original, selector, returnType, arguments - 2);
            if (!replacement || original == replacement) continue;
            method_setImplementation(method, replacement);
            ZNAHookedCount++;
            ZNALog(@"defuse-hook %@[%@ %@] %s", classMethod ? @"+@" : @"-", NSStringFromClass(cls),
                   NSStringFromSelector(selector), encoding);
        }
        free(methods);
        if (classMethod) break;
    }
}

static NSMutableSet<NSString *> *ZNAVisited(void) {
    static NSMutableSet *visited;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ visited = [NSMutableSet new]; });
    return visited;
}

// 已经「有定论」的显式站点：类已经注册了，缺哪个方法就是真缺，不必每轮补扫再试一遍。
// 只有整个类还没注册进来时才重试（Swift 那批广告转发类要等第一次用到的时候才 realized）。
static NSMutableSet<NSString *> *ZNASettledSites(void) {
    static NSMutableSet *settled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settled = [NSMutableSet new]; });
    return settled;
}

static BOOL ZNASiteSettled(NSString *key) {
    @synchronized(ZNASettledSites()) {
        if ([ZNASettledSites() containsObject:key]) return YES;
        [ZNASettledSites() addObject:key];
    }
    return NO;
}

// 只处理 App 自带可执行文件与内嵌框架里的类，系统框架一律跳过。
static BOOL ZNAClassIsAppOwned(Class cls) {
    const char *image = class_getImageName(cls);
    return image && strstr(image, ".app/");
}

static void ZNAInstallAll(NSString *pass, BOOL launchOnly);
static void ZNAInstallExplicitSites(NSString *pass);

static void ZNAInstallAll(NSString *pass, BOOL launchOnly) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger scanned = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (launchOnly ? !ZNAIsLaunchClassName(name) : !ZNAIsInterestingClassName(name)) continue;
        if (!ZNAClassIsAppOwned(classes[i])) continue;
        NSString *key = @(name);
        @synchronized(ZNAVisited()) {
            // 先占名再挂，重复的 pass 和并发的两条 pass 都不会把方法套两层。
            if ([ZNAVisited() containsObject:key]) continue;
            [ZNAVisited() addObject:key];
        }
        scanned++;
        ZNAInstallIn(classes[i]);
    }
    free(classes);
    ZNALog(@"pass %@: %u classes, %lu candidates, %lu hooks in %.0f ms", pass, count, (unsigned long)scanned,
           (unsigned long)ZNAHookedCount, (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    // 显式站点表跟着每轮补扫重试：类要等第一次用到才注册，构造函数里只跑一次会漏。
    if (!launchOnly) ZNAInstallExplicitSites(pass);
    ZNAFlushLog();
}

#pragma mark - overlay probe

// App 自己的信息流/角标广告位不一定带广告 SDK 的类名，光靠类名猜会漏。所以每秒瞄一眼界面层，
// 把新冒出来的 App 自有视图记进日志：下一份日志就能直接点名是谁弹的，再决定挂谁。只记不拦。
static NSHashTable<UIView *> *ZNASeenViews(void) {
    static NSHashTable *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSHashTable weakObjectsHashTable]; });
    return seen;
}

static BOOL ZNALooksLikeOverlayHost(NSString *className) {
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

static NSString *ZNAViewText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return ((UILabel *)view).text;
    if ([view isKindOfClass:UIButton.class]) return ((UIButton *)view).currentTitle;
    if ([view isKindOfClass:UIControl.class]) return ((UIControl *)view).accessibilityLabel;
    return nil;
}

static void ZNAScanOverlays(void) {
    static BOOL baselined = NO;
    BOOL report = baselined;
    baselined = YES;
    NSUInteger before = atomic_load_explicit(&ZNALogSeq, memory_order_relaxed);
    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [queue addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    if (queue.count == 0) {
        // 没有 scene manifest 的 App（Zoomable 就是）在新系统上通常也会被包一层 windowScene，
        // 但真包不出来的时候不能整个扫不到 —— 退回老那套 windows。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [queue addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    NSUInteger visited = 0;
    while (queue.count && visited < 900) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        [queue addObjectsFromArray:view.subviews];
        BOOL fresh = ![ZNASeenViews() containsObject:view];
        [ZNASeenViews() addObject:view];
        if (!fresh || !report) continue;
        if (view.isHidden || view.alpha < 0.05 || !view.window) continue;
        if (!ZNAClassIsAppOwned(view.class)) continue;
        NSString *className = NSStringFromClass(view.class);
        // 直接挂在窗口上的新视图一律记（弹窗都这么干）；藏在页面深处的只记名字像推广的。
        if (![view.superview isKindOfClass:UIWindow.class] && !ZNALooksLikeOverlayHost(className)) continue;
        NSString *text = ZNAViewText(view);
        ZNALog(@"overlay %@ frame=%@ text=%@", className, NSStringFromCGRect(view.frame), text ?: @"-");
    }
    // 每秒往磁盘重写整份日志，等于给主线程加了一次同步 IO —— 卡在开屏时这就是自己造的噪音。
    // 这一轮没记下新视图就别写盘。
    if (report && atomic_load_explicit(&ZNALogSeq, memory_order_relaxed) != before) ZNAFlushLog();
}

#pragma mark - explicit sites

typedef NS_ENUM(NSUInteger, ZNATerminal) {
    ZNATerminalNone = 0,  // 只吞掉调用，不补回调
    ZNATerminalSelfErr2,  // [delegate sel:self error:e]
};

typedef struct {
    const char *cls;
    const char *sel;
    const char *delegateGetter;  // AdMob 的 delegate 都是广告对象自己的属性
    const char *terminalSel;
    ZNATerminal terminal;
} ZNASuppressSite;

// 只吞「把广告画到屏幕上」这一步，而且补的必须是 SDK 自己那条流程真会发的终态回调。
//
// 加载/请求一类一律不吞（+[… loadWithAdUnitID:request:completionHandler:]、-[GADAdLoader loadRequest:]）：
// 挂空之后 SDK 的加载链永远走不到终态，App 侧等回填的那一步就吊在那里。
//
// present 按叶子类逐个列，不走父类。这份二进制里（AdMob 11.13，主镜像 __objc_classlist 实测）
// presentFromRootViewController: 各自实现于 GADAppOpenAd / GADInterstitialAd 本类，而激励用的是
// 另一个选择子 presentFromRootViewController:userDidEarnRewardHandler:（GADRewardedAd、
// GADFullScreenAd 上），所以挂前者碰不到用户主动看的那条奖励链。GAMInterstitialAd 本类一份实现都
// 没有，靠父类 GADInterstitialAd，安装时会在它本类补一份覆盖，不会反过来改父类。
//
// 开屏（GADAppOpenAd）这一次要进来：Zoomable 是浏览器，主界面在 application:didFinishLaunching
// 里就搭好了（AppDelegate 自己实现 setWindow:/window），App Open 只是盖在上面的浮层，吞掉 present
// 并补 ad:didFailToPresent: 之后 App 该看到的界面一个不少 —— 穿梭那次卡住是 Topon 的 CustomBootAd
// 把根视图切换吊在了广告回调上，形态不同。
//
// banner 和原生位也不在这里挂：GADBannerView / GADNativeAdView 本身就是 UIView，类名遮挡会把它们
// 连子树一起藏掉。AdMob 没有「先问有没有广告再决定展不展示」的同步问询，硬造一道回 NO 的网关只会
// 掐断 SDK 自己的流程。
static const ZNASuppressSite ZNASuppressSites[] = {
    { "GADInterstitialAd", "presentFromRootViewController:", "fullScreenContentDelegate",
      "ad:didFailToPresentFullScreenContentWithError:", ZNATerminalSelfErr2 },
    // GAM 是 AdMob 的 managed（Ad Manager）插屏，和 GADInterstitialAd 同一条 present 链。
    { "GAMInterstitialAd", "presentFromRootViewController:", "fullScreenContentDelegate",
      "ad:didFailToPresentFullScreenContentWithError:", ZNATerminalSelfErr2 },
    // 开屏：用户这一轮报的就是这一类。
    { "GADAppOpenAd", "presentFromRootViewController:", "fullScreenContentDelegate",
      "ad:didFailToPresentFullScreenContentWithError:", ZNATerminalSelfErr2 },
};

static void ZNAFireTerminal(id delegate, const ZNASuppressSite *site, id adObject) {
    if (!delegate || !site->terminalSel) return;
    SEL terminal = sel_getUid(site->terminalSel);
    if (![delegate respondsToSelector:terminal]) {
        ZNALog(@"terminal missing %@@%@", @(site->terminalSel), NSStringFromClass([delegate class]));
        return;
    }
    // 出错回调本身也是 SDK 协议里就有的那条：App 侧走到「这次没广告」的分支，不靠我们额外推。
    // error 给真对象而不是 nil，Swift 桥接处把没标 nullability 的参数当成非可选时会直接崩。
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, terminal, adObject, ZNABlockedError());
}

static void ZNASuppressRun(const ZNASuppressSite *site, SEL delegateGetter, id self) {
    id delegate = delegateGetter ? ((id (*)(id, SEL))objc_msgSend)(self, delegateGetter) : nil;
    atomic_fetch_add_explicit(&ZNAActionCount, 1, memory_order_relaxed);
    ZNALog(@"suppress -[%@ %@] delegate=%@", NSStringFromClass(object_getClass(self)), @(site->sel),
           delegate ? NSStringFromClass([delegate class]) : @"-");
    ZNAFireTerminal(delegate, site, self);
    // 站点命中是排查时最想要的那一行，攒够 25 次动作才写盘太晚了。
    ZNAFlushLog();
}

// 块的实参个数可以比目标方法少，但不能多：Tests/test_abi.m 在 arm64 上实测
// imp_implementationWithBlock 交给块的形参是「self、第 1 个实参、第 2 个实参……」，选择子根本不下发。
// 多声明一位就会把脏寄存器当成对象转下去（上一版一启动就闪退的原因），少声明只是够不着后面的参数。
// 这里的站点一个实参都不需要（rootViewController 用不上），所以统一只带 self。
static void ZNAInstallSite(const ZNASuppressSite *site) {
    NSString *key = [NSString stringWithFormat:@"%s %s", site->cls, site->sel];
    Class cls = NSClassFromString(@(site->cls));
    if (!cls) return;  // 类还没注册进来，下一轮补扫再来
    if (ZNASiteSettled(key)) return;
    SEL sel = sel_getUid(site->sel);
    Method own = ZNAOwnMethod(cls, sel, NO);
    Method inherited = own ?: class_getInstanceMethod(cls, sel);
    if (!inherited) {
        ZNALog(@"site absent -[%@ %@]", @(site->cls), @(site->sel));
        return;
    }
    char returnType = 'v';
    const char *encoding = method_getTypeEncoding(inherited);
    if (!ZNAReturnKind(encoding, &returnType) || returnType != 'v') {
        ZNALog(@"site refused return=%s -[%@ %@]", encoding ?: "", @(site->cls), @(site->sel));
        return;
    }
    id block = (id) ^void(id self) {
        ZNASuppressRun(site, site->delegateGetter ? sel_getUid(site->delegateGetter) : NULL, self);
    };
    ZNAKeep(block);
    IMP replacement = imp_implementationWithBlock(block);
    if (own) {
        IMP original = method_getImplementation(own);
        if (original == replacement) return;
        method_setImplementation(own, replacement);
    } else {
        // 实现只在父类上：在叶子类里补一份覆盖，父类和它的其他子类一律不动。
        if (!class_addMethod(cls, sel, replacement, encoding)) {
            ZNALog(@"site refused addMethod -[%@ %@]", @(site->cls), @(site->sel));
            return;
        }
    }
    ZNAHookedCount++;
    ZNALog(@"site-hook -[%@ %@] %s", @(site->cls), @(site->sel), encoding ?: "");
}


#pragma mark - global presentation guard

// App 侧一行广告代码都扫不出来（Zoomable 自己的 20 个类全是纯 Swift，ObjC 运行时看不见它们），
// 广告是 SDK 自己往屏幕上盖的。类名遮挡要等类注册进来才挂得上，冷启动第一弹往往赶不上，
// 所以在 UIViewController 这一层留一道总闸：任何一次模态呈现都过一遍名字。
//
// 这道闸只「藏」不「吞」：原实现照常跑完，SDK 的倒计时、关闭回调、状态机一个不落，我们只是把
// 盖上来的那一层藏掉、再按宽限期请它离场。所以它不需要补任何终态回调，也就没有掐断别人流程的风险。
// 系统类的一个方法，签名固定（3 个实参），一次装好就不用再补扫。
static void ZNAInstallPresentGuard(void) {
    SEL sel = sel_getUid("presentViewController:animated:completion:");
    Method method = class_getInstanceMethod(UIViewController.class, sel);
    if (!method) {
        ZNALog(@"present guard: -[UIViewController presentViewController:] absent");
        return;
    }
    IMP original = method_getImplementation(method);
    id block = (id) ^void(id self, id presented, BOOL animated, void *completion) {
        ((void (*)(id, SEL, id, _Bool, void *))original)(self, sel, presented, animated, completion);
        if (!presented) return;
        NSString *className = NSStringFromClass(object_getClass(presented));
        if (!ZNAIsInterestingClassName(className.UTF8String)) return;
        atomic_fetch_add_explicit(&ZNAActionCount, 1, memory_order_relaxed);
        ZNALog(@"present-guard <%@> from %@", className, NSStringFromClass(object_getClass(self)));
        ZNADefuse(presented);
        // 广告自带窗口（AdMob 的 App Open 走自己的 window）：只在这条 window 的根就是它本人时藏，
        // 否则藏的就是 App 主界面了。
        if (![presented isKindOfClass:UIViewController.class]) return;
        UIWindow *window = [(UIViewController *)presented viewIfLoaded].window;
        if (window && window.rootViewController == (UIViewController *)presented) ZNADefuse(window);
        ZNAFlushLog();
    };
    ZNAKeep(block);
    IMP replacement = imp_implementationWithBlock(block);
    if (replacement && original != replacement) {
        method_setImplementation(method, replacement);
        ZNAHookedCount++;
        ZNALog(@"present-guard installed %s", method_getTypeEncoding(method) ?: "");
    }
}

#pragma mark - entry

static dispatch_queue_t ZNAInstallQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.moxuan.zoomablenoad.install", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static void ZNAInstallExplicitSites(NSString *pass) {
    for (size_t i = 0; i < sizeof(ZNASuppressSites) / sizeof(ZNASuppressSites[0]); i++) {
        ZNAInstallSite(&ZNASuppressSites[i]);
    }
    ZNALog(@"explicit pass %@ done", pass);
    ZNAFlushLog();
}

// 启动窗口：这之前的补扫全部交给下面的定时任务，最后一次落在 40 s。
static const NSTimeInterval ZNAStartupWindow = 45;

__attribute__((constructor)) static void ZoomableNoAdEntry(void) {
    @autoreleasepool {
        ZNALaunchUptime = NSProcessInfo.processInfo.systemUptime;
        ZNALog(@"ZoomableNoAd attached to %@ / %@", NSProcessInfo.processInfo.processName,
               NSBundle.mainBundle.bundleIdentifier);
        // 第一行日志立刻落盘：这一份文件在不在，就是「注入生效了没有」的唯一凭据，
        // 后面所有 pass 都要等广告类注册才有输出，等不起。
        ZNAFlushLog();
        ZNALog(@"log file -> %@", ZNALogWrittenPath);
        ZNAFlushLog();
        // 开关文件：出问题又取不到日志时，建一个空的 ZoomableNoAd.off 再启动就能把这一版整个关掉，
        // 直接分清是 App 自己卡住还是被钩子卡住。两处都认：/var/mobile/Media 要越狱文件管理器，
        // App 容器 Documents 这一份在系统「文件」App 里就能建。
        NSString *containerSwitch = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ZoomableNoAd.off"];
        NSString *sharedSwitch = @"/var/mobile/Media/ZoomableNoAd.off";
        NSString *switchPath = [NSFileManager.defaultManager fileExistsAtPath:containerSwitch]
            ? containerSwitch
            : ([NSFileManager.defaultManager fileExistsAtPath:sharedSwitch] ? sharedSwitch : nil);
        if (switchPath) {
            ZNALog(@"disabled by %@", switchPath);
            ZNAFlushLog();
            return;
        }
        ZNAInstallPresentGuard();
        ZNAInstallAll(@"launch", YES);
        ZNAInstallExplicitSites(@"launch");
        // 主线程每秒扫一遍界面层，把新出现的 App 自有视图记进日志，先认出来才能屏蔽。
        // 扫过启动窗口就收工：这是诊断用的，一直挂在主线程上只会拖慢整个 App。
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            if (NSProcessInfo.processInfo.systemUptime - ZNALaunchUptime > ZNAStartupWindow) {
                [timer invalidate];
                ZNALog(@"overlay probe stopped");
                ZNAFlushLog();
                return;
            }
            ZNAScanOverlays();
        }];
        // 广告视图类大多要等第一次请求广告时才注册，所以要反复补扫；热启动回前台同理。
        for (NSNumber *delay in @[ @0.2, @2, @5, @15, @(ZNAStartupWindow - 5) ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           ZNAInstallQueue(), ^{
                               ZNAInstallAll(@"full", NO);
                           });
        }
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                    object:nil
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification *note) {
                                                                      NSTimeInterval age =
                                                                          NSProcessInfo.processInfo.systemUptime -
                                                                          ZNALaunchUptime;
                                                                      if (age < ZNAStartupWindow) {
                                                                          ZNALog(@"skip active pass at +%0.0fs (startup window)", age);
                                                                          // 这条之后没有 pass 会再刷盘，不主动 flush 就等于没写。
                                                                          ZNAFlushLog();
                                                                          return;
                                                                      }
                                                                      dispatch_async(ZNAInstallQueue(), ^{
                                                                          ZNAInstallAll(@"active", NO);
                                                                      });
                                                                  }];
        ZNAKeep(observer);
    }
}
