"""Mirror of Engine/ZNAPattern.m so the rule table can be reviewed before a device test.

Reads the real #define strings out of the source, replays the C glob/action logic,
and reports coverage over the class dump of the shipped binary (piped on stdin, one
class name per line) so the false positives can be reviewed on a machine without
an iOS toolchain.
"""
import re
import sys

src = open('Engine/ZNAPattern.m', encoding='utf-8').read()
src = re.sub(r'\\\n\s*', ' ', src)
# join every string literal that belongs to one #define
defs = {m.group(1): ''.join(re.findall(r'"([^"]*)"', m.group(2)))
        for m in re.finditer(r'#define\s+(ZNA_\w+)\s+(.*?)(?=\n\S|\Z)', src, re.S)
        if '"' in m.group(2)}


def between(pattern):
    return re.search(pattern, src, re.S).group(1)


def resolve(token):
    return defs[token] if token in defs else token.strip('"')


RULES = [(resolve(c), resolve(s), a) for c, s, a in
         re.findall(r'\{\s*(ZNA_\w+|"[^"]*"),\s*(ZNA_\w+|"[^"]*"),\s*(ZNAAction\w+)\s*\}',
                    between(r'static const ZNARule ZNARules\[\] = \{(.*?)\};'))]
FORBIDDEN = [x.strip().strip('",') for x in
             between(r'ZNAForbiddenSelectors\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
SPLASH = [x.strip().strip('",') for x in
          between(r'ZNASplashMarkers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
LAUNCH = [x.strip().strip('",') for x in
          between(r'ZNALaunchMarkers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
EXCLUDED = [x.strip().strip('",') for x in
            between(r'static const char \*markers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]

CORPUS = 'Tests/corpus_classes.txt'

# 展示层选择器：这些才允许被挂钩。
PRESENT = ['viewDidAppear:', 'viewWillAppear:', 'viewDidLayoutSubviews', 'didMoveToWindow', 'willMoveToWindow:',
           'layoutSubviews', 'makeKeyAndVisible', 'show', 'showAdInView', 'presentAd', 'renderAd']
# AdMob 的门面类与渲染层，必须一个不落。
SDK_CLASSES = ['GADMobileAds', 'GADInterstitialAd', 'GADAppOpenAd', 'GADAdLoader', 'GADBannerView',
               'GADNativeAdView', 'GADCustomNativeAd', 'GADFullScreenAd', 'GADFullScreenAdViewController',
               'GAMInterstitialAd', 'GAMBannerView', 'GADMediationInterstitialAdRenderer']
# 名字里带 Ad / GDT 但不是广告的类，规则一放宽就会误伤。
IGNORED = ['_TtC7Browser10AddressBar', '_TtC7Browser15DownloadManager', '_TtC7Browser22WebPopupViewController',
           '_TtC10RevenueCat12AdEventStore', '_TtC10RevenueCat21PostAdEventsOperation', 'AccountBannerView',
           'AddressBookViewController', 'DownloadViewController', 'AdHocSignature', 'FIRCLSReportAdapter',
           'GDTCORApplication', 'GDTCOREvent', 'GDTCCTUploader', 'GDTMetricsSupport',
           '_TtC16FirebaseSessions14EventGDTLogger']
# 激励视频与隐私同意：用户主动换权益 / 合规流程，一律不碰。
OUT_OF_SCOPE = ['GADRewardedAd', 'GADRewardedInterstitialAd', 'GADMediationRewardedAdRenderer', 'GADAdReward',
                'UMPConsentForm', 'UMPConsentInformation', 'UMPConsentViewController', 'UMPAppTransparencyStub']


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


def corpus():
    with open(CORPUS, encoding='utf-8') as fh:
        return [l.strip() for l in fh if l.strip()]


def assertions():
    bad = []

    def ck(cond, label):
        if not cond:
            bad.append(label)

    ck(any_glob('GADAppOpenAd', 'GAD*|*AppOpen*'), 'glob-appopen')
    ck(not any_glob('RuleAddPopController', '*Ad|*AD|AD*'), 'glob-addpop')
    ck(not any_glob('AddressBookViewController', '*AdView*|*AdBanner*'), 'glob-address')
    # 这套规则最容易踩的坑：GDTCOR*/GDTCCT* 是 Google 的传输层，不是优量汇。
    ck(not any_glob('GDTCORApplication', 'GAD*|GAM*|*AdView*|*AdUnit*'), 'glob-gdtcor')
    for c in SDK_CLASSES:
        ck(is_interesting(c) or any(action_for(c, s) != 'None' for s in PRESENT), 'cover ' + c)
    for c in IGNORED:
        ck(not is_interesting(c), 'ignore-class ' + c)
        for s in PRESENT:
            ck(action_for(c, s) == 'None', f'ignore {c}/{s}')
    for c in OUT_OF_SCOPE:
        ck(not is_interesting(c), 'out-of-scope ' + c)
        ck(not is_launch(c), 'out-of-scope-launch ' + c)
        ck(action_for(c, 'presentFromRootViewController:') == 'None', 'out-of-scope-present ' + c)
    for s in FORBIDDEN:
        ck(action_for('GADBannerView', s) == 'None', 'forbidden ' + s)
    for s in ['loadWithAdUnitID:request:completionHandler:', 'loadRequest:', 'start', 'fetchAd']:
        ck(action_for('GADAdLoader', s) == 'None', 'defuse-never-hook ' + s)
    ck(action_for('GADBannerView', 'layoutSubviews') == 'ZNAActionDefuse', 'defuse-view')
    ck(action_for('GADFullScreenAdViewController', 'viewDidAppear:') == 'ZNAActionDefuse', 'defuse-fullscreen-vc')
    ck(is_splash('GADAppOpenAd') and not is_splash('GADInterstitialAd'), 'splash-marker')
    for c in ('GADAppOpenAd', 'GADMediationAppOpenAdRenderer'):
        ck(is_launch(c), 'launch ' + c)
    ck(not is_launch('GADInterstitialAd'), 'not-launch GADInterstitialAd')
    # 开屏一类必须全部落在冷启动那道筛里，否则第一次开屏会等后台 pass（+0.2s）才挂上。
    ck(all(not (is_interesting(c) and is_splash(c)) or is_launch(c) for c in corpus()),
       'splash-like class missed by launch pass')
    # App 自己的类一个都不该命中：命中了就是拿业务界面当广告藏。
    ck(any('_TtC7Browser' in c for c in corpus()), 'corpus is not the Zoomable dump')
    ck(not [c for c in corpus() if '_TtC7Browser' in c and is_interesting(c)], 'app class caught by rules')
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
        non_admob = [c for c in sorted(hits) if not re.match(r'^(GAD|GAM)', c)]
        print('classes hooked that are not AdMob-owned (review these):', file=sys.stderr)
        for c in non_admob:
            print('  ', c, hits[c], file=sys.stderr)
        print('launch pass candidates:', file=sys.stderr)
        for c in sorted(launch):
            print('  ', c, file=sys.stderr)
    print('ASSERTIONS', 'FAILED ' + str(len(bad)) if bad else 'ok')
    sys.exit(1 if bad else 0)


main()
