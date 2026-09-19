#include "ZNAGlob.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    CHECK(ZNAMatchGlob("GADAppOpenAd", "*AppOpen*|*SplashAd|*Splash*"));
    CHECK(ZNAMatchGlob("GADMediationAppOpenAdRenderer", "GAD*|*AppOpenAd*"));
    CHECK(ZNAMatchGlob("GADMobileAds", "GADMobileAds|GADRequest"));
    CHECK(ZNAMatchGlob("GADRequest", "GADMobileAds|GADRequest"));
    CHECK(ZNAMatchGlob("GADInterstitialAd", "GAD*|*Interstitial*"));
    CHECK(ZNAMatchGlob("GADNativeAdView", "*AdView*|*NativeAd*"));
    CHECK(ZNAMatchGlob("GAMInterstitialAd", "GAM*|GAD*"));

    // 业务侧以 Ad 开头的名字（AddDevice/Address/AdEvent 无关项）不能被前缀规则顺手捞走。
    CHECK(!ZNAMatchGlob("_TtC7Browser10AddressBar", "*Ad|*AD|AD*|GAD*"));
    CHECK(!ZNAMatchGlob("AddressBookViewController", "AD*"));
    CHECK(!ZNAMatchGlob("AccountBannerView", "*AdBanner*|*BannerAd*"));
    CHECK(!ZNAMatchGlob("UpgradeController", "*AdView*|*AdUnit*"));
    CHECK(!ZNAMatchGlob("AdEventStore", "*AdView*|*AdLoader*|*AdOffer*|*AdUnit*"));
    CHECK(!ZNAMatchGlob("GDTCORApplication", "GAD*|GAM*|*AdView*"));
    CHECK(!ZNAMatchGlob("oad", "*AD"));
    CHECK(!ZNAMatchGlob("GADAdLoader", "GADMobileAds|GDT*"));
    CHECK(!ZNAMatchGlob("BU", "GAD*|"));
    CHECK(ZNAMatchGlob("GAD", "GAD*"));
    CHECK(ZNAMatchGlob("GAM", "GAM|GDT*"));
    CHECK(ZNAMatchGlob("AXB", "A?B"));
    CHECK(!ZNAMatchGlob("AB", "A?B"));

    printf(failures ? "%d glob checks failed\n" : "glob matcher ok\n", failures);
    return failures ? 1 : 0;
}
