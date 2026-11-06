// CCGlassFix v5 - 控制中心白底板 -> 深色(可配置)
// v5: 秒级巡查所有 ControlCenter 窗口; 大圆角或"大面积白块"都改色(覆盖放大面板)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static NSTimeInterval gLastLogTime = 0;
static int gTotalRecolored = 0;

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

static void CCGFLoadColor(void) {
    @autoreleasepool {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.ccglassfix.plist"];
        if (p[@"gray"]) gGray = [p[@"gray"] doubleValue];
        if (p[@"alpha"]) gAlpha = [p[@"alpha"] doubleValue];
        if (p[@"gray255"]) gGray = [p[@"gray255"] doubleValue] / 255.0;
    }
}

typedef BOOL (^CCGFJudge)(CALayer *l);

// 白 + 大圆角 -> 底板; 白 + 面积巨大 -> 放大面板背景
static BOOL CCGFIsWhitePlate(CALayer *layer) {
    CGColorRef c = layer.backgroundColor;
    if (!c) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *co = CGColorGetComponents(c);
    if (!co) return NO;
    CGFloat r, g, b, a;
    if (n >= 4) { r = co[0]; g = co[1]; b = co[2]; a = co[3]; }
    else if (n == 2) { r = g = b = co[0]; a = co[1]; }
    else return NO;
    BOOL white = r > 0.82 && g > 0.82 && b > 0.82 && a > 0.5;
    if (!white) return NO;
    CGFloat area = layer.frame.size.width * layer.frame.size.height;
    return layer.cornerRadius >= 15.0 || area > 40000.0;
}

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
    if (!CCGFGlassDisabled()) return;
    CGColorRef target = CGColorCreateGenericGray(gGray, gAlpha);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int changed = CCGFRecolor(win.layer, target);
    [CATransaction commit];
    CGColorRelease(target);
    if (changed > 0) {
        gTotalRecolored += changed;
        // 只节流日志, 不节流实际操作
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastLogTime > 1.0) {
            gLastLogTime = now;
            CCGFLog([NSString stringWithFormat:@"%@: recolored %d (total %d, gray=%.2f)",
                     from, changed, gTotalRecolored, gGray]);
        }
    }
}

// 是否控制中心相关窗口
static BOOL CCGFIsCCWindow(UIWindow *w) {
    NSString *cn = NSStringFromClass([w class]);
    return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
}

static void CCGFTick(void) {
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;
        for (UIWindow *w in app.windows) {
            if (!CCGFIsCCWindow(w)) continue;
            if (w.hidden || w.alpha < 0.05) continue;
            CCGFApplyToWindow(w, @"tick");
        }
    }
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
            CCGFTick();
            return r;
        }));
    } else if (sel == @selector(setHidden:)) {
        SetHiddenIMP orig = (SetHiddenIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL hidden) {
            orig(self, sel, hidden);
            if (!hidden) CCGFTick();
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
        // 秒级巡查: 覆盖放大面板/编辑模式等所有重渲染
        NSTimer *t = [NSTimer timerWithTimeInterval:0.7 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { CCGFTick(); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        CCGFLog(@"hooks installed + ticker");
    }
}
