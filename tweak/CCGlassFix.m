// CCGlassFix v16 - 材质层压暗 + 文件夹整屏背景(SBFolderControllerBackgroundView)直接压深色
// v21: 资源库表头/包边毛玻璃改为透明(不再铺实色, 消除硬边方块)
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


// 控制中心专用: 把"开启态"的白色实底(含渐变)压成深色, 贴近 iOS 18 的深灰控件
static BOOL CCGFColorNearWhite(CGColorRef c) {
    if (!c) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *co = CGColorGetComponents(c);
    if (!co) return NO;
    CGFloat r, g, b, a;
    if (n >= 4) { r = co[0]; g = co[1]; b = co[2]; a = co[3]; }
    else if (n == 2) { r = g = b = co[0]; a = co[1]; }
    else return NO;
    return r > 0.72 && g > 0.72 && b > 0.72 && a > 0.4;
}

static int CCGFCCStrongRecolor(CALayer *l) {
    int changed = 0;
    for (CALayer *sub in l.sublayers) changed += CCGFCCStrongRecolor(sub);
    CGFloat w = l.frame.size.width, h = l.frame.size.height;
    if (w * h < 600) return changed;
    BOOL did = NO;
    if (CCGFColorNearWhite(l.backgroundColor)) { l.backgroundColor = gTargetColor; did = YES; }
    if ([l isKindOfClass:[CAShapeLayer class]]) {
        CGColorRef f = ((CAShapeLayer *)l).fillColor;
        if (CCGFColorNearWhite(f)) { ((CAShapeLayer *)l).fillColor = gTargetColor; did = YES; }
    }
    if ([l isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *g = (CAGradientLayer *)l;
        NSArray *cols = g.colors;
        BOOL anyWhite = NO;
        for (id c in cols) {
            if (CFGetTypeID((__bridge CFTypeRef)c) == CGColorGetTypeID()
                && CCGFColorNearWhite((__bridge CGColorRef)c)) { anyWhite = YES; break; }
        }
        if (anyWhite) {
            NSMutableArray *nw = [NSMutableArray array];
            for (NSUInteger i = 0; i < cols.count; i++) [nw addObject:(__bridge id)gTargetColor];
            g.colors = nw; did = YES;
        }
    }
    if (did) { [gPlates addObject:l]; changed++; }
    return changed;
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
static const void *kFolderTintKey = &kFolderTintKey;

static BOOL CCGFIsFolderBgClass(NSString *cn) {
    return [cn containsString:@"SBFolderControllerBackground"]
        || [cn containsString:@"FolderControllerBackground"];
}
static BOOL CCGFIsMaterialClass(NSString *cn) {
    return [cn containsString:@"VisualEffect"] || [cn containsString:@"Material"]
        || [cn containsString:@"Backdrop"];
}
// 表头/包边毛玻璃: SBFFeatherBlurView / 表头 之类, 铺实色会变成一块硬边方块
static BOOL CCGFIsFeatherBlur(UIView *v) {
    int hops = 0;
    for (UIView *cur = v; cur && hops < 8; cur = cur.superview, hops++) {
        NSString *cn = NSStringFromClass([cur class]);
        if ([cn containsString:@"FeatherBlur"] || [cn containsString:@"HeaderView"]
            || [cn containsString:@"TableHeader"]) return YES;
    }
    return NO;
}

static BOOL CCGFIsWallpaperClass(NSString *cn) {
    return [cn containsString:@"HomeScreenBackdrop"] || [cn containsString:@"Wallpaper"];
}

// 上下文菜单/编辑菜单: 一律不碰(保持系统原样)
static BOOL CCGFIsMenuClass(NSString *cn) {
    return [cn containsString:@"ContextMenu"] || [cn containsString:@"EditMenu"]
        || [cn containsString:@"CalloutBar"] || [cn containsString:@"UIEditMenu"]
        || [cn containsString:@"PlatterView"] || [cn containsString:@"MenuContainer"];
}

static BOOL CCGFMatInScope(UIView *v) {
    if (CCGFIsWallpaperClass(NSStringFromClass([v class]))) return NO;
    int hops = 0;
    for (UIView *cur = v; cur && hops < 14; cur = cur.superview, hops++) {
        NSString *cn = NSStringFromClass([cur class]);
        if (CCGFIsWallpaperClass(cn)) return NO;
        if (CCGFIsMenuClass(cn)) return NO;          // 菜单内部不动
        if (CCGFClassIsTarget(cn)) return YES;       // Search / Folder / Library 子树
        if ([cur isKindOfClass:[UIWindow class]])
            return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
        // 主屏窗口本身不算作用域: 必须靠上面的 Search/Folder/Library 命中
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
    // 文件夹外面那层整屏背景:
    // 不直接改它的 backgroundColor/alpha(否则系统关闭动画淡出时不同步, 出现"延迟关闭")。
    // 做法: 压掉内部材质 -> 再挂一个自绘深色子视图。子视图自动继承父层 alpha 动画,
    // 打开/关闭/淡出全程与系统同一时钟, 天然同步。
    if (isFolderBg) {
        if ([v isKindOfClass:[UIVisualEffectView class]] && ((UIVisualEffectView *)v).effect != nil) {
            ((UIVisualEffectView *)v).effect = nil; did = YES;
        }
        for (UIView *sub in v.subviews) {
            NSString *scn = NSStringFromClass([sub class]);
            if (CCGFIsMaterialClass(scn)) {
                sub.backgroundColor = [UIColor clearColor];
                if (!sub.hidden) { sub.hidden = YES; did = YES; }
            }
        }
        UIView *tint = objc_getAssociatedObject(v, &kFolderTintKey);
        if (!tint) {
            tint = [[UIView alloc] initWithFrame:v.bounds];
            tint.backgroundColor = gTargetUIColor;
            tint.userInteractionEnabled = NO;
            tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [v insertSubview:tint atIndex:0];
            objc_setAssociatedObject(v, &kFolderTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            did = YES;
        }
        if (!CGRectEqualToRect(tint.frame, v.bounds)) tint.frame = v.bounds;
        if (did) gMatFixes++;
        [gMats addObject:v];
        return did;
    }

    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)v;
        if (ev.effect != nil) { ev.effect = nil; did = YES; }
    }
    BOOL feather = CCGFIsFeatherBlur(v);
    for (UIView *s in v.subviews) {
        NSString *scn = NSStringFromClass([s class]);
        if (CCGFIsMaterialClass(scn) || [scn containsString:@"ContentView"]) {
            s.backgroundColor = [UIColor clearColor];
            if (!s.hidden) { s.hidden = YES; did = YES; }
        }
    }
    if (feather) {
        // 表头/包边: 透明, 让壁纸透出来(铺实色会出现上方那块硬边方块)
        if (v.backgroundColor != [UIColor clearColor]) { v.backgroundColor = [UIColor clearColor]; did = YES; }
        if (v.layer.backgroundColor != NULL) { v.layer.backgroundColor = NULL; did = YES; }
    } else if (v.backgroundColor != gTargetUIColor) {
        v.backgroundColor = gTargetUIColor; did = YES;
    }
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
            UIView *tint = objc_getAssociatedObject(v, &kFolderTintKey);
            if (!tint || tint.superview != v) { if (CCGFFixMaterialView(v)) gWatchFixes++; }
            continue;
        }
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            if (((UIVisualEffectView *)v).effect != nil) {
                ((UIVisualEffectView *)v).effect = nil;
                v.backgroundColor = CCGFIsFeatherBlur(v) ? [UIColor clearColor] : gTargetUIColor;
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

static int CCGFScanMaterials(UIView *v, int depth);
static void CCGFCCViewDump(UIWindow *w);

static const void *kCCTintKey = &kCCTintKey;

static BOOL CCGFInCCWindow(UIView *v) {
    int hops = 0;
    for (UIView *cur = v; cur && hops < 20; cur = cur.superview, hops++) {
        if ([cur isKindOfClass:[UIWindow class]]) {
            NSString *cn = NSStringFromClass([cur class]);
            return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
        }
    }
    return NO;
}

// 在材质之上、内容之下插入自绘深色底 —— 系统重绘颜色换不掉它
static BOOL CCGFAddCCTint(UIView *v) {
    if (!gTargetUIColor) return NO;
    UIView *tint = objc_getAssociatedObject(v, &kCCTintKey);
    if (tint && tint.superview == v) return NO;
    // 跳过内部已有 material 子视图之后的层级, 让内容仍然可见
    NSUInteger idx = 0;
    for (NSUInteger i = 0; i < v.subviews.count; i++) {
        NSString *scn = NSStringFromClass([v.subviews[i] class]);
        if (CCGFIsMaterialClass(scn) || [scn containsString:@"Backdrop"]
            || [scn containsString:@"ContentView"]) idx = i + 1; else break;
    }
    tint = [[UIView alloc] initWithFrame:v.bounds];
    tint.backgroundColor = gTargetUIColor;
    tint.userInteractionEnabled = NO;
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (idx > v.subviews.count) idx = v.subviews.count;
    [v insertSubview:tint atIndex:idx];
    objc_setAssociatedObject(v, &kCCTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// 视图类名清单(控制中心)
static int gVCDumps = 0;
static NSTimeInterval gVCLast = 0;
static int gVCCount = 0;
static void CCGFViewDump(UIView *v, int depth) {
    if (gVCCount > 90) return;
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    NSString *cn = NSStringFromClass([v class]);
    BOOL bg = v.backgroundColor && v.backgroundColor != [UIColor clearColor];
    if (w * h >= 900) {
        gVCCount++;
        CCGFLog([NSString stringWithFormat:@"VDUMP d=%d %@ %.0fx%.0f bg=%@ alpha=%.2f",
                 depth, cn, w, h, bg ? [NSString stringWithFormat:@"%.0f%%", v.backgroundColor.CGColor ? 100.0 : 0.0] : @"-", v.alpha]);
    }
    if (depth >= 6) return;
    for (UIView *s in v.subviews) CCGFViewDump(s, depth + 1);
}
static void CCGFCCViewDump(UIWindow *w) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gVCDumps >= 2 || now - gVCLast < 12.0) return;
    gVCLast = now; gVCDumps++; gVCCount = 0;
    CCGFViewDump(w, 0);
    CCGFLog([NSString stringWithFormat:@"VDUMP end #%d count=%d", gVCDumps, gVCCount]);
}
static int CCGFCCStrongRecolor(CALayer *l);
static NSString *CCGFChain(CALayer *l, int max);
static void CCGFCCDiag(UIWindow *w);

// 只在目标子树上改色(主屏窗口用)
static int CCGFRecolorViewScoped(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    if (CCGFClassIsTarget(NSStringFromClass([v class]))) return CCGFRecolor(v.layer);
    int n = 0;
    for (UIView *s in v.subviews) n += CCGFRecolorViewScoped(s, depth - 1);
    return n;
}
static int CCGFRecolorScoped(UIView *w) { return CCGFRecolorViewScoped(w, 10); }

// 只在目标子树上处理材质
static int CCGFScanMaterialsScoped(UIView *v, int depth) {
    if (depth <= 0 || !v) return 0;
    NSString *cn = NSStringFromClass([v class]);
    if (CCGFClassIsTarget(cn)) return CCGFScanMaterials(v, depth);
    int n = 0;
    for (UIView *s in v.subviews) n += CCGFScanMaterialsScoped(s, depth - 1);
    return n;
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
            if (isCC) {
                CCGFApplyToView(w);
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                int strong = CCGFCCStrongRecolor(w.layer);
                [CATransaction commit];
                NSTimeInterval n1 = [NSDate timeIntervalSinceReferenceDate];
                if (n1 - gLastLogTime > 2.0) {
                    gLastLogTime = n1;
                    CCGFLog([NSString stringWithFormat:@"CC strong=%d plates=%lu mats=%lu matFix=%d",
                             strong, (unsigned long)gPlates.count, (unsigned long)gMats.count, gMatFixes]);
                }
                CCGFCCDiag(w);
                CCGFCCViewDump(w);
                continue;
            }
            if ([cn containsString:@"Library"]) { CCGFApplyToView(w); continue; }
            if ([cn containsString:@"HomeScreen"]) {
                // 主屏: 只处理 Search/Folder/Library 子树, 不动菜单与其它材质
                if (!gGlassDisabledCached || !gTargetColor) continue;
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                CCGFRecolorScoped(w);
                [CATransaction commit];
                CCGFScanMaterialsScoped(w, 12);
            }
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
// ---------------- 控制中心白色图层诊断 ----------------
static int gCCDumps = 0;
static NSTimeInterval gCCLastDump = 0;
static int gCCDiagCount = 0;

static void CCGFCCDiagWalk(CALayer *l, double depth) {
    if (gCCDiagCount > 55) return;
    for (CALayer *sub in l.sublayers) CCGFCCDiagWalk(sub, depth + 1);
    if (depth > 12) return;
    BOOL white = CCGFColorIsWhite(l.backgroundColor);
    CGColorRef fill = nil;
    if ([l isKindOfClass:[CAShapeLayer class]]) fill = ((CAShapeLayer *)l).fillColor;
    BOOL fillWhite = CCGFColorIsWhite(fill);
    // 渐变层白色
    BOOL gradWhite = NO;
    if ([l isKindOfClass:[CAGradientLayer class]]) {
        for (id c in ((CAGradientLayer *)l).colors) {
            if (CFGetTypeID((__bridge CFTypeRef)c) == CGColorGetTypeID()
                && CCGFColorIsWhite((__bridge CGColorRef)c)) { gradWhite = YES; break; }
        }
    }
    BOOL hasContents = (l.contents != nil) && (l.contents != (id)[NSNull null]);
    CGFloat w = l.frame.size.width, h = l.frame.size.height;
    if (w * h < 800) return;
    if (!(white || fillWhite || gradWhite) && !(hasContents && l.cornerRadius >= 10 && w*h > 3000)) return;
    gCCDiagCount++;
    id d = l.delegate;
    CCGFLog([NSString stringWithFormat:@"CCDIAG cls=%@ dcn=%@ bgW=%d fillW=%d gradW=%d contents=%d size=%.0fx%.0f r=%.0f chain=%@",
             NSStringFromClass([l class]),
             d ? NSStringFromClass([d class]) : @"-",
             (int)white, (int)fillWhite, (int)gradWhite, (int)hasContents,
             w, h, l.cornerRadius, CCGFChain(l, 4)]);
}

static void CCGFCCDiag(UIWindow *w) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gCCDumps >= 3 || now - gCCLastDump < 10.0) return;
    gCCLastDump = now; gCCDumps++;
    gCCDiagCount = 0;
    CCGFCCDiagWalk(w.layer, 0);
    CCGFLog([NSString stringWithFormat:@"CCDIAG end #%d count=%d", gCCDumps, gCCDiagCount]);
}

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
        CCGFLog(@"v25 installed: CC tint subview + view dump");
    }
}
