// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.

#import "ADOAuth2Constants.h"
#if TARGET_OS_IPHONE
    #import "UIApplicationExtensions.h"
#else
    #import "ADAuthenticationWindowController.h"
#endif
#import "ADAuthenticationContext.h"
#import "ADAuthenticationDelegate.h"
#import "ADAuthenticationWebViewController.h"
#import "ADAuthenticationViewController.h"
#import "ADAuthenticationBroker.h"
#import "ADAuthenticationSettings.h"


static NSString *const WAB_FAILED_ERROR         = @"Authorization Failed";
static NSString *const WAB_FAILED_ERROR_CODE    = @"Authorization Failed: %ld";

static NSString *const WAB_FAILED_CANCELLED     = @"The user cancelled the authorization request";
static NSString *const WAB_FAILED_NO_CONTROLLER = @"The Application does not have a current ViewController";
static NSString *const WAB_FAILED_NO_RESOURCES  = @"The required resource bundle could not be loaded. Please read read the ADALiOS readme on how to build your application with ADAL provided authentication UI resources.";

// Private interface declaration
@interface ADAuthenticationBroker () <ADAuthenticationDelegate>
@end

// Implementation
@implementation ADAuthenticationBroker
{
#if TARGET_OS_IPHONE
    ADAuthenticationViewController    *_authenticationPageController;
#else
    ADAuthenticationWindowController  *_authenticationPageController;
    NSModalSession                      _authenticationSession;
#endif
    ADAuthenticationWebViewController *_authenticationWebViewController;
    
    NSLock                             *_completionLock;
    
    void (^_completionBlock)( ADAuthenticationError *, NSURL *);
}

#pragma mark Shared Instance Methods

+ (ADAuthenticationBroker *)sharedInstance
{
    static ADAuthenticationBroker *broker     = nil;
    static dispatch_once_t          predicate;
    
    dispatch_once( &predicate, ^{
        broker = [[self allocPrivate] init];
    });
    
    return broker;
}

+ (id)alloc
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

+ (id)allocPrivate
{
    return [super alloc];
}

- (id)copy
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (id)mutableCopy
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    
    if ( self )
    {
        _completionLock = [[NSLock alloc] init];
    }
    
    return self;
}

#pragma mark - Private Methods

#if TARGET_OS_IPHONE
// Retrive the bundle containing the resources for the library. May return nil, if the bundle
// cannot be loaded.
+ (NSBundle *)frameworkBundle
{
    static NSBundle       *bundle     = nil;
    static dispatch_once_t predicate;
    
    @synchronized(self)
    {
        dispatch_once( &predicate,
                      ^{
                          NSString* mainBundlePath      = [[NSBundle mainBundle] resourcePath];
                          AD_LOG_VERBOSE_F(@"Resources Loading", @"Attempting to load resources from: %@", mainBundlePath);
                          
                          NSString* frameworkBundlePath = [mainBundlePath stringByAppendingPathComponent:@"ADALiOS.bundle"];
                          bundle = [NSBundle bundleWithPath:frameworkBundlePath];
                      });
    }
    
    return bundle;
}
#endif


#if TARGET_OS_IPHONE
// Retrieve the current storyboard from the resources for the library. Attempts to use ADALiOS bundle first
// and if the bundle is not present, assumes that the resources are build with the application itself.
// Raises an error if both the library resources bundle and the application fail to locate resources.
+ (UIStoryboard *)storyboard: (ADAuthenticationError* __autoreleasing*) error
{
    NSBundle* bundle = [self frameworkBundle];//May be nil.
    
    UIStoryboard* storeBoard = ( UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ) ?
                [UIStoryboard storyboardWithName:@"IPAL_iPad_Storyboard" bundle:bundle]
              : [UIStoryboard storyboardWithName:@"IPAL_iPhone_Storyboard" bundle:bundle];
    
    if (!storeBoard)
    {
        ADAuthenticationError* adError = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_MISSING_RESOURCES protocolCode:nil errorDetails:WAB_FAILED_NO_RESOURCES];
        if (error)
        {
            *error = adError;
        }
    }
    return storeBoard;
}
#endif

-(NSURL*) addToURL: (NSURL*) url
     correlationId: (NSUUID*) correlationId
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@&%@=%@",
                                 [url absoluteString], OAUTH2_CORRELATION_ID_REQUEST_VALUE, [correlationId UUIDString]]];
}

#pragma mark - Public Methods

// On OSX, the fullscreen parameter is ignored.
- (void)start:(NSURL *)startURL
          end:(NSURL *)endURL
      webView:(WebViewType *)webView
   fullScreen:(BOOL)fullScreen
correlationId:(NSUUID *)correlationId
   completion:(ADBrokerCallback)completionBlock
{
#pragma unused(fullScreen)
    THROW_ON_NIL_ARGUMENT(startURL);
    THROW_ON_NIL_ARGUMENT(endURL);
    THROW_ON_NIL_ARGUMENT(correlationId);
    THROW_ON_NIL_ARGUMENT(completionBlock)
    
#if !(TARGET_OS_IPHONE)
    _authenticationWebViewController = nil;
    _authenticationPageController  = nil;
    _authenticationSession           = NULL;
#endif
    
    startURL = [self addToURL:startURL correlationId:correlationId];//Append the correlation id
    
    // Save the completion block
    _completionBlock = [completionBlock copy];
    
    ADAuthenticationError* error;
    
    if ( nil == webView )
    {
#if TARGET_OS_IPHONE
        // Must have a parent view controller to start the authentication view
        UIViewController *parent = [UIApplication currentViewController];
        
        if ( parent )
        {
            // Load our resource bundle, find the navigation controller for the authentication view, and then the authentication view
            UINavigationController *navigationController = [[self.class storyboard:&error] instantiateViewControllerWithIdentifier:@"LogonNavigator"];
            
            if (navigationController)
            {
                _authenticationPageController = (ADAuthenticationViewController *)[navigationController.viewControllers objectAtIndex:0];
            
                _authenticationPageController.delegate = self;
                
                if ( fullScreen == YES )
                    [navigationController setModalPresentationStyle:UIModalPresentationFullScreen];
                else
                    [navigationController setModalPresentationStyle:UIModalPresentationFormSheet];
                
                // Show the authentication view
                [parent presentViewController:navigationController animated:YES completion:^{
                    // Instead of loading the URL immediately on completion, get the UI on the screen
                    // and then dispatch the call to load the authorization URL
                    dispatch_async( dispatch_get_main_queue(), ^{
                        [_authenticationPageController startWithURL:startURL endAtURL:endURL];
                    });
                }];
            }
            else
            {
                error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_MISSING_RESOURCES
                                                               protocolCode:nil
                                                               errorDetails:WAB_FAILED_NO_RESOURCES];
            }
        }
        else
        {
            error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_NO_MAIN_VIEW_CONTROLLER
                                                           protocolCode:nil
                                                           errorDetails:WAB_FAILED_NO_CONTROLLER];

        }
#else
        // Load the authentication view
        _authenticationPageController = [[ADAuthenticationWindowController alloc] initAtURL:startURL endAtURL:endURL];

        if ( _authenticationPageController )
        {
            _authenticationPageController.delegate = self;

            // Start the modal session
            _authenticationSession = [NSApp beginModalSessionForWindow:[_authenticationPageController window]];
            
            // Initialize the web view controller
            [_authenticationPageController start];
            
            NSDate   *beforeDate = [NSDate date];
            NSInteger result = NSRunContinuesResponse;
            
            // Loop until window is endModal is called
            while ( result == NSRunContinuesResponse )
            {
                result = [NSApp runModalSession:_authenticationSession];
                
                beforeDate = [beforeDate dateByAddingTimeInterval:300];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:beforeDate];
            }
            
            // End the modal session
            [NSApp endModalSession:_authenticationSession];
            
            _authenticationSession = NULL;
        }
        else
        {
            error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_MISSING_RESOURCES
                                                           protocolCode:nil
                                                           errorDetails:WAB_FAILED_NO_RESOURCES];
        }
#endif
    }
    else
    {
        // Use the application provided WebView
        _authenticationWebViewController = [[ADAuthenticationWebViewController alloc] initWithWebView:webView startAtURL:startURL endAtURL:endURL];
        
        if ( _authenticationWebViewController )
        {
            // Show the authentication view
            _authenticationWebViewController.delegate = self;
            [_authenticationWebViewController start];
        }
        else
        {
            error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_MISSING_RESOURCES
                                                           protocolCode:nil
                                                           errorDetails:WAB_FAILED_NO_RESOURCES];
        }
    }
    //Error occurred above. Dispatch the callback to the caller:
    if (error)
    {
        dispatch_async( [ADAuthenticationSettings sharedInstance].dispatchQueue, ^{
            _completionBlock( error, nil );
        });
    }
}

- (void)cancel
{
    [self webAuthenticationDidCancel];
}

#pragma mark - Private Methods

- (void)dispatchCompletionBlock:(ADAuthenticationError *)error URL:(NSURL *)url
{
    // NOTE: It is possible that race between a successful completion
    //       and the user cancelling the authentication dialog can
    //       occur causing this method to be called twice. The race
    //       cannot be blocked at its root, and so this method must
    //       be resilient to this condition and should not generate
    //       two callbacks.
    @synchronized(self)
    {
        if ( _completionBlock )
        {
            void (^completionBlock)( ADAuthenticationError *, NSURL *) = _completionBlock;
            _completionBlock = nil;
            
            dispatch_async( [ADAuthenticationSettings sharedInstance].dispatchQueue, ^{
                completionBlock( error, url );
            });
        }
    }
}

#pragma mark - ADAuthenticationDelegate

// The user cancelled authentication
- (void)webAuthenticationDidCancel
{
    @synchronized(self)//Prevent running between cancellation and navigation
    {
        DebugLog();
        
        // Dispatch the completion block
        
        ADAuthenticationError* error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_USER_CANCEL protocolCode:nil errorDetails:WAB_FAILED_CANCELLED];
        
#if TARGET_OS_IPHONE
        if ( nil != _authenticationPageController)
        {
            // Dismiss the authentication view and dispatch the completion block
            [[UIApplication currentViewController] dismissViewControllerAnimated:YES completion:^{
                [self dispatchCompletionBlock:error URL:nil];
            }];
        }
        else
        {
            [_authenticationWebViewController stop];
            [self dispatchCompletionBlock:error URL:nil];
        }
        
        _authenticationPageController    = nil;
        _authenticationWebViewController = nil;
#else
        // Dismiss the authentication view if active
        if ( _authenticationSession )
        {
            [NSApp stopModal];
        }
        
        [_authenticationPageController close];
        _authenticationPageController = nil;
        
        [_authenticationWebViewController stop];
        _authenticationWebViewController = nil;
        
        // Dispatch the completion block
        [self dispatchCompletionBlock:error URL:nil];
#endif
    }
}

// Authentication completed at the end URL
- (void)webAuthenticationDidCompleteWithURL:(NSURL *)endURL
{
    @synchronized(self)//Prevent running between navigation and cancellation
    {
        DebugLog();

#if TARGET_OS_IPHONE
        if ( nil != _authenticationPageController)
        {
            // Dismiss the authentication view and dispatch the completion block
            [[UIApplication currentViewController] dismissViewControllerAnimated:YES completion:^{
                [self dispatchCompletionBlock:nil URL:endURL];
            }];
        }
        else
        {
            [_authenticationWebViewController stop];
            [self dispatchCompletionBlock:nil URL:endURL];
        }
        
        _authenticationPageController    = nil;
        _authenticationWebViewController = nil;
#else
        // Dismiss the authentication view if active
        if ( _authenticationSession )
        {
            [NSApp stopModal];
        }
        
        [_authenticationPageController close];
        _authenticationPageController = nil;
        
        [_authenticationWebViewController stop];
        _authenticationWebViewController = nil;
        
        [self dispatchCompletionBlock:nil URL:endURL];
#endif
    }
}

// Authentication failed somewhere
- (void)webAuthenticationDidFailWithError:(NSError *)error
{
    @synchronized(self)//Prevent running between navigation and cancellation
    {
        // Dispatch the completion block
        ADAuthenticationError* adError = [ADAuthenticationError errorFromNSError:error errorDetails:error.localizedDescription];
        
#if TARGET_OS_IPHONE
        if ( nil != _authenticationPageController)
        {
            // Dismiss the authentication view and dispatch the completion block
            [[UIApplication currentViewController] dismissViewControllerAnimated:YES completion:^{
                [self dispatchCompletionBlock:adError URL:nil];
            }];
        }
        else
        {
            [_authenticationWebViewController stop];
            [self dispatchCompletionBlock:adError URL:nil];
        }
        
        _authenticationPageController    = nil;
        _authenticationWebViewController = nil;
#else
        // Dismiss the authentication view if active
        if ( _authenticationSession )
        {
            [NSApp stopModal];
        }
        
        [_authenticationPageController close];
        _authenticationPageController = nil;
        
        [_authenticationWebViewController stop];
        _authenticationWebViewController = nil;
        
        // Dispatch the completion block
        [self dispatchCompletionBlock:adError URL:nil];
#endif
    }
}

@end
