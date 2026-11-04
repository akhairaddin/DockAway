#import <Foundation/Foundation.h>

// The desktops and full-screen Spaces an all-desktops window is missing from,
// given SLSCopyManagedDisplaySpaces and the window's own Spaces. A window on
// no Space yet hasn't been placed by the Dock, so nothing is missing. Only
// the display it's on counts, the one with a Space it's still on: put on
// another display's Spaces too, macOS slides it across to that display with
// every desktop change. Spaces report "id64", or "ManagedSpaceID" on older
// systems, and a window's Spaces may use either.
static inline NSArray<NSNumber *> *DockAwayMissingSpaces(NSArray *displays, NSArray *membership) {
    if (![displays isKindOfClass:NSArray.class] || ![membership isKindOfClass:NSArray.class]) return @[];
    NSMutableSet<NSNumber *> *member = [NSMutableSet set];
    for (id value in membership) {
        if ([value isKindOfClass:NSNumber.class]) [member addObject:@([value unsignedLongLongValue])];
    }
    if (member.count == 0) return @[];
    NSMutableArray<NSNumber *> *missing = [NSMutableArray array];
    for (NSDictionary *display in displays) {
        if (![display isKindOfClass:NSDictionary.class]) continue;
        NSArray *spaces = display[@"Spaces"];
        if (![spaces isKindOfClass:NSArray.class]) continue;
        BOOL isWindowsDisplay = NO;
        for (NSDictionary *space in spaces) {
            if (![space isKindOfClass:NSDictionary.class]) continue;
            NSNumber *id64 = [space[@"id64"] isKindOfClass:NSNumber.class] ? space[@"id64"] : nil;
            NSNumber *managedID = [space[@"ManagedSpaceID"] isKindOfClass:NSNumber.class] ? space[@"ManagedSpaceID"] : nil;
            if ((id64 && [member containsObject:@(id64.unsignedLongLongValue)])
                || (managedID && [member containsObject:@(managedID.unsignedLongLongValue)])) {
                isWindowsDisplay = YES;
                break;
            }
        }
        if (!isWindowsDisplay) continue;
        for (NSDictionary *space in spaces) {
            if (![space isKindOfClass:NSDictionary.class]) continue;
            // Desktops (0) and full-screen Spaces (4) only.
            NSNumber *type = space[@"type"];
            if (![type isKindOfClass:NSNumber.class] || (type.intValue != 0 && type.intValue != 4)) continue;
            NSNumber *id64 = [space[@"id64"] isKindOfClass:NSNumber.class] ? space[@"id64"] : nil;
            NSNumber *managedID = [space[@"ManagedSpaceID"] isKindOfClass:NSNumber.class] ? space[@"ManagedSpaceID"] : nil;
            if ((id64 && [member containsObject:@(id64.unsignedLongLongValue)])
                || (managedID && [member containsObject:@(managedID.unsignedLongLongValue)])) continue;
            NSNumber *identifier = id64 ?: managedID;
            if (identifier && ![missing containsObject:identifier]) [missing addObject:identifier];
        }
    }
    return missing;
}
