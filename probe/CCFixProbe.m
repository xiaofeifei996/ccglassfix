// CCFixProbe - 注入 SpringBoard，增量枚举 ObjC 类名，用于定位 iOS 26 控制中心模块底板类
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kOutPath = @"/var/tmp/ccdump.txt";
static NSMutableSet<NSString *> *gSeen = nil;
static int gTick = 0;

static void Append(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kOutPath]) {
        [data writeToFile:kOutPath atomically:NO];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kOutPath];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
    } @catch (NSException *e) {
    }
    [fh closeFile];
}

static NSArray<NSString *> *SnapshotClasses(NSMutableString *delta) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return @[];
    count = objc_getClassList(classes, count);
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        const char *nm = class_getName(classes[i]);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (name.length == 0) continue;
        if (![gSeen containsObject:name]) {
            [gSeen addObject:name];
            [fresh addObject:name];
        }
    }
    free(classes);
    return fresh;
}

static void DumpTick(void) {
    gTick++;
    NSMutableString *delta = [NSMutableString string];
    NSArray<NSString *> *fresh = SnapshotClasses(delta);
    if (fresh.count == 0) return;

    NSMutableString *buf = [NSMutableString string];
    [buf appendFormat:@"\n===== tick %d (t=%ds) new=%lu total=%lu =====\n",
                       gTick, gTick * 3, (unsigned long)fresh.count, (unsigned long)gSeen.count];
    for (NSString *n in fresh) {
        Class cls = NSClassFromString(n);
        Class sup = cls ? class_getSuperclass(cls) : Nil;
        [buf appendFormat:@"%@ ::: %s\n", n, sup ? class_getName(sup) : "-"];
    }
    Append(buf);
}

__attribute__((constructor)) static void CCFixProbeInit(void) {
    @autoreleasepool {
        gSeen = [NSMutableSet set];
        Append([NSString stringWithFormat:@"\n##### ccprobe start pid=%d %@\n",
                                          getpid(), [NSDate date]]);
        DumpTick();
        __block int ticks = 0;
        NSTimer *t = [NSTimer timerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
            @autoreleasepool {
                DumpTick();
                if (++ticks > 200) [timer invalidate];
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    }
}
