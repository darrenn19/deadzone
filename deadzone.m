// deadzone.m — squeeze the whole Mac desktop into the undamaged part of the
// built-in screen.
//
// How it works: creates a virtual display the size of the good area, makes it
// the main display (menu bar + Dock move there), and shows it live on the
// built-in screen next to the damaged strip. The mouse is kept on the virtual
// display and windows left on the built-in screen are moved over.
//
// Build (once):
//   clang -fobjc-arc deadzone.m -o deadzone -framework Cocoa -framework ScreenCaptureKit \
//     -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon
// Run:
//   ./deadzone 0.25 left        (fraction of width that is damaged, and which side)
// Quit:  Control + Option + Command + Q   (or Ctrl+C in Terminal)
// Everything returns to normal the moment the program quits.
// To run it in the background at every login, use install.sh instead.

#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>

// ---- Private CoreGraphics virtual display API (the same one BetterDisplay uses) ----
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
- (void)setDispatchQueue:(dispatch_queue_t)q;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@end

// ---- State ----
static CGFloat gFraction = 0.25;
static BOOL gRight = NO;
static CGDirectDisplayID gBuiltin = 0, gVirtualID = 0;
static CGFloat gW, gH, gDeadW, gVW;
static CGVirtualDisplay *gVirtual;
static NSWindow *gWin;
static CALayer *gLayer;
static SCStream *gStream;
static id gOutput;
static CFAbsoluteTime gLastFrame = 0;

static void fail(NSString *msg) {
    fprintf(stderr, "\ndeadzone: %s\n", msg.UTF8String);
    exit(1);   // quitting undoes everything automatically
}

static NSScreen *screenForID(CGDirectDisplayID d) {
    for (NSScreen *s in NSScreen.screens) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (n.unsignedIntValue == d) return s;
    }
    return nil;
}

// ---- Receives live frames of the virtual display ----
@interface FrameOut : NSObject <SCStreamOutput, SCStreamDelegate>
@end
@implementation FrameOut
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!arr || CFArrayGetCount(arr) < 1) return;
    NSDictionary *att = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, 0);
    NSNumber *status = att[SCStreamFrameInfoStatus];
    if (status && status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
    if (!surf) return;
    id surface = (__bridge id)surf;
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gLayer.contents = surface;
        [CATransaction commit];
        gLastFrame = CFAbsoluteTimeGetCurrent();
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fail([NSString stringWithFormat:@"screen capture stopped: %@", error.localizedDescription]);
}
@end

// ---- Emergency quit hotkey: Control + Option + Command + Q ----
static OSStatus hotKeyHandler(EventHandlerCallRef c, EventRef e, void *u) {
    fprintf(stderr, "\ndeadzone: quit hotkey pressed, restoring screen.\n");
    exit(0);
    return noErr;
}
static void registerHotKey(void) {
    EventTypeSpec t = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&hotKeyHandler, 1, &t, NULL, NULL);
    EventHotKeyID hid = { 'dzon', 1 };
    EventHotKeyRef ref;
    RegisterEventHotKey(kVK_ANSI_Q, cmdKey | optionKey | controlKey, hid,
                        GetApplicationEventTarget(), 0, &ref);
}

// ---- Step 1: create the virtual display ----
static void createVirtualDisplay(void) {
    Class descC = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class dispC = NSClassFromString(@"CGVirtualDisplay");
    Class setC  = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeC = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descC || !dispC || !setC || !modeC) fail(@"this version of macOS has no virtual display support.");

    CGVirtualDisplayDescriptor *d = [[descC alloc] init];
    if ([d respondsToSelector:@selector(setDispatchQueue:)]) [d setDispatchQueue:dispatch_get_main_queue()];
    else d.queue = dispatch_get_main_queue();
    d.name = @"Deadzone";
    d.maxPixelsWide = (unsigned int)(gVW * 2);
    d.maxPixelsHigh = (unsigned int)(gH * 2);
    CGSize mm = CGDisplayScreenSize(gBuiltin);
    if (mm.width < 1) mm = CGSizeMake(286, 179);
    d.sizeInMillimeters = CGSizeMake(mm.width * gVW / gW, mm.height);
    d.productID = 0xF1C5;
    d.vendorID = 0xF1C5;
    d.serialNum = 1;

    gVirtual = [[dispC alloc] initWithDescriptor:d];
    if (!gVirtual) fail(@"could not create the virtual display.");

    CGVirtualDisplaySettings *s = [[setC alloc] init];
    s.hiDPI = 1;
    s.modes = @[ [[modeC alloc] initWithWidth:(unsigned int)gVW height:(unsigned int)gH refreshRate:60] ];
    if (![gVirtual applySettings:s]) fail(@"could not configure the virtual display.");
    gVirtualID = gVirtual.displayID;
    printf("Virtual display created (%d x %d).\n", (int)gVW, (int)gH);
}

// ---- Step 2: make the virtual display the main one (menu bar + Dock go there) ----
static void arrangeDisplays(void) {
    CGRect vb = CGDisplayBounds(gVirtualID);
    if (vb.size.width < 1) fail(@"the virtual display did not appear.");
    CGDisplayConfigRef cfg;
    CGBeginDisplayConfiguration(&cfg);
    CGConfigureDisplayOrigin(cfg, gVirtualID, 0, 0);
    CGConfigureDisplayOrigin(cfg, gBuiltin, (int32_t)vb.size.width, 0);
    // "ForAppOnly" = macOS undoes this automatically when deadzone quits
    if (CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly) != kCGErrorSuccess)
        fail(@"could not rearrange displays.");
}

// ---- Keep the mouse on the virtual display ----
static void clampMouse(void) {
    CGEventRef ev = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(ev);
    CFRelease(ev);
    CGRect vb = CGDisplayBounds(gVirtualID);
    if (CGRectContainsPoint(vb, p)) return;
    CGPoint q = CGPointMake(MIN(MAX(p.x, vb.origin.x), CGRectGetMaxX(vb) - 1),
                            MIN(MAX(p.y, vb.origin.y), CGRectGetMaxY(vb) - 1));
    CGWarpMouseCursorPosition(q);
    CGAssociateMouseAndMouseCursorPosition(true);
}

// ---- Move any window sitting on the (hidden) built-in screen onto the virtual one ----
static void moveStrayWindows(void) {
    CGRect bb = CGDisplayBounds(gBuiltin);
    CGRect vb = CGDisplayBounds(gVirtualID);
    pid_t me = getpid();
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular || app.processIdentifier == me) continue;
        AXUIElementRef a = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(a, 0.3);
        CFArrayRef wins = NULL;
        if (AXUIElementCopyAttributeValue(a, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
            for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
                CFTypeRef pv = NULL, sv = NULL;
                if (AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &pv) != kAXErrorSuccess) continue;
                if (AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sv) != kAXErrorSuccess) { CFRelease(pv); continue; }
                CGPoint pos; CGSize size;
                AXValueGetValue((AXValueRef)pv, kAXValueTypeCGPoint, &pos);
                AXValueGetValue((AXValueRef)sv, kAXValueTypeCGSize, &size);
                CFRelease(pv); CFRelease(sv);
                CGPoint c = CGPointMake(pos.x + size.width / 2, pos.y + size.height / 2);
                if (!CGRectContainsPoint(bb, c)) continue;
                CGSize ns = CGSizeMake(MIN(size.width, vb.size.width), MIN(size.height, vb.size.height - 30));
                CGPoint np = CGPointMake(vb.origin.x + (vb.size.width - ns.width) / 2, vb.origin.y + 30);
                AXValueRef npv = AXValueCreate(kAXValueTypeCGPoint, &np);
                AXValueRef nsv = AXValueCreate(kAXValueTypeCGSize, &ns);
                AXUIElementSetAttributeValue(w, kAXPositionAttribute, npv);
                AXUIElementSetAttributeValue(w, kAXSizeAttribute, nsv);
                AXUIElementSetAttributeValue(w, kAXPositionAttribute, npv);
                CFRelease(npv); CFRelease(nsv);
            }
            CFRelease(wins);
        }
        CFRelease(a);
    }
}

// ---- Step 3: black cover on the built-in screen + live picture in the good area ----
static void showOnBuiltin(void) {
    NSScreen *bs = screenForID(gBuiltin);
    if (!bs) fail(@"lost track of the built-in screen.");
    NSRect f = bs.frame;

    gWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    [gWin setFrame:f display:NO];
    gWin.backgroundColor = NSColor.blackColor;
    gWin.opaque = YES;
    gWin.hasShadow = NO;
    gWin.ignoresMouseEvents = YES;
    gWin.level = NSScreenSaverWindowLevel;
    gWin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorFullScreenAuxiliary |
                              NSWindowCollectionBehaviorIgnoresCycle;
    NSView *v = gWin.contentView;
    v.wantsLayer = YES;
    v.layer.backgroundColor = NSColor.blackColor.CGColor;

    // Size the picture from the virtual display's REAL size (macOS may not pick
    // exactly the size we asked for), fill the full height, and push it flush
    // against the good edge so no screen is wasted on that side.
    CGSize vs = CGDisplayBounds(gVirtualID).size;
    CGFloat aspect = (vs.width > 0 && vs.height > 0) ? vs.width / vs.height : gVW / gH;
    CGFloat h = f.size.height;
    CGFloat w = round(h * aspect);
    // macOS can change the built-in screen's size after the virtual display
    // takes over, so work out the damaged strip from the size it has NOW.
    CGFloat maxW = f.size.width - round(f.size.width * gFraction);
    if (w > maxW) { w = maxW; h = round(w / aspect); }
    CGFloat x = gRight ? 0 : (f.size.width - w);
    CGFloat y = (f.size.height - h) / 2;
    printf("Built-in: %d x %d, virtual: %d x %d, picture: x=%d w=%d h=%d\n",
           (int)f.size.width, (int)f.size.height, (int)vs.width, (int)vs.height, (int)x, (int)w, (int)h);

    gLayer = [CALayer layer];
    gLayer.frame = CGRectMake(x, y, w, h);
    gLayer.contentsGravity = kCAGravityResize;
    gLayer.backgroundColor = NSColor.blackColor.CGColor;
    gLayer.contentsScale = bs.backingScaleFactor;
    [v.layer addSublayer:gLayer];
    [gWin orderFrontRegardless];

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *err) {
        if (err) fail([NSString stringWithFormat:@"screen recording not allowed (%@).", err.localizedDescription]);
        SCDisplay *target = nil;
        for (SCDisplay *d in content.displays) if (d.displayID == gVirtualID) target = d;
        if (!target) fail(@"could not find the virtual display to capture.");

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        CGSize vs = CGDisplayBounds(gVirtualID).size;
        cfg.width = (size_t)(vs.width * 2);
        cfg.height = (size_t)(vs.height * 2);
        cfg.minimumFrameInterval = CMTimeMake(1, 60);
        cfg.showsCursor = YES;
        cfg.queueDepth = 6;
        cfg.pixelFormat = kCVPixelFormatType_32BGRA;

        gOutput = [FrameOut new];
        gStream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:gOutput];
        NSError *e2 = nil;
        [gStream addStreamOutput:gOutput type:SCStreamOutputTypeScreen
              sampleHandlerQueue:dispatch_queue_create("deadzone.frames", DISPATCH_QUEUE_SERIAL) error:&e2];
        if (e2) fail(e2.localizedDescription);
        [gStream startCaptureWithCompletionHandler:^(NSError *e3) {
            if (e3) fail([NSString stringWithFormat:@"could not start capture (%@).", e3.localizedDescription]);
        }];
    }];

    // Safety: if no picture shows up within 8 seconds, quit and restore everything.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gLastFrame == 0) fail(@"no picture after 8 seconds, restoring normal screen.");
        printf("Running. Quit with Control+Option+Command+Q.\n");
    });

    // Lightweight: only react when the mouse actually moves (no polling).
    NSEventMask mouseMask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                            NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged;
    [NSEvent addGlobalMonitorForEventsMatchingMask:mouseMask handler:^(NSEvent *e) { clampMouse(); }];
    [NSEvent addLocalMonitorForEventsMatchingMask:mouseMask handler:^NSEvent *(NSEvent *e) { clampMouse(); return e; }];

    // Move stray windows when apps launch/switch, plus a slow safety sweep.
    moveStrayWindows();
    NSNotificationCenter *wc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification,
                                      NSWorkspaceDidActivateApplicationNotification]) {
        [wc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ moveStrayWindows(); });
        }];
    }
    [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *t) { moveStrayWindows(); }];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1) gFraction = atof(argv[1]);
        if (argc > 2) gRight = (strcmp(argv[2], "right") == 0);
        if (gFraction < 0.05 || gFraction > 0.8) fail(@"the first number must be between 0.05 and 0.8.");

        // Permissions (both are granted to Terminal)
        BOOL ax = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES });
        BOOL rec = CGPreflightScreenCaptureAccess();
        if (!rec) CGRequestScreenCaptureAccess();
        if (!ax || !rec) {
            fprintf(stderr,
                "\ndeadzone needs permissions first.\n"
                "Open System Settings > Privacy & Security and turn ON 'deadzone'\n"
                "(or 'Terminal' if you started it from Terminal) in:\n"
                "%s%s"
                "In the background it retries every minute; from Terminal, quit Terminal\n"
                "completely (Command+Q), reopen it, and run deadzone again.\n\n",
                ax ? "" : "  - Accessibility\n",
                rec ? "" : "  - Screen & System Audio Recording (or 'Screen Recording')\n");
            sleep(60);   // when running in the background, don't nag more than once a minute
            return 1;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        CGDirectDisplayID ids[16]; uint32_t n = 0;
        CGGetActiveDisplayList(16, ids, &n);
        for (uint32_t i = 0; i < n; i++) if (CGDisplayIsBuiltin(ids[i])) gBuiltin = ids[i];
        if (!gBuiltin) fail(@"could not find the built-in screen.");
        NSScreen *bs = screenForID(gBuiltin);
        if (!bs) fail(@"could not find the built-in screen.");
        gW = bs.frame.size.width;
        gH = bs.frame.size.height;
        gDeadW = round(gW * gFraction);
        gVW = gW - gDeadW;

        registerHotKey();
        createVirtualDisplay();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            arrangeDisplays();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                showOnBuiltin();
            });
        });
        [NSApp run];
    }
    return 0;
}
