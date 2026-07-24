#import <UIKit/UIKit.h>

// ============================================================
// NotifsDontHide v1.0.2 — rootless (ElleKit)
//
// Rewritten based on reverse-engineering OneNotificationListFFS.
// iOS 16 significantly restructured notification architecture.
// ============================================================

#pragma mark - NCNotificationMasterList

@interface NCNotificationMasterList : NSObject
// iOS 16 migration (renamed)
- (void)migrateNotificationsFromIncomingSectionToHistorySection;
- (void)migrateNotificationsFromIncomingSectionToHistorySectionAndHideHistorySection:(BOOL)arg1;
// Reveal & display style
- (BOOL)isNotificationHistoryRevealed;
- (BOOL)shouldAllowNotificationHistoryReveal;
- (void)setShouldAllowNotificationHistoryReveal:(BOOL)arg1;
- (void)setNotificationHistoryRevealed:(BOOL)arg1;
- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)arg1;
- (BOOL)notificationListRevealCoordinatorShouldAllowRevealTransition:(id)arg1;
- (BOOL)notificationListInteractiveTransitionCoordinatorRequestsIsHiddenListRevealed:(id)arg1;
// Legacy section routing (fallback)
- (BOOL)_isNotificationRequestForIncomingSection:(id)arg1;
- (BOOL)_isNotificationRequestForHistorySection:(id)arg1;
@end

#pragma mark - NCNotificationStructuredSectionList

@interface NCNotificationStructuredSectionList : NSObject
- (id)incomingSectionList;
- (id)historySectionList;
- (id)_sectionForNotificationRequest:(id)arg1;
- (id)_sectionForStoredNotificationRequestOfSectionType:(long long)arg1;
@end

#pragma mark - NCNotificationListCell

@interface NCNotificationListCell : UIView
- (BOOL)cellWithActionsRevealed;
- (void)setCellWithActionsRevealed:(BOOL)arg1;
- (void)setSideSwipedWithoutTouch:(BOOL)arg1;
- (void)hideActionButtonsAnimated:(BOOL)arg1 fastAnimation:(BOOL)arg2 completion:(id)arg3;
- (void)_notifyDelegateDidDismiss;
@end

#pragma mark - CSCombinedListViewController

@interface CSCombinedListViewController : UIViewController
- (BOOL)isListDisplayStyleHiddenForUserInteraction;
- (void)setListDisplayStyleHiddenForUserInteraction:(BOOL)arg1;
- (id)currentListDisplayStyleSetting;
- (void)setCurrentListDisplayStyleSetting:(id)arg1;
- (void)performCustomTransitionToVisible:(BOOL)arg1 withAnimationSettings:(id)arg2 completion:(id)arg3;
@end

#pragma mark - NCNotificationShortLookViewController

@interface NCNotificationShortLookViewController : UIViewController
- (void)noteWillPresentForUserGesture;
- (void)_notifyDelegateDidDismiss;
@end

#pragma mark - NCNotificationGroupList

@interface NCNotificationGroupList : NSObject
- (BOOL)isGroupForNotificationRequest:(id)arg1;
- (void)handleTapOnNotificationListBaseComponent:(id)arg1;
@end

#pragma mark - NCNotificationRequest

@interface NCNotificationRequest : NSObject
@property (nonatomic,copy,readonly) NSString *sectionIdentifier;
@property (nonatomic,copy,readonly) NSString *threadIdentifier;
@end

// ============================================================
// HOOKS
// ============================================================

// ---- NCNotificationMasterList ----

%hook NCNotificationMasterList

- (void)migrateNotificationsFromIncomingSectionToHistorySection {
    return;
}

- (void)migrateNotificationsFromIncomingSectionToHistorySectionAndHideHistorySection:(BOOL)arg1 {
    return;
}

- (BOOL)_isNotificationRequestForIncomingSection:(id)arg1 {
    return YES;
}

- (BOOL)_isNotificationRequestForHistorySection:(id)arg1 {
    return NO;
}

- (BOOL)isNotificationHistoryRevealed {
    return YES;
}

- (BOOL)shouldAllowNotificationHistoryReveal {
    return NO;
}

- (void)setShouldAllowNotificationHistoryReveal:(BOOL)arg1 {
    %orig(NO);
}

- (void)setNotificationHistoryRevealed:(BOOL)arg1 {
    %orig(YES);
}

- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)arg1 {
    return NO;
}

- (BOOL)notificationListRevealCoordinatorShouldAllowRevealTransition:(id)arg1 {
    return NO;
}

- (BOOL)notificationListInteractiveTransitionCoordinatorRequestsIsHiddenListRevealed:(id)arg1 {
    return NO;
}

%end

// ---- NCNotificationStructuredSectionList ----

%hook NCNotificationStructuredSectionList

- (id)_sectionForNotificationRequest:(id)arg1 {
    return [self incomingSectionList];
}

- (id)_sectionForStoredNotificationRequestOfSectionType:(long long)arg1 {
    return [self incomingSectionList];
}

- (id)historySectionList {
    return nil;
}

%end

// ---- NCNotificationListCell ----

%hook NCNotificationListCell

- (BOOL)cellWithActionsRevealed {
    return NO;
}

- (void)setCellWithActionsRevealed:(BOOL)arg1 {
    %orig(NO);
}

- (void)setSideSwipedWithoutTouch:(BOOL)arg1 {
    %orig(NO);
}

- (void)hideActionButtonsAnimated:(BOOL)arg1 fastAnimation:(BOOL)arg2 completion:(id)arg3 {
    return;
}

- (void)_notifyDelegateDidDismiss {
    return;
}

%end

// ---- CSCombinedListViewController ----

%hook CSCombinedListViewController

- (BOOL)isListDisplayStyleHiddenForUserInteraction {
    return NO;
}

- (void)setListDisplayStyleHiddenForUserInteraction:(BOOL)arg1 {
    %orig(NO);
}

- (void)performCustomTransitionToVisible:(BOOL)arg1 withAnimationSettings:(id)arg2 completion:(id)arg3 {
    return;
}

%end

// ---- NCNotificationShortLookViewController ----

%hook NCNotificationShortLookViewController

- (void)noteWillPresentForUserGesture {
    return;
}

- (void)_notifyDelegateDidDismiss {
    return;
}

%end

// ---- NCNotificationGroupList ----

%hook NCNotificationGroupList

- (BOOL)isGroupForNotificationRequest:(id)arg1 {
    return YES;
}

- (void)handleTapOnNotificationListBaseComponent:(id)arg1 {
    return;
}

%end

// ---- NCNotificationRequest ----

%hook NCNotificationRequest

- (NSString *)threadIdentifier {
    return self.sectionIdentifier;
}

%end
