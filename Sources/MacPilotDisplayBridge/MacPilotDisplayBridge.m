#import "MacPilotDisplayBridge.h"
#import <dlfcn.h>
#import <sys/proc.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <objc/runtime.h>

// The private virtual-display interface declarations below were informed by
// UUyc-companion (MIT; see Resources/DisplayControlThirdPartyNotices.txt).
// MacPilot's bridge implementation and lifecycle handling are independent.

@interface MDVirtualDisplayDescriptor : NSObject
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) CGSize whitePoint;
@property(nonatomic) CGSize redPrimary;
@property(nonatomic) CGSize greenPrimary;
@property(nonatomic) CGSize bluePrimary;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNum;
@end

@interface MDVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface MDVirtualDisplaySettings : NSObject
@property(nonatomic) BOOL hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end

@interface MDVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(MDVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(MDVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

typedef CGError (*MDSetEnabledFunction)(CGDisplayConfigRef, CGDirectDisplayID, bool);

static CGError MDRunDisplayTransaction(CGError (^configure)(CGDisplayConfigRef), int32_t *errorCode) {
    CGDisplayConfigRef config = NULL;
    CGError begin = CGBeginDisplayConfiguration(&config);
    if (begin != kCGErrorSuccess) {
        if (errorCode) *errorCode = begin;
        return begin;
    }

    CGError staged = configure(config);
    if (staged != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (errorCode) *errorCode = staged;
        return staged;
    }

    CGError completed = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (completed != kCGErrorSuccess) CGCancelDisplayConfiguration(config);
    if (errorCode) *errorCode = completed;
    return completed;
}

BOOL MDVirtualDisplayAPIAvailable(void) {
    Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
    Class display = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptor || !mode || !settings || !display) return NO;
    NSArray<NSString *> *descriptorSetters = @[
        @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
        @"setSizeInMillimeters:", @"setVendorID:", @"setProductID:", @"setSerialNum:"
    ];
    for (NSString *name in descriptorSetters) {
        if (!class_getInstanceMethod(descriptor, NSSelectorFromString(name))) return NO;
    }
    NSArray<NSString *> *settingsSetters = @[@"setHiDPI:", @"setModes:"];
    for (NSString *name in settingsSetters) {
        if (!class_getInstanceMethod(settings, NSSelectorFromString(name))) return NO;
    }
    return class_getInstanceMethod(mode, NSSelectorFromString(@"initWithWidth:height:refreshRate:")) != NULL
        && class_getInstanceMethod(display, NSSelectorFromString(@"initWithDescriptor:")) != NULL
        && class_getInstanceMethod(display, NSSelectorFromString(@"applySettings:")) != NULL
        && class_getInstanceMethod(display, NSSelectorFromString(@"displayID")) != NULL;
}

BOOL MDDisplayEnabledAPIAvailable(void) {
    return dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled") != NULL;
}

MDVirtualDisplayToken MDVirtualDisplayCreate(
    uint32_t width,
    uint32_t height,
    BOOL hiDPI,
    double refreshRate,
    NSString *name,
    CGDirectDisplayID *displayID,
    BOOL *settingsApplied
) {
    if (!MDVirtualDisplayAPIAvailable() || width == 0 || height == 0) return NULL;

    MDVirtualDisplayDescriptor *descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    descriptor.name = name;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width / 220.0 * 25.4, height / 220.0 * 25.4);
    descriptor.vendorID = 0x5555;
    descriptor.productID = 0x0001;
    descriptor.serialNum = arc4random_uniform(UINT32_MAX - 1) + 1;

    MDVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) return NULL;
    if (displayID) *displayID = display.displayID;

    MDVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI = hiDPI;
    NSUInteger modeWidth = hiDPI ? width / 2 : width;
    NSUInteger modeHeight = hiDPI ? height / 2 : height;
    MDVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:modeWidth height:modeHeight refreshRate:refreshRate];
    settings.modes = @[mode];
    BOOL applied = [display applySettings:settings];
    if (settingsApplied) *settingsApplied = applied;
    return (__bridge_retained MDVirtualDisplayToken)display;
}

void MDVirtualDisplayRelease(MDVirtualDisplayToken token) {
    if (token) {
        id releasedObject = (__bridge_transfer id)token;
        (void)releasedObject;
    }
}

BOOL MDDisplayUUID(CGDirectDisplayID displayID, char *buffer, size_t capacity) {
    if (!buffer || capacity < 2) return NO;
    typedef CFUUIDRef (*MDCreateUUIDFunction)(CGDirectDisplayID);
    MDCreateUUIDFunction createUUID = (MDCreateUUIDFunction)dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
    if (createUUID) {
        CFUUIDRef uuid = createUUID(displayID);
        if (uuid) {
            CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, uuid);
            CFRelease(uuid);
            if (string) {
                BOOL result = CFStringGetCString(string, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
                CFRelease(string);
                if (result) return YES;
            }
        }
    }
    // Some macOS SDKs omit the UUID declaration. This fallback is only
    // considered stable inside the current boot session; the journal binds
    // numeric IDs to kern.boottime and refuses stale cross-boot recovery.
    int written = snprintf(
        buffer,
        capacity,
        "cg-%08x-%04x-%04x-%08x",
        displayID,
        CGDisplayVendorNumber(displayID),
        CGDisplayModelNumber(displayID),
        CGDisplaySerialNumber(displayID)
    );
    return written > 0 && (size_t)written < capacity;
}

BOOL MDCurrentDisplayServerIdentity(char *buffer, size_t capacity) {
    if (!buffer || capacity < 2) return NO;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t requiredBytes = 0;
    if (sysctl(mib, 4, NULL, &requiredBytes, NULL, 0) != 0
        || requiredBytes == 0 || requiredBytes > 4 * 1024 * 1024) return NO;
    struct kinfo_proc *processes = calloc(requiredBytes / sizeof(struct kinfo_proc) + 1, sizeof(struct kinfo_proc));
    if (!processes) return NO;
    size_t writtenBytes = requiredBytes;
    if (sysctl(mib, 4, processes, &writtenBytes, NULL, 0) != 0) {
        free(processes);
        return NO;
    }
    BOOL found = NO;
    size_t processCount = writtenBytes / sizeof(struct kinfo_proc);
    for (size_t index = 0; index < processCount; index++) {
        struct kinfo_proc *process = &processes[index];
        if (process->kp_proc.p_pid <= 0 || strcmp(process->kp_proc.p_comm, "WindowServer") != 0) continue;
        // WindowServer runs as _windowserver, not as the logged-in user. A
        // single instance is unambiguous; fast-user-switching/multi-session
        // systems fail closed until an audit-session-bound match is available.
        if (found) {
            found = NO;
            break;
        }
        int identityBytes = snprintf(buffer, capacity, "ws-%d-%lld-%d",
            process->kp_proc.p_pid,
            (long long)process->kp_proc.p_starttime.tv_sec,
            (int)process->kp_proc.p_starttime.tv_usec);
        found = identityBytes > 0 && (size_t)identityBytes < capacity;
    }
    free(processes);
    return found;
}

BOOL MDDisplaySetEnabled(CGDirectDisplayID displayID, BOOL enabled, int32_t *errorCode) {
    MDSetEnabledFunction function = (MDSetEnabledFunction)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    if (!function) {
        if (errorCode) *errorCode = kCGErrorNotImplemented;
        return NO;
    }
    CGError result = MDRunDisplayTransaction(^(CGDisplayConfigRef config) {
        return function(config, displayID, enabled != NO);
    }, errorCode);
    return result == kCGErrorSuccess;
}

BOOL MDDisplaySetMain(CGDirectDisplayID targetDisplayID, int32_t *errorCode) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return NO;
    CGDirectDisplayID *displayIDs = calloc(count, sizeof(CGDirectDisplayID));
    if (!displayIDs) return NO;
    CGError listResult = CGGetOnlineDisplayList(count, displayIDs, &count);
    if (listResult != kCGErrorSuccess) {
        free(displayIDs);
        if (errorCode) *errorCode = listResult;
        return NO;
    }
    CGRect target = CGDisplayBounds(targetDisplayID);
    CGError result = MDRunDisplayTransaction(^(CGDisplayConfigRef config) {
        CGError staged = CGConfigureDisplayOrigin(config, targetDisplayID, 0, 0);
        if (staged != kCGErrorSuccess) return staged;
        for (uint32_t index = 0; index < count; index++) {
            CGDirectDisplayID displayID = displayIDs[index];
            if (displayID == targetDisplayID) continue;
            CGRect bounds = CGDisplayBounds(displayID);
            staged = CGConfigureDisplayOrigin(
                config,
                displayID,
                (int32_t)(bounds.origin.x - target.origin.x),
                (int32_t)(bounds.origin.y - target.origin.y)
            );
            if (staged != kCGErrorSuccess) return staged;
        }
        return kCGErrorSuccess;
    }, errorCode);
    free(displayIDs);
    return result == kCGErrorSuccess;
}

BOOL MDDisplayRestoreOrigins(const CGDirectDisplayID *displayIDs, const CGPoint *origins, size_t count, int32_t *errorCode) {
    if ((!displayIDs || !origins) && count > 0) return NO;
    CGError result = MDRunDisplayTransaction(^(CGDisplayConfigRef config) {
        for (size_t index = 0; index < count; index++) {
            if (!CGDisplayIsOnline(displayIDs[index])) continue;
            CGError staged = CGConfigureDisplayOrigin(
                config,
                displayIDs[index],
                (int32_t)origins[index].x,
                (int32_t)origins[index].y
            );
            if (staged != kCGErrorSuccess) return staged;
        }
        return kCGErrorSuccess;
    }, errorCode);
    return result == kCGErrorSuccess;
}
