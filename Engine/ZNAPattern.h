#ifndef ZNAPATTERN_H
#define ZNAPATTERN_H

#import <Foundation/Foundation.h>
#import "ZNAGlob.h"

typedef NS_ENUM(NSUInteger, ZNAAction) {
    ZNAActionNone = 0,
    ZNAActionDefuse,
};

// 类名是否可能承载广告逻辑，用于扫描时跳过绝大多数无关类。
BOOL ZNAIsInterestingClassName(const char *name);

// 冷启动主线程那次扫描用的判定：既命中规则表、名字又像开屏宿主。
BOOL ZNAIsLaunchClassName(const char *name);

// 展示层方法（已含禁用名单）。类名是否要处理由调用方先判断，避免每个方法重跑一遍类名规则。
BOOL ZNAIsPresentationSelector(const char *selector);

// 某个类的某个方法应执行的处理。
ZNAAction ZNAActionForClass(const char *className, const char *selector);

// 是否为开屏一类（决定延后离场还是直接摘掉）。
BOOL ZNAIsSplashLikeName(const char *name);

// 参考实现：不查编译好的规则表，直接跑通用通配匹配。只用于测试比对快速路径是否等价。
BOOL ZNAIsInterestingClassNameSlow(const char *name);
BOOL ZNAIsPresentationSelectorSlow(const char *selector);

#endif
