// NotifsDontHide
// OneNotificationListFFS.dylib (in layout) handles notification persistence.

#import <Foundation/Foundation.h>

@interface NCNotificationRequest : NSObject
@property (nonatomic,copy,readonly) NSString *sectionIdentifier;
@property (nonatomic,copy,readonly) NSString *threadIdentifier;
@end

@interface NCNotificationGroupList : NSObject
- (NSInteger)notificationCount;
@end

// Force same-app notifications into one group
%hook NCNotificationRequest
- (NSString *)threadIdentifier {
    return self.sectionIdentifier;
}
%end

// Cap visible notifications to 2 per group
%hook NCNotificationGroupList
- (NSInteger)notificationCount {
    NSInteger orig = %orig;
    return (orig > 2) ? 2 : orig;
}
%end

%ctor {
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
