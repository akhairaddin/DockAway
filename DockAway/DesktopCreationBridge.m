#import "DesktopCreationBridge.h"
#import "DesktopRemovalWindowPolicy.h"
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>

// Declarations only. Resolve the private implementation dynamically so an OS
// without this operation can still launch DockAway normally.
@interface NSObject (DockAwaySpaceCreationSignatures)
- (instancetype)initWithOptions:(uint32_t)options values:(NSDictionary *)values;
- (id)performWithWMBridgeDelegate;
- (uint64_t)spaceID;
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)spaceID;
- (instancetype)initWithDisplayIdentifier:(NSString *)displayIdentifier spaceID:(uint64_t)spaceID;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (instancetype)initWithSpaceID:(uint64_t)spaceID displayIdentifier:(NSString *)displayIdentifier index:(uint32_t)index;
@end

typedef struct {
    BOOL loaded;
    int32_t (*mainConnection)(void);
    CFArrayRef (*copyManagedDisplaySpaces)(int32_t);
    CFArrayRef (*copySpacesForWindows)(int32_t, uint32_t, CFArrayRef);
    CFArrayRef (*copyWindowsWithOptionsAndTags)(int32_t, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
} DockAwaySkyLightFunctions;

// Resolved once. Loading SkyLight also registers the SLSBridged* operation
// classes looked up below; any symbol missing on this OS stays NULL.
static const DockAwaySkyLightFunctions *DockAwaySkyLight(void) {
    static DockAwaySkyLightFunctions functions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!lib) return;
        functions.loaded = YES;
        functions.mainConnection = dlsym(lib, "SLSMainConnectionID");
        functions.copyManagedDisplaySpaces = dlsym(lib, "SLSCopyManagedDisplaySpaces");
        functions.copySpacesForWindows = dlsym(lib, "SLSCopySpacesForWindows");
        functions.copyWindowsWithOptionsAndTags = dlsym(lib, "SLSCopyWindowsWithOptionsAndTags");
    });
    return &functions;
}

typedef AXError (*DockAwayAXGetWindowFunction)(AXUIElementRef, CGWindowID *);

static DockAwayAXGetWindowFunction DockAwayAXGetWindow(void) {
    static DockAwayAXGetWindowFunction function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); });
    return function;
}

// Spaces report "id64", or "ManagedSpaceID" on older systems.
static NSNumber *DockAwaySpaceIdentifierNumber(NSDictionary *space) {
    return space[@"id64"] ?: space[@"ManagedSpaceID"];
}

static uint64_t DockAwaySpaceIdentifier(NSDictionary *space) {
    return DockAwaySpaceIdentifierNumber(space).unsignedLongLongValue;
}

// Membership checks accept either identifier when a Space reports both.
static BOOL DockAwaySpaceMatches(NSDictionary *space, uint64_t spaceID) {
    NSNumber *id64 = space[@"id64"];
    NSNumber *managedID = space[@"ManagedSpaceID"];
    return (id64 && id64.unsignedLongLongValue == spaceID)
        || (managedID && managedID.unsignedLongLongValue == spaceID);
}

// Window-to-Space queries may answer with either identifier of spaceID.
static void DockAwayResolveSpaceIdentifiers(NSArray *displays, uint64_t spaceID,
                                            uint64_t *id64, uint64_t *managedID) {
    *id64 = spaceID;
    *managedID = spaceID;
    for (NSDictionary *display in displays) {
        for (NSDictionary *space in display[@"Spaces"]) {
            if (!DockAwaySpaceMatches(space, spaceID)) continue;
            NSNumber *sid64 = space[@"id64"];
            NSNumber *sMid = space[@"ManagedSpaceID"];
            if (sid64) *id64 = sid64.unsignedLongLongValue;
            if (sMid) *managedID = sMid.unsignedLongLongValue;
            break;
        }
    }
}

// Sends performWithWMBridgeDelegate through NSInvocation, which honors each
// operation's verified return type (void or object) without redeclaring it.
static void DockAwayPerformBridgeOperation(id operation) {
    NSMethodSignature *signature = [operation methodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
    if (!signature) return;
    NSInvocation *request = [NSInvocation invocationWithMethodSignature:signature];
    request.selector = @selector(performWithWMBridgeDelegate);
    [request invokeWithTarget:operation];
}

// kAXWindows plus the main and focused windows, which some apps omit from
// kAXWindows. Callers match candidates by CGWindowID.
static NSArray *DockAwayCopyCandidateWindows(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.2);
    NSMutableArray *candidates = [NSMutableArray array];
    CFTypeRef raw = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &raw) == kAXErrorSuccess && raw) {
        if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
            [candidates addObjectsFromArray:CFBridgingRelease(raw)];
        } else {
            CFRelease(raw);
        }
    }
    CFTypeRef mainWin = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &mainWin) == kAXErrorSuccess && mainWin) {
        [candidates addObject:CFBridgingRelease(mainWin)];
    }
    CFTypeRef focusedWin = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focusedWin) == kAXErrorSuccess && focusedWin) {
        [candidates addObject:CFBridgingRelease(focusedWin)];
    }
    CFRelease(app);
    return candidates;
}

static BOOL DockAwayPressWindowButton(pid_t pid, CGWindowID windowID, CFStringRef attribute) {
    @autoreleasepool {
        if (pid <= 0 || pid == getpid() || !windowID || !AXIsProcessTrusted()) return NO;
        DockAwayAXGetWindowFunction getWindowID = DockAwayAXGetWindow();
        if (!getWindowID) return NO;
        for (id object in DockAwayCopyCandidateWindows(pid)) {
            AXUIElementRef window = (__bridge AXUIElementRef)object;
            if (CFGetTypeID(window) != AXUIElementGetTypeID()) continue;
            AXUIElementSetMessagingTimeout(window, 0.2);
            CGWindowID candidate = 0;
            if (getWindowID(window, &candidate) != kAXErrorSuccess || candidate != windowID) continue;
            CFTypeRef rawButton = NULL;
            if (AXUIElementCopyAttributeValue(window, attribute, &rawButton) != kAXErrorSuccess || !rawButton) continue;
            if (CFGetTypeID(rawButton) != AXUIElementGetTypeID()) { CFRelease(rawButton); continue; }
            AXUIElementRef button = (AXUIElementRef)rawButton;
            AXUIElementSetMessagingTimeout(button, 0.2);
            CFTypeRef enabled = NULL;
            BOOL isEnabled = AXUIElementCopyAttributeValue(button, kAXEnabledAttribute, &enabled) == kAXErrorSuccess
                && enabled && CFEqual(enabled, kCFBooleanTrue);
            if (enabled) CFRelease(enabled);
            if (!isEnabled) { CFRelease(button); continue; }
            BOOL pressed = AXUIElementPerformAction(button, kAXPressAction) == kAXErrorSuccess;
            CFRelease(button);
            if (pressed) return YES;
        }
        return NO;
    }
}

static BOOL DockAwayExitFullscreen(pid_t pid, CGWindowID windowID) {
    @autoreleasepool {
        if (pid <= 0 || pid == getpid() || !windowID || !AXIsProcessTrusted()) return NO;
        DockAwayAXGetWindowFunction getWindowID = DockAwayAXGetWindow();
        if (!getWindowID) return NO;
        for (id object in DockAwayCopyCandidateWindows(pid)) {
            AXUIElementRef window = (__bridge AXUIElementRef)object;
            if (CFGetTypeID(window) != AXUIElementGetTypeID()) continue;
            AXUIElementSetMessagingTimeout(window, 0.2);
            CGWindowID candidate = 0;
            if (getWindowID(window, &candidate) != kAXErrorSuccess || candidate != windowID) continue;

            // Exiting is idempotent. Never toggle the green button on a window
            // which has already left fullscreen while this request was queued.
            CFTypeRef fullscreen = NULL;
            BOOL isFullscreen = AXUIElementCopyAttributeValue(window, CFSTR("AXFullScreen"), &fullscreen) == kAXErrorSuccess
                && fullscreen && CFEqual(fullscreen, kCFBooleanTrue);
            if (fullscreen) CFRelease(fullscreen);
            if (!isFullscreen) return NO;
            if (AXUIElementSetAttributeValue(window, CFSTR("AXFullScreen"), kCFBooleanFalse) == kAXErrorSuccess) {
                return YES;
            }

            // Fall back only to this verified fullscreen window's own button.
            CFTypeRef rawButton = NULL;
            if (AXUIElementCopyAttributeValue(window, kAXFullScreenButtonAttribute, &rawButton) == kAXErrorSuccess && rawButton) {
                if (CFGetTypeID(rawButton) == AXUIElementGetTypeID()) {
                    AXUIElementRef button = (AXUIElementRef)rawButton;
                    AXUIElementSetMessagingTimeout(button, 0.2);
                    BOOL pressed = AXUIElementPerformAction(button, kAXPressAction) == kAXErrorSuccess;
                    CFRelease(button);
                    if (pressed) return YES;
                } else {
                    CFRelease(rawButton);
                }
            }

        }
        return NO;
    }
}

BOOL DockAwayCloseWindow(pid_t pid, CGWindowID windowID) {
    return DockAwayPressWindowButton(pid, windowID, kAXCloseButtonAttribute);
}

BOOL DockAwayMinimizeWindow(pid_t pid, CGWindowID windowID) {
    return DockAwayPressWindowButton(pid, windowID, kAXMinimizeButtonAttribute);
}

BOOL DockAwayCloseFullscreenSpace(uint64_t spaceID) {
    @autoreleasepool {
        if (!spaceID) return NO;
        const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
        if (!skyLight->mainConnection || !skyLight->copyManagedDisplaySpaces) return NO;
        NSArray *displays = CFBridgingRelease(skyLight->copyManagedDisplaySpaces(skyLight->mainConnection()));
        if (!displays) return NO;

        for (NSDictionary *display in displays) {
            for (NSDictionary *space in display[@"Spaces"]) {
                if (!DockAwaySpaceMatches(space, spaceID)) continue;

                NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];
                NSDictionary *layout = space[@"TileLayoutManager"];
                if ([layout isKindOfClass:NSDictionary.class]) {
                    NSArray *tileSpaces = layout[@"TileSpaces"];
                    if ([tileSpaces isKindOfClass:NSArray.class]) {
                        for (NSDictionary *tile in tileSpaces) {
                            NSNumber *tPid = tile[@"pid"];
                            NSNumber *tWid = tile[@"fs_wid"] ?: tile[@"TileWindowID"];
                            NSString *name = tile[@"appName"] ?: tile[@"name"];
                            if (tPid && tWid) {
                                NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:@{@"pid": tPid, @"wid": tWid}];
                                if (name) dict[@"name"] = name;
                                [targets addObject:dict];
                            }
                        }
                    }
                }
                if (targets.count == 0) {
                    NSNumber *sPid = space[@"pid"];
                    NSNumber *sWid = space[@"fs_wid"];
                    if (sPid && sWid) {
                        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:@{@"pid": sPid, @"wid": sWid}];
                        if (space[@"wsid"]) dict[@"name"] = space[@"wsid"];
                        [targets addObject:dict];
                    }
                }
                if (targets.count == 0) return NO;

                BOOL anyClosed = NO;
                for (NSDictionary *target in targets) {
                    pid_t pid = [target[@"pid"] intValue];
                    CGWindowID wid = [target[@"wid"] unsignedIntValue];
                    // The selected Space authorizes operations on these exact
                    // windows, never an app-wide Quit or an untargeted menu action.
                    if (DockAwayCloseWindow(pid, wid)) {
                        anyClosed = YES;
                        continue;
                    }

                    // If closing is unsupported, leave fullscreen on that same window.
                    if (DockAwayExitFullscreen(pid, wid)) {
                        anyClosed = YES;
                        continue;
                    }

                    NSLog(@"DockAway: Could not close or exit fullscreen for window %u (pid %d) in Space %llu",
                          wid, pid, (unsigned long long)spaceID);
                }
                return anyClosed;
            }
        }
        return NO;
    }
}

static id DockAwayMenuAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, attribute, &value);
    return CFBridgingRelease(value);
}

NSArray<NSDictionary<NSString *, id> *> *DockAwayMissionControlShortcuts(pid_t pid) {
    @autoreleasepool {
        if (pid <= 0 || !AXIsProcessTrusted()) return @[];
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(app, 0.04);
        id menu = DockAwayMenuAttribute(app, kAXMenuBarAttribute);
        CFRelease(app);
        if (!menu || CFGetTypeID((__bridge CFTypeRef)menu) != AXUIElementGetTypeID()) return @[];
        NSMutableArray *pending = [NSMutableArray arrayWithObject:menu];
        NSMutableArray *result = [NSMutableArray array];
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.8;
        NSUInteger visited = 0;
        NSString *appName = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName;
        while (pending.count && visited++ < 400 && CFAbsoluteTimeGetCurrent() < deadline) {
            id object = pending.lastObject;
            [pending removeLastObject];
            if (CFGetTypeID((__bridge CFTypeRef)object) != AXUIElementGetTypeID()) continue;
            AXUIElementRef element = (__bridge AXUIElementRef)object;
            AXUIElementSetMessagingTimeout(element, 0.04);
            NSString *title = DockAwayMenuAttribute(element, kAXTitleAttribute);
            NSString *identifier = DockAwayMenuAttribute(element, kAXIdentifierAttribute);
            NSString *command = nil;
            // Only identifiable commands are eligible. Never infer a destructive
            // action from its usual key equivalent, which the user can reassign.
            if ([identifier isEqual:@"performClose:"] || [title isEqual:@"Close"] || [title isEqual:@"Close Window"]) command = @"close";
            if ([identifier isEqual:@"performMiniaturize:"] || [title isEqual:@"Minimize"]) command = @"minimize";
            if ([identifier isEqual:@"terminate:"] || (appName && [title isEqual:[@"Quit " stringByAppendingString:appName]])) command = @"quit";
            if (command) {
                id character = DockAwayMenuAttribute(element, kAXMenuItemCmdCharAttribute);
                id modifiers = DockAwayMenuAttribute(element, kAXMenuItemCmdModifiersAttribute);
                id key = DockAwayMenuAttribute(element, kAXMenuItemCmdVirtualKeyAttribute);
                if ([modifiers isKindOfClass:NSNumber.class] && [character isKindOfClass:NSString.class] && [character length]) {
                    NSMutableDictionary *entry = [@{@"action":command, @"character":character, @"modifiers":modifiers} mutableCopy];
                    if ([key isKindOfClass:NSNumber.class]) entry[@"keyCode"] = key;
                    [result addObject:entry];
                }
            }
            id children = DockAwayMenuAttribute(element, kAXChildrenAttribute);
            if ([children isKindOfClass:NSArray.class]) [pending addObjectsFromArray:[children reverseObjectEnumerator].allObjects];
        }
        return result;
    }
}

NSDictionary<NSNumber *, NSArray<NSNumber *> *> *DockAwayCopyDesktopApplicationPIDs(NSArray<NSNumber *> *spaceIDs) {
    @autoreleasepool {
        const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
        int32_t (*connection)(void) = skyLight->mainConnection;
        CFArrayRef (*copySpaces)(int32_t, uint32_t, CFArrayRef) = skyLight->copySpacesForWindows;
        if (!connection || !copySpaces) return nil;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        if (!windows) return nil;
        NSMutableDictionary<NSNumber *, NSMutableOrderedSet<NSNumber *> *> *owners = [NSMutableDictionary dictionary];
        for (NSNumber *sid in spaceIDs) owners[sid] = [NSMutableOrderedSet orderedSet];
        for (NSDictionary *window in windows) {
            // Window identity and PID only. No titles, thumbnails, or screen recording.
            if ([window[(id)kCGWindowLayer] integerValue] != 0) continue;
            NSNumber *wid = window[(id)kCGWindowNumber];
            NSNumber *pid = window[(id)kCGWindowOwnerPID];
            if (!wid || !pid) continue;
            NSArray *spaces = CFBridgingRelease(copySpaces(connection(), 7, (__bridge CFArrayRef)@[wid]));
            // Shared utility windows are not evidence of an app having a
            // desktop-specific window on every Space they span.
            if (spaces.count != 1) continue;
            for (NSNumber *sid in spaces) [owners[sid] addObject:pid];
        }
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSNumber *sid in owners) result[sid] = owners[sid].array;
        return result;
    }
}

static BOOL DockAwayMoveDesktop(uint64_t spaceID, uint64_t targetID, BOOL after) {
    @autoreleasepool {
        @try {
            if (!spaceID || !targetID || spaceID == targetID) return NO;
            const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
            int32_t (*connection)(void) = skyLight->mainConnection;
            CFArrayRef (*copyManaged)(int32_t) = skyLight->copyManagedDisplaySpaces;
            Class cls = NSClassFromString(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
            NSMethodSignature *init = [cls instanceMethodSignatureForSelector:@selector(initWithSpaceID:displayIdentifier:index:)];
            NSMethodSignature *perform = [cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
            if (!connection || !copyManaged || init.numberOfArguments != 5 || strcmp(init.methodReturnType, "@")
                || strcmp([init getArgumentTypeAtIndex:2], "Q") || strcmp([init getArgumentTypeAtIndex:3], "@")
                || strcmp([init getArgumentTypeAtIndex:4], "I") || perform.numberOfArguments != 2
                || strcmp(perform.methodReturnType, "v")) return NO;
            NSArray *displays = CFBridgingRelease(copyManaged(connection()));
            NSDictionary *sourceDisplay = nil;
            NSUInteger sourceDesktopCount = 0;
            BOOL sourceIsDesktop = NO;
            for (NSDictionary *candidate in displays) {
                NSUInteger desktopCount = 0;
                BOOL containsSource = NO;
                for (NSDictionary *space in candidate[@"Spaces"]) {
                    if (!space[@"type"]) continue;
                    NSInteger type = [space[@"type"] integerValue];
                    if (type == 0) desktopCount++;
                    if (type != 0 && type != 4) continue;
                    if (DockAwaySpaceIdentifier(space) == spaceID) {
                        containsSource = YES;
                        sourceIsDesktop = type == 0;
                    }
                }
                if (containsSource) { sourceDisplay = candidate; sourceDesktopCount = desktopCount; break; }
            }
            if (!sourceDisplay) return NO;
            for (NSDictionary *display in displays) {
                BOOL sourceFound = NO;
                NSUInteger targetIndex = NSNotFound;
                NSArray *spaces = display[@"Spaces"];
                for (NSUInteger i = 0; i < spaces.count; i++) {
                    NSDictionary *space = spaces[i];
                    if (!space[@"type"]) continue;
                    NSInteger type = [space[@"type"] integerValue];
                    if (type != 0 && type != 4) continue;
                    uint64_t sid = DockAwaySpaceIdentifier(space);
                    if (sid == spaceID) sourceFound = YES;
                    if (sid == targetID) targetIndex = i;
                }
                NSString *displayID = display[@"Display Identifier"];
                if (targetIndex == NSNotFound || ![displayID isKindOfClass:NSString.class]) continue;
                if (!sourceFound && sourceIsDesktop && sourceDesktopCount < 2) return NO;
                if (after && sourceFound) return NO;
                if (after) targetIndex++;
                id operation = [[cls alloc] initWithSpaceID:spaceID displayIdentifier:displayID index:(uint32_t)targetIndex];
                if (!operation) return NO;
                DockAwayPerformBridgeOperation(operation);
                return YES;
            }
            return NO;
        } @catch (NSException *exception) { return NO; }
    }
}

BOOL DockAwayReorderDesktop(uint64_t spaceID, uint64_t targetID) {
    return DockAwayMoveDesktop(spaceID, targetID, NO);
}

BOOL DockAwayAppendDesktop(uint64_t spaceID, uint64_t targetID) {
    return DockAwayMoveDesktop(spaceID, targetID, YES);
}

BOOL DockAwayJumpToDesktop(uint64_t spaceID, uint64_t expectedCurrentID) {
    @autoreleasepool {
        @try {
            const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
            int32_t (*connection)(void) = skyLight->mainConnection;
            CFArrayRef (*copyManaged)(int32_t) = skyLight->copyManagedDisplaySpaces;
            Class cls = NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
            NSMethodSignature *initializer = [cls instanceMethodSignatureForSelector:@selector(initWithDisplayIdentifier:spaceID:)];
            NSMethodSignature *perform = [cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
            if (!connection || !copyManaged || initializer.numberOfArguments != 4
                || strcmp(initializer.methodReturnType, "@") || strcmp([initializer getArgumentTypeAtIndex:2], "@")
                || strcmp([initializer getArgumentTypeAtIndex:3], "Q") || perform.numberOfArguments != 2
                || strcmp(perform.methodReturnType, "v")) return NO;
            Class showClass = NSClassFromString(@"SLSBridgedShowSpacesOperation");
            Class hideClass = NSClassFromString(@"SLSBridgedHideSpacesOperation");
            if (!showClass || !hideClass) return NO;
            NSArray *visibilityClasses = @[showClass, hideClass];
            for (id visibilityClass in visibilityClasses) {
                NSMethodSignature *init = [visibilityClass instanceMethodSignatureForSelector:@selector(initWithSpaces:)];
                NSMethodSignature *execute = [visibilityClass instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
                if (init.numberOfArguments != 3 || strcmp(init.methodReturnType, "@")
                    || strcmp([init getArgumentTypeAtIndex:2], "@") || execute.numberOfArguments != 2
                    || strcmp(execute.methodReturnType, "v")) return NO;
            }
            NSArray *displays = CFBridgingRelease(copyManaged(connection()));
            for (NSDictionary *display in displays) {
                BOOL containsTarget = NO;
                for (NSDictionary *space in display[@"Spaces"]) {
                    NSInteger type = [space[@"type"] integerValue];
                    if (DockAwaySpaceIdentifier(space) == spaceID && space[@"type"]
                        && (type == 0 || type == 4)) {
                        containsTarget = YES;
                        break;
                    }
                }
                if (!containsTarget) continue;

                NSString *displayID = display[@"Display Identifier"];
                if (![displayID isKindOfClass:NSString.class]) return NO;

                NSNumber *currentNum = DockAwaySpaceIdentifierNumber(display[@"Current Space"]);
                uint64_t hideSpaceID = currentNum ? currentNum.unsignedLongLongValue : expectedCurrentID;

                id operation = [[cls alloc] initWithDisplayIdentifier:displayID spaceID:spaceID];
                if (!operation) return NO;

                // Updating the current ID alone does not change visibility.
                // Show the destination and hide the origin explicitly, with
                // no animation transaction or intermediate Spaces.
                if (hideSpaceID != spaceID && hideSpaceID != 0) {
                    id hideVis = [[hideClass alloc] initWithSpaces:@[@(hideSpaceID)]];
                    if (hideVis) DockAwayPerformBridgeOperation(hideVis);
                }
                id showVis = [[showClass alloc] initWithSpaces:@[@(spaceID)]];
                if (showVis) DockAwayPerformBridgeOperation(showVis);

                DockAwayPerformBridgeOperation(operation);
                return YES; // Caller confirms the destination, without retrying swipes.
            }
            return NO;
        } @catch (NSException *exception) { return NO; }
    }
}

BOOL DockAwayActivateSpace(uint64_t spaceID) {
    @autoreleasepool {
        if (!spaceID) return NO;
        const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
        int32_t (*connection)(void) = skyLight->mainConnection;
        CFArrayRef (*copySpaces)(int32_t, uint32_t, CFArrayRef) = skyLight->copySpacesForWindows;
        if (!connection || !copySpaces) return NO;

        uint64_t targetId64 = spaceID;
        uint64_t targetManagedID = spaceID;
        if (skyLight->copyManagedDisplaySpaces) {
            NSArray *displays = CFBridgingRelease(skyLight->copyManagedDisplaySpaces(connection()));
            DockAwayResolveSpaceIdentifiers(displays, spaceID, &targetId64, &targetManagedID);
        }

        // The destination is already current when this runs. Restrict focus
        // selection to windows that are actually visible there. Scanning every
        // Space could select a hidden or all-Spaces Chrome window and pull it
        // forward after an otherwise successful desktop switch.
        CGWindowListOption visibleWindows = kCGWindowListOptionOnScreenOnly
            | kCGWindowListExcludeDesktopElements;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(visibleWindows, kCGNullWindowID));
        if (windows) {
            pid_t selfPid = getpid();
            for (NSDictionary *window in windows) {
                NSNumber *layer = window[(id)kCGWindowLayer];
                if (!layer || layer.integerValue != 0) continue;
                NSNumber *wid = window[(id)kCGWindowNumber];
                NSNumber *pidNum = window[(id)kCGWindowOwnerPID];
                if (!wid || !pidNum) continue;
                pid_t pid = (pid_t)pidNum.intValue;
                if (pid <= 0 || pid == selfPid) continue;

                NSNumber *alpha = window[(id)kCGWindowAlpha];
                if (alpha && alpha.floatValue < 0.01f) continue;

                NSDictionary *boundsDict = window[(id)kCGWindowBounds];
                if (boundsDict) {
                    CGRect r = CGRectZero;
                    if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &r)) {
                        if (r.size.width < 50 || r.size.height < 50) continue;
                    }
                }

                NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                if (!app || app.isTerminated || app.activationPolicy != NSApplicationActivationPolicyRegular) continue;

                NSArray *spaces = CFBridgingRelease(copySpaces(connection(), 7, (__bridge CFArrayRef)@[wid]));
                if (!spaces) continue;
                // A sticky utility window is visible on several Spaces but is
                // not the destination Space's frontmost application.
                if (spaces.count != 1) continue;
                BOOL onSpace = NO;
                for (NSNumber *s in spaces) {
                    uint64_t v = s.unsignedLongLongValue;
                    if (v == targetId64 || v == targetManagedID) {
                        onSpace = YES;
                        break;
                    }
                }
                if (!onSpace) continue;

                // Found frontmost application on spaceID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop

                if (AXIsProcessTrusted()) {
                    AXUIElementRef appElem = AXUIElementCreateApplication(pid);
                    if (appElem) {
                        AXUIElementSetMessagingTimeout(appElem, 0.2);
                        DockAwayAXGetWindowFunction getWindowID = DockAwayAXGetWindow();
                        CFTypeRef rawWindows = NULL;
                        if (AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute, &rawWindows) == kAXErrorSuccess && rawWindows) {
                            if (CFGetTypeID(rawWindows) == CFArrayGetTypeID()) {
                                NSArray *axWindows = CFBridgingRelease(rawWindows);
                                for (id axWinObj in axWindows) {
                                    AXUIElementRef axWin = (__bridge AXUIElementRef)axWinObj;
                                    CGWindowID candidateWid = 0;
                                    if (getWindowID && getWindowID(axWin, &candidateWid) == kAXErrorSuccess && candidateWid == (CGWindowID)wid.unsignedIntValue) {
                                        AXUIElementPerformAction(axWin, kAXRaiseAction);
                                        AXUIElementSetAttributeValue(axWin, kAXMainAttribute, kCFBooleanTrue);
                                        break;
                                    }
                                }
                            } else {
                                CFRelease(rawWindows);
                            }
                        }
                        CFRelease(appElem);
                    }
                }
                return YES;
            }
        }

        // If no regular application window is present on the space, activate Finder to focus the desktop
        NSArray<NSRunningApplication *> *finders = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
        if (finders.count > 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [finders.firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            return YES;
        }
        return NO;
    }
}

BOOL DockAwayMoveWindowToSpace(CGWindowID windowID, uint64_t targetSpaceID) {
    @autoreleasepool {
        if (!windowID || !targetSpaceID) return NO;
        if (!DockAwaySkyLight()->loaded) return NO;
        Class mover = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        if (!mover) return NO;
        NSMethodSignature *moveInit = [mover instanceMethodSignatureForSelector:@selector(initWithWindows:spaceID:)];
        NSMethodSignature *movePerform = [mover instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
        if (!moveInit || !movePerform || moveInit.numberOfArguments != 4 || movePerform.numberOfArguments != 2) return NO;
        id move = [[mover alloc] initWithWindows:@[@(windowID)] spaceID:targetSpaceID];
        if (!move) return NO;
        DockAwayPerformBridgeOperation(move);
        return YES;
    }
}

BOOL DockAwayIsWindowOnSpace(CGWindowID windowID, uint64_t spaceID) {
    @autoreleasepool {
        if (!windowID || !spaceID) return NO;
        const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
        int32_t (*connection)(void) = skyLight->mainConnection;
        CFArrayRef (*copySpaces)(int32_t, uint32_t, CFArrayRef) = skyLight->copySpacesForWindows;
        if (!connection || !copySpaces) return NO;

        uint64_t targetId64 = spaceID;
        uint64_t targetManagedID = spaceID;
        if (skyLight->copyManagedDisplaySpaces) {
            NSArray *displays = CFBridgingRelease(skyLight->copyManagedDisplaySpaces(connection()));
            DockAwayResolveSpaceIdentifiers(displays, spaceID, &targetId64, &targetManagedID);
        }

        NSArray *spaces = CFBridgingRelease(copySpaces(connection(), 7, (__bridge CFArrayRef)@[@(windowID)]));
        if (!spaces) return NO;
        for (NSNumber *s in spaces) {
            uint64_t v = s.unsignedLongLongValue;
            if (v == targetId64 || v == targetManagedID) {
                return YES;
            }
        }
        return NO;
    }
}

BOOL DockAwayRepositionWindowToDisplay(pid_t pid, CGWindowID windowID, CGRect displayBounds) {
    @autoreleasepool {
        if (pid <= 0 || !windowID) return NO;

        CGFloat currentWidth = 800;
        CGFloat currentHeight = 600;
        CGRect r = CGRectZero;
        NSArray *windowInfo = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID));
        if (windowInfo.count > 0) {
            NSDictionary *info = windowInfo.firstObject;
            NSDictionary *boundsDict = info[(id)kCGWindowBounds];
            if (boundsDict) {
                if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &r)) {
                    if (r.size.width > 100) currentWidth = r.size.width;
                    if (r.size.height > 100) currentHeight = r.size.height;
                }
            }
        }

        if (currentWidth > displayBounds.size.width - 40) currentWidth = displayBounds.size.width - 40;
        if (currentHeight > displayBounds.size.height - 80) currentHeight = displayBounds.size.height - 80;

        CGFloat targetX = displayBounds.origin.x + MAX(20.0, (displayBounds.size.width - currentWidth) / 2.0);
        CGFloat targetY = displayBounds.origin.y + MAX(40.0, (displayBounds.size.height - currentHeight) / 2.0);

        if (!AXIsProcessTrusted()) return NO;
        AXUIElementRef appElem = AXUIElementCreateApplication(pid);
        if (!appElem) return NO;
        AXUIElementSetMessagingTimeout(appElem, 0.2);

        DockAwayAXGetWindowFunction getWindowID = DockAwayAXGetWindow();
        CFTypeRef rawWindows = NULL;
        BOOL success = NO;
        if (AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute, &rawWindows) == kAXErrorSuccess && rawWindows) {
            if (CFGetTypeID(rawWindows) == CFArrayGetTypeID()) {
                NSArray *axWindows = CFBridgingRelease(rawWindows);
                for (id axWinObj in axWindows) {
                    AXUIElementRef axWin = (__bridge AXUIElementRef)axWinObj;
                    CGWindowID candidateWid = 0;
                    if (getWindowID && getWindowID(axWin, &candidateWid) == kAXErrorSuccess && candidateWid == windowID) {
                        if (currentWidth < r.size.width || currentHeight < r.size.height) {
                            CGSize newSize = CGSizeMake(currentWidth, currentHeight);
                            AXValueRef sizeVal = AXValueCreate(kAXValueTypeCGSize, &newSize);
                            if (sizeVal) {
                                AXUIElementSetAttributeValue(axWin, kAXSizeAttribute, sizeVal);
                                CFRelease(sizeVal);
                            }
                        }
                        CGPoint newPos = CGPointMake(targetX, targetY);
                        AXValueRef val = AXValueCreate(kAXValueTypeCGPoint, &newPos);
                        if (val) {
                            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute, val);
                            CFRelease(val);
                        }
                        AXUIElementPerformAction(axWin, kAXRaiseAction);
                        AXUIElementSetAttributeValue(axWin, kAXMainAttribute, kCFBooleanTrue);
                        success = YES;
                        break;
                    }
                }
            } else {
                CFRelease(rawWindows);
            }
        }
        CFRelease(appElem);
        return success;
    }
}

static Class creationClass(void) {
    DockAwaySkyLight(); // Loads SkyLight, which registers the operation classes.
    return NSClassFromString(@"SLSBridgedSpaceCreateOperation");
}

BOOL DockAwayDesktopCreationAvailable(void) {
    Class cls = creationClass();
    NSMethodSignature *initializer = [cls instanceMethodSignatureForSelector:@selector(initWithOptions:values:)];
    NSMethodSignature *perform = [cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
    return initializer.numberOfArguments == 4 && perform.numberOfArguments == 2
        && strcmp(initializer.methodReturnType, "@") == 0
        && strcmp([initializer getArgumentTypeAtIndex:2], "I") == 0
        && strcmp([initializer getArgumentTypeAtIndex:3], "@") == 0
        && strcmp(perform.methodReturnType, "@") == 0;
}

uint64_t DockAwayCreateDesktop(void) {
    @autoreleasepool {
        @try {
            if (!DockAwayDesktopCreationAvailable()) return 0;
            NSDictionary *values = @{@"type": @0, @"uuid": NSUUID.UUID.UUIDString};
            id operation = [[creationClass() alloc] initWithOptions:0 values:values];
            id result = [operation performWithWMBridgeDelegate];
            NSMethodSignature *signature = [result methodSignatureForSelector:@selector(spaceID)];
            if (signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, "Q") != 0) return 0;
            return [result spaceID];
        } @catch (NSException *exception) {
            // A private-API change must not take down the menu-bar app.
            return 0;
        }
    }
}

uint64_t DockAwayCreateDesktopOnDisplay(uint32_t displayID, uint64_t anchorSpaceID) {
    @autoreleasepool {
        uint64_t created = 0;
        @try {
            if (!CGDisplayIsActive(displayID) || !anchorSpaceID || !DockAwayDesktopCreationAvailable()) return 0;
            const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
            int32_t (*connection)(void) = skyLight->mainConnection;
            CFArrayRef (*copyManaged)(int32_t) = skyLight->copyManagedDisplaySpaces;
            Class cls = NSClassFromString(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
            NSMethodSignature *initializer = [cls instanceMethodSignatureForSelector:@selector(initWithSpaceID:displayIdentifier:index:)];
            NSMethodSignature *perform = [cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
            // Validate placement support before creating anything. Never retry creation.
            if (!connection || !copyManaged || initializer.numberOfArguments != 5
                || strcmp(initializer.methodReturnType, "@")
                || strcmp([initializer getArgumentTypeAtIndex:2], "Q")
                || strcmp([initializer getArgumentTypeAtIndex:3], "@")
                || strcmp([initializer getArgumentTypeAtIndex:4], "I")
                || perform.numberOfArguments != 2 || strcmp(perform.methodReturnType, "v")) return 0;
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
            NSString *expectedDisplay = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
            if (uuid) CFRelease(uuid);
            NSArray *displays = CFBridgingRelease(copyManaged(connection()));
            NSString *destination = nil;
            NSUInteger insertionIndex = 0;
            for (NSDictionary *display in displays) {
                NSString *identifier = display[@"Display Identifier"];
                if (![identifier isKindOfClass:NSString.class]) continue;
                BOOL matches = (expectedDisplay && [identifier caseInsensitiveCompare:expectedDisplay] == NSOrderedSame)
                    || (![NSScreen screensHaveSeparateSpaces] && [identifier isEqualToString:@"Main"]);
                if (!matches) continue;
                NSArray *spaces = display[@"Spaces"];
                for (NSDictionary *space in spaces) {
                    uint64_t sid = DockAwaySpaceIdentifier(space);
                    if (sid == anchorSpaceID && [space[@"type"] intValue] == 0) {
                        destination = identifier;
                        insertionIndex = spaces.count;
                        break;
                    }
                }
            }
            if (!destination) return 0;
            created = DockAwayCreateDesktop();
            if (!created || !CGDisplayIsActive(displayID)) return created;
            // Creation itself has no display argument. Place only this newly
            // created Space, leaving every pre-existing desktop untouched.
            NSArray *latest = CFBridgingRelease(copyManaged(connection()));
            for (NSDictionary *display in latest) {
                if (![display[@"Display Identifier"] isEqual:destination]) continue;
                for (NSDictionary *space in display[@"Spaces"]) {
                    if (DockAwaySpaceIdentifier(space) == created) return created;
                }
            }
            id operation = [[cls alloc] initWithSpaceID:created displayIdentifier:destination index:(uint32_t)insertionIndex];
            if (!operation) return created;
            DockAwayPerformBridgeOperation(operation);
            return created; // Swift confirms membership on the requested display.
        } @catch (NSException *exception) {
            return created; // Preserve identity if creation succeeded but placement failed.
        }
    }
}

BOOL DockAwayDesktopRemovalAvailable(void) {
    creationClass(); // Load SkyLight once.
    Class cls = NSClassFromString(@"SLSBridgedSpaceDestroyOperation");
    NSMethodSignature *initializer = [cls instanceMethodSignatureForSelector:NSSelectorFromString(@"initWithSpaceID:")];
    NSMethodSignature *perform = [cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
    return initializer.numberOfArguments == 3 && perform.numberOfArguments == 2
        && strcmp(initializer.methodReturnType, "@") == 0
        && strcmp([initializer getArgumentTypeAtIndex:2], "Q") == 0
        && strcmp(perform.methodReturnType, "v") == 0;
}

BOOL DockAwayRemoveDesktop(uint64_t spaceID) {
    @autoreleasepool {
        @try {
            if (!spaceID || !DockAwayDesktopRemovalAvailable()) return NO;
            // Revalidate immediately before sending the request. Never destroy a
            // fullscreen Space or the last regular desktop on a display.
            const DockAwaySkyLightFunctions *skyLight = DockAwaySkyLight();
            int32_t (*connection)(void) = skyLight->mainConnection;
            CFArrayRef (*copyManaged)(int32_t) = skyLight->copyManagedDisplaySpaces;
            if (!connection || !copyManaged) return NO;
            NSArray *displays = CFBridgingRelease(copyManaged(connection()));
            BOOL allowed = NO;
            uint64_t destination = 0;
            for (NSDictionary *display in displays) {
                NSUInteger count = 0;
                BOOL found = NO;
                for (NSDictionary *space in display[@"Spaces"]) {
                    if (space[@"type"] && [space[@"type"] intValue] == 0) {
                        count++;
                        if (DockAwaySpaceIdentifier(space) == spaceID) found = YES;
                    }
                }
                if (found && count > 1) {
                    uint64_t current = DockAwaySpaceIdentifier(display[@"Current Space"]);
                    // The UI switches away first when closing the active desktop.
                    if (current == spaceID) return NO;
                    for (NSDictionary *space in display[@"Spaces"]) {
                        uint64_t identifier = DockAwaySpaceIdentifier(space);
                        if (space[@"type"] && [space[@"type"] intValue] == 0 && identifier != spaceID) {
                            if (!destination || identifier == current) destination = identifier;
                        }
                    }
                    allowed = destination != 0;
                }
            }
            if (!allowed) return NO;
            CFArrayRef (*copyWindows)(int32_t, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *) = skyLight->copyWindowsWithOptionsAndTags;
            CFArrayRef (*copySpaces)(int32_t, uint32_t, CFArrayRef) = skyLight->copySpacesForWindows;
            Class mover = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
            NSMethodSignature *moveInit = [mover instanceMethodSignatureForSelector:@selector(initWithWindows:spaceID:)];
            NSMethodSignature *movePerform = [mover instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
            if (!copyWindows || !copySpaces || moveInit.numberOfArguments != 4
                || strcmp(moveInit.methodReturnType, "@") || strcmp([moveInit getArgumentTypeAtIndex:2], "@")
                || strcmp([moveInit getArgumentTypeAtIndex:3], "Q") || movePerform.numberOfArguments != 2
                || strcmp(movePerform.methodReturnType, "v")) return NO;
            // Include minimized windows. Preserve windows assigned to multiple
            // Spaces by migrating only those whose sole Space is the target.
            BOOL evacuated = NO;
            NSMutableSet *migrating = [NSMutableSet set];
            for (int attempt = 0; attempt < 20; attempt++) {
                NSArray *windowInfo = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
                if (!windowInfo) return NO;
                NSMutableDictionary *infoByID = [NSMutableDictionary dictionary];
                for (NSDictionary *info in windowInfo) {
                    NSNumber *wid = info[(id)kCGWindowNumber];
                    if (wid) infoByID[wid] = info;
                }
                uint64_t setTags = 0, clearTags = 0;
                NSArray *windows = CFBridgingRelease(copyWindows(connection(), 0, (__bridge CFArrayRef)@[@(spaceID)], 7, &setTags, &clearTags));
                if (!windows) return NO;
                NSMutableArray *exclusive = [NSMutableArray array];
                for (NSNumber *window in windows) {
                    NSArray *spaces = CFBridgingRelease(copySpaces(connection(), 7, (__bridge CFArrayRef)@[window]));
                    if (!spaces) return NO;
                    if (spaces.count != 1 || ![spaces containsObject:@(spaceID)]) continue;
                    NSDictionary *info = infoByID[window];
                    // Unknown metadata is not permission to move a system window
                    // or destroy a desktop with an unclassified application window.
                    if (!info || !info[(id)kCGWindowLayer] || !info[(id)kCGWindowOwnerPID]) return NO;
                    if (DockAwayCanMigrateDesktopWindow(info)) [exclusive addObject:window];
                }
                if (!exclusive.count) { evacuated = YES; break; }
                [migrating addObjectsFromArray:exclusive];
                id move = [[mover alloc] initWithWindows:exclusive spaceID:destination];
                DockAwayPerformBridgeOperation(move);
                [NSThread sleepForTimeInterval:0.1];
            }
            if (!evacuated) return NO; // Never destroy a desktop with stranded app windows.
            for (NSNumber *window in migrating) {
                NSArray *spaces = CFBridgingRelease(copySpaces(connection(), 7, (__bridge CFArrayRef)@[window]));
                if (![spaces containsObject:@(destination)]) return NO;
            }
            // The user could change Spaces while the window moves were pending.
            // Abort if the target became current or its destination disappeared.
            BOOL topologyValid = NO;
            NSArray *latest = CFBridgingRelease(copyManaged(connection()));
            for (NSDictionary *display in latest) {
                if (DockAwaySpaceIdentifier(display[@"Current Space"]) == spaceID) return NO;
                BOOL targetFound = NO, destinationFound = NO;
                for (NSDictionary *space in display[@"Spaces"]) {
                    if (!space[@"type"] || [space[@"type"] intValue] != 0) continue;
                    uint64_t sid = DockAwaySpaceIdentifier(space);
                    targetFound |= sid == spaceID;
                    destinationFound |= sid == destination;
                }
                if (targetFound && destinationFound) topologyValid = YES;
            }
            if (!topologyValid) return NO;
            id allocated = [NSClassFromString(@"SLSBridgedSpaceDestroyOperation") alloc];
            SEL initialize = NSSelectorFromString(@"initWithSpaceID:");
            // The asynchronous destroy executor returns void, unlike creation.
            // NSInvocation preserves each verified ABI without conflicting declarations.
            NSInvocation *init = [NSInvocation invocationWithMethodSignature:[allocated methodSignatureForSelector:initialize]];
            init.selector = initialize;
            [init setArgument:&spaceID atIndex:2];
            [init invokeWithTarget:allocated];
            __unsafe_unretained id raw = nil;
            [init getReturnValue:&raw];
            id operation = raw;
            if (!operation) return NO;
            DockAwayPerformBridgeOperation(operation);
            return YES; // Dispatch only; the caller must confirm disappearance.
        } @catch (NSException *exception) {
            return NO;
        }
    }
}
