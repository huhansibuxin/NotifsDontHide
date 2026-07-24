// NotifsDontHide — force same-app notification grouping.
// OneNotificationListFFS.dylib (in layout) handles notification persistence.
// Keep hooks minimal to avoid MSHookMessageEx chain conflicts with original dylib.

#import <Foundation/Foundation.h>

@interface NCNotificationRequest : NSObject
@property (nonatomic,copy,readonly) NSString *sectionIdentifier;
@property (nonatomic,copy,readonly) NSString *threadIdentifier;
@end

%hook NCNotificationRequest

- (NSString *)threadIdentifier {
    return self.sectionIdentifier;
}

%end

// ============================================================
// Ensure OneNotificationListFFS.dylib's CFPreferences switch is ON.
// The original dylib checks CFPreferencesGetAppBooleanValue("enabled", ...)
// with NULL default → false when unset, so all 49 hooks are dormant.
// ============================================================
%ctor {
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
