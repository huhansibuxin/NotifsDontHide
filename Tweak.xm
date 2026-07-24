#import <UIKit/UIKit.h>

// ============================================================
// NotifsDontHide v1.0.3 — rootless (ElleKit)
//
// Completely rewritten based on exact __objc_methname list
// extracted from OneNotificationListFFS.dylib.
//
// iOS 16+: _isNotificationRequestForIncomingSection is DEAD.
// Section routing now goes through NCNotificationStructuredSectionList.
// ============================================================

#pragma mark - NCNotificationMasterList

@interface NCNotificationMasterList : NSObject
- (void)migrateNotificationsFromIncomingSectionToHistorySection;
- (void)migrateNotificationsFromIncomingSectionToHistorySectionAndHideHistorySection:(BOOL)arg1;
- (BOOL)isNotificationHistoryRevealed;
- (BOOL)shouldAllowNotificationHistoryReveal;
- (void)setShouldAllowNotificationHistoryReveal:(BOOL)arg1;
- (void)setNotificationHistoryRevealed:(BOOL)arg1;
- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)arg1;
- (BOOL)notificationListRevealCoordinatorShouldAllowRevealTransition:(id)arg1;
- (BOOL)notificationListInteractiveTransitionCoordinatorRequestsIsHiddenListRevealed:(id)arg1;
- (void)setGroupListView:(id)arg1;
- (id)groupListView;
- (id)historySectionList;
- (id)incomingSectionList;
@end

#pragma mark - NCNotificationStructuredSectionList

@interface NCNotificationStructuredSectionList : NSObject
- (id)_sectionForNotificationRequest:(id)arg1;
- (id)_sectionForStoredNotificationRequestOfSectionType:(long long)arg1;
- (id)incomingSectionList;
- (id)historySectionList;
- (id)_currentCellForNotificationRequest:(id)arg1;
@end

#pragma mark - NCNotificationListCell

@interface NCNotificationListCell : UIView
- (BOOL)cellWithActionsRevealed;
- (void)setCellWithActionsRevealed:(BOOL)arg1;
- (void)setSideSwipedWithoutTouch:(BOOL)arg1;
- (void)hideActionButtonsAnimated:(BOOL)arg1 fastAnimation:(BOOL)arg2 completion:(id)arg3;
- (void)_notifyDelegateDidDismiss;
- (void)_handleTapToExpandGroupForNotificationRequest:(id)arg1;
- (void)_handleTapOnView:(id)arg1;
@end

#pragma mark - CSCombinedListViewController

@interface CSCombinedListViewController : UIViewController
- (BOOL)isListDisplayStyleHiddenForUserInteraction;
- (void)setListDisplayStyleHiddenForUserInteraction:(BOOL)arg1;
- (id)currentListDisplayStyleSetting;
- (void)setCurrentListDisplayStyleSetting:(id)arg1;
- (void)performCustomTransitionToVisible:(BOOL)arg1 withAnimationSettings:(id)arg2 completion:(id)arg3;
- (BOOL)isTransitioning;
- (BOOL)isPresented;
- (void)viewWillAppear:(BOOL)arg1;
- (void)viewDidAppear:(BOOL)arg1;
@end

#pragma mark - NCNotificationShortLookViewController

@interface NCNotificationShortLookViewController : UIViewController
- (void)noteWillPresentForUserGesture;
- (void)_notifyDelegateDidDismiss;
- (id)notificationRequest;
@end

#pragma mark - NCNotificationGroupList

@interface NCNotificationGroupList : NSObject
- (BOOL)isGroupForNotificationRequest:(id)arg1;
- (BOOL)isGrouped;
- (void)toggleGroupedState;
- (void)collapseGroupForNotificationRequest:(id)arg1 withCompletion:(id)arg2;
- (void)handleTapOnNotificationListBaseComponent:(id)arg1;
- (id)notificationGroups;
- (id)leadingNotificationRequest;
- (id)orderedRequests;
@end

#pragma mark - SBLockScreenManager

@interface SBLockScreenManager : NSObject
+ (id)sharedInstanceIfExists;
- (BOOL)isLockScreenActive;
- (BOOL)isLockScreenVisible;
- (BOOL)isLockScreenPresentationPending;
@end

#pragma mark - NCNotificationRequest

@interface NCNotificationRequest : NSObject
@property (nonatomic,copy,readonly) NSString *sectionIdentifier;
@property (nonatomic,copy,readonly) NSString *threadIdentifier;
@end

#pragma mark - CSCoverSheetViewController

@interface CSCoverSheetViewController : UIViewController
- (void)_coversheetDidDismiss;
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

- (id)historySectionList {
    return nil;
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

- (void)_handleTapToExpandGroupForNotificationRequest:(id)arg1 {
    return;
}

- (void)_handleTapOnView:(id)arg1 {
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

- (void)toggleGroupedState {
    return;
}

%end

// ---- NCNotificationRequest ----

%hook NCNotificationRequest

- (NSString *)threadIdentifier {
    return self.sectionIdentifier;
}

%end
