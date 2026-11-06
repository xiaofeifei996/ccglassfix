// CCFixProbe v2 - dump CC 关键类的方法/属性 + 打开控制中心时的视图层级
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kHierPath = @"/var/tmp/ccview.txt";
static BOOL gDumpedHierarchy = NO;

static void AppendFile(NSString *path, NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:NO];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (NSException *e) {}
    [fh closeFile];
}

// ---------- 类结构 dump ----------
static void DumpClassInfo(NSString *out, Class cls) {
    NSMutableString *buf = [NSMutableString string];
    Class sup = class_getSuperclass(cls);
    [buf appendFormat:@"\n===== %s : %s =====\n", class_getName(cls), sup ? class_getName(sup) : "-"];

    unsigned int ivn = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivn);
    [buf appendString:@"-- ivars --\n"];
    for (unsigned int i = 0; i < ivn; i++)
        [buf appendFormat:@"  %s (%s)\n", ivar_getName(ivars[i]) ?: "?", ivar_getTypeEncoding(ivars[i]) ?: "?"];
    free(ivars);

    unsigned int pn = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pn);
    [buf appendString:@"-- properties --\n"];
    for (unsigned int i = 0; i < pn; i++)
        [buf appendFormat:@"  %s <%s>\n", property_getName(props[i]), property_getAttributes(props[i])];
    free(props);

    for (int meta = 0; meta < 2; meta++) {
        Class c = meta ? objc_getMetaClass(class_getName(cls)) : cls;
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(c, &mn);
        [buf appendFormat:@"-- %s methods --\n", meta ? "class" : "instance"];
        for (unsigned int i = 0; i < mn; i++)
            [buf appendFormat:@"  %s\n", sel_getName(method_getName(ms[i]))];
        free(ms);
    }
    AppendFile(out, buf);
}

static void DumpAllClassInfo(NSString *out) {
    NSArray *targets = @[
        @"CCUIControlCenterMaterialView",
        @"CCUIContentModuleBackgroundView",
        @"CCUISliderModuleBackgroundViewController",
        @"CCUICustomContentModuleBackgroundViewController",
        @"CCUIOverlayBackgroundView",
        @"CCUIButtonModuleView",
        @"CCUIMenuModuleItemView",
        @"CCUIRoundButton",
        @"CCUILabeledRoundButton",
        @"CCUIButtonModuleViewController",
        @"CCUIMainViewController",
        @"CCUIControlHostView",
        @"CCUIControlHostViewController",
    ];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    AppendFile(out, [NSString stringWithFormat:@"##### classinfo %@\n", [NSDate date]]);
    for (NSString *name in targets) {
        Class cls = NSClassFromString(name);
        if (!cls) { AppendFile(out, [name stringByAppendingString:@" NOT LOADED\n"]); continue; }
        DumpClassInfo(out, cls);
    }
}

// ---------- 视图层级 dump ----------
static void DumpView(UIView *v, int depth, NSMutableString *buf) {
    if (depth > 14 || buf.length > 500000) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    UIColor *bg = v.backgroundColor;
    UITraitCollection *tc = v.traitCollection;
    [buf appendFormat:@"%@%@ f=%@ a=%.2f h=%d o=%d style=%ld ovr=%ld",
        pad, NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
        v.alpha, (int)v.hidden, (int)v.opaque,
        (long)tc.userInterfaceStyle, (long)v.overrideUserInterfaceStyle];
    if (bg) [buf appendFormat:@" bg=%@", bg];
    if ([v isKindOfClass:NSClassFromString(@"UIVisualEffectView")]) {
        @try {
            id eff = [(id)v performSelector:NSSelectorFromString(@"effect")];
            if (eff) [buf appendFormat:@" EFF=%@", eff];
        } @catch (...) {}
    }
    [buf appendString:@"\n"];
    for (UIView *sub in v.subviews) DumpView(sub, depth + 1, buf);
}

static void DumpHierarchy(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIWindow *win in app.windows) {
        NSMutableString *probe = [NSMutableString string];
        // 先快速判断这扇窗口里有没有 CCUI 视图
        __block BOOL hasCC = NO;
        NSMutableArray *stack = [win.subviews mutableCopy];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            NSString *cn = NSStringFromClass([v class]);
            if ([cn hasPrefix:@"CCUI"] || [cn hasPrefix:@"SBControl"]) { hasCC = YES; break; }
            [stack addObjectsFromArray:v.subviews];
        }
        if (!hasCC) continue;
        NSMutableString *buf = [NSMutableString string];
        [buf appendFormat:@"\n##### WINDOW %@ level=%.0f hidden=%d style=%ld %@\n",
            NSStringFromClass([win class]), win.windowLevel, (int)win.hidden,
            (long)win.traitCollection.userInterfaceStyle, [NSDate date]];
        DumpView(win, 0, buf);
        AppendFile(kHierPath, buf);
        gDumpedHierarchy = YES;
    }
}

__attribute__((constructor)) static void CCFixProbeInit(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:kHierPath error:nil];
        AppendFile(kHierPath, [NSString stringWithFormat:@"##### ccprobe v2 pid=%d %@\n",
                               getpid(), [NSDate date]]);
        DumpAllClassInfo(@"/var/tmp/ccclass.txt");
        __block int n = 0;
        __block int dumps = 0;
        NSTimer *t = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            @autoreleasepool {
                if (!gDumpedHierarchy) { DumpHierarchy(); if (gDumpedHierarchy) dumps++; }
                else { gDumpedHierarchy = NO; } // 每次 DumpHierarchy 由内部置位
                if (++n > 150 || dumps >= 6) [timer invalidate];
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    }
}
