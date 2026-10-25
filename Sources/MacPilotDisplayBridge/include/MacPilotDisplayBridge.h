#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef const void *MDVirtualDisplayToken;

BOOL MDVirtualDisplayAPIAvailable(void);
BOOL MDDisplayEnabledAPIAvailable(void);
MDVirtualDisplayToken _Nullable MDVirtualDisplayCreate(
    uint32_t width,
    uint32_t height,
    BOOL hiDPI,
    double refreshRate,
    NSString *name,
    CGDirectDisplayID *displayID,
    BOOL *settingsApplied
);
void MDVirtualDisplayRelease(MDVirtualDisplayToken token);

BOOL MDDisplayUUID(CGDirectDisplayID displayID, char *buffer, size_t capacity);
BOOL MDCurrentDisplayServerIdentity(char *buffer, size_t capacity);
BOOL MDDisplaySetEnabled(CGDirectDisplayID displayID, BOOL enabled, int32_t *errorCode);
BOOL MDDisplaySetMain(CGDirectDisplayID targetDisplayID, int32_t *errorCode);
BOOL MDDisplayRestoreOrigins(const CGDirectDisplayID *displayIDs, const CGPoint *origins, size_t count, int32_t *errorCode);

NS_ASSUME_NONNULL_END
