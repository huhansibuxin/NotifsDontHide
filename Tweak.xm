#import <UIKit/UIKit.h>

// ============================================================
// NotifsDontHide
//
// Inspired by KeepItSimple (P2KDev) and Notif (KingPuffDadday).
// Zero-config tweak: all notifications stay in ONE list,
// history/missed sections are eliminated at the source.
// ============================================================

// -- Master list: controls notification section routing --
@interface NCNotificationMasterList : NSObject
- (BOOL)_isNotificationRequestForIncomingSection:(id)arg1;
- (BOOL)_isNotificationRequestForHistorySection:(id)arg1;
- (void)migrateNotifications;
- (void)_migrateNotificationsFromList:(id)arg1 toList:(id)arg2 passingTest:(id)arg3 hideToList:(BOOL)arg4 clearRequests:(BOOL)arg5;
- (BOOL)isNotificationHistoryRevealed;
- (BOOL)shouldAllowNotificationHistoryReveal;
- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)arg1;
- (void)setShouldAllowNotificationHistoryReveal:(BOOL)arg1;
- (void)setRevealCoordinator:(id)arg1;
- (id)revealCoordinator;
- (BOOL)isMissedSectionActive;
- (void)setMissedSectionActive:(BOOL)arg1;
- (BOOL)notificationStructuredSectionList:(id)arg1 shouldFilterNotificationRequest:(id)arg2;
@end

// ============================================================
// Hook NCNotificationMasterList: kill history/missed sections
// ============================================================
%hook NCNotificationMasterList

// All notifications → incoming section
- (BOOL)_isNotificationRequestForIncomingSection:(id)arg1 {
    return YES;
}

// No notification → history section
- (BOOL)_isNotificationRequestForHistorySection:(id)arg1 {
    return NO;
}

// Block migration between sections
- (void)migrateNotifications {
    return;
}

- (void)_migrateNotificationsFromList:(id)arg1 toList:(id)arg2 passingTest:(id)arg3 hideToList:(BOOL)arg4 clearRequests:(BOOL)arg5 {
    return;
}

// Always treat history as revealed (prevents UI from hiding old notifs)
- (BOOL)isNotificationHistoryRevealed {
    return YES;
}

- (BOOL)shouldAllowNotificationHistoryReveal {
    return NO;
}

- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)arg1 {
    return NO;
}

- (void)setShouldAllowNotificationHistoryReveal:(BOOL)arg1 {
    %orig(NO);
}

// Disable reveal coordinator
- (void)setRevealCoordinator:(id)arg1 {
    return;
}

- (id)revealCoordinator {
    return nil;
}

// Disable missed section
- (BOOL)isMissedSectionActive {
    return NO;
}

- (void)setMissedSectionActive:(BOOL)arg1 {
    %orig(NO);
}

// Don't filter anything out
- (BOOL)notificationStructuredSectionList:(id)arg1 shouldFilterNotificationRequest:(id)arg2 {
    return NO;
}

%end
