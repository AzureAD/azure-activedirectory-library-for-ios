//
//  ADInstanceDiscoveryTests.m
//  ADALiOS
//
//  Created by Boris Vidolov on 12/30/13.
//  Copyright (c) 2013 MS Open Tech. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "XCTestCase+TestHelperMethods.h"
#import "ADInstanceDiscovery.h"
#import <libkern/OSAtomic.h>

NSString* const sAlwaysTrusted = @"https://login.windows.net";

//The next set of variables are used for the thread-safety tests.
dispatch_semaphore_t sThreadsCompletedSemaphore;//Signals the completion of all threads
volatile int32_t sNumThreadsDone;//Number of threads that have exited.
const int sMaxTestThreads = 10;//How many threads to spawn
const int sThreadsRunDuration = 3;//The number of seconds to run the threads.


//Test category to expose internal methods.
@interface ADInstanceDiscovery(Test)

//Existing private methods:
-(NSString*) extractBase: (NSString*) authority
                   error: (ADAuthenticationError* __autoreleasing *) error;
-(BOOL) isAuthorityValidated: (NSString*) authorityHost;
-(void) setAuthorityValidation: (NSString*) authorityHost;

//Additional methods to extract instance data:
-(NSMutableSet*) getInternalValidatedAuthorities;

@end

//Avoid warnings for incomplete implementation, as the methods are actually implemented, just not in the category:
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation ADInstanceDiscovery(Test)


/*! Internal method, not exposed in the header. Used for testing only. */
-(NSSet*) getInternalValidatedAuthorities
{
    return mValidatedAuthorities;
}

@end


@interface ADInstanceDiscoveryTests : XCTestCase
{
    ADInstanceDiscovery* mInstanceDiscovery;
    NSMutableSet* mValidatedAuthorities;
    //Used for asynchronous calls:
    BOOL mValidated;
    ADAuthenticationError* mError;
}

@end

@implementation ADInstanceDiscoveryTests

- (void)setUp
{
    [super setUp];
    [self adTestBegin];
    mInstanceDiscovery = [ADInstanceDiscovery sharedInstance];
    mValidatedAuthorities = [mInstanceDiscovery getInternalValidatedAuthorities];
    //Initialized correctly
    XCTAssertNotNil(mValidatedAuthorities);
    XCTAssertTrue([mValidatedAuthorities containsObject:sAlwaysTrusted]);
    //Start clean: remove all validated authorities:
    if (mValidatedAuthorities.count > 1)
    {
        [mValidatedAuthorities removeAllObjects];
        [mValidatedAuthorities addObject:sAlwaysTrusted];
        XCTAssertTrue(mValidatedAuthorities.count == 1);
    }
}

- (void)tearDown
{
    mInstanceDiscovery = nil;
    mValidatedAuthorities = nil;
    [self adTestEnd];
    [super tearDown];
}

- (void)testInitializers
{
    XCTAssertThrows([ADInstanceDiscovery new]);
    XCTAssertThrows([[ADInstanceDiscovery alloc] init]);
}

-(void) testSharedInstance
{
    [self clearLogs];
    XCTAssertEqualObjects(mInstanceDiscovery, [ADInstanceDiscovery sharedInstance]);
    ADAssertLogsContain(TEST_LOG_INFO, @"sharedInstance");
}

-(void) testGetValidatedAuthorities
{
    //Test the property:
    NSSet* validatedAuthorities = mInstanceDiscovery.validatedAuthorities;
    XCTAssertNotEqual(validatedAuthorities, mValidatedAuthorities);
    XCTAssertEqualObjects(validatedAuthorities, mValidatedAuthorities);
    XCTAssertFalse([validatedAuthorities isKindOfClass:[NSMutableSet class]], "Read-only class should be returned.");
    ADAssertLogsContain(TEST_LOG_INFO, @"getValidatedAuthorities");
    
    //Modify and test again:
    NSString* newAuthority = @"https://testGetValidatedAuthorities.com";
    [mValidatedAuthorities addObject:newAuthority];
    validatedAuthorities = mInstanceDiscovery.validatedAuthorities;
    XCTAssertTrue([validatedAuthorities containsObject:newAuthority]);
}

-(void) testExtractBaseBadAuthority
{
    //Nil:
    ADAuthenticationError* error;
    NSString* result = [mInstanceDiscovery extractBase:nil error:&error];
    XCTAssertNil(result);
    [self validateForInvalidArgument:@"authority" error:error];
    error = nil;//Cleanup
    
    //Do not pass error object. Make sure error is logged.
    [self clearLogs];
    result = [mInstanceDiscovery extractBase:nil error:nil];
    XCTAssertNil(result);
    ADAssertLogsContain(TEST_LOG_MESSAGE, "Error");
    ADAssertLogsContain(TEST_LOG_INFO, "authority");
    error = nil;
    
    //White space string:
    result = [mInstanceDiscovery extractBase:@"   " error:&error];
    XCTAssertNil(result);
    [self validateForInvalidArgument:@"authority" error:error];
    error = nil;
    
    //Invalid URL:
    result = [mInstanceDiscovery extractBase:@"a sdfasdfasas;djfasd jfaosjd fasj;" error:&error];
    XCTAssertNil(result);
    [self validateForInvalidArgument:@"authority" error:error];
    error = nil;
    
    //Invalid URL scheme (not using SSL):
    result = [mInstanceDiscovery extractBase:@"http://login.windows.net" error:&error];
    XCTAssertNil(result);
    [self validateForInvalidArgument:@"authority" error:error];
    error = nil;
    
    //Path
    result = [mInstanceDiscovery extractBase:@"././login.windows.net" error:&error];
    XCTAssertNil(result);
    [self validateForInvalidArgument:@"authority" error:error];
    error = nil;
    
    //Relative URL
    result = [mInstanceDiscovery extractBase:@"login" error:&error];
    XCTAssertNil(result);
    [self validateForInvalidArgument:@"authority" error:error];
    error = nil;
}

-(void) testExtractBaseNormal
{
    ADAuthenticationError* error;
    NSString* authority = @"httpS://Login.Windows.Net/MSopentech.onmicrosoft.com/oauth2/authorize";
    NSString* result = [mInstanceDiscovery extractBase:authority error:&error];
    ADAssertNoError;
    ADAssertStringEquals(result, @"https://login.windows.net");
    error = nil;//Cleanup
    
    //End with "/"
    authority = @"httpS://Login.Windows.Net/MSopentech.onmicrosoft.com/oauth2/authorize/";
    result = [mInstanceDiscovery extractBase:authority error:&error];
    ADAssertNoError;
    ADAssertStringEquals(result, @"https://login.windows.net");
    error = nil;
    
    //End with "/" and base only:
    authority = @"httpS://Login.Windows.Net/";
    result = [mInstanceDiscovery extractBase:authority error:&error];
    ADAssertNoError;
    ADAssertStringEquals(result, @"https://login.windows.net");
    error = nil;
}

-(void) testIsAuthorityValidated
{
    XCTAssertThrows([mInstanceDiscovery isAuthorityValidated:nil]);
    XCTAssertThrows([mInstanceDiscovery isAuthorityValidated:@"  "]);
    NSString* anotherHost = @"https://somedomain.com";
    XCTAssertFalse([mInstanceDiscovery isAuthorityValidated:anotherHost]);
    XCTAssertTrue([mInstanceDiscovery isAuthorityValidated:sAlwaysTrusted]);
    [mValidatedAuthorities addObject:anotherHost];
    XCTAssertTrue([mInstanceDiscovery isAuthorityValidated:anotherHost]);
}

-(void) testSetAuthorityValidation
{
    XCTAssertThrows([mInstanceDiscovery setAuthorityValidation:nil]);
    XCTAssertThrows([mInstanceDiscovery setAuthorityValidation:@"  "]);
    //Test that re-adding is ok. This can happen in multi-threaded scenarios:
    [mInstanceDiscovery setAuthorityValidation:sAlwaysTrusted];
    
    NSString* anotherHost = @"https://another.host.com";
    [mInstanceDiscovery setAuthorityValidation:anotherHost];
    XCTAssertTrue([mValidatedAuthorities containsObject:anotherHost]);
}

-(void) threadProc
{
    @autoreleasepool
    {
        const int maxAuthorities = 100;
        NSMutableArray* array = [[NSMutableArray alloc] initWithCapacity:maxAuthorities];
        for (int i = 0; i < maxAuthorities; ++i)
        {
            [array addObject:[NSString stringWithFormat:@"%d", i]];
        }
        NSDate* end = [NSDate dateWithTimeIntervalSinceNow:sThreadsRunDuration];
        NSDate* now;
        do
        {
            @autoreleasepool//The cycle will create constantly objects, so it needs its own autorelease pool
            {
                @synchronized(mInstanceDiscovery)//Use the same lock, as internal implementation
                {
                    [mValidatedAuthorities removeAllObjects];
                }
                
                for(int i = 0; i < maxAuthorities; ++i)
                {
                    //Just add a check objects. Note that the result is not guaranteed due to multiple
                    //threads:
                    [mInstanceDiscovery setAuthorityValidation:[array objectAtIndex:i]];
                    [mInstanceDiscovery isAuthorityValidated:[array objectAtIndex:i]];
                }
                
                now = [NSDate dateWithTimeIntervalSinceNow:0];
            }
        } while ([end compare:now] == NSOrderedDescending);
        if (OSAtomicIncrement32(&sNumThreadsDone) == sMaxTestThreads)
        {
            dispatch_semaphore_signal(sThreadsCompletedSemaphore);
        }
    }
}

-(void) testMultipleThreads
{
    sThreadsCompletedSemaphore = dispatch_semaphore_create(0);
    XCTAssertTrue(sThreadsCompletedSemaphore, "Cannot create semaphore");

    sNumThreadsDone = 0;
    [ADLogger setLevel:ADAL_LOG_LEVEL_NO_LOG];//Disable to stress better the cache.
    for (int i = 0; i < sMaxTestThreads; ++i)
    {
        [self performSelectorInBackground:@selector(threadProc) withObject:self];
    }
    if (dispatch_semaphore_wait(sThreadsCompletedSemaphore, dispatch_time(DISPATCH_TIME_NOW, (sThreadsRunDuration + 5)*NSEC_PER_SEC)))
    {
        XCTFail("Timed out. The threads did not complete smoothly. If the applicaiton has not crashed, this is an indication of a deadlock.");
    }
}

//Calls the asynchronous "validateAuthority" method and waits for completion.
//Sets the iVars of the test class according to the response
-(void) validateAuthority: (NSString*) authority
                     line: (int) line
{
    __block dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block volatile int executed = 0;
    mError = nil;//Reset
    [mInstanceDiscovery validateAuthority:authority completionBlock:^(BOOL validated, ADAuthenticationError *error)
    {
        if (OSAtomicCompareAndSwapInt(0, 1, &executed))
        {
            //Executed once, all ok:
            mValidated = validated;
            mError = error;
            dispatch_semaphore_signal(completed);
        }
        else
        {
            //Intentionally crash the test execution. As this happens on another thread,
            //there is no reliable to ensure that a second call is not made, without just throwing.
            //Note that the test will succeed, but the test run will fail:
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Double calls of acquire token." userInfo:nil];
        }
    }];
    if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 1000*NSEC_PER_SEC)))
    {
        [self recordFailureWithDescription:@"Timeout while calling validateAuthority method." inFile:@"" __FILE__ atLine:line expected:NO];
        return;
    }
    if (mError)
    {
        XCTAssertFalse(mValidated);
    }
}

//Does not call the server, just passes invalid authority
-(void) testValidateAuthorityError
{
    [self validateAuthority:@"http://invalidscheme.com" line:__LINE__];
    XCTAssertNotNil(mError);
    
    [self validateAuthority:@"https://Invalid URL 2305 8 -0238460-820-386" line:__LINE__];
    XCTAssertNotNil(mError);
}

//Does not call the server, just leverages the cache:
-(void) testValidateAuthorityCache
{
    [self validateAuthority:sAlwaysTrusted line:__LINE__];
    XCTAssertTrue(mValidated);
    XCTAssertNil(mError);
}


@end
