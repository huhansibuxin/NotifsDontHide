// NotifsDontHide — force same-app notification grouping.
// OneNotificationListFFS.dylib (in layout) handles notification persistence.

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
    return self.sectionIdentifier;
}

%end

%hook NCNotificationGroupList

- (NSUInteger)maxVisibleNotificationCount {
    return 2;
}

- (BOOL)shouldShowSummaryView {
    NSUInteger total = [self notificationCount];
    if (total > 2) {
        return YES;
    }
    return %orig;
}

%end

%hook NCNotificationGroupManager

- (id)groupForNotificationRequest:(id)arg1 createIfNecessary:(BOOL)arg2 {
    id group = %orig;
    return group;
}

%end

%ctor {
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
