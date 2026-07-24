// NotifsDontHide — force same-app notification grouping.
// OneNotificationListFFS.dylib (in layout) handles notification persistence.
// Keep hooks minimal to avoid MSHookMessageEx chain conflicts with original dylib.

#import <Foundation/Foundation.h>

@interface NCNotificationRequest : NSObject
@property (nonatomic,copy,readonly) NSString *sectionIdentifier;
@property (nonatomic,copy,readonly) NSString *threadIdentifier;
@end

@interface NCNotificationGroupList : NSObject
- (NSUInteger)notificationCount;
@end

@interface NCNotificationGroupManager : NSObject
- (id)groupForNotificationRequest:(id)arg1 createIfNecessary:(BOOL)arg2;
@end

%hook NCNotificationRequest

- (NSString *)threadIdentifier {
    NSString *orig = %orig;
    NSString *section = self.sectionIdentifier;
    static int callCount = 0;
    if (++callCount <= 5) {
        NSLog(@"[NHD] threadIdentifier: orig=%@ → section=%@", orig, section);
    }
    return section;
}

%end

%hook NCNotificationGroupList
- (NSUInteger)maxVisibleNotificationCount {
    NSUInteger orig = %orig;
    NSLog(@"[NHD] GroupList.maxVisibleNotificationCount: orig=%lu → forced=2", (unsigned long)orig);
    return 2;
}
- (BOOL)shouldShowSummaryView {
    BOOL orig = %orig;
    NSUInteger total = [self notificationCount];
    if (total > 2) {
        NSLog(@"[NHD] GroupList.shouldShowSummaryView: orig=%d, total=%lu → forced YES", orig, (unsigned long)total);
        return YES;
    }
    NSLog(@"[NHD] GroupList.shouldShowSummaryView: orig=%d, total=%lu → passthrough", orig, (unsigned long)total);
    return orig;
}
%end

%hook NCNotificationGroupManager
- (id)groupForNotificationRequest:(id)arg1 createIfNecessary:(BOOL)arg2 {
    id group = %orig;
    NSLog(@"[NHD] GroupManager.groupForNotificationRequest: create=%d, group=%@", arg2, group);
    return group;
}
%end

// ============================================================
// Ensure OneNotificationListFFS.dylib's CFPreferences switch is ON.
// The original dylib checks CFPreferencesGetAppBooleanValue("enabled", ...)
// with NULL default → false when unset, so all 49 hooks are dormant.
// ============================================================
%ctor {
    // Minimal diagnostic — does this even run?
    [@"LOADED" writeToFile:@"/tmp/NHD_diag.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
