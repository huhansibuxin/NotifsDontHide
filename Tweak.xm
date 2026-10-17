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
// No logging. Production paths contain no file I/O, no locks, no sleeps and no
// synchronous network calls, so nothing here can block the main thread. If
// on-device diagnosis is ever needed again, the gated logger from 1.1.0 is in
// git history (commit 31ad15e) — but note it cost 3 syscalls per line, which is
// why it was dropped rather than left switched off.
//
// Robustness: every private call is guarded by respondsToSelector:, every typed
// IMP checks its orig pointer, and the tap recognizer targets a weak proxy so
// no group list / recognizer retain cycle can form.
//
// ============================================================================
// LOGOS PITFALL — never put a printf format specifier inside a %hook/%ctor block
// ============================================================================
// Logos preprocesses these blocks by scanning for %-prefixed tokens. A bare
// "%d" or "%@" inside an NSString literal in a block is not a valid directive,
// and it derails Logos's block/brace tracking. The resulting errors point at
// the PREPROCESSED output, not your source:
//     Tweak.xm:527: error: function definition is not allowed here
//     Tweak.xm:539: error: function definition is not allowed here
//     Tweak.xm:859: error: expected '}'
// Those look like a structural brace bug but are not — check for stray format
// specifiers in strings inside %hook/%ctor first. Keep printf-style formatting
// in plain C helper functions and pass only plain strings into Logos blocks.
//
// Related, already-burned rules:
//   * %orig must sit alone on its own line. Never write
//     "if (x) { %orig; return; }" — Logos expands %orig into a long
//     _logos_orig$Class$sel$(self, _cmd, ...) call and its parser cannot cope
//     with that sharing a line with other statements. Same misleading errors.
//   * %orig(<arg>) cannot rewrite an argument on a private method — use
//     MSHookMessageEx + typed IMP instead (the 1.0.43/1.0.44 lesson).
//   * %new generates code that does not compile for these private classes —
//     use _class_addMethod (what the original 0.0.2 binary does).
// ============================================================================
//
// Verified against: /var/jb/Library/MobileSubstrate/DynamicLibraries/
//                   OneNotificationListFFS.dylib (0.0.2, iphoneos-arm64e)
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
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

// Send a one-arg (NSUInteger index) message that returns an object, safely.
// Needed for objectAtIndex: — casting an integer to id is disallowed under ARC
// ("cast of 'uintptr_t' to 'id' is disallowed"), so pass it as a real integer.
static id onl_sendIndex(id obj, SEL sel, NSUInteger idx) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(obj, sel, idx);
}

// Send a zero-arg message that returns NSUInteger, safely.
static NSUInteger onl_sendUInt0(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

// Read an instance variable by name, walking the class hierarchy. This is what
// makes the tweak survive ivar-offset churn between iOS builds — never hardcode
// an offset, always resolve the name at runtime.
//
// Prefer onl_groupListView() below: this generic walk costs one hash lookup per
// class in the chain and is only worth paying on cold paths.
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

// Resolve the "_groupListView" Ivar ONCE, then reuse it.
//
// Why this matters: onl_shouldExpand() runs on every isGrouped: call, which the
// list machinery fires on every layout pass. The generic ivar walk above costs
// a class_getInstanceVariable hash lookup per class in the chain
// (NCNotificationGroupList -> ... -> UIView -> UIResponder -> NSObject, ~5-6
// lookups) every single time. Caching turns that into one pointer compare.
//
// Every call site passes an NCNotificationGroupList (either `self` inside the
// %hook block, or a value already validated by isKindOfClass:), so a single
// cache entry is correct. If the ivar is not found the tweak degrades to
// "never force-expand", which is safe.
static Ivar onl_groupListViewIvar(void) {
    static Ivar cached = NULL;
    static BOOL resolved = NO;
    if (resolved) return cached;

    resolved = YES;
    Class c = objc_getClass("NCNotificationGroupList");
    while (c) {
        Ivar iv = class_getInstanceVariable(c, "_groupListView");
        if (iv) {
            cached = iv;
            break;
        }
        c = class_getSuperclass(c);
    }
    return cached;
}

static BOOL onl_isKindOfClass(id obj, Class cls) {
    if (!obj || !cls) return NO;
    return ((BOOL (*)(id, SEL, Class))objc_msgSend)(obj, @selector(isKindOfClass:), cls);
}

// ---------------------------------------------------------------------------
// Group-list predicates (all operate on NCNotificationGroupList instances)
// ---------------------------------------------------------------------------

// A real multi-notification stack: responds to orderedRequests and holds >1.
// respondsToSelector: is answered from the runtime's per-class cache, so the
// guard is effectively free; the two message sends that follow are unavoidable.
static BOOL onl_isMultiGroup(id groupList) {
    if (!groupList) return NO;
    if (![groupList respondsToSelector:@selector(orderedRequests)]) return NO;
    id reqs = onl_send0(groupList, @selector(orderedRequests));
    if (!reqs) return NO;
    return onl_sendUInt0(reqs, @selector(count)) > 1;
}

// The group's scroll view, resolved from the cached Ivar (never by offset).
static id onl_groupListView(id groupList) {
    if (!groupList) return nil;
    Ivar iv = onl_groupListViewIvar();
    if (!iv) return nil;
    return object_getIvar(groupList, iv);
}

// UIScrollView class, resolved once. objc_getClass() is a lookup into the
// runtime's class table and onl_shouldExpand() runs on every layout pass.
static Class onl_scrollViewClass(void) {
    static Class cached = NULL;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        cached = objc_getClass("UIScrollView");
    }
    return cached;
}

// Whether this stack is small enough that force-expanding it cannot flood the
// lock screen. Mirrors the original: the collapsed content must fit inside its
// own frame and stay under the height limit.
//
// Runs on every isGrouped: call, so the order of the checks matters: the two
// cheapest disqualifiers (not a multi-group, no scroll view) come first and
// short-circuit before any struct-returning message send.
static BOOL onl_shouldExpand(id groupList) {
    if (!groupList) return NO;
    if (!onl_isMultiGroup(groupList)) return NO;

    id listView = onl_groupListView(groupList);
    if (!listView) return NO;

    Class scrollCls = onl_scrollViewClass();
    if (!scrollCls || !onl_isKindOfClass(listView, scrollCls)) return NO;

    // Both selectors exist on every UIScrollView, so these guards are belt-and-
    // braces for a future iOS rename rather than a per-call cost.
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
                id req = onl_sendIndex(reqs, @selector(objectAtIndex:), i);
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

// ---------------------------------------------------------------------------
// Weak tap target.
//
// UIGestureRecognizer retains its target, and addGestureRecognizer: makes the
// view retain the recognizer. Pointing the recognizer straight at the group
// list therefore creates a retain cycle: groupList -> recognizer -> groupList.
// Notification group lists are created and destroyed as notifications arrive,
// so every one that leaked would accumulate over a session.
//
// This proxy breaks the cycle: the group list owns the proxy strongly, and the
// proxy refers back weakly. When the group list goes away the proxy's target
// goes nil and the tap becomes a no-op instead of a crash or a leak.
// ---------------------------------------------------------------------------
@interface ONLWeakTapTarget : NSObject
@property (nonatomic, weak) id target;
@end

@implementation ONLWeakTapTarget
- (void)onl_forwardTap:(UIGestureRecognizer *)tap {
    id t = self.target;
    if (!t) return;
    if (![t respondsToSelector:@selector(onl_handleStackGroupTap:)]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(t, @selector(onl_handleStackGroupTap:), tap);
}
@end

// Install our tap recognizer on the group list, once. Idempotent.
//
// Called from setGroupListView: only — the setter fires once per view
// assignment, whereas the groupListView getter is read on every layout pass.
// Putting this on the getter cost a respondsToSelector + associated-object
// lookup per read for something that only needs to happen once.
static void onl_ensureTapRecognizer(id groupList) {
    if (!groupList) return;
    // Cheapest disqualifier first: if the handler was never registered (host
    // class missing at load, or _class_addMethod failed) a recognizer firing at
    // a non-existent selector takes SpringBoard down.
    if (![groupList respondsToSelector:@selector(onl_handleStackGroupTap:)]) {
        return;
    }
    if (objc_getAssociatedObject(groupList, kKeyTapRecognizer)) return;
    if (!onl_isMultiGroup(groupList)) return;

    Class viewCls = objc_getClass("UIView");
    if (!viewCls || !onl_isKindOfClass(groupList, viewCls)) return;

    Class tapCls = objc_getClass("UITapGestureRecognizer");
    if (!tapCls) return;

    // Strong ref on the group list, weak ref back — see ONLWeakTapTarget above.
    ONLWeakTapTarget *proxy = [[ONLWeakTapTarget alloc] init];
    if (!proxy) return;
    proxy.target = groupList;

    id tap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        [tapCls alloc], @selector(initWithTarget:action:), proxy,
        @selector(onl_forwardTap:));
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
    // Keep the PROXY alive, not the recognizer. The view already retains the
    // recognizer via addGestureRecognizer:, so retaining it again would be
    // redundant; what needs an owner is the proxy, because the recognizer's
    // reference to it is the only thing otherwise holding it.
    objc_setAssociatedObject(groupList, kKeyTapRecognizer, proxy,
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
//
// These three are installed with MSHookMessageEx rather than %hook so they can
// be registered conditionally. That means the orig_* pointers are only valid if
// the hook actually took — if MSHookMessageEx failed they stay NULL and calling
// them would jump to address 0. Every call site below therefore checks first.
// ---------------------------------------------------------------------------
static id (*orig_threadIdentifier)(id, SEL);
static id hook_threadIdentifier(id self, SEL _cmd) {
    if (!g_mergeEarly || !orig_threadIdentifier) {
        // Feature off, or hook never installed: fall through to a safe answer.
        if (orig_threadIdentifier) return orig_threadIdentifier(self, _cmd);
        return onl_send0(self, @selector(sectionIdentifier));
    }
    // Force every notification of an app onto one thread => one collapsible
    // group, so the 2nd notification already merges into the bar.
    if ([self respondsToSelector:@selector(sectionIdentifier)]) {
        return onl_send0(self, @selector(sectionIdentifier));
    }
    return orig_threadIdentifier(self, _cmd);
}

static NSUInteger (*orig_collapsingThreshold)(id, SEL);
static NSUInteger hook_collapsingThreshold(id self, SEL _cmd) {
    if (!orig_collapsingThreshold) return 4;   // iOS default, safe fallback
    return g_mergeEarly ? kCollapseThreshold : orig_collapsingThreshold(self, _cmd);
}

static NSUInteger (*orig_dynamicGroupingThreshold)(id, SEL);
static NSUInteger hook_dynamicGroupingThreshold(id self, SEL _cmd) {
    if (!orig_dynamicGroupingThreshold) return 4;   // iOS default, safe fallback
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
    if (ONL_ACTIVE) { return; }
    %orig;
}

- (void)migrateNotificationsFromIncomingSectionToHistorySectionAndHideHistorySection:(BOOL)hide {
    if (ONL_ACTIVE) { return; }
    %orig;
}

// (C) Pin the list display style so the incoming section is never collapsed
// away, and never marked hidden-for-user-interaction. The four SETTERS that
// rewrite their argument live below as typed IMPs — Logos %orig cannot do that
// on private methods ("Invalid argument structure", the 1.0.43/1.0.44 failure).
- (NSInteger)currentListDisplayStyleSetting {
    if (ONL_ACTIVE) return 0;
    return %orig;
}
- (BOOL)isListDisplayStyleHiddenForUserInteraction {
    if (ONL_ACTIVE) return NO;
    return %orig;
}

// (D) History must NEVER be revealed — the opposite of the old approach. With
// no history section there is no empty-hint problem to race against.
- (BOOL)isNotificationHistoryRevealed {
    if (ONL_ACTIVE) return NO;
    return %orig;
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

// Install our tap recognizer the first time a list view is assigned.
//
// Setter only — deliberately NOT the getter. groupListView is read on every
// layout pass, so hanging an idempotency check off it meant a
// respondsToSelector + associated-object lookup per read for a one-time
// setup. If a group list somehow never receives a setGroupListView: call the
// recognizer is simply absent and taps fall through to the system, which is a
// graceful degradation rather than a crash.
- (void)setGroupListView:(id)groupListView {
    %orig;
    if (ONL_ACTIVE) onl_ensureTapRecognizer(self);
}
- (id)groupListView {
    return %orig;
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
    // %orig must sit alone on its own line, never inside a single-line
    // "{ %orig; return; }" — Logos expands it into a long
    // _logos_orig$...$(self, _cmd, ...) call and its parser cannot handle that
    // sharing a line with other statements.
    if (!ONL_ACTIVE) {
        %orig;
        return;
    }
    if (!onl_isMultiGroup(self)) {
        %orig;
        return;
    }

    if (grouped) {
        objc_setAssociatedObject(self, kKeyExpanded, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        if (!onl_expansionAllowed(self)) {
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
    if (!ONL_ACTIVE) {
        %orig;
        return;
    }
    if (onl_shouldExpand(self) && !onl_expansionAllowed(self)) {
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
    if (!ONL_ACTIVE) {
        %orig;
        return NO;
    }

    id flag = objc_getAssociatedObject(self, kKeyStackTap);
    if ([flag boolValue]) {
        objc_setAssociatedObject(self, kKeyStackTap, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (onl_shouldExpand(self)) {
        return NO;
    }
    %orig;
    return NO;
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
                id g = onl_sendIndex(groups, @selector(objectAtIndex:), i);
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
    // Logos forward-declares every hooked class (@class Xxx;), so sending an
    // NSObject message to `self` here fails with "receiver type ... is a
    // forward declaration". Cast to id first — the 1.0.47 lesson.
    id me = (id)self;
    if (!groupList && [me respondsToSelector:@selector(delegate)]) {
        id d = onl_send0(me, @selector(delegate));
        if (d) groupList = onl_groupListForView(d);
    }
    if (groupList && onl_shouldExpand(groupList)) {
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
}

static void ndh_reloadPrefs(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    ndh_loadPrefs();
}

// Hook only if the class and selector both exist, so a future iOS change can
// never crash SpringBoard from this tweak. Used for the opt-in Feature 1 set
// and for the argument-rewriting setters, which are declared with plain C
// functions rather than %hook.
static void ndh_try_hook(const char *clsName, SEL sel, IMP imp, IMP *orig) {
    Class cls = objc_getClass(clsName);
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    MSHookMessageEx(cls, sel, imp, orig);
}

// ---------------------------------------------------------------------------
// Argument-rewriting setters — typed IMP, NOT Logos %orig.
//
// Logos %orig cannot rewrite an argument on a private method whose signature
// it has to infer: every form fails with "Invalid argument structure in %orig"
// (1.0.43 tried %orig((BOOL)1); 1.0.44 gave up on %orig for setters entirely
// and switched to MSHookMessageEx + typed IMP). Keep this pattern — do not
// "simplify" it back into %hook.
// ---------------------------------------------------------------------------

static void (*orig_setCurrentListDisplayStyleSetting)(id, SEL, NSInteger);
static void hook_setCurrentListDisplayStyleSetting(id self, SEL _cmd, NSInteger setting) {
    if (!orig_setCurrentListDisplayStyleSetting) return;
    orig_setCurrentListDisplayStyleSetting(self, _cmd, ONL_ACTIVE ? 0 : setting);
}

static void (*orig_setListDisplayStyleHiddenForUserInteraction)(id, SEL, BOOL);
static void hook_setListDisplayStyleHiddenForUserInteraction(id self, SEL _cmd, BOOL hidden) {
    if (!orig_setListDisplayStyleHiddenForUserInteraction) return;
    orig_setListDisplayStyleHiddenForUserInteraction(self, _cmd,
                                                     ONL_ACTIVE ? (BOOL)0 : hidden);
}

static void (*orig_setNotificationHistoryRevealed)(id, SEL, BOOL);
static void hook_setNotificationHistoryRevealed(id self, SEL _cmd, BOOL revealed) {
    if (!orig_setNotificationHistoryRevealed) return;
    orig_setNotificationHistoryRevealed(self, _cmd,
                                        ONL_ACTIVE ? (BOOL)0 : revealed);
}

static void (*orig_setShouldAllowNotificationHistoryReveal)(id, SEL, BOOL);
static void hook_setShouldAllowNotificationHistoryReveal(id self, SEL _cmd, BOOL allow) {
    if (!orig_setShouldAllowNotificationHistoryReveal) return;
    orig_setShouldAllowNotificationHistoryReveal(self, _cmd,
                                                 ONL_ACTIVE ? (BOOL)0 : allow);
}

// ---------------------------------------------------------------------------
// Tap handler — installed with _class_addMethod, NOT Logos %new.
//
// %new makes Logos generate a category/implementation for the host class and
// that output does not compile cleanly for these private classes ("function
// definition is not allowed here" + a dangling brace). The original 0.0.2
// binary uses _class_addMethod directly, which is both proven and gives us an
// explicit type encoding instead of one Logos has to infer.
//
// Signature: void return, id self, SEL _cmd, id tap  ->  "v@:@"
// ---------------------------------------------------------------------------
static void hook_onl_handleStackGroupTap(id self, SEL _cmd, id tap) {
    if (!ONL_ACTIVE) return;
    if (!tap) return;
    if (((NSInteger (*)(id, SEL))objc_msgSend)(tap, @selector(state))
        != UIGestureRecognizerStateEnded) return;

    if (![self respondsToSelector:@selector(hitTest:withEvent:)]) return;

    CGPoint p = ((CGPoint (*)(id, SEL, id))objc_msgSend)(tap,
                                                        @selector(locationInView:), self);
    id hit = ((id (*)(id, SEL, CGPoint, id))objc_msgSend)(
        self, @selector(hitTest:withEvent:), p, nil);
    if (!hit) return;

    id cell = onl_findCellInView(hit);
    if (!cell) return;
    onl_performCellAction(self, cell);
}

// Install the tap handler on NCNotificationGroupList. Returns YES on success.
static BOOL ndh_installStackTapHandler(void) {
    Class cls = objc_getClass("NCNotificationGroupList");
    if (!cls) return NO;
    SEL sel = @selector(onl_handleStackGroupTap:);
    if (class_getInstanceMethod(cls, sel)) return YES;   // already there
    // "v@:@" — void return, self, _cmd, id argument.
    return class_addMethod(cls, sel, (IMP)&hook_onl_handleStackGroupTap, "v@:@");
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

    // Argument-rewriting setters — typed IMP (see the note above: Logos %orig
    // cannot rewrite arguments on private methods).
    ndh_try_hook("NCNotificationMasterList",
                 @selector(setCurrentListDisplayStyleSetting:),
                 (IMP)&hook_setCurrentListDisplayStyleSetting,
                 (IMP*)&orig_setCurrentListDisplayStyleSetting);
    ndh_try_hook("NCNotificationMasterList",
                 @selector(setListDisplayStyleHiddenForUserInteraction:),
                 (IMP)&hook_setListDisplayStyleHiddenForUserInteraction,
                 (IMP*)&orig_setListDisplayStyleHiddenForUserInteraction);
    ndh_try_hook("NCNotificationMasterList",
                 @selector(setNotificationHistoryRevealed:),
                 (IMP)&hook_setNotificationHistoryRevealed,
                 (IMP*)&orig_setNotificationHistoryRevealed);
    ndh_try_hook("NCNotificationMasterList",
                 @selector(setShouldAllowNotificationHistoryReveal:),
                 (IMP)&hook_setShouldAllowNotificationHistoryReveal,
                 (IMP*)&orig_setShouldAllowNotificationHistoryReveal);

    // Tap handler, installed with _class_addMethod (see the note above).
    if (ndh_installStackTapHandler()) {
    } else {
    }
}
