#import <UIKit/UIKit.h>

// ============================================================
// NotifsDontHide - notifications never hide from Notification Center
//
// iOS moves viewed notifications into a "history" section,
// hiding them on the next visit. This tweak forces all
// notifications to stay visible in a single unified list.
// ============================================================

// -- Notification Center (下拉通知中心) --
@interface NCNotificationCombinedListViewController : UIViewController
- (void)forceNotificationHistoryRevealed:(bool)arg1 animated:(bool)arg2;
@end

// -- Lock Screen (锁屏通知) --
@interface CSCombinedListViewController : UIViewController
- (void)forceNotificationHistoryRevealed:(bool)arg1 animated:(bool)arg2;
@end

// -- Section header (分区标题, 隐藏它以获得统一列表) --
@interface NCNotificationListSectionHeaderView : UICollectionReusableView
@end

// -- "No Older Notifications" hint --
@interface NCNotificationListSectionRevealHintView : UIView
@end

// -- Section header height --
@interface NCNotificationStructuredSectionList : NSObject
- (double)headerViewHeightForNotificationList:(id)arg1;
@end


// === Hook: 每次打开通知中心时展开历史 ===
%hook NCNotificationCombinedListViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self forceNotificationHistoryRevealed:YES animated:NO];
}

%end


// === Hook: 锁屏通知也展开历史 ===
%hook CSCombinedListViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self forceNotificationHistoryRevealed:YES animated:NO];
}

%end


// === Hook: 隐藏分区标题 ===
%hook NCNotificationListSectionHeaderView

- (id)initWithFrame:(CGRect)arg1 {
    NCNotificationListSectionHeaderView *r = %orig;
    r.hidden = YES;
    return r;
}

%end


// === Hook: 隐藏"无旧通知"提示文字 ===
%hook NCNotificationListSectionRevealHintView

- (void)layoutSubviews {
    return;
}

%end


// === Hook: 分区标题高度归零 ===
%hook NCNotificationStructuredSectionList

- (double)headerViewHeightForNotificationList:(id)arg1 {
    return 0;
}

%end
