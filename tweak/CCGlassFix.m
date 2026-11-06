// CCGlassFix - 修复 iOS 26 禁用液态玻璃后控制中心白底白图标
// 原理: 回退渲染下 SBControlCenterWindow 的 userInterfaceStyle 停在浅色,
//       底板被画成白色而图标仍是深色模式白色。强制窗口深色即可恢复可读。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL CCGFGlassDisabled(void) {
    @autoreleasepool {
        NSDictionary *gp = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/Managed Preferences/mobile/.GlobalPreferences.plist"];
        return [gp[@"com.apple.SwiftUI.DisableSolarium"] boolValue];
    }
}

static BOOL CCGFSystemIsDark(void) {
    @autoreleasepool {
        NSDictionary *gp = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/Managed Preferences/mobile/.GlobalPreferences.plist"];
        NSString *style = gp[@"AppleInterfaceStyle"];
        return [style isKindOfClass:[NSString class]] && [style isEqualToString:@"Dark"];
    }
}

static void CCGFApplyIfNeeded(id obj) {
    if (![obj isKindOfClass:NSClassFromString(@"SBControlCenterWindow")]) return;
    if (!CCGFGlassDisabled()) return;
    if (CCGFSystemIsDark()) {
        ((UIView *)obj).overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
}

// 通用 hook: 替换 cls 上的 sel(若只在父类实现则替换父类 IMP, 用 isKindOfClass 限制只影响目标类)
typedef id (*InitSceneIMP)(id, SEL, id);
typedef id (*InitFrameIMP)(id, SEL, CGRect);
typedef id (*InitIMP)(id, SEL);

static void CCGFHookInitWithScene(Class cls) {
    SEL sel = @selector(initWithWindowScene:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    InitSceneIMP orig = (InitSceneIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^id(id self, id scene) {
        id result = orig(self, sel, scene);
        CCGFApplyIfNeeded(result);
        return result;
    });
    method_setImplementation(m, newImp);
}

static void CCGFHookInitWithFrame(Class cls) {
    SEL sel = @selector(initWithFrame:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    InitFrameIMP orig = (InitFrameIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^id(id self, CGRect frame) {
        id result = orig(self, sel, frame);
        CCGFApplyIfNeeded(result);
        return result;
    });
    method_setImplementation(m, newImp);
}

static void CCGFHookInit(Class cls) {
    SEL sel = @selector(init);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    InitIMP orig = (InitIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^id(id self) {
        id result = orig(self, sel);
        CCGFApplyIfNeeded(result);
        return result;
    });
    method_setImplementation(m, newImp);
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (!winCls) return;
        CCGFHookInitWithScene(winCls);
        CCGFHookInitWithFrame(winCls);
        CCGFHookInit(winCls);
        NSLog(@"[CCGlassFix] hooks installed");
    }
}
