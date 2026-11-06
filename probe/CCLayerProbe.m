// CCLayerProbe - 控制中心打开时, 找出所有带背景色的 CALayer (定位白色底板)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kPath = @"/var/tmp/cclayers.txt";
static BOOL gDumped = NO;

static void Log(NSString *msg) {
    @autoreleasepool {
        NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kPath])
            [d writeToFile:kPath atomically:NO];
        else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kPath];
            if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; } @catch(...){} [fh closeFile]; }
        }
    }
}

static NSString *ColorDesc(CGColorRef c) {
    if (!c) return @"nil";
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *co = CGColorGetComponents(c);
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%.2f ", co[i]];
    return s;
}

static void WalkLayer(CALayer *layer, int depth, UIView *ccWin) {
    if (depth > 20) return;
    CGColorRef bg = layer.backgroundColor;
    if (bg) {
        const CGFloat *co = CGColorGetComponents(bg);
        size_t n = CGColorGetNumberOfComponents(bg);
        // 找白色/浅色 (前几个分量都 > 0.8) 或任何带背景色的层
        BOOL white = n >= 3 && co[0] > 0.8 && co[1] > 0.8 && co[2] > 0.8;
        CGFloat alpha = n >= 4 ? co[n-1] : (n==2 ? co[1] : 1.0);
        id delegate = layer.delegate;
        NSString *viewCls = delegate ? NSStringFromClass([delegate class]) : @"-";
        NSMutableString *pad = [NSMutableString string];
        for (int i=0;i<depth;i++) [pad appendString:@" "];
        Log([NSString stringWithFormat:@"%@[%@] bg=(%@) a=%.2f r=%.1f f=%@ view=%@ %@",
             pad, NSStringFromClass([layer class]), ColorDesc(bg), alpha,
             layer.cornerRadius, NSStringFromCGRect(layer.frame), viewCls,
             white ? @"<<< WHITE" : @""]);
    }
    for (CALayer *sub in layer.sublayers) WalkLayer(sub, depth+1, ccWin);
}

static void TryDump(void) {
    if (gDumped) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIWindow *w in app.windows) {
        if ([w isKindOfClass:NSClassFromString(@"SBControlCenterWindow")] && !w.hidden && w.alpha > 0.5) {
            Log([NSString stringWithFormat:@"\n##### CC OPEN %@ frame=%@", [NSDate date], NSStringFromCGRect(w.frame)]);
            WalkLayer(w.layer, 0, w);
            gDumped = YES;
        }
    }
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        Log([NSString stringWithFormat:@"cclayerprobe loaded pid=%d", getpid()]);
        NSTimer *t = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tm){
            @autoreleasepool { TryDump(); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    }
}
