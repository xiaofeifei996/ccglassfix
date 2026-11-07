// CCGlassFix v14 - 控制中心 / App资源库 / 搜索 / App文件夹 的白色底 -> 深色(可配置)
// 白色底的真实来源是材质层: UIVisualEffectView / MTMaterialView(私有), 而非 backgroundColor
// 策略: 定位到"文件夹/搜索/资源库/控制中心"作用域内的材质层 -> 去掉材质(effect=nil/隐藏backdrop) + 铺深色
//       逐帧看护, 系统重新加回材质就再压掉, 消除打开文件夹/滑动时的白闪
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static NSTimeInterval gLastLogTime = 0;
static int gWatchFixes = 0;
static int gAddFixes = 0;
static int gHookFixes = 0;
static int gMatFixes = 0;
static CGColorRef gTargetColor = NULL;
static UIColor *gTargetUIColor = nil;
static BOOL gGlassDisabledCached = NO;
static NSHashTable *gPlates = nil;     // 白色底板图层
static NSHashTable *gMats = nil;       // 材质视图(已处理)

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
        || [cn containsString:@"Search"] || [cn containsString:@"Folder"];
}

// ---------- 材质层 ----------
static BOOL CCGFIsMaterialClass(NSString *cn) {
    return [cn containsString:@"VisualEffect"] || [cn containsString:@"Material"]
        || [cn containsString:@"Backdrop"];
}

// 墙纸/主屏底板不能动(否则背景被盖成深色)
static BOOL CCGFIsWallpaperClass(NSString *cn) {
    return [cn containsString:@"HomeScreenBackdrop"] || [cn containsString:@"Wallpaper"];
}

// 材质视图是否处于需要变暗的作用域(文件夹/搜索/资源库/控制中心)
static BOOL CCGFMatInScope(UIView *v) {
    NSString *selfCn = NSStringFromClass([v class]);
    if (CCGFIsWallpaperClass(selfCn)) return NO;
    int hops = 0;
    for (UIView *cur = v; cur && hops < 14; cur = cur.superview, hops++) {
        NSString *cn = NSStringFromClass([cur class]);
        if (CCGFIsWallpaperClass(cn)) return NO;      // 属于墙纸层, 跳过
        if (CCGFClassIsTarget(cn)) return YES;
        if ([cur isKindOfClass:[UIWindow class]])
            return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
    }
    return NO;
}

// 把一个材质视图压成实心深色(幂等, 可反复调用)
static BOOL CCGFFixMaterialView(UIView *v) {
    if (!gTargetUIColor) return NO;
    NSString *cn = NSStringFromClass([v class]);
    if (!CCGFIsMaterialClass(cn)) return NO;
    if (!CCGFMatInScope(v)) return NO;
    BOOL did = NO;
    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)v;
        if (ev.effect != nil) { ev.effect = nil; did = YES; }
    }
    // 子层里的 backdrop / 内容层全部压掉
    for (UIView *s in v.subviews) {
        NSString *scn = NSStringFromClass([s class]);
        if (CCGFIsMaterialClass(scn) || [scn containsString:@"ContentView"]) {
            if (s.backgroundColor != gTargetUIColor) s.backgroundColor = [UIColor clearColor];
            if (!s.hidden) { s.hidden = YES; did = YES; }
        }
    }
    if (v.backgroundColor != gTargetUIColor) { v.backgroundColor = gTargetUIColor; did = YES; }
    if (did) gMatFixes++;
    [gMats addObject:v];
    return did;
}

static int CCGFScanMaterials(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    int n = 0;
    if (CCGFIsMaterialClass(NSStringFromClass([v class]))) {
        if (CCGFFixMaterialView(v)) n++;
        // 材质视图内部不再下钻
    }
    for (UIView *s in v.subviews) n += CCGFScanMaterials(s, depth - 1);
    return n;
}

static void CCGFWatchMaterials(void) {
    if (!gGlassDisabledCached || !gTargetUIColor || gMats.count == 0) return;
    NSArray *all = gMats.allObjects;
    for (UIView *v in all) {
        @autoreleasepool {
            if ([v isKindOfClass:[UIVisualEffectView class]]) {
                if (((UIVisualEffectView *)v).effect != nil) {
                    ((UIVisualEffectView *)v).effect = nil;
                    v.backgroundColor = gTargetUIColor;
                    gWatchFixes++;
                }
            } else if (v.hidden || CCGFColorIsWhite(v.layer.backgroundColor) == NO) {
                // 被系统重新加回了 backdrop / 颜色
                if (CCGFFixMaterialView(v)) gWatchFixes++;
            }
        }
    }
}

// ---------- 白色底板(CALayer) ----------
static BOOL CCGFLayerInTarget(CALayer *layer) {
    int hops = 0;
    for (CALayer *cur = layer; cur && hops < 80; cur = cur.superlayer, hops++) {
        id d = cur.delegate;
        if (d && [d isKindOfClass:[UIView class]]) {
            NSString *cn = NSStringFromClass([d class]);
            if (CCGFClassIsTarget(cn)) return YES;
            if ([d isKindOfClass:[UIWindow class]])
                return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
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

static BOOL CCGFApplyColor(CALayer *l) {
    BOOL isFill = NO;
    if (!CCGFWhiteColorOf(l, &isFill)) return NO;
    if (isFill) ((CAShapeLayer *)l).fillColor = gTargetColor;
    else l.backgroundColor = gTargetColor;
    [gPlates addObject:l];
    return YES;
}

static int CCGFRecolor(CALayer *layer) {
    int changed = 0;
    for (CALayer *sub in layer.sublayers) changed += CCGFRecolor(sub);
    if (CCGFLayerShapeOK(layer) && CCGFApplyColor(layer)) changed++;
    return changed;
}

static int CCGFApplyToView(UIView *win, NSString *from) {
    if (!gGlassDisabledCached || !gTargetColor) return 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int plates = CCGFRecolor(win.layer);
    [CATransaction commit];
    int mats = CCGFScanMaterials(win, 40);
    if (plates + mats > 0) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastLogTime > 1.0) {
            gLastLogTime = now;
            CCGFLog([NSString stringWithFormat:@"%@ plates=%d mats=%d (reg p=%lu m=%lu watch=%d add=%d hook=%d mat=%d)",
                     from, plates, mats, (unsigned long)gPlates.count, (unsigned long)gMats.count,
                     gWatchFixes, gAddFixes, gHookFixes, gMatFixes]);
        }
    }
    return plates + mats;
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
            if (isCC || isLib) { CCGFApplyToView(w, isCC ? @"tickCC" : @"tickLib"); continue; }
            if ([cn containsString:@"HomeScreen"]) CCGFApplyToView(w, @"tickHome");
        }
    }
}

// ---------- 逐帧看护: 已登记的底板 ----------
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

// ---------- hook: setBackgroundColor ----------
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

// ---------- hook: addSublayer (材质层/底板出现的当帧就处理, 消除白闪) ----------
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
    if (!gTargetColor || !gGlassDisabledCached || !sub) return;
    // 1) 新加的材质层(文件夹/搜索面板背景)立即压掉
    id d = sub.delegate;
    if (d && [d isKindOfClass:[UIView class]]) {
        UIView *dv = (UIView *)d;
        if (CCGFIsMaterialClass(NSStringFromClass([dv class]))) {
            if (CCGFFixMaterialView(dv)) gAddFixes++;
            return;
        }
        // 材质视图内部被重新加回 backdrop 时, 立刻隐藏
        NSString *scn = NSStringFromClass([dv class]);
        if (CCGFIsMaterialClass(scn) || [scn containsString:@"ContentView"]) {
            UIView *parent = dv.superview;
            if (parent && CCGFIsMaterialClass(NSStringFromClass([parent class]))
                && CCGFMatInScope(parent)) {
                dv.hidden = YES;
                gAddFixes++;
            }
            return;
        }
    }
    // 2) 新加的白色底板
    if (CCGFLayerInTarget(sub)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gAddFixes += CCGFRecolorSub(sub);
        [CATransaction commit];
    }
}

// ---------- hook: SBControlCenterWindow ----------
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
        gMats = [NSHashTable weakObjectsHashTable];
        CCGFLoadColor();
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d gray=%.2f a=%.2f", getpid(), gGray, gAlpha]);
        Method m = class_getInstanceMethod([CALayer class], @selector(setBackgroundColor:));
        if (m) {
            gOrigSetBG = (SetBGIMP)method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^void(id self, CGColorRef c){
                CCGFSetBGColor(self, @selector(setBackgroundColor:), c);
            }));
        }
        Method mv = class_getInstanceMethod([UIView class], @selector(setBackgroundColor:));
        if (mv) {
            gOrigUIViewSetBG = (UIViewSetBGIMP)method_getImplementation(mv);
            method_setImplementation(mv, imp_implementationWithBlock(^void(id self, UIColor *c){
                CCGFUIViewSetBG(self, @selector(setBackgroundColor:), c);
            }));
        }
        Method ma = class_getInstanceMethod([CALayer class], @selector(addSublayer:));
        if (ma) {
            gOrigAddSublayer = (AddSublayerIMP)method_getImplementation(ma);
            method_setImplementation(ma, imp_implementationWithBlock(^void(id self, CALayer *s){
                CCGFAddSublayer(self, @selector(addSublayer:), s);
            }));
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
            @autoreleasepool { CCGFWatchPlates(); CCGFWatchMaterials(); }
        }] selector:@selector(main)];
        dl.preferredFramesPerSecond = 0;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCGFLog(@"v14 installed: material killer + plate hooks + 0.25s tick + native-Hz watch");
    }
}
