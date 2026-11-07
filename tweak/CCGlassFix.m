// CCGlassFix v16 - 材质层压暗 + 文件夹整屏背景(SBFolderControllerBackgroundView)直接压深色
// v18: 文件夹整屏背景保持不透明深色, 但关闭时完全不干预系统淡出动画
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static NSTimeInterval gLastLogTime = 0;
static int gWatchFixes = 0, gAddFixes = 0, gHookFixes = 0, gMatFixes = 0;
static CGColorRef gTargetColor = NULL;
static UIColor *gTargetUIColor = nil;
static BOOL gGlassDisabledCached = NO;
static NSHashTable *gPlates = nil;
static NSHashTable *gMats = nil;

static BOOL gRec = NO;
static NSTimeInterval gRecStart = 0;
static NSMutableSet *gRecKeys = nil;
static int gRecCount = 0;

static void CCGFLog(NSString *msg) {
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kLogPath]) [data writeToFile:kLogPath atomically:NO];
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

// 文件夹外面那层整屏材质(SBFolderControllerBackgroundView) - 白闪主犯
static BOOL CCGFIsFolderBgClass(NSString *cn) {
    return [cn containsString:@"SBFolderControllerBackground"]
        || [cn containsString:@"FolderControllerBackground"];
}
static BOOL CCGFIsMaterialClass(NSString *cn) {
    return [cn containsString:@"VisualEffect"] || [cn containsString:@"Material"]
        || [cn containsString:@"Backdrop"];
}
static BOOL CCGFIsWallpaperClass(NSString *cn) {
    return [cn containsString:@"HomeScreenBackdrop"] || [cn containsString:@"Wallpaper"];
}

static BOOL CCGFMatInScope(UIView *v) {
    if (CCGFIsWallpaperClass(NSStringFromClass([v class]))) return NO;
    int hops = 0;
    for (UIView *cur = v; cur && hops < 14; cur = cur.superview, hops++) {
        NSString *cn = NSStringFromClass([cur class]);
        if (CCGFIsWallpaperClass(cn)) return NO;
        if (CCGFClassIsTarget(cn)) return YES;
        if ([cur isKindOfClass:[UIWindow class]])
            return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"]
                || [cn containsString:@"HomeScreen"];
    }
    return NO;
}

static BOOL CCGFFixMaterialView(UIView *v) {
    if (!gTargetUIColor) return NO;
    NSString *vcn = NSStringFromClass([v class]);
    BOOL isFolderBg = CCGFIsFolderBgClass(vcn);
    if (!CCGFIsMaterialClass(vcn) && !isFolderBg) return NO;
    if (!CCGFMatInScope(v)) return NO;
    BOOL did = NO;
    // 文件夹外面那层整屏背景: 铺不透明深色(不做透明), 但绝不干预它自身的显示/隐藏,
    // 这样系统关闭文件夹时的淡出动画能照常走完, 不会出现"背景延迟关闭"
    if (isFolderBg) {
        if ([v isKindOfClass:[UIVisualEffectView class]] && ((UIVisualEffectView *)v).effect != nil) {
            ((UIVisualEffectView *)v).effect = nil; did = YES;
        }
        // 只压掉内部材质/backdrop 子层, 其它子层一律不动(否则关闭动画不同步)
        for (UIView *s in v.subviews) {
            NSString *scn = NSStringFromClass([s class]);
            if (CCGFIsMaterialClass(scn)) {
                s.backgroundColor = [UIColor clearColor];
                if (!s.hidden) { s.hidden = YES; did = YES; }
            }
        }
        // 仅在它完整可见(未处于淡出)时铺色, 淡出过程中放手
        if (v.alpha > 0.98) {
            if (v.backgroundColor != gTargetUIColor) { v.backgroundColor = gTargetUIColor; did = YES; }
            if (v.layer.backgroundColor != gTargetColor) { v.layer.backgroundColor = gTargetColor; did = YES; }
        }
        if (did) gMatFixes++;
        [gMats addObject:v];
        return did;
    }
    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)v;
        if (ev.effect != nil) { ev.effect = nil; did = YES; }
    }
    for (UIView *s in v.subviews) {
        NSString *scn = NSStringFromClass([s class]);
        if (CCGFIsMaterialClass(scn) || [scn containsString:@"ContentView"]) {
            s.backgroundColor = [UIColor clearColor];
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
    NSString *cn = NSStringFromClass([v class]);
    if (CCGFIsMaterialClass(cn) || CCGFIsFolderBgClass(cn)) { if (CCGFFixMaterialView(v)) n++; }
    for (UIView *s in v.subviews) n += CCGFScanMaterials(s, depth - 1);
    return n;
}

static void CCGFWatchMaterials(void) {
    if (!gGlassDisabledCached || !gTargetUIColor || gMats.count == 0) return;
    for (UIView *v in gMats.allObjects) {
        if (CCGFIsFolderBgClass(NSStringFromClass([v class]))) {
            // 关闭动画进行中(alpha 下降)就完全放手
            if (v.alpha <= 0.98) continue;
            if (v.backgroundColor != gTargetUIColor) {
                if (CCGFFixMaterialView(v)) gWatchFixes++;
            }
            continue;
        }
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            if (((UIVisualEffectView *)v).effect != nil) {
                ((UIVisualEffectView *)v).effect = nil;
                v.backgroundColor = gTargetUIColor;
                gWatchFixes++;
            }
        } else if (CCGFFixMaterialView(v)) gWatchFixes++;
    }
}

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

static void CCGFApplyToView(UIView *win) {
    if (!gGlassDisabledCached || !gTargetColor) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CCGFRecolor(win.layer);
    [CATransaction commit];
    CCGFScanMaterials(win, 40);
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
            if (isCC || [cn containsString:@"Library"] || [cn containsString:@"HomeScreen"])
                CCGFApplyToView(w);
        }
    }
}

static void CCGFWatchPlates(void) {
    if (!gGlassDisabledCached || !gTargetColor || gPlates.count == 0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in gPlates.allObjects) {
        BOOL isFill = NO;
        if (CCGFWhiteColorOf(l, &isFill)) {
            if (isFill) ((CAShapeLayer *)l).fillColor = gTargetColor;
            else l.backgroundColor = gTargetColor;
            gWatchFixes++;
        }
    }
    [CATransaction commit];
}

// ---------------- 帧级录制 ----------------
static NSString *CCGFChain(CALayer *l, int max) {
    NSMutableString *ms = [NSMutableString string];
    int hops = 0;
    for (CALayer *cur = l; cur && hops < max; cur = cur.superlayer, hops++) {
        id d = cur.delegate;
        [ms appendFormat:@"%@/", d ? NSStringFromClass([d class]) : NSStringFromClass([cur class])];
    }
    return ms;
}

static void CCGFRecWalk(CALayer *l, double el) {
    if (gRecCount > 70) return;
    for (CALayer *s in l.sublayers) CCGFRecWalk(s, el);
    id d = l.delegate;
    NSString *dcn = d ? NSStringFromClass([d class]) : @"-";
    NSString *lcn = NSStringFromClass([l class]);
    BOOL white = CCGFColorIsWhite(l.backgroundColor);
    BOOL mat = CCGFIsMaterialClass(dcn) || CCGFIsMaterialClass(lcn);
    CGFloat w = l.frame.size.width, h = l.frame.size.height;
    if (!mat) {
        if (!white) return;
        if (w * h < 3000) return;
    }
    if (w * h < 200) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.0fx%.0f|%.0f|%d", lcn, dcn, w, h, l.cornerRadius, (int)white];
    if ([gRecKeys containsObject:key]) return;
    [gRecKeys addObject:key];
    gRecCount++;
    CCGFLog([NSString stringWithFormat:@"REC +%.0fms L=%@ dcn=%@ white=%d opacity=%.2f hides=%d size=%.0fx%.0f r=%.0f chain=%@",
             el, lcn, dcn, (int)white, l.opacity, (int)l.hidden, w, h, l.cornerRadius, CCGFChain(l, 5)]);
}

static void CCGFRecTick(void) {
    if (!gRec) return;
    double el = ([NSDate timeIntervalSinceReferenceDate] - gRecStart) * 1000.0;
    if (el > 1600) { gRec = NO; CCGFLog([NSString stringWithFormat:@"REC end count=%d", gRecCount]); return; }
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        for (UIWindow *w in app.windows) {
            NSString *cn = NSStringFromClass([w class]);
            if (![cn containsString:@"HomeScreen"] && ![cn containsString:@"Folder"]) continue;
            if (w.hidden) continue;
            CCGFRecWalk(w.layer, el);
        }
    }
}

static void CCGFStartRec(NSString *why) {
    if (gRec) return;
    gRec = YES;
    gRecStart = [NSDate timeIntervalSinceReferenceDate];
    if (!gRecKeys) gRecKeys = [NSMutableSet new];
    [gRecKeys removeAllObjects];
    gRecCount = 0;
    CCGFLog([NSString stringWithFormat:@"REC start (%@)", why]);
}

// ---------------- hooks ----------------
typedef void (*SetBGIMP)(id, SEL, CGColorRef);
static SetBGIMP gOrigSetBG = NULL;
static void CCGFSetBGColor(id self, SEL sel, CGColorRef color) {
    if (color && gTargetColor && gGlassDisabledCached && CCGFColorIsWhite(color)) {
        CALayer *layer = (CALayer *)self;
        if (CCGFLayerShapeOK(layer) && CCGFLayerInTarget(layer)) {
            color = gTargetColor; [gPlates addObject:layer]; gHookFixes++;
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
            color = gTargetUIColor; [gPlates addObject:v.layer]; gHookFixes++;
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
    if (!gTargetColor || !gGlassDisabledCached || !sub) return;
    id d = sub.delegate;
    if (d && [d isKindOfClass:[UIView class]]) {
        UIView *dv = (UIView *)d;
        NSString *dcn2 = NSStringFromClass([dv class]);
        if (CCGFIsMaterialClass(dcn2) || CCGFIsFolderBgClass(dcn2)) { if (CCGFFixMaterialView(dv)) gAddFixes++; return; }
        UIView *parent = dv.superview;
        if (parent && CCGFIsMaterialClass(NSStringFromClass([parent class])) && CCGFMatInScope(parent)) {
            dv.hidden = YES; gAddFixes++; return;
        }
    }
    if (CCGFLayerInTarget(sub)) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        gAddFixes += CCGFRecolorSub(sub);
        [CATransaction commit];
    }
}

// didMoveToWindow: 视图一进入层级就处理(早于首次绘制) + 触发录制
typedef void (*DidMoveIMP)(id, SEL);
static DidMoveIMP gOrigDidMove = NULL;
static void CCGFDidMoveToWindow(id self, SEL sel) {
    gOrigDidMove(self, sel);
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"Folder"] && ![cn containsString:@"Icon"] && ![cn containsString:@"Image"]) {
        CCGFStartRec(cn);
        // 动画开始前预热: 把整棵树的材质/底板先压成深色
        if (gTargetUIColor) {
            UIWindow *w = v.window;
            if (w) {
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                CCGFRecolor(w.layer);
                [CATransaction commit];
                CCGFScanMaterials(w, 40);
            }
        }
    }
    if (gTargetUIColor && gGlassDisabledCached
        && (CCGFIsMaterialClass(cn) || CCGFIsFolderBgClass(cn))) {
        if (CCGFFixMaterialView(v)) gAddFixes++;
    }
}

typedef id (*InitSceneIMP)(id, SEL, id);
typedef void (*SetHiddenIMP)(id, SEL, BOOL);
static void CCGFHookWin(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (sel == @selector(initWithWindowScene:)) {
        InitSceneIMP orig = (InitSceneIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id self, id scene) {
            id r = orig(self, sel, scene); CCGFTick(); return r;
        }));
    } else if (sel == @selector(setHidden:)) {
        SetHiddenIMP orig = (SetHiddenIMP)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL hidden) {
            orig(self, sel, hidden); if (!hidden) CCGFTick();
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
        if (m) { gOrigSetBG = (SetBGIMP)method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^void(id self, CGColorRef c){
                CCGFSetBGColor(self, @selector(setBackgroundColor:), c); })); }
        Method mv = class_getInstanceMethod([UIView class], @selector(setBackgroundColor:));
        if (mv) { gOrigUIViewSetBG = (UIViewSetBGIMP)method_getImplementation(mv);
            method_setImplementation(mv, imp_implementationWithBlock(^void(id self, UIColor *c){
                CCGFUIViewSetBG(self, @selector(setBackgroundColor:), c); })); }
        Method ma = class_getInstanceMethod([CALayer class], @selector(addSublayer:));
        if (ma) { gOrigAddSublayer = (AddSublayerIMP)method_getImplementation(ma);
            method_setImplementation(ma, imp_implementationWithBlock(^void(id self, CALayer *s){
                CCGFAddSublayer(self, @selector(addSublayer:), s); })); }
        Method md = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
        if (md) { gOrigDidMove = (DidMoveIMP)method_getImplementation(md);
            method_setImplementation(md, imp_implementationWithBlock(^void(id self){
                CCGFDidMoveToWindow(self, @selector(didMoveToWindow)); })); }
        Class winCls = NSClassFromString(@"SBControlCenterWindow");
        if (winCls) { CCGFHookWin(winCls, @selector(initWithWindowScene:));
                      CCGFHookWin(winCls, @selector(setHidden:)); }
        NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { CCGFTick(); } }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            @autoreleasepool { CCGFWatchPlates(); CCGFWatchMaterials(); CCGFRecTick(); }
        }] selector:@selector(main)];
        dl.preferredFramesPerSecond = 0;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCGFLog(@"v18 installed: folder-bg opaque + non-interfering fade");
    }
}
