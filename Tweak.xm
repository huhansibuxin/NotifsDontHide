// NotifsDontHide — force same-app notification grouping
// OneNotificationListFFS.dylib handles notification persistence (shipped in layout)

#import <Foundation/Foundation.h>

// ============================================================
// Force all notifications from the same app into one group
// by making threadIdentifier == sectionIdentifier (bundle ID).
// iOS groups notifications by threadIdentifier internally.
// ============================================================

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
// Ensure groups stay in grouped (collapsed) state
// ============================================================

@interface NCNotificationGroupList : NSObject
- (BOOL)isGrouped;
- (BOOL)isGroupForNotificationRequest:(id)request;
@end

%hook NCNotificationGroupList

- (BOOL)isGrouped {
    return YES;
}

- (BOOL)isGroupForNotificationRequest:(id)request {
    return YES;
}

%end

// OneNotificationListFFS.dylib is loaded separately via MobileSubstrate filter
