#import <Foundation/Foundation.h>
#import "ZNAPattern.h"
#import <stdio.h>

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

// 展示层选择器：这些才允许被兜底挂钩。
static const char *const presentSelectors[] = {
    "viewDidAppear:", "viewWillAppear:", "viewDidLayoutSubviews", "didMoveToWindow", "willMoveToWindow:",
    "layoutSubviews", "makeKeyAndVisible", "show", "showAdInView", "presentAd", "renderAd",
};

// 兜底层永远不碰加载/请求：v0.0.1 的教训是把这一层挂成空实现，宿主 App 等不到 SDK 回调、卡在开屏页。
static const char *const loadSelectors[] = {
    "loadWithAdUnitID:request:completionHandler:", "loadRequest:", "loadAd", "fetchAd", "getAdData",
    "start", "startWithConfiguration:", "registerView", "setDelegate:", "addDelegate:",
};

// AdMob 的门面类与渲染层：这些必须进候选表。
static const char *const sdkClasses[] = {
    "GADMobileAds", "GADRequest", "GADInterstitialAd", "GADAppOpenAd", "GADAdLoader", "GADBannerView",
    "GADNativeAdView", "GADCustomNativeAd", "GADFullScreenAd", "GADFullScreenAdViewController",
    "GAMInterstitialAd", "GAMBannerView", "GADMediationInterstitialAdRenderer", "GADAdChoicesView",
};

// App 自己那层（Zoomable 全是纯 Swift，只有这些业务名进了 ObjC 运行时）。
// 一个都不该被规则命中：命中了就是拿业务界面当广告藏。
static const char *const appClasses[] = {
    "_TtC7Browser10AddressBar", "_TtC7Browser11AppDelegate", "_TtC7Browser11TabGridView",
    "_TtC7Browser15DownloadManager", "_TtC7Browser21BrowserViewController",
    "_TtC7Browser21ProUpgradeViewController", "_TtC7Browser22ProPurchaseController",
    "_TtC7Browser22WebPopupViewController", "_TtC7Browser9ZMWebView",
};

// 名字里带 Ad/GDT 但不是广告的第三方类：规则一放宽就会被误伤。
static const char *const ignoredClasses[] = {
    // RevenueCat 的「广告事件上报」，跟展示无关。
    "_TtC10RevenueCat12AdEventStore", "_TtC10RevenueCat21PostAdEventsOperation",
    "_TtC10RevenueCat19PaywallCacheWarming", "ProUpgradeViewController", "AccountBannerView",
    "AddressBookViewController", "DownloadViewController", "AdHocSignature", "FIRCLSReportAdapter",
    // GDTCOR*/GDTCCT* 是 Google 自己的传输层，不是优量汇：这条是这套规则最容易踩的坑。
    "GDTCORApplication", "GDTCOREvent", "GDTCCTUploader", "GDTMetricsSupport",
    "_TtC16FirebaseSessions14EventGDTLogger",
};

// 激励视频（用户主动换权益）与隐私同意弹窗（合规流程）：一律不参与。
static const char *const outOfScopeClasses[] = {
    "GADRewardedAd", "GADRewardedInterstitialAd", "GADMediationRewardedAdRenderer", "GADAdReward",
    "UMPConsentForm", "UMPConsentInformation", "UMPConsentViewController", "UMPAppTransparencyStub",
    "UMPView",
};

static BOOL AnyPresentHit(const char *className) {
    for (size_t i = 0; i < sizeof(presentSelectors) / sizeof(presentSelectors[0]); i++) {
        if (ZNAActionForClass(className, presentSelectors[i]) != ZNAActionNone) return YES;
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        CHECK(ZNAMatchGlob("GADAppOpenAd", "GAD*|*AppOpen*"));
        CHECK(ZNAMatchGlob("GADInterstitialAd", "*Interstitial*"));
        CHECK(!ZNAMatchGlob("RuleAddPopController", "*Ad|*AD|AD*"));
        CHECK(!ZNAMatchGlob("AddressBookViewController", "*AdView*|*AdBanner*"));
        CHECK(!ZNAMatchGlob("AddressBar", "*AdView*|*BannerAd*|*AdBanner*"));
        CHECK(!ZNAMatchGlob("oad", "*AD"));
        CHECK(!ZNAMatchGlob("GDTCORApplication", "GAD*|GAM*|*AdView*|*AdUnit*"));

        for (size_t i = 0; i < sizeof(sdkClasses) / sizeof(sdkClasses[0]); i++) {
            CHECK(ZNAIsInterestingClassName(sdkClasses[i]));
        }

        // 业务类：既不能进候选表，也不能被挂任何展示层钩子。
        for (size_t i = 0; i < sizeof(appClasses) / sizeof(appClasses[0]); i++) {
            CHECK(!ZNAIsInterestingClassName(appClasses[i]));
            for (size_t s = 0; s < sizeof(presentSelectors) / sizeof(presentSelectors[0]); s++) {
                CHECK(ZNAActionForClass(appClasses[i], presentSelectors[s]) == ZNAActionNone);
            }
        }
        for (size_t i = 0; i < sizeof(ignoredClasses) / sizeof(ignoredClasses[0]); i++) {
            CHECK(!ZNAIsInterestingClassName(ignoredClasses[i]));
            for (size_t s = 0; s < sizeof(presentSelectors) / sizeof(presentSelectors[0]); s++) {
                CHECK(ZNAActionForClass(ignoredClasses[i], presentSelectors[s]) == ZNAActionNone);
            }
        }
        for (size_t i = 0; i < sizeof(outOfScopeClasses) / sizeof(outOfScopeClasses[0]); i++) {
            CHECK(!ZNAIsInterestingClassName(outOfScopeClasses[i]));
            CHECK(!ZNAIsLaunchClassName(outOfScopeClasses[i]));
            CHECK(ZNAActionForClass(outOfScopeClasses[i], "presentFromRootViewController:") == ZNAActionNone);
        }

        for (size_t i = 0; i < sizeof(loadSelectors) / sizeof(loadSelectors[0]); i++) {
            CHECK(ZNAActionForClass("GADAdLoader", loadSelectors[i]) == ZNAActionNone);
            CHECK(ZNAActionForClass("GADInterstitialAd", loadSelectors[i]) == ZNAActionNone);
            CHECK(ZNAActionForClass("GADMobileAds", loadSelectors[i]) == ZNAActionNone);
        }

        CHECK(ZNAActionForClass("GADInterstitialAd", "presentFromRootViewController:") == ZNAActionDefuse);
        CHECK(ZNAActionForClass("GADBannerView", "layoutSubviews") == ZNAActionDefuse);
        CHECK(ZNAActionForClass("GADNativeAdView", "didMoveToWindow") == ZNAActionDefuse);
        CHECK(ZNAActionForClass("GADFullScreenAdViewController", "viewDidAppear:") == ZNAActionDefuse);
        CHECK(ZNAActionForClass("GADAppOpenAd", "viewWillAppear:") == ZNAActionDefuse);
        CHECK(ZNAActionForClass("GADBannerView", "dealloc") == ZNAActionNone);
        CHECK(ZNAActionForClass("GADBannerView", "viewDidLoad") == ZNAActionNone);
        CHECK(ZNAActionForClass("GADBannerView", "class") == ZNAActionNone);

        CHECK(ZNAIsSplashLikeName("GADAppOpenAd"));
        CHECK(ZNAIsSplashLikeName("GADMediationAppOpenAdRenderer"));
        CHECK(!ZNAIsSplashLikeName("GADInterstitialAd"));
        CHECK(!ZNAIsSplashLikeName("GADBannerView"));

        // 广告 SDK 的类名一律以 GAD/GAM 打头，App 层不暴露名字 —— 兜底表要覆盖的就是这一批。
        for (size_t i = 0; i < sizeof(sdkClasses) / sizeof(sdkClasses[0]); i++) {
            if (!ZNAIsInterestingClassName(sdkClasses[i]) && !AnyPresentHit(sdkClasses[i])) {
                failures++;
                printf("FAIL sdk class not covered: %s\n", sdkClasses[i]);
            }
        }

        // 选择器：快速匹配必须和通用通配匹配一字不差（禁用名单两边都有）。
        const char *const selectorCorpus[] = {
            "viewDidAppear:", "viewWillAppear:", "viewDidLayoutSubviews", "didMoveToWindow", "willMoveToWindow:",
            "layoutSubviews", "makeKeyAndVisible", "show", "showAd", "showInView:", "presentAd", "renderAd",
            "presentFromRootViewController:", "loadWithAdUnitID:request:completionHandler:", "loadRequest:",
            "startWithConfiguration:", "dealloc", "init", "class", "respondsToSelector:", "viewDidLoad",
            "description", "hidden", "setHidden:", "shareInstance", "isKindOfClass:",
        };
        for (size_t i = 0; i < sizeof(selectorCorpus) / sizeof(selectorCorpus[0]); i++) {
            CHECK(ZNAIsPresentationSelector(selectorCorpus[i]) == ZNAIsPresentationSelectorSlow(selectorCorpus[i]));
        }

        // 类名：拿真机二进制的类名表回归，快速路径和逐条通配匹配不能有半个字的分歧。
        NSString *corpusPath = NSProcessInfo.processInfo.arguments.count > 1
                                   ? NSProcessInfo.processInfo.arguments[1]
                                   : @"Tests/corpus_classes.txt";
        NSString *corpus = [NSString stringWithContentsOfFile:corpusPath encoding:NSUTF8StringEncoding error:NULL];
        if (!corpus) {
            printf("SKIP corpus %s (fast matcher not regression-checked)\n", corpusPath.UTF8String);
        } else {
            NSArray<NSString *> *names = [corpus componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
            NSUInteger interesting = 0, launch = 0, divergence = 0, missedSplash = 0, appOwned = 0;
            for (NSString *name in names) {
                if (name.length == 0) continue;
                const char *utf8 = name.UTF8String;
                if (ZNAIsInterestingClassName(utf8) != ZNAIsInterestingClassNameSlow(utf8)) {
                    divergence++;
                    if (divergence < 10) printf("FAIL fast/slow mismatch: %s\n", utf8);
                }
                // 主二进制里带 _TtC7Browser 前缀的是 App 自己的类，一个都不该被命中：
                // 命中就说明规则放宽到了业务名上。
                if (strstr(utf8, "_TtC7Browser")) {
                    CHECK(!ZNAIsInterestingClassName(utf8));
                    appOwned++;
                }
                if (!ZNAIsInterestingClassName(utf8)) {
                    CHECK(!ZNAIsLaunchClassName(utf8));
                    continue;
                }
                interesting++;
                if (ZNAIsLaunchClassName(utf8)) {
                    launch++;
                } else if (ZNAIsSplashLikeName(utf8)) {
                    missedSplash++;
                    if (missedSplash < 10) printf("FAIL launch-critical class missed: %s\n", utf8);
                }
            }
            CHECK(divergence == 0);
            CHECK(missedSplash == 0);
            CHECK(appOwned > 0);
            // 冷启动主线程只挂 launch 这一批，太多就说明那道预筛没起作用。
            CHECK(launch < 200);
            printf("corpus: %lu interesting (%lu launch) of %lu classes, %lu app-owned\n",
                   (unsigned long)interesting, (unsigned long)launch, (unsigned long)names.count,
                   (unsigned long)appOwned);
        }

        printf(failures ? "%d checks failed\n" : "pattern rules ok\n", failures);
        return failures ? 1 : 0;
    }
}
