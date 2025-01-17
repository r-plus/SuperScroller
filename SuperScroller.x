#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <notify.h>
#import <libactivator/libactivator.h>

// Useful as a good reference implementation of how to consume Activator events inside apps.
// Listener must register for events in SpringBoard and then dispatch them out to the appropriate app.
// Because SpringBoard can never _ever_ wait on applications it owns, events are sent asynchronously over
// darwin notifications and state on whether or not a potential future event is to be handled is maintained

%config(generator=internal);

__attribute__((visibility("hidden")))
@interface SuperScroller : NSObject <LAListener>
@end

#define kUp "com.rpetrich.superscroller.up"
#define kAutoUp "com.rpetrich.superscroller.autoup"
#define kDown "com.rpetrich.superscroller.down"
#define kAutoDown "com.rpetrich.superscroller.autodown"

static NSMutableSet *scrollableViews;
static BOOL isActive;
static int notifyToken;
static NSTimer *scrollingTimer = nil;
static BOOL autoscrolling = NO;

enum {
	UIScrollableDirectionLeft = 1,
	UIScrollableDirectionRight = 2,
	UIScrollableDirectionUp = 4,
	UIScrollableDirectionDown = 8,
};

static inline int GetScrollableDirections()
{
	int result = 0;
	for (UIScrollView *scrollView in [[scrollableViews copy] autorelease])
		if ([scrollView isKindOfClass:[UIScrollView class]])
			result |= [scrollView scrollableDirections];
	return result;
}

static void ScrollUpNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	for (UIScrollView *scrollView in [[scrollableViews copy] autorelease]) {
		if ([scrollView isKindOfClass:[UIScrollView class]] && ([scrollView scrollableDirections] & UIScrollableDirectionUp)) {
			CGPoint contentOffset = scrollView.contentOffset;
			contentOffset.y -= scrollView.bounds.size.height - 20.0f;
			CGFloat topOffset = -scrollView.contentInset.top;
			if (contentOffset.y < topOffset)
				contentOffset.y = topOffset;
			[scrollView setContentOffset:contentOffset animated:YES];
		}
	}
}

static void AutoScrollUpNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	for (UIScrollView *scrollView in [[scrollableViews copy] autorelease]) {
		if ([scrollView isKindOfClass:[UIScrollView class]] && ([scrollView scrollableDirections] & UIScrollableDirectionUp)) {
			autoscrolling = YES;
			if (!scrollingTimer)
				scrollingTimer = [NSTimer scheduledTimerWithTimeInterval:(35.0 / 1000.0) target:scrollView selector:@selector(autoscrollUpTimerFired) userInfo:nil repeats:YES];
		}
	}
}

static void ScrollDownNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	for (UIScrollView *scrollView in [[scrollableViews copy] autorelease]) {
		if ([scrollView isKindOfClass:[UIScrollView class]] && ([scrollView scrollableDirections] & UIScrollableDirectionDown)) {
			CGPoint contentOffset = scrollView.contentOffset;
			CGFloat height = scrollView.bounds.size.height;
			contentOffset.y += height - 20.0f;
			CGFloat maxY = scrollView.contentSize.height + scrollView.contentInset.bottom - height;
			if (contentOffset.y > maxY)
				contentOffset.y = maxY;
			[scrollView setContentOffset:contentOffset animated:YES];
		}
	}
}

static void AutoScrollDownNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	for (UIScrollView *scrollView in [[scrollableViews copy] autorelease]) {
		if ([scrollView isKindOfClass:[UIScrollView class]] && ([scrollView scrollableDirections] & UIScrollableDirectionDown)) {
			autoscrolling = YES;
			if (!scrollingTimer)
				scrollingTimer = [NSTimer scheduledTimerWithTimeInterval:(35.0 / 1000.0) target:scrollView selector:@selector(autoscrollDownTimerFired) userInfo:nil repeats:YES];
		}
	}
}

static void WillEnterForegroundNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	notify_set_state(notifyToken, GetScrollableDirections());
	if (!isActive) {
		isActive = YES;
		CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
		CFNotificationCenterAddObserver(darwin, ScrollUpNotificationReceived, ScrollUpNotificationReceived, CFSTR(kUp), NULL, CFNotificationSuspensionBehaviorCoalesce);
		CFNotificationCenterAddObserver(darwin, AutoScrollUpNotificationReceived, AutoScrollUpNotificationReceived, CFSTR(kAutoUp), NULL, CFNotificationSuspensionBehaviorCoalesce);
		CFNotificationCenterAddObserver(darwin, ScrollDownNotificationReceived, ScrollDownNotificationReceived, CFSTR(kDown), NULL, CFNotificationSuspensionBehaviorCoalesce);
		CFNotificationCenterAddObserver(darwin, AutoScrollDownNotificationReceived, AutoScrollDownNotificationReceived, CFSTR(kAutoDown), NULL, CFNotificationSuspensionBehaviorCoalesce);
	}
}

static void DidEnterBackgroundNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	if (isActive) {
		isActive = NO;
		CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
		CFNotificationCenterRemoveObserver(darwin, ScrollUpNotificationReceived, CFSTR(kUp), NULL);
		CFNotificationCenterRemoveObserver(darwin, AutoScrollUpNotificationReceived, CFSTR(kAutoUp), NULL);
		CFNotificationCenterRemoveObserver(darwin, ScrollDownNotificationReceived, CFSTR(kDown), NULL);
		CFNotificationCenterRemoveObserver(darwin, AutoScrollDownNotificationReceived, CFSTR(kAutoDown), NULL);
	}
}

%hook UIWindow

- (void)_unregisterScrollToTopView:(id)scrollToTopView
{
	[scrollableViews removeObject:scrollToTopView];
	if (isActive)
		notify_set_state(notifyToken, GetScrollableDirections());
	%orig;
}

- (void)_registerScrollToTopView:(id)scrollToTopView
{
	[scrollableViews addObject:scrollToTopView];
	if (isActive)
		notify_set_state(notifyToken, GetScrollableDirections());
	%orig;
}

%end

%hook UIScrollView

- (void)_notifyDidScroll
{
	if (isActive && [scrollableViews containsObject:self])
		notify_set_state(notifyToken, GetScrollableDirections());
	%orig;
}

- (BOOL)gestureRecognizer:(id)arg1 shouldReceiveTouch:(id)arg2
{
	autoscrolling = NO;
	return %orig;
}

%new(v@:)
	- (void)autoscrollUpTimerFired
{
	if (!autoscrolling) {
		[scrollingTimer invalidate];
		scrollingTimer = nil;
		return;
	}
	CGPoint contentOffset = self.contentOffset;
	contentOffset.y = self.bounds.origin.y - 1.0f;
	CGFloat topOffset = -self.contentInset.top;
	if (contentOffset.y < topOffset) {
		contentOffset.y = topOffset;
		autoscrolling = NO;
	}
	[self setContentOffset:contentOffset animated:NO];
}

%new(v@:)
	- (void)autoscrollDownTimerFired
{
	if (!autoscrolling) {
		[scrollingTimer invalidate];
		scrollingTimer = nil;
		return;
	}
	CGPoint contentOffset = self.contentOffset;
	CGFloat height = self.bounds.size.height;
	contentOffset.y += 1.0f;
	CGFloat maxY = self.contentSize.height + self.contentInset.bottom - height;
	if (contentOffset.y > maxY) {
		contentOffset.y = maxY;
		autoscrolling = NO;
	}
	[self setContentOffset:contentOffset animated:NO];
}

%end

@implementation SuperScroller

+ (void)load
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	notify_register_check("com.rpetrich.superscroller", &notifyToken);
	if (LASharedActivator.runningInsideSpringBoard) {
		SuperScroller *scroller = [[self alloc] init];
		if (![LASharedActivator hasSeenListenerWithName:@kUp])
			[LASharedActivator assignEvent:[LAEvent eventWithName:LAEventNameVolumeUpPress mode:LAEventModeApplication] toListenerWithName:@kUp];
		if (![LASharedActivator hasSeenListenerWithName:@kAutoUp])
			[LASharedActivator assignEvent:[LAEvent eventWithName:LAEventNameVolumeUpHoldShort mode:LAEventModeApplication] toListenerWithName:@kAutoUp];
		if (![LASharedActivator hasSeenListenerWithName:@kDown])
			[LASharedActivator assignEvent:[LAEvent eventWithName:LAEventNameVolumeDownPress mode:LAEventModeApplication] toListenerWithName:@kDown];
		if (![LASharedActivator hasSeenListenerWithName:@kAutoDown])
			[LASharedActivator assignEvent:[LAEvent eventWithName:LAEventNameVolumeDownHoldShort mode:LAEventModeApplication] toListenerWithName:@kAutoDown];
		[LASharedActivator registerListener:scroller forName:@kUp];
		[LASharedActivator registerListener:scroller forName:@kAutoUp];
		[LASharedActivator registerListener:scroller forName:@kDown];
		[LASharedActivator registerListener:scroller forName:@kAutoDown];
	} else {
		%init;
		scrollableViews = [[NSMutableSet alloc] init];
		CFNotificationCenterRef local = CFNotificationCenterGetLocalCenter();
		CFNotificationCenterAddObserver(local, WillEnterForegroundNotificationReceived, WillEnterForegroundNotificationReceived, (CFStringRef)UIApplicationDidFinishLaunchingNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
		CFNotificationCenterAddObserver(local, WillEnterForegroundNotificationReceived, WillEnterForegroundNotificationReceived, (CFStringRef)UIApplicationWillEnterForegroundNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
		CFNotificationCenterAddObserver(local, DidEnterBackgroundNotificationReceived, DidEnterBackgroundNotificationReceived, (CFStringRef)UIApplicationDidEnterBackgroundNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
	}
	[pool drain];
}

- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event forListenerName:(NSString *)listenerName
{
	if ([(SpringBoard *)UIApp _accessibilityFrontMostApplication]) {
		uint64_t state = 0;
		notify_get_state(notifyToken, &state);
		if ([listenerName isEqualToString:@kUp]) {
			if (state & UIScrollableDirectionUp) {
				notify_post(kUp);
				event.handled = YES;
			}
		} else if ([listenerName isEqualToString:@kDown]) {
			if (state & UIScrollableDirectionDown) {
				notify_post(kDown);
				event.handled = YES;
			}
		} else if ([listenerName isEqualToString:@kAutoUp]) {
			if (state & UIScrollableDirectionUp) {
				notify_post(kAutoUp);
				event.handled = YES;
			}
		} else if ([listenerName isEqualToString:@kAutoDown]) {
			if (state & UIScrollableDirectionDown) {
				notify_post(kAutoDown);
				event.handled = YES;
			}
		}
	}
}

@end
