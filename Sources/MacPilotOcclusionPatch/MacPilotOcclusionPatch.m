#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSApplicationOcclusionState MacPilotApplicationOcclusionState(id self, SEL command) {
    (void)self;
    (void)command;
    return NSApplicationOcclusionStateVisible;
}

static NSWindowOcclusionState MacPilotWindowOcclusionState(id self, SEL command) {
    (void)self;
    (void)command;
    return NSWindowOcclusionStateVisible;
}

void MacPilotInstallOcclusionPatch(void) {
    Method applicationMethod = class_getInstanceMethod(NSApplication.class, @selector(occlusionState));
    if (applicationMethod != NULL) {
        method_setImplementation(applicationMethod, (IMP)MacPilotApplicationOcclusionState);
    }

    Method windowMethod = class_getInstanceMethod(NSWindow.class, @selector(occlusionState));
    if (windowMethod != NULL) {
        method_setImplementation(windowMethod, (IMP)MacPilotWindowOcclusionState);
    }
}

__attribute__((constructor))
static void MacPilotOcclusionPatchDidLoad(void) {
    MacPilotInstallOcclusionPatch();
}
