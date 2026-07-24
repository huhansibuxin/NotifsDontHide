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
    NSString *orig = %orig;
    NSString *section = self.sectionIdentifier;
    static int callCount = 0;
    if (++callCount <= 5) {
        NSLog(@"[NHD] threadIdentifier: orig=%@ → section=%@", orig, section);
    }
    return section;
}

%end

// ============================================================
// Ensure OneNotificationListFFS.dylib's CFPreferences switch is ON.
// The original dylib checks CFPreferencesGetAppBooleanValue("enabled", ...)
// with NULL default → false when unset, so all 49 hooks are dormant.
// ============================================================
%ctor {
    // Write diagnostic file to confirm dylib loaded
    NSString *diag = @"/var/jb/var/mobile/Documents/NHD_diag.txt";
    NSString *log = [NSString stringWithFormat:
        @"NotifsDontHide loaded\n"
        @"NCNotificationRequest = %@\n"
        @"respondsToSelector(threadIdentifier) = %d\n"
        @"respondsToSelector(sectionIdentifier) = %d\n",
        NSClassFromString(@"NCNotificationRequest") ? @"YES" : @"nil",
        [NSClassFromString(@"NCNotificationRequest") respondsToSelector:@selector(threadIdentifier)],
        [NSClassFromString(@"NCNotificationRequest") respondsToSelector:@selector(sectionIdentifier)]];
    [log writeToFile:diag atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    // Ensure OneNotificationListFFS.dylib's CFPreferences switch is ON.
    CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
        CFSTR("com.b4db1r3.onenotificationlistffs"));
    CFPreferencesAppSynchronize(CFSTR("com.b4db1r3.onenotificationlistffs"));
}
