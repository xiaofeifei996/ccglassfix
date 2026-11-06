// CCGlassFix v3 - 修复 iOS 26 禁用液态玻璃后控制中心白底白图标
// v3: 窗口可能早于插件创建 -> 补扫描 + setHidden 钩子(每次打开 CC 都会触发)
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

static void CCGFApplyToWindow(UIView *win, NSString *from) {
    if (![win isKindOfClass:NSClassFromString(@"SBControlCenterWindow")]) return;
    if (!CCGFGlassDisabled()) { CCGFLog([NSString stringWithFormat:@"CC via %@ but glass enabled", from]); return; }
    if (!CCGFSystemIsDark()) { CCGFLog([NSString stringWithFormat:@"CC via %@ but system light", from]); return; }
    long before = (long)win.overrideUserInterfaceStyle;
    win.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // 同时传播到 root VC 的 view, 保证 SwiftUI hosting 也吃到
    if ([win respondsToSelector:@selector(rootViewController)]) {
        UIViewController *rvc = [(UIWindow *)win rootViewController];
        if (rvc) rvc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    CCGFLog([NSString stringWithFormat:@"CC via %@: override %ld -> dark (traitStyle=%ld)",
             from, before, (long)win.traitCollection.userInterfaceStyle]);
}

// ---------- hooks ----------
typedef id (*InitSceneIMP)(id, SEL, id);
typedef void (*SetHiddenIMP)(id, SEL, BOOL);

static void CCGFHook(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CCGFLog([NSString stringWithFormat:@"no %@", NSStringFromSelector(sel)]); return; }

    if (sel == @selector(initWithWindowScene:)) {
        InitSceneIMP orig = (InitSceneIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id self, id scene) {
            id r = orig(self, sel, scene);
            CCGFApplyToWindow(r, @"initWithWindowScene");
            return r;
        }));
    } else if (sel == @selector(setHidden:)) {
        SetHiddenIMP orig = (SetHiddenIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL hidden) {
            orig(self, sel, hidden);
            if (!hidden) CCGFApplyToWindow(self, @"setHidden:");
        }));
    }
    CCGFLog([NSString stringWithFormat:@"hooked %@", NSStringFromSelector(sel)]);
}

static void CCGFScanExisting(void) {
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) { CCGFLog(@"no sharedApplication"); return; }
        NSArray *wins = app.windows;
        CCGFLog([NSString stringWithFormat:@"scan %lu windows", (unsigned long)wins.count]);
        for (UIWindow *w in wins) CCGFApplyToWindow(w, @"scan");
    }
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d", getpid()]);
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (!winCls) { CCGFLog(@"SBControlCenterWindow NOT FOUND"); return; }
        CCGFHook(winCls, @selector(initWithWindowScene:));
        CCGFHook(winCls, @selector(setHidden:));
        // 窗口可能已存在: 延迟扫描 (等 UIApplication 就绪)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CCGFScanExisting(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CCGFScanExisting(); });
        CCGFLog(@"hooks installed");
    }
}
