// CCGlassFix v29 - 仅控制中心: 在白色背景图层内部插入同形子层盖住白色
// 原理: CALayer 的 sublayer 永远绘制在该层 backgroundColor 之上,
//       所以系统无论怎么重绘白色背景, 都盖不住我们插入的子层。
// 作用域: 仅 SBControlCenterWindow; 不碰窗口背景、不碰主屏/资源库/文件夹/菜单。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/tmp/ccglassfix.log";
static NSString *const kTintName = @"CCGFTint";
static CGFloat gGray = 0.13;
static CGFloat gAlpha = 0.92;
static CGColorRef gTargetColor = NULL;
static BOOL gGlassDisabled = NO;
static int gStamped = 0;
static NSTimeInterval gLastLog = 0;

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
    }
}

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

static BOOL CCGFIsCCWindow(UIWindow *w) {
    NSString *cn = NSStringFromClass([w class]);
    return [cn containsString:@"ControlCenter"] || [cn containsString:@"SBControl"];
}

// 模块库(添加控制)页面: 里面是小尺寸预览图标, 不处理
static NSHashTable *gSkipRoots = nil;

static BOOL CCGFInGallery(UIView *v) {
    int hops = 0;
    for (UIView *cur = v; cur && hops < 30; cur = cur.superview, hops++) {
        if (!gSkipRoots) gSkipRoots = [NSHashTable weakObjectsHashTable];
        if ([gSkipRoots containsObject:cur]) return YES;
        NSString *cn = NSStringFromClass([cur class]);
        if ([cn containsString:@"Gallery"] || [cn containsString:@"Picker"]
            || [cn containsString:@"SearchControl"] || [cn containsString:@"Editor"]
            || [cn containsString:@"LibraryView"]) return YES;
    }
    return NO;
}

// 窗口背景/壁纸层不动
static BOOL CCGFIsBgClass(NSString *cn) {
    return [cn containsString:@"Background"] || [cn containsString:@"Backdrop"]
        || [cn containsString:@"Wallpaper"] || [cn containsString:@"Window"];
}

// 核心: 在白色图层内插入同形子层
static int CCGFStamp(CALayer *l, int depth) {
    if (depth > 45 || !l) return 0;
    int n = 0;
    for (CALayer *sub in l.sublayers) n += CCGFStamp(sub, depth + 1);

    if ([l.name isEqualToString:kTintName]) return n;
    id d = l.delegate;
    if (d && [d isKindOfClass:[UIView class]]) {
        if (CCGFIsBgClass(NSStringFromClass([d class]))) return n;
        if (CCGFInGallery((UIView *)d)) return n;   // 模块库页面不处理
    }
    // 已经盖过
    for (CALayer *c in l.sublayers) if ([c.name isEqualToString:kTintName]) return n;

    CGFloat w = l.bounds.size.width, h = l.bounds.size.height;
    if (w < 8 || h < 8 || w * h < 900) return n;

    BOOL white = CCGFNearWhite(l.backgroundColor);
    if (!white) white = CCGFNearWhite(l.borderColor) ? NO : NO;  // 只用背景/fill 判定
    if (!white && [l isKindOfClass:[CAShapeLayer class]])
        white = CCGFNearWhite(((CAShapeLayer *)l).fillColor);
    if (!white) return n;

    // 圆角: 优先用图层自身; 否则按形状推断(圆形/胶囊)
    CGFloat r = l.cornerRadius;
    if (r <= 0.5) {
        if (fabs(w - h) < 2.0) r = w / 2.0;
        else if (h < w * 0.66) r = h / 2.0;
    }
    // 直接改色(最快见效, 也消掉白边本身的来源)
    if (CCGFNearWhite(l.backgroundColor)) l.backgroundColor = gTargetColor;
    if ([l isKindOfClass:[CAShapeLayer class]]
        && CCGFNearWhite(((CAShapeLayer *)l).fillColor)) {
        ((CAShapeLayer *)l).fillColor = gTargetColor;
    }

    // 再叠一层向外扩 2pt 的不透明深色, 由父层按原圆角裁掉 -> 抗锯齿白边被外部覆盖
    CALayer *tint = [CALayer layer];
    tint.name = kTintName;
    tint.frame = CGRectInset(l.bounds, -2.0, -2.0);
    tint.backgroundColor = gTargetColor;
    tint.allowsEdgeAntialiasing = YES;
    if (r > 0.5) {
        // 父层裁剪: 与白色背景同一圆角轮廓, 不多不少
        l.masksToBounds = YES;
        l.allowsEdgeAntialiasing = YES;
        if (l.cornerRadius <= 0.5) l.cornerRadius = r;
        if (@available(iOS 13.0, *)) l.cornerCurve = kCACornerCurveContinuous;
    }
    [l insertSublayer:tint atIndex:0];   // 图标等原有子层仍在其上
    gStamped++;
    return n + 1;
}

static void CCGFTick(void) {
    @autoreleasepool {
        gGlassDisabled = CCGFGlassOff();
        if (!gGlassDisabled || !gTargetColor) return;
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;
        for (UIWindow *w in app.windows) {
            if (w.hidden || w.alpha < 0.05 || !CCGFIsCCWindow(w)) continue;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            CCGFStamp(w.layer, 0);
            [CATransaction commit];
        }
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastLog > 5.0) {
            gLastLog = now;
            CCGFLog([NSString stringWithFormat:@"tick stamped=%d", gStamped]);
        }
    }
}

__attribute__((constructor)) static void CCGlassFixInit(void) {
    @autoreleasepool {
        CCGFLoadColor();
        gGlassDisabled = CCGFGlassOff();
        CCGFLog([NSString stringWithFormat:@"loaded pid=%d gray=%.2f v31", getpid(), gGray]);
        NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { CCGFTick(); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            @autoreleasepool { CCGFTick(); }
        }] selector:@selector(main)];
        dl.preferredFramesPerSecond = 20;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCGFLog(@"v31 installed: + skip gallery/picker page");
    }
}
