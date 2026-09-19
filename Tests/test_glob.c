#include "TNAGlob.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    CHECK(TNAMatchGlob("CustomBootAd", "*BootAd|*SplashAd|*Splash*"));
    CHECK(TNAMatchGlob("GDTSplashAd", "*SplashAd"));
    CHECK(TNAMatchGlob("ATAdManager", "ATAdManager|ATInitModule"));
    CHECK(TNAMatchGlob("ATInitModule", "ATAdManager|ATInitModule"));
    CHECK(TNAMatchGlob("GADAppOpenAd", "GAD*|*AppOpenAd*"));
    CHECK(TNAMatchGlob("_TtC13Transocks_iOS10AdsManager", "*AdsManager*"));
    CHECK(TNAMatchGlob("_TtC13Transocks_iOS18GADNativeAdAdapter", "*GAD*Adapter*"));
    CHECK(TNAMatchGlob("ATADXSplashAdapter", "AT*|GDT*|GAD*"));

    // 业务侧以 Ad 开头的名字（AddDevice/Address/ADs 无关项）不能被前缀规则顺手捞走。
    CHECK(!TNAMatchGlob("RuleAddPopController", "*Ad|*AD|AD*|AT*"));
    CHECK(!TNAMatchGlob("AddressBookViewController", "AD*"));
    CHECK(!TNAMatchGlob("AccountBannerView", "*AdBanner*|*BannerAd*"));
    CHECK(!TNAMatchGlob("UpgradeController", "*AdView*|*AdUnit*"));
    CHECK(!TNAMatchGlob("oad", "*AD"));
    CHECK(!TNAMatchGlob("ATAdManager", "ATInitModule|GDT*"));
    CHECK(!TNAMatchGlob("BU", "AT*|"));
    CHECK(TNAMatchGlob("AT", "AT*"));
    CHECK(TNAMatchGlob("AT", "AT|GDT*"));
    CHECK(TNAMatchGlob("AXB", "A?B"));
    CHECK(!TNAMatchGlob("AB", "A?B"));

    printf(failures ? "%d glob checks failed\n" : "glob matcher ok\n", failures);
    return failures ? 1 : 0;
}
