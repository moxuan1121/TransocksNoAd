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

static void ZNAFlushLog(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ZoomableNoAd.log"];
    NSArray<NSString *> *snapshot;
    @synchronized(ZNAJournal()) {
        snapshot = [ZNAJournal() copy];
    }
    NSString *text = [snapshot componentsJoinedByString:@"\n"];
    (void)[text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    // 沙盒里的日志取不出来就等于没有：这份同时写到 /var/mobile/Media，Filza 或爱思直接能拿到。
    for (NSString *shared in @[ @"/var/mobile/Media/ZoomableNoAd.log",
                                @"/var/mobile/Media/Documents/ZoomableNoAd.log" ]) {
        (void)[text writeToFile:shared atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
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
// present 按叶子类逐个列，不走父类：GoogleMobileAds 11.x 里 presentFromRootViewController: 只实现
// 在共享基类 GADFullScreenAd 上，插屏、开屏、激励三份共用同一个 IMP。改基类等于把用户主动看的
// 激励视频一起吞掉（奖励拿不到），所以在这里点名要压的那两个，安装时在本类补一份覆盖实现。
//
// 开屏（GADAppOpenAd）故意不进来：它就挂在冷启动/回前台那条链上，把 present 挂空 App 等不到
// adDidDismissFullScreenContent:，启动流程走不完 —— 穿梭 0.0.1「闪退保住了却卡在开屏」就是这个坑。
// 开屏改由不牵扯回调的类名遮挡处理：GADFullScreenAdViewController 和 GAD* 渲染层照常跑完自己的
// 加载、倒计时、关闭流程，只由 ZNADefuse 把盖上来的窗口和视图藏掉，再由它对 presenter 的关闭观察
// 把「已经关掉」这条通知补回给 App。
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
        // 开关文件：真机上出问题又取不到日志时，建一个空的 /var/mobile/Media/ZoomableNoAd.off
        // 再启动，就能把这一版整个关掉，直接分清是 App 自己卡住还是被钩子卡住。
        if ([NSFileManager.defaultManager fileExistsAtPath:@"/var/mobile/Media/ZoomableNoAd.off"]) {
            ZNALog(@"disabled by /var/mobile/Media/ZoomableNoAd.off");
            ZNAFlushLog();
            return;
        }
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
