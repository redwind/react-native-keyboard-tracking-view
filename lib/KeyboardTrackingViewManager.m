//
//  KeyboardTrackingViewManager.m
//  ReactNativeChat
//
//  Created by Artal Druk on 19/04/2016.
//  Copyright © 2016 Wix.com All rights reserved.
//

#import "KeyboardTrackingViewManager.h"
#import "ObservingInputAccessoryView.h"
#import "UIResponder+FirstResponder.h"

#import <WebKit/WebKit.h>
#import <React/RCTScrollView.h>
#import <React/RCTBridge.h>
#import <React/RCTUIManager.h>
#import <React/UIView+React.h>
#import <React/RCTUIManagerUtils.h>

#import <objc/runtime.h>
#import <WebKit/WebKit.h>


NSUInteger const kInputViewKey = 101010;
NSUInteger const kMaxDeferedInitializeAccessoryViews = 15;
NSInteger  const kTrackingViewNotFoundErrorCode = 1;
NSInteger  const kBottomViewHeight = 100;

typedef NS_ENUM(NSUInteger, KeyboardTrackingScrollBehavior) {
    KeyboardTrackingScrollBehaviorNone,
    KeyboardTrackingScrollBehaviorScrollToBottomInvertedOnly,
    KeyboardTrackingScrollBehaviorFixedOffset
};

@interface KeyboardTrackingView : UIView
{
    Class _newClass;
    NSMapTable *_inputViewsMap;
    ObservingInputAccessoryView *_observingInputAccessoryView;
    UIView *_bottomView;
    CGFloat _bottomViewHeight;
}

@property (nonatomic, strong) UIScrollView *scrollViewToManage;
@property (nonatomic) BOOL scrollIsInverted;
@property (nonatomic) BOOL revealKeyboardInteractive;
@property (nonatomic) BOOL isDraggingScrollView;
@property (nonatomic) BOOL manageScrollView;
@property (nonatomic) BOOL requiresSameParentToManageScrollView;
@property (nonatomic) NSUInteger deferedInitializeAccessoryViewsCount;
@property (nonatomic) CGFloat originalHeight;
@property (nonatomic) KeyboardTrackingScrollBehavior scrollBehavior;
@property (nonatomic) BOOL addBottomView;
@property (nonatomic) BOOL scrollToFocusedInput;
@property (nonatomic) BOOL allowHitsOutsideBounds;

@end

@interface KeyboardTrackingView () <ObservingInputAccessoryViewDelegate, UIScrollViewDelegate>

@end

@implementation KeyboardTrackingView

-(instancetype)init
{
    self = [super init];
    
    if (self)
    {
        [self addObserver:self forKeyPath:@"bounds" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
        _inputViewsMap = [NSMapTable weakToWeakObjectsMapTable];
        _deferedInitializeAccessoryViewsCount = 0;
        
        _observingInputAccessoryView = [ObservingInputAccessoryView new];
        _observingInputAccessoryView.delegate = self;
        
        _manageScrollView = YES;
        _allowHitsOutsideBounds = NO;
        
        _bottomViewHeight = kBottomViewHeight;
        
        self.addBottomView = NO;
        self.scrollToFocusedInput = NO;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rctContentDidAppearNotification:) name:RCTContentDidAppearNotification object:nil];
    }
    
    return self;
}

-(RCTRootView*)getRootView
{
    UIView *view = self;
    while (view.superview != nil)
    {
        view = view.superview;
        if ([view isKindOfClass:[RCTRootView class]])
            break;
    }
    
    if ([view isKindOfClass:[RCTRootView class]])
    {
        return (RCTRootView*)view;
    }
    return nil;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_allowHitsOutsideBounds) {
        return [super hitTest:point withEvent:event];
    }
    
    if (self.isHidden || self.alpha == 0 || self.clipsToBounds) {
        return nil;
    }
    
    UIView *subview = [super hitTest:point withEvent:event];
    if (subview == nil) {
        NSArray<UIView*>* allSubviews = [self getBreadthFirstSubviewsForView:self];
        for (UIView *tmpSubview in allSubviews) {
            CGPoint pointInSubview = [self convertPoint:point toView:tmpSubview];
            if ([tmpSubview pointInside:pointInSubview withEvent:event]) {
                subview = tmpSubview;
                break;
            }
        }
    }
    
    return subview;
}

-(void)_swizzleWebViewInputAccessory:(WKWebView*)webview
{
    UIView* subview;
    for (UIView* view in webview.scrollView.subviews)
    {
        if([[view.class description] hasPrefix:@"UIWeb"])
        {
            subview = view;
        }
    }
    
    if(_newClass == nil)
    {
        NSString* name = [NSString stringWithFormat:@"%@_Tracking_%p", subview.class, self];
        _newClass = NSClassFromString(name);
        
        _newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
        if(!_newClass) return;
        
        Method method = class_getInstanceMethod([UIResponder class], @selector(inputAccessoryView));
        class_addMethod(_newClass, @selector(inputAccessoryView), imp_implementationWithBlock(^(id _self){return _observingInputAccessoryView;}), method_getTypeEncoding(method));
        
        objc_registerClassPair(_newClass);
    }
    
    object_setClass(subview, _newClass);
    [subview reloadInputViews];
}

-(void)layoutSubviews
{
    [super layoutSubviews];
    [self updateBottomViewFrame];
}

- (void)initializeAccessoryViewsAndHandleInsets
{
    NSArray<UIView*>* allSubviews = [self getBreadthFirstSubviewsForView:[self getRootView]];
    NSMutableArray<RCTScrollView*>* rctScrollViewsArray = [NSMutableArray array];
    
    for (UIView* subview in allSubviews)
    {
        if(_manageScrollView)
        {
            if(_scrollViewToManage == nil)
            {
                if(_requiresSameParentToManageScrollView && [subview isKindOfClass:[RCTScrollView class]] && subview.superview == self.superview)
                {
                    _scrollViewToManage = ((RCTScrollView*)subview).scrollView;
                }
                else if(!_requiresSameParentToManageScrollView && [subview isKindOfClass:[UIScrollView class]])
                {
                    _scrollViewToManage = (UIScrollView*)subview;
                }
                
                if(_scrollViewToManage != nil)
                {
                    _scrollIsInverted = CGAffineTransformEqualToTransform(_scrollViewToManage.superview.transform, CGAffineTransformMakeScale(1, -1));
                }
            }
            
            if([subview isKindOfClass:[RCTScrollView class]])
            {
                [rctScrollViewsArray addObject:(RCTScrollView*)subview];
            }
        }
        
        if ([subview isKindOfClass:NSClassFromString(@"RCTTextField")])
        {
            UITextField *textField = nil;
            Ivar backedTextInputIvar = class_getInstanceVariable([subview class], "_backedTextInput");
            if (backedTextInputIvar != NULL)
            {
                textField = [subview valueForKey:@"_backedTextInput"];
            }
            else if([subview isKindOfClass:[UITextField class]])
            {
                textField = (UITextField*)subview;
            }
            [self setupTextField:textField];
        }
        else if ([subview isKindOfClass:NSClassFromString(@"RCTUITextField")] && [subview isKindOfClass:[UITextField class]])
        {
            [self setupTextField:(UITextField*)subview];
        }
        else if ([subview isKindOfClass:NSClassFromString(@"RCTMultilineTextInputView")])
        {
            [self setupTextView:[subview valueForKey:@"_backedTextInputView"]];
        }
        else if ([subview isKindOfClass:NSClassFromString(@"RCTTextView")])
        {
            UITextView *textView = nil;
            Ivar backedTextInputIvar = class_getInstanceVariable([subview class], "_backedTextInput");
            if (backedTextInputIvar != NULL)
            {
                textView = [subview valueForKey:@"_backedTextInput"];
            }
            else if([subview isKindOfClass:[UITextView class]])
            {
                textView = (UITextView*)subview;
            }
            [self setupTextView:textView];
        }
        else if ([subview isKindOfClass:NSClassFromString(@"RCTUITextView")] && [subview isKindOfClass:[UITextView class]])
        {
            [self setupTextView:(UITextView*)subview];
        }
        else if ([subview isKindOfClass:[WKWebView class]])
        {
            [self _swizzleWebViewInputAccessory:(WKWebView*)subview];
        }
    }
    
    for (RCTScrollView *scrollView in rctScrollViewsArray)
    {
        if(scrollView.scrollView == _scrollViewToManage)
        {
            [scrollView removeScrollListener:self];
            [scrollView addScrollListener:self];
            break;
        }
    }
    
#if __IPHONE_OS_VERSION_MAX_ALLOWED > __IPHONE_10_3
    if (@available(iOS 11.0, *)) {
        if (_scrollViewToManage != nil) {
            _scrollViewToManage.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
    }
#endif
    
    [self _updateScrollViewInsets];
    
    _originalHeight = _observingInputAccessoryView.height;
    
    [self addBottomViewIfNecessary];
}

- (void)setupTextView:(UITextView*)textView
{
    if (textView != nil)
    {
        [textView setInputAccessoryView:_observingInputAccessoryView];
        [textView reloadInputViews];
        [_inputViewsMap setObject:textView forKey:@(kInputViewKey)];
    }
}

- (void)setupTextField:(UITextField*)textField
{
    if (textField != nil)
    {
        [textField setInputAccessoryView:_observingInputAccessoryView];
        [textField reloadInputViews];
        [_inputViewsMap setObject:textField forKey:@(kInputViewKey)];
    }
}

-(void) deferedInitializeAccessoryViewsAndHandleInsets
{
    if(self.window == nil)
    {
        return;
    }
    
    if (_observingInputAccessoryView.height == 0 && self.deferedInitializeAccessoryViewsCount < kMaxDeferedInitializeAccessoryViews)
    {
        self.deferedInitializeAccessoryViewsCount++;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self deferedInitializeAccessoryViewsAndHandleInsets];
        });
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self initializeAccessoryViewsAndHandleInsets];
        });
    }
}

- (void)willMoveToWindow:(nullable UIWindow *)newWindow
{
    if (newWindow == nil && [ObservingInputAccessoryViewManager sharedInstance].activeObservingInputAccessoryView == _observingInputAccessoryView)
    {
        [ObservingInputAccessoryViewManager sharedInstance].activeObservingInputAccessoryView = nil;
    }
    else if (newWindow != nil)
    {
        [ObservingInputAccessoryViewManager sharedInstance].activeObservingInputAccessoryView = _observingInputAccessoryView;
    }
}

-(void)didMoveToWindow
{
    [super didMoveToWindow];
    
    self.deferedInitializeAccessoryViewsCount = 0;
    
    [self deferedInitializeAccessoryViewsAndHandleInsets];
}

-(void)dealloc
{
    [self removeObserver:self forKeyPath:@"bounds"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context
{
    _observingInputAccessoryView.height = self.bounds.size.height;
}

- (void)observingInputAccessoryViewKeyboardWillDisappear:(ObservingInputAccessoryView *)observingInputAccessoryView
{
    _bottomViewHeight = kBottomViewHeight;
    [self updateBottomViewFrame];
}

- (NSArray*)getBreadthFirstSubviewsForView:(UIView*)view
{
    if(view == nil)
    {
        return nil;
    }
    
    NSMutableArray *allSubviews = [NSMutableArray new];
    NSMutableArray *queue = [NSMutableArray new];
    
    [allSubviews addObject:view];
    [queue addObject:view];
    
    while ([queue count] > 0) {
        UIView *current = [queue lastObject];
        [queue removeLastObject];
        
        for (UIView *n in current.subviews)
        {
            [allSubviews addObject:n];
            [queue insertObject:n atIndex:0];
        }
    }
    return allSubviews;
}

- (NSArray*)getAllReactSubviewsForView:(UIView*)view
{
    NSMutableArray *allSubviews = [NSMutableArray new];
    for (UIView *subview in view.reactSubviews)
    {
        [allSubviews addObject:subview];
        [allSubviews addObjectsFromArray:[self getAllReactSubviewsForView:subview]];
    }
    return allSubviews;
}

- (void)_updateScrollViewInsets
{
    if(self.scrollViewToManage != nil)
    {
        UIEdgeInsets insets = self.scrollViewToManage.contentInset;
        CGFloat bottomSafeArea = [self getBottomSafeArea];
        CGFloat bottomInset = MAX(self.bounds.size.height, _observingInputAccessoryView.keyboardHeight + _observingInputAccessoryView.height);
        
        CGFloat originalBottomInset = self.scrollIsInverted ? insets.top : insets.bottom;
        CGPoint originalOffset = self.scrollViewToManage.contentOffset;
        
        bottomInset += (_observingInputAccessoryView.keyboardHeight == 0 ? bottomSafeArea : 0);
        if(self.scrollIsInverted)
        {
            insets.top = bottomInset;
        }
        else
        {
            insets.bottom = bottomInset;
        }
        self.scrollViewToManage.contentInset = insets;
        
        if(self.scrollBehavior == KeyboardTrackingScrollBehaviorScrollToBottomInvertedOnly && _scrollIsInverted)
        {
            BOOL fisrtTime = _observingInputAccessoryView.keyboardHeight == 0 && _observingInputAccessoryView.keyboardState == KeyboardStateHidden;
            BOOL willOpen = _observingInputAccessoryView.keyboardHeight != 0 && _observingInputAccessoryView.keyboardState == KeyboardStateHidden;
            BOOL isOpen = _observingInputAccessoryView.keyboardHeight != 0 && _observingInputAccessoryView.keyboardState == KeyboardStateShown;
            if(fisrtTime || willOpen || (isOpen && !self.isDraggingScrollView))
            {
                [self.scrollViewToManage setContentOffset:CGPointMake(self.scrollViewToManage.contentOffset.x, -self.scrollViewToManage.contentInset.top) animated:!fisrtTime];
            }
        }
        else if(self.scrollBehavior == KeyboardTrackingScrollBehaviorFixedOffset && !self.isDraggingScrollView)
        {
            CGFloat insetsDiff = (bottomInset - originalBottomInset) * (self.scrollIsInverted ? -1 : 1);
            self.scrollViewToManage.contentOffset = CGPointMake(originalOffset.x, originalOffset.y + insetsDiff);
        }
        
        insets = self.scrollViewToManage.contentInset;
        if(self.scrollIsInverted)
        {
            insets.top = bottomInset;
        }
        else
        {
            insets.bottom = bottomInset;
        }
        self.scrollViewToManage.scrollIndicatorInsets = insets;
    }
}

#pragma mark - bottom view

-(void)setAddBottomView:(BOOL)addBottomView
{
    _addBottomView = addBottomView;
    [self addBottomViewIfNecessary];
}

-(void)addBottomViewIfNecessary
{
    if (self.addBottomView && _bottomView == nil)
    {
        _bottomView = [UIView new];
        _bottomView.backgroundColor = [UIColor whiteColor];
        [self addSubview:_bottomView];
        [self updateBottomViewFrame];
    }
    else if (!self.addBottomView && _bottomView != nil)
    {
        [_bottomView removeFromSuperview];
        _bottomView = nil;
    }
}

-(void)updateBottomViewFrame
{
    if (_bottomView != nil)
    {
        _bottomView.frame = CGRectMake(0, self.frame.size.height, self.frame.size.width, _bottomViewHeight);
    }
}

#pragma mark - safe area

-(void)safeAreaInsetsDidChange
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED > __IPHONE_10_3
    if (@available(iOS 11.0, *)) {
        [super safeAreaInsetsDidChange];
    }
#endif
    [self updateTransformAndInsets];
}

-(CGFloat)getBottomSafeArea
{
    CGFloat bottomSafeArea = 0;
#if __IPHONE_OS_VERSION_MAX_ALLOWED > __IPHONE_10_3
    if (@available(iOS 11.0, *)) {
        bottomSafeArea = self.superview ? self.superview.safeAreaInsets.bottom : self.safeAreaInsets.bottom;
    }
#endif
    return bottomSafeArea;
}

#pragma RCTRootView notifications

- (void) rctContentDidAppearNotification:(NSNotification*)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if(notification.object == [self getRootView] && _manageScrollView && _scrollViewToManage == nil)
        {
            [self initializeAccessoryViewsAndHandleInsets];
        }
    });
}

-(CGFloat)getTabBarHeight {
  UITabBarController *tabBarController = (UITabBarController *)[[[UIApplication sharedApplication] delegate] window].rootViewController;
  CGFloat tabbarHeight = 0.0f;

  if (!tabBarController.tabBar.isHidden) {
    tabbarHeight = tabBarController.tabBar.bounds.size.height;
  }

  return tabbarHeight;
}


#pragma mark - ObservingInputAccessoryViewDelegate methods

-(void)updateTransformAndInsets
{
    CGFloat bottomSafeArea = [self getBottomSafeArea];
    CGFloat tabBarHeight = [self getTabBarHeight];
    CGFloat accessoryTranslation = MIN(-bottomSafeArea, -(_observingInputAccessoryView.keyboardHeight - tabBarHeight));
    
    if (_observingInputAccessoryView.keyboardHeight <= bottomSafeArea) {
        _bottomViewHeight = kBottomViewHeight;
    } else if (_observingInputAccessoryView.keyboardState != KeyboardStateWillHide) {
        _bottomViewHeight = 0;
    }
    [self updateBottomViewFrame];
    
    self.transform = CGAffineTransformMakeTranslation(0, accessoryTranslation);
    [self _updateScrollViewInsets];
}

- (void)performScrollToFocusedInput
{
    if (_scrollViewToManage != nil && self.scrollToFocusedInput)
    {
        UIResponder *currentFirstResponder = [UIResponder currentFirstResponder];
        if (currentFirstResponder != nil && [currentFirstResponder isKindOfClass:[UIView class]])
        {
            UIView *reponderView = (UIView*)currentFirstResponder;
            if ([reponderView isDescendantOfView:_scrollViewToManage])
            {
                CGRect frame = [_scrollViewToManage convertRect:reponderView.frame fromView:reponderView];
                frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height + 20);
                [_scrollViewToManage scrollRectToVisible:frame animated:NO];
            }
        }
    }
}

- (void)observingInputAccessoryViewDidChangeFrame:(ObservingInputAccessoryView*)observingInputAccessoryView
{
    [self updateTransformAndInsets];
}

- (void) observingInputAccessoryViewKeyboardWillAppear:(ObservingInputAccessoryView *)observingInputAccessoryView keyboardDelta:(CGFloat)delta
{
    if (observingInputAccessoryView.keyboardHeight > 0) //prevent hiding the bottom view if an external keyboard is in use
    {
        _bottomViewHeight = 0;
        [self updateBottomViewFrame];
    }
    
    [self performScrollToFocusedInput];
}

#pragma mark - UIScrollViewDelegate methods

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if(_observingInputAccessoryView.keyboardState != KeyboardStateHidden || !self.revealKeyboardInteractive)
    {
        return;
    }
    
    UIView *inputView = [_inputViewsMap objectForKey:@(kInputViewKey)];
    if (inputView != nil && scrollView.contentOffset.y * (self.scrollIsInverted ? -1 : 1) > (self.scrollIsInverted ? scrollView.contentInset.top : scrollView.contentInset.bottom) + 50 && ![inputView isFirstResponder])
    {
        for (UIGestureRecognizer *gesture in scrollView.gestureRecognizers)
        {
            if([gesture isKindOfClass:[UIPanGestureRecognizer class]])
            {
                gesture.enabled = NO;
                gesture.enabled = YES;
            }
        }
        
        [inputView reactFocus];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    self.isDraggingScrollView = YES;
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset
{
    self.isDraggingScrollView = NO;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    self.isDraggingScrollView = NO;
}

- (CGFloat)getKeyboardHeight
{
    return _observingInputAccessoryView ? _observingInputAccessoryView.keyboardHeight : 0;
}

-(CGFloat)getScrollViewTopContentInset
{
    return (self.scrollViewToManage != nil) ? -self.scrollViewToManage.contentInset.top : 0;
}

-(void)scrollToStart
{
    if (self.scrollViewToManage != nil)
    {
        [self.scrollViewToManage setContentOffset:CGPointMake(self.scrollViewToManage.contentOffset.x, -self.scrollViewToManage.contentInset.top) animated:YES];
    }
}

@end

@implementation RCTConvert (KeyboardTrackingScrollBehavior)
RCT_ENUM_CONVERTER(KeyboardTrackingScrollBehavior, (@{ @"KeyboardTrackingScrollBehaviorNone": @(KeyboardTrackingScrollBehaviorNone),
                                                       @"KeyboardTrackingScrollBehaviorScrollToBottomInvertedOnly": @(KeyboardTrackingScrollBehaviorScrollToBottomInvertedOnly),
                                                       @"KeyboardTrackingScrollBehaviorFixedOffset": @(KeyboardTrackingScrollBehaviorFixedOffset)}),
                   KeyboardTrackingScrollBehaviorNone, unsignedIntegerValue)
@end

@implementation KeyboardTrackingViewManager

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

RCT_REMAP_VIEW_PROPERTY(scrollBehavior, scrollBehavior, KeyboardTrackingScrollBehavior)
RCT_REMAP_VIEW_PROPERTY(revealKeyboardInteractive, revealKeyboardInteractive, BOOL)
RCT_REMAP_VIEW_PROPERTY(manageScrollView, manageScrollView, BOOL)
RCT_REMAP_VIEW_PROPERTY(requiresSameParentToManageScrollView, requiresSameParentToManageScrollView, BOOL)
RCT_REMAP_VIEW_PROPERTY(addBottomView, addBottomView, BOOL)
RCT_REMAP_VIEW_PROPERTY(scrollToFocusedInput, scrollToFocusedInput, BOOL)
RCT_REMAP_VIEW_PROPERTY(allowHitsOutsideBounds, allowHitsOutsideBounds, BOOL)

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

- (NSDictionary<NSString *, id> *)constantsToExport
{
    return @{
             @"KeyboardTrackingScrollBehaviorNone": @(KeyboardTrackingScrollBehaviorNone),
             @"KeyboardTrackingScrollBehaviorScrollToBottomInvertedOnly": @(KeyboardTrackingScrollBehaviorScrollToBottomInvertedOnly),
             @"KeyboardTrackingScrollBehaviorFixedOffset": @(KeyboardTrackingScrollBehaviorFixedOffset),
             };
}

- (UIView *)view
{
    return [[KeyboardTrackingView alloc] init];
}

RCT_EXPORT_METHOD(getNativeProps:(nonnull NSNumber *)reactTag resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    [self.bridge.uiManager addUIBlock:
     ^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, KeyboardTrackingView *> *viewRegistry) {
         
         KeyboardTrackingView *view = viewRegistry[reactTag];
         if (!view || ![view isKindOfClass:[KeyboardTrackingView class]]) {
             NSString *errorMessage = [NSString stringWithFormat:@"Error: cannot find KeyboardTrackingView with tag #%@", reactTag];
             RCTLogError(@"%@", errorMessage);
             [self rejectPromise:reject withErrorMessage:errorMessage errorCode:kTrackingViewNotFoundErrorCode];
             return;
         }
         
         resolve(@{@"trackingViewHeight": @(view.bounds.size.height),
                   @"keyboardHeight": @([view getKeyboardHeight]),
                   @"contentTopInset": @([view getScrollViewTopContentInset])});
     }];
}

RCT_EXPORT_METHOD(scrollToStart:(nonnull NSNumber *)reactTag)
{
    [self.bridge.uiManager addUIBlock:
     ^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, KeyboardTrackingView *> *viewRegistry) {
         
         KeyboardTrackingView *view = viewRegistry[reactTag];
         if (!view || ![view isKindOfClass:[KeyboardTrackingView class]]) {
             RCTLogError(@"Error: cannot find KeyboardTrackingView with tag #%@", reactTag);
             return;
         }
         
         [view scrollToStart];
     }];
}

#pragma mark - helper methods

-(void)rejectPromise:(RCTPromiseRejectBlock)reject withErrorMessage:(NSString*)errorMessage errorCode:(NSInteger)errorCode
{
    NSString *errorDescription = NSLocalizedString(errorMessage, nil);
    NSError *error = [NSError errorWithDomain:@"com.keyboardTrackingView" code:errorCode userInfo:@{NSLocalizedFailureReasonErrorKey: errorDescription}];
    reject([NSString stringWithFormat:@"%ld", (long)errorCode], errorDescription, error);
}

@end
