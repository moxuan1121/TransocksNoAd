#import "TNAPattern.h"
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    const char *classes;
    const char *selectors;
    TNAAction action;
} TNARule;

// 穿梭（Transocks-iOS / com.fobwifi.fobwifi 3.4.0）的广告栈全在主二进制里静态链接：
// AT* 是 TopOn/AnyThink 聚合（689 个类），GDT* 是优量汇（533 个），GAD*/GAM* 是 Google AdMob（356 个）。
// App 自己那层是 Swift，只有实现了 SDK 协议的方法才进 ObjC 运行时：
// _TtC13Transocks_iOS10AdsManager（GDT 开屏+插屏宿主）、_TtC13Transocks_iOS12CustomBootAd（自绘开屏图）、
// _TtCO13Transocks_iOS7ToponAd*（TopOn 开屏/插屏回调转发）、*_GAD*AdAdapter（AdMob 原生/插屏/开屏）。
// 刻意不写 *Ad* / AD*：App 里有 AccountBannerView、RuleAddPopController 这类业务名，大小写敏感的
// 'Add' 一样会被 *Ad* 命中。也刻意不含 UMP*（Google 隐私同意弹窗）和 *Reward*（激励视频是用户主动看的，
// 屏蔽掉等于白看广告拿不到奖励）。
#define TNA_AD_CLASSES                                                             \
    "AT*|GDT*|GAD*|GAM*|*Splash*|*splash*|*Interstitial*|*InsertAd*|*NativeAd*|"   \
    "*NativeAD*|*AdView*|*ADView*|*BannerAd*|*AdBanner*|*AppOpenAd*|*AdManager*|"   \
    "*ADManager*|*AdLoader*|*AdOffer*|*AdsManager*|*AdsPlacement*|*AdUnit*|"       \
    "*BootAd*|*ToponAd*|*ToponManager*|*GAD*Adapter*|*AnyThink*"

// 只挂「展示」这一层：原实现照常跑完，SDK 的加载、倒计时、关闭回调都不被截断，
// 宿主 App 的开屏流程因此不会卡住。显式站点表（TNAHooks.m 的 gate/suppress）也一律不碰加载/请求，
// 只吞中途弹出的插屏展示并补上 SDK 自己的终态回调；开屏靠问询回 NO、取广告回 nil 加这里的遮挡。
#define TNA_PRESENT_SEL                                                            \
    "viewDidAppear:|viewWillAppear:|viewDidLayoutSubviews|didMoveToWindow|"        \
    "willMoveToWindow:|layoutSubviews|makeKeyAndVisible|show*|present*|render*"

static const TNARule TNARules[] = {
    { TNA_AD_CLASSES, TNA_PRESENT_SEL, TNAActionDefuse },
};

static const char *TNAForbiddenSelectors[] = {
    "load", "initialize", "dealloc", ".cxx_destruct", "forwardInvocation:", "class",
    "methodSignatureForSelector:", "respondsToSelector:", "isKindOfClass:", "release", "retain",
    "copy", "copyWithZone:", "init", "new", "viewDidLoad", "encodeWithCoder:", "initWithCoder:", "description",
};

static const char *TNASplashMarkers[] = { "Splash", "splash", "SPLASH", "BootAd", "LaunchAd", "launchad", "AppOpenAd" };

// 冷启动主线程那道筛只看这些片段：TopOn 的开屏宿主是 ATTSplash*/ATOfferSplash*/ATNativeSplash*，
// AdMob 的是 GADAppOpenAd，App 自己的是 CustomBootAd 和 AdsManager（GDT 开屏+插屏的宿主控制器）。
static const char *TNALaunchMarkers[] = { "Splash", "splash", "SPLASH", "BootAd", "LaunchAd", "launchad",
                                          "AppOpenAd", "AdsManager" };

#pragma mark - compiled matcher

// 通用通配匹配在两千多个类名上也要几十毫秒，冷启动那道主线程筛必须先过一遍位图预筛。
typedef enum {
    TNATokPrefix = 0,
    TNATokSuffix,
    TNATokContains,
    TNATokExact,
    TNATokLoose,
} TNATokKind;

typedef struct {
    char *text;
    size_t length;
    unsigned char kind;
    char head;
} TNAToken;

typedef struct {
    TNAToken *tokens;
    size_t count;
    size_t capacity;
    unsigned char startHeads[16];  // 前缀/全等类片段要求的首字母
    unsigned char anyHeads[16];    // 后缀/包含类片段要求的字母
    unsigned char loose;           // 存在无法预筛的片段时置 1
} TNATokenSet;

static void TNABitSet(unsigned char *bits, char c) {
    if ((unsigned char)c < 128) bits[(unsigned char)c >> 3] |= (unsigned char)(1u << ((unsigned char)c & 7));
}

static BOOL TNABitGet(const unsigned char *bits, char c) {
    return (unsigned char)c < 128 && (bits[(unsigned char)c >> 3] & (1u << ((unsigned char)c & 7))) != 0;
}

static BOOL TNAAnyBit(const unsigned char *a, const unsigned char *b) {
    for (size_t i = 0; i < 16; i++) {
        if (a[i] & b[i]) return YES;
    }
    return NO;
}

static BOOL TNAAllBits(const unsigned char *need, const unsigned char *have) {
    for (size_t i = 0; i < 16; i++) {
        if ((need[i] & have[i]) != need[i]) return NO;
    }
    return YES;
}

// 名字里出现过哪些 ASCII 字符。整套规则都靠它做一次性排除，所以每个名字只扫这一遍。
static void TNANameLetters(const char *name, unsigned char *present) {
    memset(present, 0, 16);
    for (const char *c = name; *c; c++) TNABitSet(present, *c);
}

static char *TNACopy(const char *start, size_t length) {
    char *copy = malloc(length + 1);
    if (!copy) return NULL;
    memcpy(copy, start, length);
    copy[length] = '\0';
    return copy;
}

static void TNATokenSetAdd(TNATokenSet *set, const char *segment, size_t length) {
    if (set->count == set->capacity) {
        size_t capacity = set->capacity ? set->capacity * 2 : 32;
        TNAToken *tokens = realloc(set->tokens, capacity * sizeof(TNAToken));
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

    TNAToken *token = &set->tokens[set->count];
    token->head = 0;
    if (inner) {
        token->kind = TNATokLoose;
        token->length = length;
        token->text = TNACopy(segment, length);
        if (!token->text) return;
        set->loose = 1;
    } else {
        token->kind = lead ? (trail ? TNATokContains : TNATokSuffix) : (trail ? TNATokPrefix : TNATokExact);
        token->length = end - begin;
        token->text = TNACopy(segment + begin, token->length);
        if (!token->text) return;
        token->head = token->text[0];
        TNABitSet(token->kind == TNATokPrefix || token->kind == TNATokExact ? set->startHeads : set->anyHeads,
                  token->head);
    }
    set->count++;
}

static void TNATokenSetCompile(TNATokenSet *set, const char *alternatives) {
    memset(set, 0, sizeof(*set));
    for (const char *p = alternatives; p && *p;) {
        const char *bar = strchr(p, '|');
        size_t length = bar ? (size_t)(bar - p) : strlen(p);
        if (length) TNATokenSetAdd(set, p, length);
        if (!bar) break;
        p = bar + 1;
    }
}

typedef struct {
    TNATokenSet classes;
    TNATokenSet selectors;
    TNAAction action;
} TNACompiledRule;

#define TNALaunchMarkerCount (sizeof(TNALaunchMarkers) / sizeof(TNALaunchMarkers[0]))
static unsigned char TNALaunchMarkerLetters[TNALaunchMarkerCount][16];

#define TNARuleCount (sizeof(TNARules) / sizeof(TNARules[0]))
static TNACompiledRule TNACompiled[TNARuleCount];
static pthread_once_t TNACompileFlag = PTHREAD_ONCE_INIT;

static void TNACompileRules(void) {
    for (size_t i = 0; i < TNARuleCount; i++) {
        TNATokenSetCompile(&TNACompiled[i].classes, TNARules[i].classes);
        TNATokenSetCompile(&TNACompiled[i].selectors, TNARules[i].selectors);
        TNACompiled[i].action = TNARules[i].action;
    }
    for (size_t i = 0; i < TNALaunchMarkerCount; i++) {
        for (const char *c = TNALaunchMarkers[i]; *c; c++) TNABitSet(TNALaunchMarkerLetters[i], *c);
    }
}

static void TNAEnsureCompiled(void) {
    pthread_once(&TNACompileFlag, TNACompileRules);
}

// 激励视频和隐私同意弹窗不参与兜底屏蔽：前者是用户主动换权益，后者是 SDK 合规流程。
// SDK 自己的类名里 Reward/Rewarded 都成对出现，App 侧没有任何激励入口（3.4.0 静态可确认），
// 但规则要能跟着版本走，所以这里做名字级排除而不是「反正用不到」。
static BOOL TNANameExcluded(const char *name) {
    static const char *markers[] = { "Reward", "reward", "REWARD", "Consent", "consent", "UMPAppTransparency" };
    for (size_t i = 0; i < sizeof(markers) / sizeof(markers[0]); i++) {
        if (strstr(name, markers[i])) return YES;
    }
    return NO;
}

static BOOL TNAMatchTokenSetMasked(const char *name, const TNATokenSet *set, const unsigned char *present) {
    if (!set->loose && !TNABitGet(set->startHeads, name[0]) && !TNAAnyBit(set->anyHeads, present)) return NO;
    if (!set->tokens) return NO;
    size_t nameLength = 0;
    for (const TNAToken *token = set->tokens, *end = token + set->count; token < end; token++) {
        switch (token->kind) {
            case TNATokLoose:
                if (TNAMatchGlob(name, token->text)) return YES;
                break;
            case TNATokPrefix:
                if (name[0] == token->head && strncmp(name, token->text, token->length) == 0) return YES;
                break;
            case TNATokExact:
                if (name[0] == token->head && strlen(name) == token->length &&
                    memcmp(name, token->text, token->length) == 0) return YES;
                break;
            case TNATokSuffix:
                if (!TNABitGet(present, token->head)) break;
                if (nameLength == 0) nameLength = strlen(name);
                if (nameLength >= token->length &&
                    memcmp(name + nameLength - token->length, token->text, token->length) == 0) return YES;
                break;
            default:
                if (!TNABitGet(present, token->head)) break;
                if (strstr(name, token->text)) return YES;
                break;
        }
    }
    return NO;
}

static BOOL TNAMatchTokenSet(const char *name, const TNATokenSet *set) {
    unsigned char present[16];
    TNANameLetters(name, present);
    return TNAMatchTokenSetMasked(name, set, present);
}

static BOOL TNASelectorForbidden(const char *selector) {
    for (size_t i = 0; i < sizeof(TNAForbiddenSelectors) / sizeof(TNAForbiddenSelectors[0]); i++) {
        if (strcmp(selector, TNAForbiddenSelectors[i]) == 0) return YES;
    }
    return NO;
}

BOOL TNAIsInterestingClassName(const char *name) {
    if (!name || TNANameExcluded(name)) return NO;
    TNAEnsureCompiled();
    for (size_t i = 0; i < TNARuleCount; i++) {
        if (TNAMatchTokenSet(name, &TNACompiled[i].classes)) return YES;
    }
    return NO;
}

BOOL TNAIsInterestingClassNameSlow(const char *name) {
    if (!name || TNANameExcluded(name)) return NO;
    for (size_t i = 0; i < TNARuleCount; i++) {
        if (TNAMatchGlob(name, TNARules[i].classes)) return YES;
    }
    return NO;
}

BOOL TNAIsPresentationSelector(const char *selector) {
    if (!selector || TNASelectorForbidden(selector)) return NO;
    TNAEnsureCompiled();
    for (size_t i = 0; i < TNARuleCount; i++) {
        if (TNAMatchTokenSet(selector, &TNACompiled[i].selectors)) return YES;
    }
    return NO;
}

BOOL TNAIsPresentationSelectorSlow(const char *selector) {
    if (!selector || TNASelectorForbidden(selector)) return NO;
    for (size_t i = 0; i < TNARuleCount; i++) {
        if (TNAMatchGlob(selector, TNARules[i].selectors)) return YES;
    }
    return NO;
}

static BOOL TNAIsLaunchMarkerAt(const char *name, const unsigned char *present) {
    for (size_t i = 0; i < TNALaunchMarkerCount; i++) {
        if (TNAAllBits(TNALaunchMarkerLetters[i], present) && strstr(name, TNALaunchMarkers[i])) return YES;
    }
    return NO;
}

// 冷启动主线程那道筛：命中规则表、而且名字像开屏宿主。两件事共用一次字符扫描。
BOOL TNAIsLaunchClassName(const char *name) {
    if (!name || !name[0] || TNANameExcluded(name)) return NO;
    TNAEnsureCompiled();
    unsigned char present[16];
    TNANameLetters(name, present);
    for (size_t i = 0; i < TNARuleCount; i++) {
        if (!TNAMatchTokenSetMasked(name, &TNACompiled[i].classes, present)) continue;
        if (TNAIsLaunchMarkerAt(name, present)) return YES;
    }
    return NO;
}

TNAAction TNAActionForClass(const char *className, const char *selector) {
    if (!className || !selector || TNASelectorForbidden(selector)) return TNAActionNone;
    if (TNANameExcluded(className)) return TNAActionNone;
    TNAEnsureCompiled();
    for (size_t i = 0; i < TNARuleCount; i++) {
        if (TNAMatchTokenSet(className, &TNACompiled[i].classes) &&
            TNAMatchTokenSet(selector, &TNACompiled[i].selectors)) return TNACompiled[i].action;
    }
    return TNAActionNone;
}

BOOL TNAIsSplashLikeName(const char *name) {
    if (!name) return NO;
    for (size_t i = 0; i < sizeof(TNASplashMarkers) / sizeof(TNASplashMarkers[0]); i++) {
        if (strstr(name, TNASplashMarkers[i])) return YES;
    }
    return NO;
}
