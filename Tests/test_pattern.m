#import <Foundation/Foundation.h>
#import "TNAPattern.h"
#import <stdio.h>

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

// 展示层选择器：这些才允许被兜底挂钩。
static const char *const presentSelectors[] = {
    "viewDidAppear:", "viewWillAppear:", "viewDidLayoutSubviews", "didMoveToWindow", "willMoveToWindow:",
    "layoutSubviews", "makeKeyAndVisible", "show", "showAdInView", "presentAd", "renderAd",
};

// 兜底层永远不碰加载/请求：v0.0.1 就是把这一层挂成了空实现，宿主 App 等不到 SDK 回调、卡在开屏页。
static const char *const loadSelectors[] = {
    "loadAd", "loadAdData", "loadADInfo", "start", "getAdData", "fetchAd", "requestAd", "prepareToShow",
    "registerAdapter:", "setDelegate:", "loadGDTAd", "loadTopOnAd", "loadSplashAD",
};

// App 自己的广告宿主（Swift 类只有实现 SDK 协议的方法才进 ObjC 运行时）。
static const char *const appHostClasses[] = {
    "_TtC13Transocks_iOS10AdsManager", "_TtC13Transocks_iOS12CustomBootAd", "_TtC13Transocks_iOS12ToponManager",
    "_TtCO13Transocks_iOS7ToponAd12SplashAdaper", "_TtCO13Transocks_iOS7ToponAd18InterstitialAdaper",
    "_TtC13Transocks_iOS16GADOpenAdAdapter", "_TtC13Transocks_iOS18GADNativeAdAdapter",
    "_TtC13Transocks_iOS24GADInterstitialAdAdapter",
};

// 三家 SDK 的门面类。
static const char *const sdkFaceClasses[] = {
    "ATAdManager", "ATSplash", "ATSplashManager", "ATBanner", "ATInterstitial", "ATNative", "ATNativeAdView",
    "ATMediaPlayer", "ATADXAdManager", "ATInterstitialAutoAdManager", "GDTSplashAd", "GDTUnifiedInterstitialAd",
    "GDTUnifiedBannerView", "GDTSDKConfig", "GADInterstitialAd", "GADAppOpenAd", "GADAdLoader", "GADBannerView",
};

// 名字里带 Ad 但不是广告的 App 业务类：规则一放宽就会被误伤。
static const char *const ignoredClasses[] = {
    "_TtC13Transocks_iOS20RuleAddPopController", "_TtC13Transocks_iOS17UpgradeController",
    "_TtC13Transocks_iOS23RouterUpgradeController", "_TtC13Transocks_iOS20RouterRuleHeaderView",
    "_TtC13Transocks_iOS24SettingSectionHeaderView", "JCOREAddress", "JCOREMacAddressManager",
    "JPUSHAddressConfigController", "APMAdExposureReporter", "APMPBAdCampaignInfo", "FIRCLSReportAdapter",
    "ABTExperimentPayload", "AccountBannerView", "AddressBookViewController", "DownloadViewController",
};

// 激励视频（用户主动换权益）与隐私同意弹窗（合规流程）：一律不参与。
static const char *const outOfScopeClasses[] = {
    "ATRewardedVideoAd", "ATRewardVideoAd", "ATADXRewardedVideoAdapter", "ATIVRewardModel",
    "ATConsentPrivacySetting", "ATUMPConsentHandler", "UMPConsentForm", "UMPAppTransparencyStub",
};

static BOOL AnyPresentHit(const char *className) {
    for (size_t i = 0; i < sizeof(presentSelectors) / sizeof(presentSelectors[0]); i++) {
        if (TNAActionForClass(className, presentSelectors[i]) != TNAActionNone) return YES;
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        CHECK(TNAMatchGlob("CustomBootAd", "*SplashAd|*BootAd*"));
        CHECK(TNAMatchGlob("ATAdManager", "ATAdManager|ATInitModule"));
        CHECK(TNAMatchGlob("GDTSplashAd", "GDT*"));
        CHECK(!TNAMatchGlob("RuleAddPopController", "*Ad|*AD|AD*"));
        CHECK(!TNAMatchGlob("AddressBookViewController", "*Ad"));
        CHECK(!TNAMatchGlob("oad", "*AD"));
        CHECK(TNAMatchGlob("_TtC13Transocks_iOS10AdsManager", "*AdsManager*"));

        for (size_t i = 0; i < sizeof(appHostClasses) / sizeof(appHostClasses[0]); i++) {
            CHECK(TNAIsInterestingClassName(appHostClasses[i]));
        }
        for (size_t i = 0; i < sizeof(sdkFaceClasses) / sizeof(sdkFaceClasses[0]); i++) {
            CHECK(TNAIsInterestingClassName(sdkFaceClasses[i]));
        }

        // 业务类：既不能进候选表，也不能被挂任何展示层钩子。
        for (size_t i = 0; i < sizeof(ignoredClasses) / sizeof(ignoredClasses[0]); i++) {
            CHECK(!TNAIsInterestingClassName(ignoredClasses[i]));
            for (size_t s = 0; s < sizeof(presentSelectors) / sizeof(presentSelectors[0]); s++) {
                CHECK(TNAActionForClass(ignoredClasses[i], presentSelectors[s]) == TNAActionNone);
            }
        }
        for (size_t i = 0; i < sizeof(outOfScopeClasses) / sizeof(outOfScopeClasses[0]); i++) {
            CHECK(!TNAIsInterestingClassName(outOfScopeClasses[i]));
            CHECK(!TNAIsLaunchClassName(outOfScopeClasses[i]));
        }

        for (size_t i = 0; i < sizeof(loadSelectors) / sizeof(loadSelectors[0]); i++) {
            CHECK(TNAActionForClass("ATAdManager", loadSelectors[i]) == TNAActionNone);
            CHECK(TNAActionForClass("GDTSplashAd", loadSelectors[i]) == TNAActionNone);
            CHECK(TNAActionForClass("_TtC13Transocks_iOS10AdsManager", loadSelectors[i]) == TNAActionNone);
        }

        CHECK(TNAActionForClass("_TtC13Transocks_iOS10AdsManager", "viewDidAppear:") == TNAActionDefuse);
        CHECK(TNAActionForClass("GDTSplashViewController", "viewDidAppear:") == TNAActionDefuse);
        CHECK(TNAActionForClass("GADBannerView", "layoutSubviews") == TNAActionDefuse);
        CHECK(TNAActionForClass("ATTSplashADView", "didMoveToWindow") == TNAActionDefuse);
        CHECK(TNAActionForClass("ATBanner", "dealloc") == TNAActionNone);
        CHECK(TNAActionForClass("ATBanner", "viewDidLoad") == TNAActionNone);
        CHECK(TNAActionForClass("ATBanner", "class") == TNAActionNone);

        CHECK(TNAIsSplashLikeName("_TtC13Transocks_iOS12CustomBootAd"));
        CHECK(TNAIsSplashLikeName("GDTSplashAd"));
        CHECK(!TNAIsSplashLikeName("GDTUnifiedInterstitialAd"));
        CHECK(!TNAIsSplashLikeName("GADInterstitialAd"));

        for (size_t i = 0; i < sizeof(appHostClasses) / sizeof(appHostClasses[0]); i++) {
            if (!TNAIsInterestingClassName(appHostClasses[i]) && !AnyPresentHit(appHostClasses[i])) {
                failures++;
                printf("FAIL app host not covered: %s\n", appHostClasses[i]);
            }
        }

        // 选择器：快速匹配必须和通用通配匹配一字不差（禁用名单两边都有）。
        const char *const selectorCorpus[] = {
            "viewDidAppear:", "viewWillAppear:", "viewDidLayoutSubviews", "didMoveToWindow", "willMoveToWindow:",
            "layoutSubviews", "makeKeyAndVisible", "show", "showAd", "showInView:", "presentAd", "renderAd",
            "showSplashWithPlacementID:scene:window:delegate:", "presentFromRootViewController:",
            "loadAd", "loadAdData", "startWithAppID:", "dealloc", "init", "class", "respondsToSelector:",
            "viewDidLoad", "description", "hidden", "setHidden:", "shareInstance", "isKindOfClass:",
        };
        for (size_t i = 0; i < sizeof(selectorCorpus) / sizeof(selectorCorpus[0]); i++) {
            CHECK(TNAIsPresentationSelector(selectorCorpus[i]) == TNAIsPresentationSelectorSlow(selectorCorpus[i]));
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
            NSUInteger interesting = 0, launch = 0, divergence = 0, missedSplash = 0;
            for (NSString *name in names) {
                if (name.length == 0) continue;
                const char *utf8 = name.UTF8String;
                if (TNAIsInterestingClassName(utf8) != TNAIsInterestingClassNameSlow(utf8)) {
                    divergence++;
                    if (divergence < 10) printf("FAIL fast/slow mismatch: %s\n", utf8);
                }
                if (!TNAIsInterestingClassName(utf8)) {
                    CHECK(!TNAIsLaunchClassName(utf8));
                    continue;
                }
                interesting++;
                if (TNAIsLaunchClassName(utf8)) {
                    launch++;
                } else if (TNAIsSplashLikeName(utf8)) {
                    missedSplash++;
                    if (missedSplash < 10) printf("FAIL launch-critical class missed: %s\n", utf8);
                }
            }
            CHECK(divergence == 0);
            CHECK(missedSplash == 0);
            // 冷启动主线程只挂 launch 这一批，太多就说明那道预筛没起作用。
            CHECK(launch < 200);
            printf("corpus: %lu interesting (%lu launch) of %lu classes\n", (unsigned long)interesting,
                   (unsigned long)launch, (unsigned long)names.count);
        }

        printf(failures ? "%d checks failed\n" : "pattern rules ok\n", failures);
        return failures ? 1 : 0;
    }
}
