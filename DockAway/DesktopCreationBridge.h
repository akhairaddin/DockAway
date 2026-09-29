#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

BOOL DockAwayCloseWindow(pid_t pid, CGWindowID windowID);
BOOL DockAwayMinimizeWindow(pid_t pid, CGWindowID windowID);

NS_ASSUME_NONNULL_BEGIN
NSArray<NSDictionary<NSString *, id> *> *DockAwayMissionControlShortcuts(pid_t pid);
BOOL DockAwayDesktopCreationAvailable(void);
BOOL DockAwayDesktopRemovalAvailable(void);
BOOL DockAwayRemoveDesktop(uint64_t spaceID);
BOOL DockAwayCloseFullscreenSpace(uint64_t spaceID);
uint64_t DockAwayCreateDesktop(void);
uint64_t DockAwayCreateDesktopOnDisplay(uint32_t displayID, uint64_t anchorSpaceID);
BOOL DockAwayJumpToDesktop(uint64_t spaceID, uint64_t expectedCurrentID);
BOOL DockAwayActivateSpace(uint64_t spaceID);
BOOL DockAwayReorderDesktop(uint64_t spaceID, uint64_t targetID);
BOOL DockAwayAppendDesktop(uint64_t spaceID, uint64_t targetID);
BOOL DockAwayMoveWindowToSpace(CGWindowID windowID, uint64_t targetSpaceID);
BOOL DockAwayIsWindowOnSpace(CGWindowID windowID, uint64_t spaceID);
BOOL DockAwayRepositionWindowToDisplay(pid_t pid, CGWindowID windowID, CGRect displayBounds);
NSDictionary<NSNumber *, NSArray<NSNumber *> *> * _Nullable DockAwayCopyDesktopApplicationPIDs(NSArray<NSNumber *> *spaceIDs);
NS_ASSUME_NONNULL_END
