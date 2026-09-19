#ifndef TNAPATTERN_H
#define TNAPATTERN_H

#import <Foundation/Foundation.h>
#import "TNAGlob.h"

typedef NS_ENUM(NSUInteger, TNAAction) {
    TNAActionNone = 0,
    TNAActionDefuse,
};

// 类名是否可能承载广告逻辑，用于扫描时跳过绝大多数无关类。
BOOL TNAIsInterestingClassName(const char *name);

// 冷启动主线程那次扫描用的判定：既命中规则表、名字又像开屏宿主。
BOOL TNAIsLaunchClassName(const char *name);

// 展示层方法（已含禁用名单）。类名是否要处理由调用方先判断，避免每个方法重跑一遍类名规则。
BOOL TNAIsPresentationSelector(const char *selector);

// 某个类的某个方法应执行的处理。
TNAAction TNAActionForClass(const char *className, const char *selector);

// 是否为开屏一类（决定延后离场还是直接摘掉）。
BOOL TNAIsSplashLikeName(const char *name);

// 参考实现：不查编译好的规则表，直接跑通用通配匹配。只用于测试比对快速路径是否等价。
BOOL TNAIsInterestingClassNameSlow(const char *name);
BOOL TNAIsPresentationSelectorSlow(const char *selector);

#endif
