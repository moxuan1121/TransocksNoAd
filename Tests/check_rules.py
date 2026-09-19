"""Mirror of Engine/TNAPattern.m so the rule table can be reviewed before a device test.

Reads the real #define strings out of the source, replays the C glob/action logic,
and reports coverage over the class dump of the shipped binary (piped on stdin, one
class name per line) so the false positives can be reviewed on a machine without
an iOS toolchain.
"""
import re
import sys

src = open('Engine/TNAPattern.m', encoding='utf-8').read()
src = re.sub(r'\\\n\s*', ' ', src)
# join every string literal that belongs to one #define
defs = {m.group(1): ''.join(re.findall(r'"([^"]*)"', m.group(2)))
        for m in re.finditer(r'#define\s+(TNA_\w+)\s+(.*?)(?=\n\S|\Z)', src, re.S)
        if '"' in m.group(2)}


def between(pattern):
    return re.search(pattern, src, re.S).group(1)


def resolve(token):
    return defs[token] if token in defs else token.strip('"')


RULES = [(resolve(c), resolve(s), a) for c, s, a in
         re.findall(r'\{\s*(TNA_\w+|"[^"]*"),\s*(TNA_\w+|"[^"]*"),\s*(TNAAction\w+)\s*\}',
                    between(r'static const TNARule TNARules\[\] = \{(.*?)\};'))]
FORBIDDEN = [x.strip().strip('",') for x in
             between(r'TNAForbiddenSelectors\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
SPLASH = [x.strip().strip('",') for x in
          between(r'TNASplashMarkers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
LAUNCH = [x.strip().strip('",') for x in
          between(r'TNALaunchMarkers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
EXCLUDED = [x.strip().strip('",') for x in
            between(r'static const char \*markers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]

# 展示层选择器：这些才允许被挂钩。
PRESENT = ['viewDidAppear:', 'viewWillAppear:', 'viewDidLayoutSubviews', 'didMoveToWindow', 'willMoveToWindow:',
           'layoutSubviews', 'makeKeyAndVisible', 'show', 'showAdInView', 'presentAd', 'renderAd']
# App 自己的广告宿主 + 三家 SDK 的门面类，必须一个不落。
APP_HOSTS = ['_TtC13Transocks_iOS10AdsManager', '_TtC13Transocks_iOS12CustomBootAd',
             '_TtCO13Transocks_iOS7ToponAd12SplashAdaper', '_TtCO13Transocks_iOS7ToponAd18InterstitialAdaper',
             '_TtC13Transocks_iOS16GADOpenAdAdapter', '_TtC13Transocks_iOS18GADNativeAdAdapter',
             '_TtC13Transocks_iOS24GADInterstitialAdAdapter']
SDK_FACES = ['ATAdManager', 'ATSplashAd', 'ATBanner', 'ATInterstitial', 'ATNative', 'ATNativeAdView',
             'ATMediaPlayer', 'ATADXAdManager', 'GDTSplashAd', 'GDTUnifiedInterstitialAd', 'GDTUnifiedBannerView',
             'GDTSDKConfig', 'GADInterstitialAd', 'GADAppOpenAd', 'GADAdLoader', 'GADBannerView',
             'GADMAdNetworkAdapterLifecycleProxyTestAnimationDelegator']

# 业务类：名字里带 Ad 但不是广告，规则一旦放宽就会误伤。
IGNORED = ['_TtC13Transocks_iOS20RuleAddPopController', '_TtC13Transocks_iOS17UpgradeController',
           '_TtC13Transocks_iOS23RouterUpgradeController', '_TtC13Transocks_iOS20RouterRuleHeaderView',
           '_TtC13Transocks_iOS24SettingSectionHeaderView', 'JCOREAddress', 'JCOREMacAddressManager',
           'JPUSHAddressConfigController', 'APMAdExposureReporter', 'APMPBAdCampaignInfo',
           'FIRCLSReportAdapter', 'ABTExperimentPayload', 'DownloadHandler', 'AdHocSignature']
# 激励视频与隐私同意：用户主动换权益 / 合规流程，一律不碰。
OUT_OF_SCOPE = ['ATRewardedVideoAd', 'ATRewardVideoAd', 'ATConsentPrivacySetting', 'ATUMPConsentHandler',
                'UMPConsentForm', 'UMPAppTransparencyStub', 'ATADXRewardedVideoAdapter', 'ATIVRewardModel']


def glob(name, pat):
    while pat:
        if pat[0] == '|':
            return glob(name, pat[1:])
        if pat[0] == '*':
            rest = pat[1:]
            if not rest or rest[0] == '|':
                return True
            return any(glob(name[i:], rest) for i in range(len(name) + 1))
        if not name or (pat[0] != '?' and pat[0] != name[0]):
            return False
        name, pat = name[1:], pat[1:]
    return not name


def any_glob(name, pats):
    return any(glob(name, p) for p in pats.split('|'))


def excluded(name):
    return any(m in name for m in EXCLUDED)


def action_for(cls, sel):
    if sel in FORBIDDEN or excluded(cls):
        return 'None'
    for cpat, spat, act in RULES:
        if any_glob(cls, cpat) and any_glob(sel, spat):
            return act
    return 'None'


def is_interesting(cls):
    return not excluded(cls) and any(any_glob(cls, c) for c, _, _ in RULES)


def is_launch(cls):
    return is_interesting(cls) and any(m in cls for m in LAUNCH)


def is_splash(cls):
    return any(m in cls for m in SPLASH)


def assertions():
    bad = []

    def ck(cond, label):
        if not cond:
            bad.append(label)

    ck(any_glob('CustomBootAd', '*BootAd|*SplashAd|*Splash*'), 'glob-bootad')
    ck(not any_glob('RuleAddPopController', '*Ad|*AD|AD*'), 'glob-addpop')
    ck(not any_glob('AddressBookViewController', '*AdView*|*AdBanner*'), 'glob-address')
    for c in APP_HOSTS + SDK_FACES:
        ck(is_interesting(c) or any(action_for(c, s) != 'None' for s in PRESENT), 'cover ' + c)
    for c in IGNORED:
        ck(not is_interesting(c), 'ignore-class ' + c)
        for s in PRESENT:
            ck(action_for(c, s) == 'None', f'ignore {c}/{s}')
    for c in OUT_OF_SCOPE:
        ck(not is_interesting(c), 'out-of-scope ' + c)
        ck(not is_launch(c), 'out-of-scope-launch ' + c)
    for s in FORBIDDEN:
        ck(action_for('GDTSplashAd', s) == 'None', 'forbidden ' + s)
    for s in ['loadAd', 'loadAdData', 'start', 'getAdData', 'fetchAd']:
        ck(action_for('ATAdManager', s) == 'None', 'defuse-never-hook ' + s)
    ck(action_for('GADBannerView', 'layoutSubviews') == 'TNAActionDefuse', 'defuse-view')
    ck(action_for('_TtC13Transocks_iOS10AdsManager', 'viewDidAppear:') != 'None', 'host-vc')
    ck(is_splash('_TtC13Transocks_iOS12CustomBootAd'), 'splash-marker-bootad')
    ck(is_splash('GDTSplashAd') and not is_splash('GADInterstitialAd'), 'splash-marker')
    for c in ('_TtC13Transocks_iOS12CustomBootAd', 'GDTSplashAd', 'ATSplashAd', 'GADAppOpenAd',
              '_TtC13Transocks_iOS10AdsManager'):
        ck(is_launch(c), 'launch ' + c)
    ck(not is_launch('ATAdManager'), 'not-launch ATAdManager')
    # 开屏一类必须全部落在冷启动那道筛里，否则第一次开屏会等后台 pass（+0.2s）才挂上。
    ck(all(not (is_interesting(c) and is_splash(c)) or is_launch(c) for c in
           [l.strip() for l in open('Tests/corpus_classes.txt', encoding='utf-8') if l.strip()]),
       'splash-like class missed by launch pass')
    return bad


def main():
    print('rules:', [(c[:44] + '...', s, a) for c, s, a in RULES])
    bad = assertions()
    for b in bad:
        print('FAIL', b)
    classes = [l.strip() for l in sys.stdin if l.strip()]
    if classes:
        hits = {}
        for c in classes:
            actions = sorted({action_for(c, s) for s in PRESENT} - {'None'})
            if actions:
                hits[c] = actions
        launch = [c for c in classes if is_launch(c)]
        interesting = [c for c in classes if is_interesting(c)]
        print(f'corpus: {len(interesting)} interesting, {len(hits)} would get a hook, '
              f'{len(launch)} launch-only', file=sys.stderr)
        with open('rule_hits.txt', 'w', encoding='utf-8') as fh:
            for c in sorted(hits):
                fh.write(f'{c} {" ".join(hits[c])}\n')
        swift = [c for c in sorted(hits) if not re.match(r'^(AT|GDT|GAD|GAM)', c)]
        print('non-SDK classes hooked:', file=sys.stderr)
        for c in swift:
            print('  ', c, hits[c], file=sys.stderr)
    print('ASSERTIONS', 'FAILED ' + str(len(bad)) if bad else 'ok')
    sys.exit(1 if bad else 0)


main()
