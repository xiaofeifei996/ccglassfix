// CCGlassFix v4 - 控制中心白底板 -> 深色(可配置)
// 原理: 禁用液态玻璃后, CC 模块底板是"纯白+大圆角"的 CALayer。
//       遍历 SBControlCenterWindow 的图层树, 把这类层重着色为深色。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;   // 默认深灰 ~iOS16
static CGFloat gAlpha = 0.92;  // 默认微透
static NSTimeInterval gLastApply = 0;
static int gAppliedCount = 0;

static void CCGFLog(NSString *msg) {
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kLogPath])
            [data writeToFile:kLogPath atomically:NO];
        else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
            if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch(...){} [fh closeFile]; }
        }
    }
}

static BOOL CCGFGlassDisabled(void) {
    @autoreleasepool {
        NSDictionary *gp = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/Managed Preferences/mobile/.GlobalPreferences.plist"];
        return [gp[@"com.apple.SwiftUI.DisableSolarium"] boolValue];
    }
}

// 可配置颜色: /var/mobile/Library/Preferences/com.ccglassfix.plist -> gray(0-1) alpha(0-1)
static void CCGFLoadColor(void) {
    @autoreleasepool {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.ccglassfix.plist"];
        if (p[@"gray"]) gGray = [p[@"gray"] doubleValue];
        if (p[@"alpha"]) gAlpha = [p[@"alpha"] doubleValue];
        if (p[@"gray255"]) gGray = [p[@"gray255"] doubleValue] / 255.0;
    }
}

// 是否"近纯白+大圆角"的底板层
static BOOL CCGFIsWhitePlate(CALayer *layer) {
    CGColorRef c = layer.backgroundColor;
    if (!c) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *co = CGColorGetComponents(c);
    if (!co) return NO;
    CGFloat r, g, b, a;
    if (n >= 4) { r = co[0]; g = co[1]; b = co[2]; a = co[3]; }        // RGBA
    else if (n == 2) { r = g = b = co[0]; a = co[1]; }                 // 灰度+alpha
    else return NO;
    BOOL white = r > 0.82 && g > 0.82 && b > 0.82 && a > 0.5;
    return white && layer.cornerRadius >= 15.0;
}

// 递归重着色
static int CCGFRecolor(CALayer *layer, CGColorRef target) {
    int changed = 0;
    if (CCGFIsWhitePlate(layer)) {
        layer.backgroundColor = target;
        changed++;
    }
    for (CALayer *sub in layer.sublayers) changed += CCGFRecolor(sub, target);
    return changed;
}

static void CCGFApplyToWindow(UIView *win, NSString *from) {
    if (![win isKindOfClass:NSClassFromString(@"SBControlCenterWindow")]) return;
    if (!CCGFGlassDisabled()) return;
    // 节流
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastApply < 0.5) return;
    gLastApply = now;

    CGColorRef target = CGColorCreateGenericGray(gGray, gAlpha);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int changed = CCGFRecolor(win.layer, target);
    [CATransaction commit];
    CGColorRelease(target);
    if (changed > 0) {
        gAppliedCount += changed;
        CCGFLog([NSString stringWithFormat:@"%@: recolored %d white plates (gray=%.2f a=%.2f)",
                 from, changed, gGray, gAlpha]);
    }
}

// ---------- hooks ----------
typedef id (*InitSceneIMP)(id, SEL, id);
typedef void (*SetHiddenIMP)(id, SEL, BOOL);
typedef void (*VoidIMP)(id, SEL);

static void CCGFHook(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CCGFLog([NSString stringWithFormat:@"no %@", NSStringFromSelector(sel)]); return; }
    if (sel == @selector(initWithWindowScene:)) {
        InitSceneIMP orig = (InitSceneIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id self, id scene) {
            id r = orig(self, sel, scene);
            CCGFApplyToWindow(r, @"init");
            return r;
        }));
    } else if (sel == @selector(setHidden:)) {
        SetHiddenIMP orig = (SetHiddenIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL hidden) {
            orig(self, sel, hidden);
            if (!hidden) {
                // 立即 + 延迟补一次(材质异步渲染)
                CCGFApplyToWindow(self, @"setHidden");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ CCGFApplyToWindow(self, @"setHidden+0.2"); });
            }
        }));
    } else if (sel == @selector(layoutSubviews)) {
        VoidIMP orig = (VoidIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^void(id self) {
            orig(self, sel);
            if ([self isKindOfClass:NSClassFromString(@"SBControlCenterWindow")])
                CCGFApplyToWindow(self, @"layout");
        }));
    }
    CCGFLog([NSString stringWithFormat:@"hooked %@", NSStringFromSelector(sel)]);
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        CCGFLoadColor();
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d gray=%.2f a=%.2f", getpid(), gGray, gAlpha]);
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (!winCls) { CCGFLog(@"SBControlCenterWindow NOT FOUND"); return; }
        CCGFHook(winCls, @selector(initWithWindowScene:));
        CCGFHook(winCls, @selector(setHidden:));
        CCGFHook(winCls, @selector(layoutSubviews));
        CCGFLog(@"hooks installed");
    }
}
