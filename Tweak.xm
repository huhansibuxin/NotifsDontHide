// NotifsDontHide — two features, one dylib, no bundled helpers.
//
// Feature 1 — merge early (after the 2nd notification) for ALL apps:
//   iOS default shows up to 4 individually, the 5th collapses. We collapse
//   after the 1st, so the 2nd notification already merges into one bar.
//
// Feature 2 — never hide in Notification Center:
//   iOS migrates incoming notifications into a "history" section and hides
//   that section (and hides grouped notifications on device re-auth). We
//   block the migration and the hide calls so everything stays visible.
//
// This single tweak replaces the old split design (NotifsDontHide + the
// bundled OneNotificationListFFS.dylib). The "never hide" logic was
// reverse-engineered from OneNotificationListFFS and rewritten here against
// the real iOS 16 method names (verified on-device).

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

// Notifications shown individually before the rest collapse into the single
// merged group bar. 1 => "2nd notification merges into the bar".
static const NSUInteger kCollapseThreshold = 1;

// Hook a method only if the class and selector actually exist (silent skip, so
// a future iOS change can never crash SpringBoard from this tweak).
static void ndh_try_hook(const char *clsName, SEL sel, IMP imp, IMP *orig) {
    Class cls = objc_getClass(clsName);
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    MSHookMessageEx(cls, sel, imp, orig);
}

// --- Feature 1: merge after the 2nd ---

// Force every notification of an app onto one thread => one group, so the
// collapsing queue treats them as one collapsible set.
static id (*orig_threadIdentifier)(id, SEL);
static id hook_threadIdentifier(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(sectionIdentifier)]) {
        return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
    }
    return orig_threadIdentifier(self, _cmd);
}

// iOS 16: how many requests accumulate in a collapsing queue before they merge
// into one collapsed "bar". Default is 4 (=> the 5th merges). Return 1 so the
// 2nd notification already merges.
static NSUInteger (*orig_collapsingThreshold)(id, SEL);
static NSUInteger hook_collapsingThreshold(id self, SEL _cmd) {
    return kCollapseThreshold;
}

// iOS 16 backup lever: dynamic grouping threshold on the section list.
static NSUInteger (*orig_dynamicGroupingThreshold)(id, SEL);
static NSUInteger hook_dynamicGroupingThreshold(id self, SEL _cmd) {
    return kCollapseThreshold;
}

%ctor {
    ndh_try_hook("NCNotificationRequest", @selector(threadIdentifier),
                 (IMP)&hook_threadIdentifier, (IMP*)&orig_threadIdentifier);
    ndh_try_hook("NCNotificationCollapsingQueue", @selector(collapsingThreshold),
                 (IMP)&hook_collapsingThreshold, (IMP*)&orig_collapsingThreshold);
    ndh_try_hook("NCNotificationStructuredSectionList", @selector(dynamicGroupingThreshold),
                 (IMP)&hook_dynamicGroupingThreshold, (IMP*)&orig_dynamicGroupingThreshold);
}

// --- Feature 2: never hide (rewritten from OneNotificationListFFS, iOS 16 names) ---

%hook NCNotificationMasterList
// Block incoming -> history migration: notifications never move to the hidden
// history section, so they stay visible. (iOS 16's 9-arg variant of the
// method KeepItSimple hooked as a 2-arg version on iOS 13-15.)
- (void)_migrateNotificationsFromList:(id)arg1 toList:(id)arg2 passingTest:(id)arg3 filterRequestsPassingTest:(id)arg4 hideToList:(BOOL)arg5 clearRequests:(BOOL)arg6 filterForDestination:(id)arg7 animateRemoval:(BOOL)arg8 reorderGroupNotifications:(BOOL)arg9 {
    // intentionally empty: keep everything where it is.
}
// Tell the system there is always visible content, so it never collapses/hides
// the list.
- (BOOL)hasVisibleContentToReveal { return YES; }
%end

%hook NCNotificationStructuredSectionList
// Block the "hide groups" calls that fire when the device re-authenticates
// (lock/unlock) or in other situations, so grouped notifications stay shown.
- (void)_hideNotificationGroupsOnDeviceReauthentication {
    // intentionally empty.
}
- (void)_hideNotificationGroupsPassingTest:(id)arg1 {
    // intentionally empty.
}
- (BOOL)hasVisibleContentToReveal { return YES; }
%end
