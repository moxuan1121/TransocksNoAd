#import "ZNAPattern.h"
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    const char *classes;
    const char *selectors;
    ZNAAction action;
} ZNARule;

// Zoomable（Browser / com.actowise.browser 3.7）只有一家广告 SDK：Google AdMob 11.13.0，
// 而且 Frameworks/GoogleMobileAds.framework 只是个 35 KB 的桩，真身静态链进了主二进制
// （主二进制的类名表里 GAD* 三百多个）。App 自己那层是纯 Swift，一个 @objc 类都没暴露
// （_TtC7Browser* 只有 BrowserViewController、ProUpgradeViewController 这些业务名），
// 挂不上 App 层，只能挂 SDK 层。这套规则要躲开三个坑：
// 1) 不能写 GDT* —— 这库里 GDTCOR*/GDTCCT* 是 Google 自己的上报与崩溃传输，跟优量汇无关；
// 2) 不能写 *Ad*、也不能写宽泛的 *Banner* —— App 里有 AddressBar、DownloadManager 这类业务名，
//    banner 位靠 GADBannerView 命中就够了；
// 3) 不含 UMP*/*Consent*（Google 隐私同意弹窗，是合规流程）和 *Reward*（激励视频是用户主动
//    换权益的，屏蔽掉等于白看广告拿不到奖励）。
#define ZNA_AD_CLASSES \
    "GAD*|GAM*|*AdMob*|*GoogleMobileAds*|*Splash*|*splash*|*Interstitial*|" \
    "*InsertAd*|*NativeAd*|*AdView*|*BannerAd*|*AdBanner*|*AppOpenAd*|*AppOpen*|" \
    "*AdManager*|*ADManager*|*AdLoader*|*AdOffer*|*AdsPlacement*|*AdUnit*"

// 只挂「展示」这一层：原实现照常跑完，SDK 的加载、渲染统计、关闭回调都不被截断，宿主 App 的
// 流程因此不会卡住。显式站点表（ZNAHooks.m 的 suppress）也只吞中途弹出的全屏展示并补上 SDK
// 自己那条失败回调；开屏（GADAppOpenAd）不吞，交给这里的遮挡兜底。
#define ZNA_PRESENT_SEL \
    "viewDidAppear:|viewWillAppear:|viewDidLayoutSubviews|didMoveToWindow|" \
    "willMoveToWindow:|layoutSubviews|makeKeyAndVisible|show*|present*|render*"

static const ZNARule ZNARules[] = {
    { ZNA_AD_CLASSES, ZNA_PRESENT_SEL, ZNAActionDefuse },
};

static const char *ZNAForbiddenSelectors[] = {
    "load", "initialize", "dealloc", ".cxx_destruct", "forwardInvocation:", "class",
    "methodSignatureForSelector:", "respondsToSelector:", "isKindOfClass:", "release", "retain",
    "copy", "copyWithZone:", "init", "new", "viewDidLoad", "encodeWithCoder:", "initWithCoder:", "description",
};

static const char *ZNASplashMarkers[] = { "Splash", "splash", "SPLASH", "LaunchAd", "launchad", "AppOpen" };

// 冷启动主线程那道筛只看这些片段：AdMob 的开屏宿主是 GADAppOpenAd 和它内部那批 *AppOpen*/*Splash*
// 渲染类。App 自己的启动页是 storyboard 里的普通控制器，名字不带广告字样，本来就不在这套规则里。
static const char *ZNALaunchMarkers[] = { "Splash", "splash", "SPLASH", "LaunchAd", "launchad", "AppOpen" };

#pragma mark - compiled matcher

// 通用通配匹配在两千多个类名上也要几十毫秒，冷启动那道主线程筛必须先过一遍位图预筛。
typedef enum {
    ZNATokPrefix = 0,
    ZNATokSuffix,
    ZNATokContains,
    ZNATokExact,
    ZNATokLoose,
} ZNATokKind;

typedef struct {
    char *text;
    size_t length;
    unsigned char kind;
    char head;
} ZNAToken;

typedef struct {
    ZNAToken *tokens;
    size_t count;
    size_t capacity;
    unsigned char startHeads[16];  // 前缀/全等类片段要求的首字母
    unsigned char anyHeads[16];    // 后缀/包含类片段要求的字母
    unsigned char loose;           // 存在无法预筛的片段时置 1
} ZNATokenSet;

static void ZNABitSet(unsigned char *bits, char c) {
    if ((unsigned char)c < 128) bits[(unsigned char)c >> 3] |= (unsigned char)(1u << ((unsigned char)c & 7));
}

static BOOL ZNABitGet(const unsigned char *bits, char c) {
    return (unsigned char)c < 128 && (bits[(unsigned char)c >> 3] & (1u << ((unsigned char)c & 7))) != 0;
}

static BOOL ZNAAnyBit(const unsigned char *a, const unsigned char *b) {
    for (size_t i = 0; i < 16; i++) {
        if (a[i] & b[i]) return YES;
    }
    return NO;
}

static BOOL ZNAAllBits(const unsigned char *need, const unsigned char *have) {
    for (size_t i = 0; i < 16; i++) {
        if ((need[i] & have[i]) != need[i]) return NO;
    }
    return YES;
}

// 名字里出现过哪些 ASCII 字符。整套规则都靠它做一次性排除，所以每个名字只扫这一遍。
static void ZNANameLetters(const char *name, unsigned char *present) {
    memset(present, 0, 16);
    for (const char *c = name; *c; c++) ZNABitSet(present, *c);
}

static char *ZNACopy(const char *start, size_t length) {
    char *copy = malloc(length + 1);
    if (!copy) return NULL;
    memcpy(copy, start, length);
    copy[length] = '\0';
    return copy;
}

static void ZNATokenSetAdd(ZNATokenSet *set, const char *segment, size_t length) {
    if (set->count == set->capacity) {
        size_t capacity = set->capacity ? set->capacity * 2 : 32;
        ZNAToken *tokens = realloc(set->tokens, capacity * sizeof(ZNAToken));
        if (!tokens) return;
        set->tokens = tokens;
        set->capacity = capacity;
    }
    size_t begin = 0, end = length;
    BOOL lead = NO, trail = NO, inner = NO;
    if (end > begin && segment[begin] == '*') { lead = YES; begin++; }
    if (end > begin && segment[end - 1] == '*') { trail = YES; end--; }
    for (size_t i = begin; i < end; i++) {
        if (segment[i] == '*' || segment[i] == '?') inner = YES;
    }
    if (begin == end) inner = YES;

    ZNAToken *token = &set->tokens[set->count];
    token->head = 0;
    if (inner) {
        token->kind = ZNATokLoose;
        token->length = length;
        token->text = ZNACopy(segment, length);
        if (!token->text) return;
        set->loose = 1;
    } else {
        token->kind = lead ? (trail ? ZNATokContains : ZNATokSuffix) : (trail ? ZNATokPrefix : ZNATokExact);
        token->length = end - begin;
        token->text = ZNACopy(segment + begin, token->length);
        if (!token->text) return;
        token->head = token->text[0];
        ZNABitSet(token->kind == ZNATokPrefix || token->kind == ZNATokExact ? set->startHeads : set->anyHeads,
                  token->head);
    }
    set->count++;
}

static void ZNATokenSetCompile(ZNATokenSet *set, const char *alternatives) {
    memset(set, 0, sizeof(*set));
    for (const char *p = alternatives; p && *p;) {
        const char *bar = strchr(p, '|');
        size_t length = bar ? (size_t)(bar - p) : strlen(p);
        if (length) ZNATokenSetAdd(set, p, length);
        if (!bar) break;
        p = bar + 1;
    }
}

typedef struct {
    ZNATokenSet classes;
    ZNATokenSet selectors;
    ZNAAction action;
} ZNACompiledRule;

#define ZNALaunchMarkerCount (sizeof(ZNALaunchMarkers) / sizeof(ZNALaunchMarkers[0]))
static unsigned char ZNALaunchMarkerLetters[ZNALaunchMarkerCount][16];

#define ZNARuleCount (sizeof(ZNARules) / sizeof(ZNARules[0]))
static ZNACompiledRule ZNACompiled[ZNARuleCount];
static pthread_once_t ZNACompileFlag = PTHREAD_ONCE_INIT;

static void ZNACompileRules(void) {
    for (size_t i = 0; i < ZNARuleCount; i++) {
        ZNATokenSetCompile(&ZNACompiled[i].classes, ZNARules[i].classes);
        ZNATokenSetCompile(&ZNACompiled[i].selectors, ZNARules[i].selectors);
        ZNACompiled[i].action = ZNARules[i].action;
    }
    for (size_t i = 0; i < ZNALaunchMarkerCount; i++) {
        for (const char *c = ZNALaunchMarkers[i]; *c; c++) ZNABitSet(ZNALaunchMarkerLetters[i], *c);
    }
}

static void ZNAEnsureCompiled(void) {
    pthread_once(&ZNACompileFlag, ZNACompileRules);
}

// 激励视频和隐私同意弹窗不参与兜底屏蔽：前者是用户主动换权益，后者是 SDK 合规流程。
// Zoomable 里这两种都真的存在（GADRewardedAd / GADRewardedInterstitialAd，以及 UMP* 同意门），
// 所以这道排除是必需的而不是摆设：GAD* 那条规则会把它们一并命中，靠名字才摘得干净。
static BOOL ZNANameExcluded(const char *name) {
    static const char *markers[] = { "Reward", "reward", "REWARD", "Consent", "consent", "UMPAppTransparency" };
    for (size_t i = 0; i < sizeof(markers) / sizeof(markers[0]); i++) {
        if (strstr(name, markers[i])) return YES;
    }
    return NO;
}

static BOOL ZNAMatchTokenSetMasked(const char *name, const ZNATokenSet *set, const unsigned char *present) {
    if (!set->loose && !ZNABitGet(set->startHeads, name[0]) && !ZNAAnyBit(set->anyHeads, present)) return NO;
    if (!set->tokens) return NO;
    size_t nameLength = 0;
    for (const ZNAToken *token = set->tokens, *end = token + set->count; token < end; token++) {
        switch (token->kind) {
            case ZNATokLoose:
                if (ZNAMatchGlob(name, token->text)) return YES;
                break;
            case ZNATokPrefix:
                if (name[0] == token->head && strncmp(name, token->text, token->length) == 0) return YES;
                break;
            case ZNATokExact:
                if (name[0] == token->head && strlen(name) == token->length &&
                    memcmp(name, token->text, token->length) == 0) return YES;
                break;
            case ZNATokSuffix:
                if (!ZNABitGet(present, token->head)) break;
                if (nameLength == 0) nameLength = strlen(name);
                if (nameLength >= token->length &&
                    memcmp(name + nameLength - token->length, token->text, token->length) == 0) return YES;
                break;
            default:
                if (!ZNABitGet(present, token->head)) break;
                if (strstr(name, token->text)) return YES;
                break;
        }
    }
    return NO;
}

static BOOL ZNAMatchTokenSet(const char *name, const ZNATokenSet *set) {
    unsigned char present[16];
    ZNANameLetters(name, present);
    return ZNAMatchTokenSetMasked(name, set, present);
}

static BOOL ZNASelectorForbidden(const char *selector) {
    for (size_t i = 0; i < sizeof(ZNAForbiddenSelectors) / sizeof(ZNAForbiddenSelectors[0]); i++) {
        if (strcmp(selector, ZNAForbiddenSelectors[i]) == 0) return YES;
    }
    return NO;
}

BOOL ZNAIsInterestingClassName(const char *name) {
    if (!name || ZNANameExcluded(name)) return NO;
    ZNAEnsureCompiled();
    for (size_t i = 0; i < ZNARuleCount; i++) {
        if (ZNAMatchTokenSet(name, &ZNACompiled[i].classes)) return YES;
    }
    return NO;
}

BOOL ZNAIsInterestingClassNameSlow(const char *name) {
    if (!name || ZNANameExcluded(name)) return NO;
    for (size_t i = 0; i < ZNARuleCount; i++) {
        if (ZNAMatchGlob(name, ZNARules[i].classes)) return YES;
    }
    return NO;
}

BOOL ZNAIsPresentationSelector(const char *selector) {
    if (!selector || ZNASelectorForbidden(selector)) return NO;
    ZNAEnsureCompiled();
    for (size_t i = 0; i < ZNARuleCount; i++) {
        if (ZNAMatchTokenSet(selector, &ZNACompiled[i].selectors)) return YES;
    }
    return NO;
}

BOOL ZNAIsPresentationSelectorSlow(const char *selector) {
    if (!selector || ZNASelectorForbidden(selector)) return NO;
    for (size_t i = 0; i < ZNARuleCount; i++) {
        if (ZNAMatchGlob(selector, ZNARules[i].selectors)) return YES;
    }
    return NO;
}

static BOOL ZNAIsLaunchMarkerAt(const char *name, const unsigned char *present) {
    for (size_t i = 0; i < ZNALaunchMarkerCount; i++) {
        if (ZNAAllBits(ZNALaunchMarkerLetters[i], present) && strstr(name, ZNALaunchMarkers[i])) return YES;
    }
    return NO;
}

// 冷启动主线程那道筛：命中规则表、而且名字像开屏宿主。两件事共用一次字符扫描。
BOOL ZNAIsLaunchClassName(const char *name) {
    if (!name || !name[0] || ZNANameExcluded(name)) return NO;
    ZNAEnsureCompiled();
    unsigned char present[16];
    ZNANameLetters(name, present);
    for (size_t i = 0; i < ZNARuleCount; i++) {
        if (!ZNAMatchTokenSetMasked(name, &ZNACompiled[i].classes, present)) continue;
        if (ZNAIsLaunchMarkerAt(name, present)) return YES;
    }
    return NO;
}

ZNAAction ZNAActionForClass(const char *className, const char *selector) {
    if (!className || !selector || ZNASelectorForbidden(selector)) return ZNAActionNone;
    if (ZNANameExcluded(className)) return ZNAActionNone;
    ZNAEnsureCompiled();
    for (size_t i = 0; i < ZNARuleCount; i++) {
        if (ZNAMatchTokenSet(className, &ZNACompiled[i].classes) &&
            ZNAMatchTokenSet(selector, &ZNACompiled[i].selectors)) return ZNACompiled[i].action;
    }
    return ZNAActionNone;
}

BOOL ZNAIsSplashLikeName(const char *name) {
    if (!name) return NO;
    for (size_t i = 0; i < sizeof(ZNASplashMarkers) / sizeof(ZNASplashMarkers[0]); i++) {
        if (strstr(name, ZNASplashMarkers[i])) return YES;
    }
    return NO;
}
