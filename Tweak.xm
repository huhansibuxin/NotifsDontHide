// NotifsDontHide — rewritten from OneNotificationListFFS 0.0.2 (iOS 16 branch).
//
// ============================================================================
// WHY THE OLD APPROACH FAILED (18 versions, 1.0.31 → 1.0.48)
// ============================================================================
// The old Feature 2 followed the KeepItSimple route: let notifications migrate
// into the "history" section, then FORCE that section revealed so they stay
// visible. That fights SpringBoard's notification-list lifecycle head-on:
//
//   1.0.41  blocked the 9-arg _migrateNotificationsFromList: mover
//           → notifications DESTROYED on unlock (the incoming list is torn
//             down and migration into history is the only thing keeping them)
//   1.0.44/45  force-revealed unconditionally
//           → permanent "No Older Notifications" empty hint
//   1.0.46  content-aware reveal + 150ms/500ms retry
//           → first-open-after-cold-start race still loses notifications
//
// Root cause was architectural, not a wrong hook point: every version tried to
// control WHICH SECTION notifications live in, and SpringBoard owns that.
//
// ============================================================================
// WHAT ONL DOES INSTEAD (reverse-engineered from the shipped 0.0.2 binary)
// ============================================================================
// ONL never lets notifications reach history at all, and never reveals it:
//
//   A. BLOCK the two history-migration entry points on NCNotificationMasterList.
//   B. REDIRECT any request the system wants in history → incoming section
//      (_sectionForNotificationRequest: / _sectionForStoredNotificationRequestOfSectionType:).
//      This is the piece 1.0.41 was missing: the notification still "migrates",
//      just into the section that stays alive instead of the one that gets torn
//      down. Blocking alone (A) loses data; A+B is safe.
//   C. Force the list display style to 0 and hidden-for-user-interaction to NO,
//      so the incoming section is never collapsed or torn down on unlock.
//   D. Force history NOT revealed (opposite of the old approach) → no history
//      section, therefore no empty-hint problem at all.
//   E. For the "one list" effect: any NCNotificationGroupList that holds more
//      than one notification AND whose collapsed view is short (<160pt) gets
//      FORCE-EXPANDED, so every notification shows individually on the lock
//      screen. Big stacks stay collapsed (160pt guard) so the screen never
//      fills up.
//   F. Taps are routed through a custom recognizer so a tap on a cell inside a
//      force-expanded stack opens that notification instead of re-collapsing
//      the stack.
//
// No reveal race exists because the interception happens at the deterministic
// section-routing layer (B), not at a content-hydration timing layer.
//
// Event-driven only. The only timers are the two one-shot 300ms/800ms gates
// that clear transient tap state — identical to the original. No polling.
//
// Verified against: /var/jb/Library/MobileSubstrate/DynamicLibraries/
//                   OneNotificationListFFS.dylib (0.0.2, iphoneos-arm64e)
// ============================================================================

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <string.h>
#import <dispatch/dispatch.h>

// ---------------------------------------------------------------------------
// Prefs
// ---------------------------------------------------------------------------
// App id kept identical to the old build so an existing settings pane and any
// saved preferences keep working across the upgrade.
static NSString *const kPrefsAppID = @"com.huhansibuxin.notifsdonthide";

// Master switch for the ONL architecture. Default YES (tweak is on).
static BOOL g_enabled = YES;
// Opt-in legacy Feature 1: collapse after the 1st notification (merge early).
// OFF by default — ONL's force-expand (E) already yields the single-list
// effect, and merging everything into one giant group can push the stack past
// the 160pt guard so it never expands. Flip on only for A/B testing.
static BOOL g_mergeEarly = NO;
// Debug log gate: create /var/jb/tmp/ndh_debug to enable. Zero cost when off.
static BOOL g_debug = NO;
// iOS version gate: the hook set below is the iOS 16 branch. On any other
// major version every hook degrades to a pure pass-through.
static BOOL g_supported = NO;

static const NSUInteger kCollapseThreshold = 1;
// Stacks whose collapsed view is shorter than this are force-expanded.
static const CGFloat kExpandHeightLimit = 160.0;
// Transient "user tapped, expansion allowed" gate lifetime.
static const uint64_t kExpansionGateNS = 800 * NSEC_PER_MSEC;
// Transient "this tap came from an expanded stack" flag lifetime.
static const uint64_t kStackTapNS = 300 * NSEC_PER_MSEC;

// Associated-object keys. Unique to this tweak so they can never collide with
// another tweak's state on the same object.
static const void *kKeyExpanded      = (const void *)&kKeyExpanded;
static const void *kKeyExpansionGate = (const void *)&kKeyExpansionGate;
static const void *kKeyTapRecognizer = (const void *)&kKeyTapRecognizer;
static const void *kKeyStackTap      = (const void *)&kKeyStackTap;

#define ONL_ACTIVE (g_enabled && g_supported)

// ---------------------------------------------------------------------------
// Debug logging — injected dylib NSLog is NOT captured by oslog on this setup,
// so append to a file instead. Gated by g_debug; production cost is one
// statically-false branch.
// ---------------------------------------------------------------------------
static void ndh_log(NSString *fmt, ...) {
    if (!g_debug) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/var/jb/tmp/NotifsDontHide.log", "a");
    if (f) { fprintf(f, "%s\n", [msg UTF8String]); fclose(f); }
}

// ---------------------------------------------------------------------------
// Safe ObjC helpers. Every private call is guarded by respondsToSelector so a
// future iOS rename degrades to a no-op instead of an unrecognized-selector
// crash in SpringBoard.
// ---------------------------------------------------------------------------

// Send a zero-arg message that returns an object, safely.
static id onl_send0(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

// Send a one-arg message that returns an object, safely.
static id onl_send1(id obj, SEL sel, id arg) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

// Send a zero-arg message that returns NSUInteger, safely.
static NSUInteger onl_sendUInt0(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

// Read an instance variable by name, walking the class hierarchy. This is what
// makes the tweak survive ivar-offset churn between iOS builds — never hardcode
// an offset, always resolve the name at runtime.
static id onl_ivarValue(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    Class c = object_getClass(obj);
    while (c) {
        Ivar iv = class_getInstanceVariable(c, ivarName);
        if (iv) return object_getIvar(obj, iv);
        c = class_getSuperclass(c);
    }
    return nil;
}

static BOOL onl_isKindOfClass(id obj, Class cls) {
    if (!obj || !cls) return NO;
    return ((BOOL (*)(id, SEL, Class))objc_msgSend)(obj, @selector(isKindOfClass:), cls);
}

// ---------------------------------------------------------------------------
// Group-list predicates (all operate on NCNotificationGroupList instances)
// ---------------------------------------------------------------------------

// A real multi-notification stack: responds to orderedRequests and holds >1.
static BOOL onl_isMultiGroup(id groupList) {
    if (!groupList) return NO;
    if (![groupList respondsToSelector:@selector(orderedRequests)]) return NO;
    id reqs = onl_send0(groupList, @selector(orderedRequests));
    if (!reqs) return NO;
    return onl_sendUInt0(reqs, @selector(count)) > 1;
}

// The group's scroll view, resolved by ivar name (never by offset).
static id onl_groupListView(id groupList) {
    return onl_ivarValue(groupList, "_groupListView");
}

// Whether this stack is small enough that force-expanding it cannot flood the
// lock screen. Mirrors the original: the collapsed content must fit inside its
// own frame and stay under the height limit.
static BOOL onl_shouldExpand(id groupList) {
    if (!groupList) return NO;
    if (!onl_isMultiGroup(groupList)) return NO;

    id listView = onl_groupListView(groupList);
    if (!listView) return NO;

    Class scrollCls = objc_getClass("UIScrollView");
    if (!scrollCls || !onl_isKindOfClass(listView, scrollCls)) return NO;

    if (![listView respondsToSelector:@selector(contentSize)]) return NO;
    if (![listView respondsToSelector:@selector(bounds)]) return NO;

    CGSize content = ((CGSize (*)(id, SEL))objc_msgSend)(listView, @selector(contentSize));
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(listView, @selector(bounds));

    // Content must fit within the visible frame (no scrolling needed to see it
    // all) and the frame must be short enough that expanding is not absurd.
    if (content.height > CGRectGetHeight(bounds) + 1.0) return NO;
    return CGRectGetHeight(bounds) < kExpandHeightLimit;
}

// Transient "user tapped, expansion allowed" gate.
static BOOL onl_expansionAllowed(id groupList) {
    if (!groupList) return NO;
    id v = objc_getAssociatedObject(groupList, kKeyExpansionGate);
    return [v boolValue];
}

static void onl_setExpansionGate(id groupList, BOOL on) {
    if (!groupList) return;
    objc_setAssociatedObject(groupList, kKeyExpansionGate,
                             on ? (id)kCFBooleanTrue : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!on) return;
    // Strong-capture self for the (<=800ms) gate window so the group list is
    // guaranteed alive when the timer fires.
    id me = groupList;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kExpansionGateNS),
                   dispatch_get_main_queue(), ^{
        // Only clear if still set — a newer tap may have refreshed it.
        id cur = objc_getAssociatedObject(me, kKeyExpansionGate);
        if ([cur boolValue]) {
            objc_setAssociatedObject(me, kKeyExpansionGate, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

// Force-expand a stack on the next main-queue turn. Doing this synchronously
// inside a setter re-enters the list machinery and deadlocks, so it is always
// deferred — exactly as the original does.
static void onl_forceExpand(id groupList) {
    if (!groupList) return;
    id me = groupList;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ONL_ACTIVE) return;
        // Dismiss any revealed swipe actions first, otherwise the expanded
        // stack shows a half-open action row.
        if ([me respondsToSelector:@selector(hideActionButtonsAnimated:fastAnimation:completion:)]) {
            ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(
                me, @selector(hideActionButtonsAnimated:fastAnimation:completion:),
                YES, YES, nil);
        }
        if ([me respondsToSelector:@selector(setCellWithActionsRevealed:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(me, @selector(setCellWithActionsRevealed:), nil);
        }
        // Collapse the per-cell action reveal for every request in the stack.
        id reqs = onl_send0(me, @selector(orderedRequests));
        if (reqs) {
            NSUInteger n = onl_sendUInt0(reqs, @selector(count));
            for (NSUInteger i = 0; i < n; i++) {
                id req = onl_send1(reqs, @selector(objectAtIndex:), (id)(uintptr_t)i);
                if (!req) continue;
                id cell = onl_send1(me, @selector(_currentCellForNotificationRequest:), req);
                if (!cell) continue;
                if ([cell respondsToSelector:@selector(setCellWithActionsRevealed:)]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(cell, @selector(setCellWithActionsRevealed:), nil);
                }
            }
        }
    });
}

// Install our tap recognizer on the group list, once. Idempotent.
static void onl_ensureTapRecognizer(id groupList) {
    if (!groupList) return;
    if (!onl_isMultiGroup(groupList)) return;

    // CRASH GUARD: the handler is injected with %new, which Logos silently
    // skips if the host class was missing at load time. Firing a recognizer at
    // a selector that was never registered takes SpringBoard down, so verify
    // the method really exists on this instance before wiring anything up.
    if (![groupList respondsToSelector:@selector(onl_handleStackGroupTap:)]) {
        ndh_log(@"[NDH] onl_handleStackGroupTap: missing — recognizer NOT installed");
        return;
    }
    if (objc_getAssociatedObject(groupList, kKeyTapRecognizer)) return;

    Class viewCls = objc_getClass("UIView");
    if (!viewCls || !onl_isKindOfClass(groupList, viewCls)) return;

    Class tapCls = objc_getClass("UITapGestureRecognizer");
    if (!tapCls) return;

    id tap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        [tapCls alloc], @selector(initWithTarget:action:), groupList,
        @selector(onl_handleStackGroupTap:));
    if (!tap) return;

    // Must not eat touches — the notification cells underneath still need them.
    if ([tap respondsToSelector:@selector(setCancelsTouchesInView:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(tap, @selector(setCancelsTouchesInView:), NO);
    }
    if ([tap respondsToSelector:@selector(setDelaysTouchesBegan:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(tap, @selector(setDelaysTouchesBegan:), NO);
    }
    if ([tap respondsToSelector:@selector(setDelaysTouchesEnded:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(tap, @selector(setDelaysTouchesEnded:), NO);
    }
    if ([groupList respondsToSelector:@selector(addGestureRecognizer:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(groupList, @selector(addGestureRecognizer:), tap);
    }
    objc_setAssociatedObject(groupList, kKeyTapRecognizer, tap,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Perform the tapped notification's default action (open the app). Returns YES
// when the tap was consumed so callers can skip %orig.
static BOOL onl_performCellAction(id groupList, id cell) {
    if (!cell) return NO;
    if (![cell respondsToSelector:@selector(defaultActionForNotificationListCell:)]) return NO;

    id action = onl_send1(cell, @selector(defaultActionForNotificationListCell:), cell);
    if (!action) return NO;
    if (![action respondsToSelector:@selector(performWithSender:target:)]) return NO;

    // Collapse revealed actions before firing, so the app opens from a clean
    // list rather than from a half-open swipe row.
    if ([groupList respondsToSelector:@selector(hideActionButtonsAnimated:fastAnimation:completion:)]) {
        ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(
            groupList, @selector(hideActionButtonsAnimated:fastAnimation:completion:),
            YES, YES, nil);
    }
    if ([groupList respondsToSelector:@selector(setCellWithActionsRevealed:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(groupList, @selector(setCellWithActionsRevealed:), nil);
    }

    ((void (*)(id, SEL, id, id))objc_msgSend)(action, @selector(performWithSender:target:), cell, nil);
    return YES;
}

// Walk a view's superview chain looking for an NCNotificationListCell.
static id onl_findCellInView(id view) {
    Class cellCls = objc_getClass("NCNotificationListCell");
    if (!cellCls) return nil;

    id v = view;
    while (v) {
        if (onl_isKindOfClass(v, cellCls)) return v;
        if (![v respondsToSelector:@selector(superview)]) break;
        v = onl_send0(v, @selector(superview));
    }
    return nil;
}

// Given any view, find the NCNotificationGroupList that owns it, following the
// superview chain and the delegate pointer.
static id onl_groupListForView(id view) {
    if (!view) return nil;
    Class glCls = objc_getClass("NCNotificationGroupList");
    if (!glCls) return nil;

    id v = view;
    while (v) {
        if (onl_isKindOfClass(v, glCls)) return v;
        if ([v respondsToSelector:@selector(delegate)]) {
            id d = onl_send0(v, @selector(delegate));
            if (d && onl_isKindOfClass(d, glCls)) return d;
        }
        if (![v respondsToSelector:@selector(superview)]) break;
        v = onl_send0(v, @selector(superview));
    }
    return nil;
}

// ---------------------------------------------------------------------------
// Legacy Feature 1 (opt-in): merge after the 1st notification.
// ---------------------------------------------------------------------------
static id (*orig_threadIdentifier)(id, SEL);
static id hook_threadIdentifier(id self, SEL _cmd) {
    if (!g_mergeEarly) return orig_threadIdentifier(self, _cmd);
    // Force every notification of an app onto one thread => one collapsible
    // group, so the 2nd notification already merges into the bar.
    if ([self respondsToSelector:@selector(sectionIdentifier)]) {
        return onl_send0(self, @selector(sectionIdentifier));
    }
    return orig_threadIdentifier(self, _cmd);
}

static NSUInteger (*orig_collapsingThreshold)(id, SEL);
static NSUInteger hook_collapsingThreshold(id self, SEL _cmd) {
    return g_mergeEarly ? kCollapseThreshold : orig_collapsingThreshold(self, _cmd);
}

static NSUInteger (*orig_dynamicGroupingThreshold)(id, SEL);
static NSUInteger hook_dynamicGroupingThreshold(id self, SEL _cmd) {
    return g_mergeEarly ? kCollapseThreshold : orig_dynamicGroupingThreshold(self, _cmd);
}

// ---------------------------------------------------------------------------
// Hooks — NCNotificationMasterList (iOS 16 branch)
// ---------------------------------------------------------------------------
%hook NCNotificationMasterList

// (A) Block the two history-migration entry points. Safe ONLY because (B)
// redirects any request that still lands in history back into the incoming
// section, which is the section that stays alive across unlock.
- (void)migrateNotificationsFromIncomingSectionToHistorySection {
    if (ONL_ACTIVE) { ndh_log(@"[NDH] blocked migrate (no-arg)"); return; }
    %orig;
}

- (void)migrateNotificationsFromIncomingSectionToHistorySectionAndHideHistorySection:(BOOL)hide {
    if (ONL_ACTIVE) { ndh_log(@"[NDH] blocked migrate+hide (%d)", hide); return; }
    %orig;
}

// (C) Pin the list display style so the incoming section is never collapsed
// away, and never marked hidden-for-user-interaction.
- (void)setCurrentListDisplayStyleSetting:(NSInteger)setting {
    // NOTE: pass an explicitly-typed literal, never YES/NO — those expand to
    // __objc_yes/__objc_no and choke Logos %orig argument inference (the 1.0.43
    // build failure).
    if (ONL_ACTIVE) { %orig((NSInteger)0); return; }
    %orig;
}
- (NSInteger)currentListDisplayStyleSetting {
    if (ONL_ACTIVE) return 0;
    return %orig;
}
- (void)setListDisplayStyleHiddenForUserInteraction:(BOOL)hidden {
    if (ONL_ACTIVE) { %orig((BOOL)0); return; }
    %orig;
}
- (BOOL)isListDisplayStyleHiddenForUserInteraction {
    if (ONL_ACTIVE) return NO;
    return %orig;
}

// (D) History must NEVER be revealed — the opposite of the old approach. With
// no history section there is no empty-hint problem to race against.
- (void)setNotificationHistoryRevealed:(BOOL)revealed {
    if (ONL_ACTIVE) { %orig((BOOL)0); return; }
    %orig;
}
- (BOOL)isNotificationHistoryRevealed {
    if (ONL_ACTIVE) return NO;
    return %orig;
}
- (void)setShouldAllowNotificationHistoryReveal:(BOOL)allow {
    if (ONL_ACTIVE) { %orig((BOOL)0); return; }
    %orig;
}
- (BOOL)shouldAllowNotificationHistoryReveal {
    if (ONL_ACTIVE) return NO;
    return %orig;
}
- (BOOL)notificationListRevealCoordinatorShouldAllowReveal:(id)coordinator {
    if (ONL_ACTIVE) return NO;
    return %orig;
}
- (BOOL)notificationListRevealCoordinatorShouldAllowRevealTransition:(id)coordinator {
    if (ONL_ACTIVE) return NO;
    return %orig;
}
- (BOOL)notificationListInteractiveTransitionCoordinatorRequestsIsHiddenListRevealed:(id)coordinator {
    if (ONL_ACTIVE) return NO;
    return %orig;
}

// (B) The safety net. If the system still resolves a request to the history
// section, hand it the incoming section instead so the notification survives.
- (id)_sectionForNotificationRequest:(id)request {
    id section = %orig;
    if (!ONL_ACTIVE) return section;
    id history = onl_send0(self, @selector(historySectionList));
    if (section && history && section == history) {
        id incoming = onl_send0(self, @selector(incomingSectionList));
        if (incoming) {
            ndh_log(@"[NDH] redirected request history -> incoming");
            return incoming;
        }
    }
    return section;
}

- (id)_sectionForStoredNotificationRequestOfSectionType:(NSInteger)sectionType {
    id section = %orig;
    if (!ONL_ACTIVE) return section;
    id history = onl_send0(self, @selector(historySectionList));
    if (section && history && section == history) {
        id incoming = onl_send0(self, @selector(incomingSectionList));
        if (incoming) return incoming;
    }
    return section;
}

%end

// ---------------------------------------------------------------------------
// Hooks — NCNotificationGroupList (iOS 16 branch): stack expansion state
// ---------------------------------------------------------------------------
%hook NCNotificationGroupList

// Lazily install our tap recognizer the first time the list view shows up.
- (void)setGroupListView:(id)groupListView {
    %orig;
    if (ONL_ACTIVE) onl_ensureTapRecognizer(self);
}
- (id)groupListView {
    id v = %orig;
    if (ONL_ACTIVE) onl_ensureTapRecognizer(self);
    return v;
}

// Track expansion state. In NCNotificationGroupList, grouped==YES means the
// stack is COLLAPSED into one bar; grouped==NO means EXPANDED.
//
// Original behaviour (verified in the 0.0.2 binary):
//   grouped==YES  -> clear the expanded flag, let the collapse happen
//   grouped==NO   -> swallow the expansion unless the user explicitly asked
//                    for it (expansion gate open), otherwise set the flag and
//                    let it happen
//
// The swallow on the NO path is deliberate: iOS's own expansion goes through
// the grouped state machine, which it is free to reverse later (scroll away,
// relock, reauth). By refusing that path we keep control of the expansion.
- (void)setGrouped:(BOOL)grouped animated:(BOOL)animated {
    if (!ONL_ACTIVE) { %orig; return; }
    if (!onl_isMultiGroup(self)) { %orig; return; }

    if (grouped) {
        objc_setAssociatedObject(self, kKeyExpanded, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        if (!onl_expansionAllowed(self)) {
            ndh_log(@"[NDH] blocked system-initiated expand");
            return;
        }
        objc_setAssociatedObject(self, kKeyExpanded, (id)kCFBooleanTrue,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

- (BOOL)isGrouped {
    if (!ONL_ACTIVE) return %orig;
    // While force-expanded, report "grouped" only if we really are, so the
    // system does not try to re-collapse us.
    if (onl_isMultiGroup(self)) {
        id flag = objc_getAssociatedObject(self, kKeyExpanded);
        if (![flag boolValue]) return YES;
    }
    return %orig;
}

// Block the automatic toggle for small stacks — they should stay expanded.
- (void)toggleGroupedState {
    if (!ONL_ACTIVE) { %orig; return; }
    if (onl_shouldExpand(self) && !onl_expansionAllowed(self)) {
        ndh_log(@"[NDH] blocked toggleGroupedState");
        return;
    }
    %orig;
}

// The system's own expand entry point. For small stacks we take over: open the
// expansion gate, force the expand on the next turn, and skip the original so
// the system cannot immediately re-collapse us.
- (BOOL)_handleTapToExpandGroupForNotificationRequest:(id)request {
    if (!ONL_ACTIVE) return %orig;
    if (onl_shouldExpand(self) && !onl_expansionAllowed(self)) {
        onl_setExpansionGate(self, YES);
        onl_forceExpand(self);
        objc_setAssociatedObject(self, kKeyExpanded, (id)kCFBooleanTrue,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    return %orig;
}

// A tap on a notification inside a force-expanded stack should OPEN that
// notification, not toggle the stack. Mark the tap, let the 300ms window
// consume the follow-up call, and report "do not interpret as default action"
// so the system leaves the stack alone.
- (BOOL)notificationViewControllerShouldInterpretTapAsDefaultAction:(id)controller {
    if (!ONL_ACTIVE) return %orig;
    if (onl_shouldExpand(self) && onl_expansionAllowed(self)) {
        objc_setAssociatedObject(self, kKeyStackTap, (id)kCFBooleanTrue,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id me = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kStackTapNS),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(me, kKeyStackTap, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
        return NO;
    }
    return %orig;
}

// Follow-up to the above: consume the marked tap, otherwise swallow taps on
// force-expanded stacks so they cannot re-collapse them.
- (BOOL)handleTapOnNotificationViewController:(id)controller {
    if (!ONL_ACTIVE) { %orig; return NO; }

    id flag = objc_getAssociatedObject(self, kKeyStackTap);
    if ([flag boolValue]) {
        objc_setAssociatedObject(self, kKeyStackTap, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ndh_log(@"[NDH] consumed marked stack tap");
        return NO;
    }
    if (onl_shouldExpand(self)) {
        ndh_log(@"[NDH] swallowed handleTapOnNotificationViewController");
        return NO;
    }
    %orig;
    return NO;
}

// Our own tap handler, added to the class at load time. Resolves the tapped
// cell and fires its default action so a tap opens the notification.
%new
- (void)onl_handleStackGroupTap:(UIGestureRecognizer *)tap {
    if (!ONL_ACTIVE) return;
    if (!tap) return;
    if ([tap state] != UIGestureRecognizerStateEnded) return;

    UIView *groupView = (UIView *)self;
    if (![groupView respondsToSelector:@selector(hitTest:withEvent:)]) return;

    CGPoint p = [tap locationInView:groupView];
    id hit = ((id (*)(id, SEL, CGPoint, id))objc_msgSend)(
        groupView, @selector(hitTest:withEvent:), p, nil);
    if (!hit) return;

    id cell = onl_findCellInView(hit);
    if (!cell) return;
    onl_performCellAction(self, cell);
}

%end

// ---------------------------------------------------------------------------
// Hooks — NCNotificationStructuredSectionList (iOS 16 branch)
// ---------------------------------------------------------------------------
%hook NCNotificationStructuredSectionList

// Resolve which group a tapped base component belongs to. If that group is a
// small stack we own, swallow the tap so it cannot collapse the stack.
- (BOOL)handleTapOnNotificationListBaseComponent:(id)component {
    if (!ONL_ACTIVE) return %orig;

    id groupList = nil;
    Class glCls = objc_getClass("NCNotificationGroupList");

    // Direct group list, or a view whose delegate is one.
    if (glCls && onl_isKindOfClass(component, glCls)) {
        groupList = component;
    } else if ([component respondsToSelector:@selector(delegate)]) {
        id d = onl_send0(component, @selector(delegate));
        if (glCls && d && onl_isKindOfClass(d, glCls)) groupList = d;
    }

    // Otherwise search this section's notification groups for the one that
    // owns the component's request.
    if (!groupList && glCls &&
        [component respondsToSelector:@selector(notificationRequest)] &&
        [component respondsToSelector:@selector(notificationGroups)]) {
        id req = onl_send0(component, @selector(notificationRequest));
        id groups = onl_send0(component, @selector(notificationGroups));
        if (req && groups) {
            NSUInteger n = onl_sendUInt0(groups, @selector(count));
            for (NSUInteger i = 0; i < n; i++) {
                id g = onl_send1(groups, @selector(objectAtIndex:), (id)(uintptr_t)i);
                if (!g) continue;
                if (onl_isKindOfClass(g, glCls) &&
                    [g respondsToSelector:@selector(isGroupForNotificationRequest:)]) {
                    BOOL owns = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                        g, @selector(isGroupForNotificationRequest:), req);
                    if (owns) { groupList = g; break; }
                }
            }
        }
    }

    if (groupList && onl_shouldExpand(groupList) && !onl_expansionAllowed(groupList)) {
        ndh_log(@"[NDH] swallowed handleTapOnNotificationListBaseComponent");
        return NO;
    }
    return %orig;
}

%end

// ---------------------------------------------------------------------------
// Hooks — NCNotificationShortLookViewController (iOS 16 branch)
// ---------------------------------------------------------------------------
%hook NCNotificationShortLookViewController

// A tap on the short-look (banner) view that belongs to a small stack we own
// must not collapse the stack.
- (BOOL)_handleTapOnView:(id)view {
    if (!ONL_ACTIVE) return %orig;

    id groupList = onl_groupListForView(view);
    if (!groupList && [self respondsToSelector:@selector(delegate)]) {
        id d = onl_send0(self, @selector(delegate));
        if (d) groupList = onl_groupListForView(d);
    }
    if (groupList && onl_shouldExpand(groupList)) {
        ndh_log(@"[NDH] swallowed short-look _handleTapOnView");
        return NO;
    }
    return %orig;
}

%end

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
static void ndh_loadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsAppID);

    CFPropertyListRef v = CFPreferencesCopyAppValue(
        CFSTR("enabled"), (__bridge CFStringRef)kPrefsAppID);
    if (v) {
        g_enabled = [(__bridge id)v boolValue];
        CFRelease(v);
    } else {
        g_enabled = YES;
    }

    v = CFPreferencesCopyAppValue(CFSTR("mergeEarly"),
                                  (__bridge CFStringRef)kPrefsAppID);
    if (v) {
        g_mergeEarly = [(__bridge id)v boolValue];
        CFRelease(v);
    } else {
        g_mergeEarly = NO;
    }

    g_debug = [[NSFileManager defaultManager]
               fileExistsAtPath:@"/var/jb/tmp/ndh_debug"];
}

static void ndh_reloadPrefs(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    ndh_loadPrefs();
    ndh_log(@"[NDH] prefs reloaded: enabled=%d mergeEarly=%d",
            g_enabled, g_mergeEarly);
}

// Hook only if the class and selector both exist, so a future iOS change can
// never crash SpringBoard from this tweak. Used for the opt-in Feature 1 set,
// which is declared with plain C functions rather than %hook.
static void ndh_try_hook(const char *clsName, SEL sel, IMP imp, IMP *orig) {
    Class cls = objc_getClass(clsName);
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    MSHookMessageEx(cls, sel, imp, orig);
}

%ctor {
    ndh_loadPrefs();

    // Version gate: this hook set is the iOS 16 branch of the original. On any
    // other major version every hook degrades to a pass-through, which is safe
    // but inert — extend with the iOS 17 branch before enabling there.
    NSString *ver = [[UIDevice currentDevice] systemVersion];
    NSComparisonResult cmp = [ver compare:@"16.0" options:NSNumericSearch];
    NSComparisonResult cmp17 = [ver compare:@"17.0" options:NSNumericSearch];
    g_supported = (cmp != NSOrderedAscending) && (cmp17 == NSOrderedAscending);

    ndh_log(@"[NDH] ctor: iOS=%@ supported=%d enabled=%d mergeEarly=%d",
            ver, g_supported, g_enabled, g_mergeEarly);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)ndh_reloadPrefs,
        CFSTR("com.huhansibuxin.notifsdonthide/ReloadPrefs"), NULL,
        CFNotificationSuspensionBehaviorCoalesce);

    // Opt-in legacy Feature 1.
    ndh_try_hook("NCNotificationRequest", @selector(threadIdentifier),
                 (IMP)&hook_threadIdentifier, (IMP*)&orig_threadIdentifier);
    ndh_try_hook("NCNotificationCollapsingQueue", @selector(collapsingThreshold),
                 (IMP)&hook_collapsingThreshold, (IMP*)&orig_collapsingThreshold);
    ndh_try_hook("NCNotificationStructuredSectionList",
                 @selector(dynamicGroupingThreshold),
                 (IMP)&hook_dynamicGroupingThreshold,
                 (IMP*)&orig_dynamicGroupingThreshold);
}
