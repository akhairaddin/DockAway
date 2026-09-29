#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Space queries also return per-Space menu bars, wallpaper and WindowManager
// surfaces. Never migrate those into another Space before destroying the source.
static inline BOOL DockAwayCanMigrateDesktopWindow(NSDictionary *info) {
    NSNumber *layer = info[(id)kCGWindowLayer];
    NSNumber *pid = info[(id)kCGWindowOwnerPID];
    if (![layer isKindOfClass:NSNumber.class] || ![pid isKindOfClass:NSNumber.class] || pid.intValue <= 0) return NO;
    int level = layer.intValue;
    return level == CGWindowLevelForKey(kCGNormalWindowLevelKey)
        || level == CGWindowLevelForKey(kCGFloatingWindowLevelKey)
        || level == CGWindowLevelForKey(kCGModalPanelWindowLevelKey);
}
