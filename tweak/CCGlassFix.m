// CCGlassFix v13 - 控制中心 / App资源库 / 主屏搜索 / 文件夹 白底 -> 深色(可配置)
// v13: 白底其实是材质层(MTMaterialView / UIVisualEffectView), 直接把 effect 置空 + 铺深色
//      并对所有材质层做逐帧看护, 消除打开文件夹时的白闪
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static NSTimeInterval gLastLogTime = 0;
static int gTotalRecolored = 0;
static int gWatchFixes = 0;
static int gAddFixes = 0;
static int gHookFixes = 0;
static CGColorRef gTargetColor = NULL;
static UIColor *gTargetUIColor = nil;
static BOOL gGlassDisabledCached = NO;
static NSHashTable *gPlates = nil;
static int gDumps = 0;
static NSTimeInterval gLastDump = 0;

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

static BOOL CCGFClassIsTarget(NSString *cn) {
    return [cn containsString:@"Library"] || [cn containsString:@"AppLibrary"]
        || [cn containsString:@"Search"];
}

// 沿 superlayer 链判断该图层是否处于 控制中心 / App资源库 / 搜索 容器内
static BOOL CCGFLayerInTarget(CALayer *layer) {
    int hops = 0;
    for (CALayer *cur = layer; cur && hops < 80; cur = cur.superlayer, hops++) {
        id d = cur.delegate;
        if (d && [d isKindOfClass:[UIView class]]) {
            NSString *cn = NSStringFromClass([d class]);
            if (CCGFClassIsTarget(cn)) return YES;
            if ([d isKindOfClass:[UIWindow class]]) {
                return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
            }
        }
    }
    return NO;
}

static CGColorRef CCGFWhiteColorOf(CALayer *l, BOOL *isFill) {
    if (isFill) *isFill = NO;
    if (CCGFColorIsWhite(l.backgroundColor)) return l.backgroundColor;
    if ([l isKindOfClass:[CAShapeLayer class]]) {
        CGColorRef f = ((CAShapeLayer *)l).fillColor;
        if (CCGFColorIsWhite(f)) { if (isFill) *isFill = YES; return f; }
    }
    return NULL;
}

static BOOL CCGFLayerShapeOK(CALayer *layer) {
    CGFloat area = layer.frame.size.width * layer.frame.size.height;
    return layer.cornerRadius >= 15.0 || area >= 1200.0;
}

// 把白底板改成目标色; 返回是否改动
static BOOL CCGFApplyColor(CALayer *l) {
    BOOL isFill = NO;
    if (!CCGFWhiteColorOf(l, &isFill)) return NO;
    if (isFill) ((CAShapeLayer *)l).fillColor = gTargetColor;
    else l.backgroundColor = gTargetColor;
    [gPlates addObject:l];
    return YES;
}

// ---------- 材质层(白底的真正来源) ----------
static NSHashTable *gEffects = nil;   // 已处理的 UIVisualEffectView(弱引用)

// 该材质层是否属于需要变暗的区域(控制中心/资源库/主屏/文件夹)
static BOOL CCGFViewInScope(UIView *v) {
    int hops = 0;
    for (UIView *cur = v; cur && hops < 12; cur = cur.superview, hops++) {
        NSString *cn = NSStringFromClass([cur class]);
        if (CCGFClassIsTarget(cn)) return YES;
        if ([cur isKindOfClass:[UIWindow class]])
            return [cn containsString:@"HomeScreen"] || [cn containsString:@"ControlCenter"]
                || [cn containsString:@"SBControl"];
    }
    return NO;
}

// 把材质视图变成实心深色(去掉毛玻璃, 消除白色)
static void CCGFKillEffect(UIVisualEffectView *ev) {
    ev.effect = nil;
    ev.backgroundColor = gTargetUIColor;
    // 清掉残留的 backdrop / content 白层
    for (UIView *s in ev.subviews) {
        NSString *cn = NSStringFromClass([s class]);
        if ([cn containsString:@"Backdrop"] || [cn containsString:@"VisualEffectContent"]) {
            s.backgroundColor = [UIColor clearColor];
        }
    }
    [gEffects addObject:ev];
}

static int CCGFScanEffects(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    int n = 0;
    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        if (CCGFViewInScope(v) && v.effect != nil) { CCGFKillEffect((UIVisualEffectView *)v); n++; }
    }
    for (UIView *s in v.subviews) n += CCGFScanEffects(s, depth - 1);
    return n;
}

// 逐帧看护材质层: 系统重新给 effect 就再置空
static void CCGFWatchEffects(void) {
    if (!gGlassDisabledCached || !gTargetUIColor) return;
    NSArray *all = gEffects.allObjects;
    for (UIVisualEffectView *ev in all) {
        if (ev.effect != nil) { ev.effect = nil; ev.backgroundColor = gTargetUIColor; gWatchFixes++; }
    }
}

// ---------- 巡查 ----------
static int CCGFRecolor(CALayer *layer) {
    int changed = 0;
    for (CALayer *sub in layer.sublayers) changed += CCGFRecolor(sub);
    if (CCGFLayerShapeOK(layer) && CCGFApplyColor(layer)) changed++;
    return changed;
}

static void CCGFApplyToWindow(UIView *win, NSString *from) {
    if (!gGlassDisabledCached || !gTargetColor) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int changed = CCGFRecolor(win.layer);
    [CATransaction commit];
    int eff = CCGFScanEffects(win, 40);   // 材质层(白色毛玻璃)一起去掉
    if (changed + eff > 0) {
        gTotalRecolored += changed + eff;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastLogTime > 1.0) {
            gLastLogTime = now;
            CCGFLog([NSString stringWithFormat:@"%@: plates=%d effects=%d (plates=%lu effs=%lu watch=%d add=%d hook=%d)",
                     from, changed, eff, (unsigned long)gPlates.count, (unsigned long)gEffects.count,
                     gWatchFixes, gAddFixes, gHookFixes]);
        }
    }
}

static int CCGFApplyToSubtrees(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    if (CCGFClassIsTarget(NSStringFromClass([v class]))) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        int changed = CCGFRecolor(v.layer);
        [CATransaction commit];
        return changed;
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

// ---------- 诊断: 列出主屏里剩下的白色图层 ----------
static NSString *CCGFChain(CALayer *l) {
    NSMutableString *ms = [NSMutableString string];
    int hops = 0;
    for (CALayer *cur = l; cur && hops < 6; cur = cur.superlayer, hops++) {
        id d = cur.delegate;
        NSString *cn = d ? NSStringFromClass([d class]) : NSStringFromClass([cur class]);
        [ms appendFormat:@"%@/", cn];
    }
    return ms;
}

static int gDiagCount = 0;
static void CCGFDiag(CALayer *layer, NSString *ctx) {
    if (gDiagCount > 60) return;
    for (CALayer *sub in layer.sublayers) CCGFDiag(sub, ctx);
    BOOL isFill = NO;
    CGColorRef c = CCGFWhiteColorOf(layer, &isFill);
    CGFloat w = layer.frame.size.width, h = layer.frame.size.height;
    if (!c) {
        // 非纯背景色: 记录视觉特效层(胶囊/材质)与带图内容的大图层
        id d = layer.delegate;
        NSString *dcn = d ? NSStringFromClass([d class]) : @"-";
        if ([dcn containsString:@"VisualEffect"] || [dcn containsString:@"Backdrop"]
            || [dcn containsString:@"Material"]) {
            gDiagCount++;
            CCGFLog([NSString stringWithFormat:@"DIAG %@ EFFECT dcn=%@ size=%.0fx%.0f r=%.0f chain=%@",
                     ctx, dcn, w, h, layer.cornerRadius, CCGFChain(layer)]);
        } else if (layer.contents && w * h > 8000) {
            gDiagCount++;
            CCGFLog([NSString stringWithFormat:@"DIAG %@ CONTENT dcn=%@ size=%.0fx%.0f r=%.0f chain=%@",
                     ctx, dcn, w, h, layer.cornerRadius, CCGFChain(layer)]);
        }
        return;
    }
    if (w * h < 400) return;
    gDiagCount++;
    CCGFLog([NSString stringWithFormat:@"DIAG %@ cls=%@ fill=%d size=%.0fx%.0f r=%.0f chain=%@",
             ctx, NSStringFromClass([layer class]), (int)isFill, w, h, layer.cornerRadius, CCGFChain(layer)]);
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
            if ([cn containsString:@"HomeScreen"]) {
                // 不再等资源库出现: 每次 tick 全量扫主屏窗口(与 v9 一致, 重启即生效)
                CCGFApplyToWindow(w, @"tickHome");
                NSTimeInterval now2 = [NSDate timeIntervalSinceReferenceDate];
                if (gDumps < 3 && now2 - gLastDump > 12.0) {
                    gLastDump = now2; gDumps++;
                    gDiagCount = 0;
                    CCGFDiag(w.layer, @"home");
                    CCGFLog([NSString stringWithFormat:@"DIAG end #%d count=%d", gDumps, gDiagCount]);
                }
            }
        }
    }
}

// ---------- 逐帧看护 ----------
static void CCGFWatchPlates(void) {
    if (!gGlassDisabledCached || !gTargetColor || gPlates.count == 0) return;
    NSArray *all = gPlates.allObjects;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in all) {
        BOOL isFill = NO;
        if (CCGFWhiteColorOf(l, &isFill)) {
            if (isFill) ((CAShapeLayer *)l).fillColor = gTargetColor;
            else l.backgroundColor = gTargetColor;
            gWatchFixes++;
        }
    }
    [CATransaction commit];
}

// ---------- 源头 hook ----------
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

typedef void (*AddSublayerIMP)(id, SEL, CALayer *);
static AddSublayerIMP gOrigAddSublayer = NULL;

static int CCGFRecolorSub(CALayer *layer) {
    int changed = 0;
    for (CALayer *s in layer.sublayers) changed += CCGFRecolorSub(s);
    if (CCGFLayerShapeOK(layer) && CCGFApplyColor(layer)) changed++;
    return changed;
}

static void CCGFAddSublayer(id self, SEL sel, CALayer *sub) {
    gOrigAddSublayer(self, sel, sub);
    if (gTargetColor && gGlassDisabledCached && sub && CCGFLayerInTarget(sub)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gAddFixes += CCGFRecolorSub(sub);
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
        gEffects = [NSHashTable weakObjectsHashTable];
        CCGFLoadColor();
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d gray=%.2f a=%.2f", getpid(), gGray, gAlpha]);
        Method m = class_getInstanceMethod([CALayer class], @selector(setBackgroundColor:));
        if (m) {
            gOrigSetBG = (SetBGIMP)method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^void(id self, CGColorRef c){
                CCGFSetBGColor(self, @selector(setBackgroundColor:), c);
            }));
            CCGFLog(@"hooked CALayer setBackgroundColor:");
        }
        Method mv = class_getInstanceMethod([UIView class], @selector(setBackgroundColor:));
        if (mv) {
            gOrigUIViewSetBG = (UIViewSetBGIMP)method_getImplementation(mv);
            method_setImplementation(mv, imp_implementationWithBlock(^void(id self, UIColor *c){
                CCGFUIViewSetBG(self, @selector(setBackgroundColor:), c);
            }));
            CCGFLog(@"hooked UIView setBackgroundColor:");
        }
        Method ma = class_getInstanceMethod([CALayer class], @selector(addSublayer:));
        if (ma) {
            gOrigAddSublayer = (AddSublayerIMP)method_getImplementation(ma);
            method_setImplementation(ma, imp_implementationWithBlock(^void(id self, CALayer *s){
                CCGFAddSublayer(self, @selector(addSublayer:), s);
            }));
            CCGFLog(@"hooked CALayer addSublayer:");
        }
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (winCls) {
            CCGFHookWin(winCls, @selector(initWithWindowScene:));
            CCGFHookWin(winCls, @selector(setHidden:));
        }
        NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { CCGFTick(); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            @autoreleasepool { CCGFWatchPlates(); CCGFWatchEffects(); }
        }] selector:@selector(main)];
        dl.preferredFramesPerSecond = 0;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCGFLog(@"v11 installed: hooks + addSublayer + tick 0.25s + native-Hz watch + diag");
    }
}
