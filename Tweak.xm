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
