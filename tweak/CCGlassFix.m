// CCGlassFix v8 - 控制中心 + App资源库 白底板 -> 深色(可配置)
// v8: 白底板登记进弱引用表 + CADisplayLink 逐帧看护(变白的帧立刻压回深色, 消除闪烁)
//     + hook UIView/CALayer setBackgroundColor: 双保险 + 0.25s 巡查发现新底板
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static NSTimeInterval gLastLogTime = 0;
static int gTotalRecolored = 0;
static int gWatchFixes = 0;   // 帧看护修复
static int gAddFixes = 0;     // addSublayer 即时修复
static int gHookFixes = 0;    // 源头 hook 修复
static CGColorRef gTargetColor = NULL;
static UIColor *gTargetUIColor = nil;
static BOOL gGlassDisabledCached = NO;
static NSHashTable *gPlates = nil;  // 已登记底板图层(弱引用)

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
        if (gTargetColor) CGColorRelease(gTargetColor);
        gTargetColor = CGColorCreateGenericGray(gGray, gAlpha);
        gTargetUIColor = [UIColor colorWithCGColor:gTargetColor];
    }
}

static BOOL CCGFColorIsWhite(CGColorRef c) {
    if (!c) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *co = CGColorGetComponents(c);
    if (!co) return NO;
    CGFloat r, g, b, a;
    if (n >= 4) { r = co[0]; g = co[1]; b = co[2]; a = co[3]; }
    else if (n == 2) { r = g = b = co[0]; a = co[1]; }
    else return NO;
    return r > 0.82 && g > 0.82 && b > 0.82 && a > 0.5;
}

static BOOL CCGFLayerShapeOK(CALayer *layer) {
    CGFloat area = layer.frame.size.width * layer.frame.size.height;
    return layer.cornerRadius >= 15.0 || area > 40000.0;
}

// 沿 superlayer 链判断该图层是否处于 控制中心 / App资源库 / 搜索 容器内
static BOOL CCGFLayerInTarget(CALayer *layer) {
    int hops = 0;
    for (CALayer *cur = layer; cur && hops < 80; cur = cur.superlayer, hops++) {
        id d = cur.delegate;
        if (d && [d isKindOfClass:[UIView class]]) {
            NSString *cn = NSStringFromClass([d class]);
            if ([cn containsString:@"Library"] || [cn containsString:@"AppLibrary"]) return YES;
            if ([cn containsString:@"Search"]) return YES;
            if ([d isKindOfClass:[UIWindow class]]) {
                return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
            }
        }
    }
    return NO;
}

// ---------- 巡查发现新底板 ----------
static int CCGFRecolor(CALayer *layer, CGColorRef target) {
    int changed = 0;
    if (CCGFColorIsWhite(layer.backgroundColor) && CCGFLayerShapeOK(layer)) {
        layer.backgroundColor = target;
        [gPlates addObject:layer];
        changed++;
    }
    for (CALayer *sub in layer.sublayers) changed += CCGFRecolor(sub, target);
    return changed;
}

static void CCGFApplyToWindow(UIView *win, NSString *from) {
    if (!gGlassDisabledCached || !gTargetColor) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int changed = CCGFRecolor(win.layer, gTargetColor);
    [CATransaction commit];
    if (changed > 0) {
        gTotalRecolored += changed;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastLogTime > 1.0) {
            gLastLogTime = now;
            CCGFLog([NSString stringWithFormat:@"%@: discovered %d (plates=%lu, watch=%d add=%d hook=%d)",
                     from, changed, (unsigned long)gPlates.count, gWatchFixes, gAddFixes, gHookFixes]);
        }
    }
}

static BOOL CCGFClassIsTarget(NSString *cn) {
    return [cn containsString:@"Library"] || [cn containsString:@"AppLibrary"]
        || [cn containsString:@"Search"];
}

// 深度受限查找目标子树并逐棵改色
static int CCGFApplyToSubtrees(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    NSString *cn = NSStringFromClass([v class]);
    if (CCGFClassIsTarget(cn)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        int changed = CCGFRecolor(v.layer, gTargetColor);
        [CATransaction commit];
        return changed;  // 子树已全覆盖, 不再下钻
    }
    int total = 0;
    for (UIView *s in v.subviews) total += CCGFApplyToSubtrees(s, depth - 1);
    return total;
}

static BOOL CCGFHasTarget(UIView *v, int depth) {
    if (depth <= 0 || !v) return NO;
    if (CCGFClassIsTarget(NSStringFromClass([v class]))) return YES;
    for (UIView *s in v.subviews)
        if (CCGFHasTarget(s, depth - 1)) return YES;
    return NO;
}

static void CCGFTick(void) {
    @autoreleasepool {
        gGlassDisabledCached = CCGFGlassDisabled();
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;
        for (UIWindow *w in app.windows) {
            if (w.hidden || w.alpha < 0.05) continue;
            NSString *cn = NSStringFromClass([w class]);
            BOOL isCC = [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
            BOOL isLib = [cn containsString:@"Library"] || [cn containsString:@"AppLibrary"];
            if (isCC || isLib) {
                CCGFApplyToWindow(w, isCC ? @"tickCC" : @"tickLib");
                continue;
            }
            // 主屏窗口: 只改 Library/Search 子树, 不碰小组件等其它白色元素
            if ([cn containsString:@"HomeScreen"] && CCGFHasTarget(w, 8)) {
                int changed = CCGFApplyToSubtrees(w, 8);
                if (changed > 0) {
                    gTotalRecolored += changed;
                    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                    if (now - gLastLogTime > 1.0) {
                        gLastLogTime = now;
                        CCGFLog([NSString stringWithFormat:@"tickHome: discovered %d (plates=%lu, watch=%d add=%d hook=%d)",
                                 changed, (unsigned long)gPlates.count, gWatchFixes, gAddFixes, gHookFixes]);
                    }
                }
            }
        }
    }
}

// ---------- 逐帧看护: 登记过的底板一旦变白立刻压回 ----------
static void CCGFWatchPlates(void) {
    if (!gGlassDisabledCached || !gTargetColor || gPlates.count == 0) return;
    NSArray *all = gPlates.allObjects;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in all) {
        if (CCGFColorIsWhite(l.backgroundColor)) {
            l.backgroundColor = gTargetColor;
            gWatchFixes++;
        }
    }
    [CATransaction commit];
}

// ---------- 源头 hook 双保险 ----------
typedef void (*SetBGIMP)(id, SEL, CGColorRef);
static SetBGIMP gOrigSetBG = NULL;

static void CCGFSetBGColor(id self, SEL sel, CGColorRef color) {
    if (color && gTargetColor && gGlassDisabledCached && CCGFColorIsWhite(color)) {
        CALayer *layer = (CALayer *)self;
        if (CCGFLayerShapeOK(layer) && CCGFLayerInTarget(layer)) {
            color = gTargetColor;
            [gPlates addObject:layer];
            gHookFixes++;
        }
    }
    gOrigSetBG(self, sel, color);
}

typedef void (*UIViewSetBGIMP)(id, SEL, UIColor *);
static UIViewSetBGIMP gOrigUIViewSetBG = NULL;

static void CCGFUIViewSetBG(id self, SEL sel, UIColor *color) {
    if (color && gTargetUIColor && gGlassDisabledCached && CCGFColorIsWhite(color.CGColor)) {
        UIView *v = (UIView *)self;
        if (CCGFLayerShapeOK(v.layer) && CCGFLayerInTarget(v.layer)) {
            color = gTargetUIColor;
            [gPlates addObject:v.layer];
            gHookFixes++;
        }
    }
    gOrigUIViewSetBG(self, sel, color);
}

// ---------- addSublayer hook: 新底板挂进目标容器当帧改色 ----------
static int CCGFRecolorSub(CALayer *layer, CGColorRef target) {
    int changed = 0;
    if (CCGFColorIsWhite(layer.backgroundColor) && CCGFLayerShapeOK(layer)) {
        layer.backgroundColor = target;
        [gPlates addObject:layer];
        changed++;
    }
    for (CALayer *sub in layer.sublayers) changed += CCGFRecolorSub(sub, target);
    return changed;
}

typedef void (*AddSublayerIMP)(id, SEL, CALayer *);
static AddSublayerIMP gOrigAddSublayer = NULL;

static void CCGFAddSublayer(id self, SEL sel, CALayer *sub) {
    gOrigAddSublayer(self, sel, sub);
    if (gTargetColor && gGlassDisabledCached && sub &&
        CCGFColorIsWhite(sub.backgroundColor) && CCGFLayerShapeOK(sub) &&
        CCGFLayerInTarget(sub)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gAddFixes += CCGFRecolorSub(sub, gTargetColor);
        [CATransaction commit];
    }
}

// ---------- SBControlCenterWindow hooks ----------
typedef id (*InitSceneIMP)(id, SEL, id);
typedef void (*SetHiddenIMP)(id, SEL, BOOL);

static void CCGFHookWin(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
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
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        gPlates = [NSHashTable weakObjectsHashTable];
        CCGFLoadColor();
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d gray=%.2f a=%.2f", getpid(), gGray, gAlpha]);
        // 1) CALayer 级 hook
        Method m = class_getInstanceMethod([CALayer class], @selector(setBackgroundColor:));
        if (m) {
            gOrigSetBG = (SetBGIMP)method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^void(id self, CGColorRef c){
                CCGFSetBGColor(self, @selector(setBackgroundColor:), c);
            }));
            CCGFLog(@"hooked CALayer setBackgroundColor:");
        }
        // 2) UIView 级 hook
        Method mv = class_getInstanceMethod([UIView class], @selector(setBackgroundColor:));
        if (mv) {
            gOrigUIViewSetBG = (UIViewSetBGIMP)method_getImplementation(mv);
            method_setImplementation(mv, imp_implementationWithBlock(^void(id self, UIColor *c){
                CCGFUIViewSetBG(self, @selector(setBackgroundColor:), c);
            }));
            CCGFLog(@"hooked UIView setBackgroundColor:");
        }
        // 3) addSublayer 即时改色(新底板同帧修复)
        Method ma = class_getInstanceMethod([CALayer class], @selector(addSublayer:));
        if (ma) {
            gOrigAddSublayer = (AddSublayerIMP)method_getImplementation(ma);
            method_setImplementation(ma, imp_implementationWithBlock(^void(id self, CALayer *s){
                CCGFAddSublayer(self, @selector(addSublayer:), s);
            }));
            CCGFLog(@"hooked CALayer addSublayer:");
        }
        // 4) 窗口 hook
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (winCls) {
            CCGFHookWin(winCls, @selector(initWithWindowScene:));
            CCGFHookWin(winCls, @selector(setHidden:));
        } else {
            CCGFLog(@"SBControlCenterWindow NOT FOUND");
        }
        // 5) 巡查发现新底板
        NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { CCGFTick(); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        // 6) 逐帧看护登记底板 (原生刷新率 60Hz -> 最多 1/60s 延迟)
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            @autoreleasepool { CCGFWatchPlates(); }
        }] selector:@selector(main)];
        dl.preferredFramesPerSecond = 0;  // 0 = 原生刷新率
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCGFLog(@"v9 installed: hooks + addSublayer + tick 0.25s + native-Hz watch");
    }
}
