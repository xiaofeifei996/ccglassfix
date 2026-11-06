// CCGlassFix v2 - 修复 iOS 26 禁用液态玻璃后控制中心白底白图标
// v2: 增加加载/调用日志, hook 覆盖 didMoveToWindow
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";

static void CCGFLog(NSString *msg) {
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kLogPath]) {
            [data writeToFile:kLogPath atomically:NO];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) return;
        @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (NSException *e) {}
        [fh closeFile];
    }
}

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

static void CCGFApplyIfNeeded(id obj, NSString *from) {
    BOOL isCC = [obj isKindOfClass:NSClassFromString(@"SBControlCenterWindow")];
    if (!isCC) return;
    BOOL disabled = CCGFGlassDisabled();
    BOOL dark = CCGFSystemIsDark();
    UIView *v = (UIView *)obj;
    CCGFLog([NSString stringWithFormat:@"CC window via %@, glassDisabled=%d sysDark=%d style=%ld",
             from, disabled, dark, (long)v.traitCollection.userInterfaceStyle]);
    if (disabled && dark) {
        v.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        CCGFLog(@"applied dark override");
    }
}

typedef id (*InitSceneIMP)(id, SEL, id);
typedef id (*InitFrameIMP)(id, SEL, CGRect);
typedef id (*InitIMP)(id, SEL);
typedef void (*VoidWindowIMP)(id, SEL, id);

static void CCGFHookInitWithScene(Class cls) {
    SEL sel = @selector(initWithWindowScene:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CCGFLog(@"no initWithWindowScene"); return; }
    InitSceneIMP orig = (InitSceneIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^id(id self, id scene) {
        id r = orig(self, sel, scene);
        CCGFApplyIfNeeded(r, @"initWithWindowScene");
        return r;
    });
    method_setImplementation(m, newImp);
    CCGFLog(@"hooked initWithWindowScene");
}

static void CCGFHookInitWithFrame(Class cls) {
    SEL sel = @selector(initWithFrame:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CCGFLog(@"no initWithFrame"); return; }
    InitFrameIMP orig = (InitFrameIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^id(id self, CGRect f) {
        id r = orig(self, sel, f);
        CCGFApplyIfNeeded(r, @"initWithFrame");
        return r;
    });
    method_setImplementation(m, newImp);
    CCGFLog(@"hooked initWithFrame");
}

static void CCGFHookInit(Class cls) {
    SEL sel = @selector(init);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CCGFLog(@"no init"); return; }
    InitIMP orig = (InitIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^id(id self) {
        id r = orig(self, sel);
        CCGFApplyIfNeeded(r, @"init");
        return r;
    });
    method_setImplementation(m, newImp);
    CCGFLog(@"hooked init");
}

static void CCGFHookDidMoveToWindow(Class cls) {
    SEL sel = @selector(didMoveToWindow);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CCGFLog(@"no didMoveToWindow"); return; }
    // didMoveToWindow 无参数, 用无参 IMP
    typedef void (*DMTWIMP)(id, SEL);
    DMTWIMP orig = (DMTWIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^void(id self) {
        orig(self, sel);
        CCGFApplyIfNeeded(self, @"didMoveToWindow");
    });
    method_setImplementation(m, newImp);
    CCGFLog(@"hooked didMoveToWindow");
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d", getpid()]);
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (!winCls) { CCGFLog(@"SBControlCenterWindow NOT FOUND"); return; }
        CCGFHookInitWithScene(winCls);
        CCGFHookInitWithFrame(winCls);
        CCGFHookInit(winCls);
        CCGFHookDidMoveToWindow(winCls);
        CCGFLog(@"hooks installed");
    }
}
