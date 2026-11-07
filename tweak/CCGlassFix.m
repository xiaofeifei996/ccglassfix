// CCGlassFix v26 - 仅处理「控制中心」白色底 -> 深灰
// 关键: 控制中心由 SwiftUI 渲染, 会在布局阶段把白色刷回; 单纯定时改色会慢一步/被覆盖。
// 做法: ① hook 模块类(CCUI* / *Module*) 的 layoutSubviews, 布局一结束立刻压色(在渲染之前)
//       ② 材质层(effect/backdrop)直接压掉
//       ③ 0.2s 巡查 + 逐帧看护兜底
// 作用域严格限制在 SBControlCenterWindow 内, 不影响主屏/文件夹/资源库/菜单。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static CGColorRef gTargetColor = NULL;
static UIColor *gTargetUIColor = nil;
static BOOL gGlassDisabled = NO;
static NSHashTable *gPlates = nil;
static int gFixCount = 0;
static NSTimeInterval gLastLog = 0;
static NSUInteger gHookClassCount = 0;

static void CCGFLog(NSString *msg) {
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kLogPath]) [d writeToFile:kLogPath atomically:NO];
        else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
            if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; } @catch(...){} [fh closeFile]; }
        }
    }
}

static BOOL CCGFGlassOff(void) {
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
        if (gTargetColor) CGColorRelease(gTargetColor);
        gTargetColor = CGColorCreateGenericGray(gGray, gAlpha);
        gTargetUIColor = [UIColor colorWithCGColor:gTargetColor];
    }
}

// 近白判定(控制中心开启态填充偏浅灰, 阈值放宽)
static BOOL CCGFNearWhite(CGColorRef c) {
    if (!c) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *co = CGColorGetComponents(c);
    if (!co) return NO;
    CGFloat r, g, b, a;
    if (n >= 4) { r = co[0]; g = co[1]; b = co[2]; a = co[3]; }
    else if (n == 2) { r = g = b = co[0]; a = co[1]; }
    else return NO;
    return r > 0.70 && g > 0.70 && b > 0.70 && a > 0.35;
}

// 模块视图: 只有这些才允许改色; 窗口背景/材质底板一律不动
static BOOL CCGFIsModuleView(NSString *cn) {
    if ([cn containsString:@"Background"] || [cn containsString:@"Backdrop"]
        || [cn containsString:@"Wallpaper"] || [cn containsString:@"Window"]) return NO;
    if ([cn containsString:@"ModuleView"] || [cn containsString:@"ButtonModule"]
        || [cn containsString:@"SliderModule"] || [cn containsString:@"ToggleModule"]
        || [cn containsString:@"ModuleContainer"] || [cn containsString:@"ContentModule"]
        || [cn containsString:@"CCUIButton"] || [cn containsString:@"CCUIControl"]) return YES;
    return NO;
}

static BOOL CCGFIsCCWindow(UIView *w) {
    NSString *cn = NSStringFromClass([w class]);
    return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
}

static BOOL CCGFViewInCC(UIView *v) {
    int hops = 0;
    for (UIView *cur = v; cur && hops < 24; cur = cur.superview, hops++) {
        if ([cur isKindOfClass:[UIWindow class]]) return CCGFIsCCWindow(cur);
    }
    return NO;
}

// ---------- 改色 ----------
static int CCGFRecolorLayer(CALayer *l) {
    int changed = 0;
    for (CALayer *sub in l.sublayers) changed += CCGFRecolorLayer(sub);
    CGFloat w = l.frame.size.width, h = l.frame.size.height;
    if (w * h < 400) return changed;

    BOOL did = NO;
    if (CCGFNearWhite(l.backgroundColor)) { l.backgroundColor = gTargetColor; did = YES; }
    if ([l isKindOfClass:[CAShapeLayer class]]) {
        CGColorRef f = ((CAShapeLayer *)l).fillColor;
        if (CCGFNearWhite(f)) { ((CAShapeLayer *)l).fillColor = gTargetColor; did = YES; }
    }
    if ([l isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *g = (CAGradientLayer *)l;
        NSArray *cols = g.colors;
        BOOL anyWhite = NO;
        for (id c in cols) {
            if (CFGetTypeID((__bridge CFTypeRef)c) == CGColorGetTypeID()
                && CCGFNearWhite((__bridge CGColorRef)c)) { anyWhite = YES; break; }
        }
        if (anyWhite && cols.count) {
            NSMutableArray *nw = [NSMutableArray arrayWithCapacity:cols.count];
            for (NSUInteger i = 0; i < cols.count; i++) [nw addObject:(__bridge id)gTargetColor];
            g.colors = nw; did = YES;
        }
    }
    if (did) { [gPlates addObject:l]; changed++; }
    return changed;
}

// 材质层: 去掉毛玻璃并铺深色
static int CCGFKillMaterials(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    int n = 0;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"Background"] || [cn containsString:@"Wallpaper"]) {
        for (UIView *s in v.subviews) n += CCGFKillMaterials(s, depth - 1);
        return n;
    }
    BOOL isMat = [cn containsString:@"Material"] || [cn containsString:@"VisualEffect"]
              || [cn containsString:@"Backdrop"];
    if (isMat) {
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffectView *ev = (UIVisualEffectView *)v;
            if (ev.effect != nil) { ev.effect = nil; n++; }
        }
        for (UIView *s in v.subviews) {
            NSString *scn = NSStringFromClass([s class]);
            if ([scn containsString:@"Material"] || [scn containsString:@"Backdrop"]
                || [scn containsString:@"VisualEffect"] || [scn containsString:@"ContentView"]) {
                if (!s.hidden) { s.hidden = YES; n++; }
            }
        }
        if (v.backgroundColor != gTargetUIColor) { v.backgroundColor = gTargetUIColor; n++; }
        return n;   // 材质内部不再下钻
    }
    for (UIView *s in v.subviews) n += CCGFKillMaterials(s, depth - 1);
    return n;
}

static void CCGFApply(UIView *root) {
    if (!gGlassDisabled || !gTargetColor || !root) return;
    if (!CCGFIsModuleView(NSStringFromClass([root class]))) return;  // 只改模块, 不动窗口背景
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int n = CCGFRecolorLayer(root.layer);
    [CATransaction commit];
    n += CCGFKillMaterials(root, 30);
    if (n) gFixCount += n;
}

static void CCGFApply(UIView *root);

// ---------- 定位控制中心窗口 ----------
static UIWindow *CCGFCCWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    for (UIWindow *w in app.windows) {
        if (w.hidden || w.alpha < 0.05) continue;
        if (CCGFIsCCWindow(w)) return w;
    }
    return nil;
}

// ---------- hook: layoutSubviews(仅控制中心模块类自己实现的) ----------
typedef void (*LayoutIMP)(id, SEL);
static BOOL gInLayout = NO;

static void CCGFFixNow(UIView *v) {
    if (gInLayout) return;
    gInLayout = YES;
    CCGFApply(v);
    gInLayout = NO;
}

static BOOL CCGFClassLooksCC(NSString *cn) {
    return [cn containsString:@"CCUI"] || [cn containsString:@"Module"]
        || [cn containsString:@"ControlCenter"];
}

static int gHookClassCount2 = 0;

static void CCGFInstallLayoutHooks(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * total);
    if (!classes) return;
    total = objc_getClassList(classes, total);
    for (int i = 0; i < total; i++) {
        Class cls = classes[i];
        NSString *cn = NSStringFromClass(cls);
        if (!CCGFClassLooksCC(cn)) continue;
        if (![cls isSubclassOfClass:[UIView class]]) continue;
        // 必须是该类自己实现的 layoutSubviews(避免改到父类共享的 Method)
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        if (!methods) continue;
        Method target = NULL;
        for (unsigned int k = 0; k < mc; k++) {
            if (method_getName(methods[k]) == @selector(layoutSubviews)) { target = methods[k]; break; }
        }
        if (target) {
            LayoutIMP orig = (LayoutIMP)method_getImplementation(target);
            method_setImplementation(target, imp_implementationWithBlock(^void(id self){
                orig(self, @selector(layoutSubviews));
                if (!gGlassDisabled || !gTargetColor) return;
                if (![self isKindOfClass:[UIView class]]) return;
                UIView *v = (UIView *)self;
                if (!v.window || !CCGFIsCCWindow(v.window)) return;
                CCGFFixNow(v);
            }));
            gHookClassCount2++;
        }
        free(methods);
    }
    free(classes);
    gHookClassCount = (NSUInteger)gHookClassCount2;
}

// 遍历控制中心里的模块视图
static int gModCount = 0;
static void CCGETCMods(UIView *v, int depth) {
    if (depth > 22 || !v) return;
    if (CCGFIsModuleView(NSStringFromClass([v class]))) {
        gModCount++;
        CCGFApply(v);
        return;   // 模块内部一次处理完, 不再下钻
    }
    for (UIView *s in v.subviews) CCGETCMods(s, depth + 1);
}

// ---------- 巡查 ----------
static void CCGFTick(void) {
    @autoreleasepool {
        gGlassDisabled = CCGFGlassOff();
        UIWindow *w = CCGFCCWindow();
        if (!w) return;
        CCGETCMods(w, 0);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastLog > 3.0) {
            gLastLog = now;
            CCGFLog([NSString stringWithFormat:@"tick fixes=%d plates=%lu hooks=%lu",
                     gFixCount, (unsigned long)gPlates.count, (unsigned long)gHookClassCount]);
        }
    }
}

static void CCGFWatch(void) {
    if (!gGlassDisabled || !gTargetColor || gPlates.count == 0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in gPlates.allObjects) {
        if (CCGFNearWhite(l.backgroundColor)) l.backgroundColor = gTargetColor;
        if ([l isKindOfClass:[CAShapeLayer class]]) {
            CGColorRef f = ((CAShapeLayer *)l).fillColor;
            if (CCGFNearWhite(f)) ((CAShapeLayer *)l).fillColor = gTargetColor;
        }
    }
    [CATransaction commit];
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        gPlates = [NSHashTable weakObjectsHashTable];
        CCGFLoadColor();
        gGlassDisabled = CCGFGlassOff();
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d gray=%.2f CC-only", getpid(), gGray]);
        CCGFInstallLayoutHooks();
        CCGFLog([NSString stringWithFormat:@"layout hooks installed on %lu classes", (unsigned long)gHookClassCount]);
        NSTimer *t = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { CCGFTick(); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            @autoreleasepool { CCGFWatch(); }
        }] selector:@selector(main)];
        dl.preferredFramesPerSecond = 0;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCGFLog(@"v27 installed: CC modules only, window background untouched");
    }
}
