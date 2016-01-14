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

#import "ADAuthenticationContext+Internal.h"
#import "ADAuthenticationSettings.h"
#import "ADBrokerKeyHelper.h"
#import "ADBrokerNotificationManager.h"
#import "NSDictionary+ADExtensions.h"
#import "NSString+ADHelperMethods.h"
#import "ADPkeyAuthHelper.h"
#import "ADHelpers.h"
#import "ADUserIdentifier.h"
#import "ADAuthenticationRequest.h"

@implementation ADAuthenticationRequest (Broker)

+ (BOOL)respondsToUrl:(NSString*)url
{
    NSArray* urlTypes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleURLTypes"];
    
    NSString* scheme = [[NSURL URLWithString:url] scheme];
    if (!scheme)
    {
        return NO;
    }
    
    for (NSDictionary* urlRole in urlTypes)
    {
        NSArray* urlSchemes = [urlRole objectForKey:@"CFBundleURLSchemes"];
        if ([urlSchemes containsObject:scheme])
        {
            return YES;
        }
    }
    
    return NO;
}

+ (void)internalHandleBrokerResponse:(NSURL *)response
{
    ADAuthenticationCallback completionBlock = [ADBrokerNotificationManager sharedInstance].copyAndClearCallback;
    if (!completionBlock)
    {
        AD_LOG_ERROR(@"Received broker response without a completionBlock.", AD_FAILED, nil, nil);
        return;
    }
    
    HANDLE_ARGUMENT(response);
    
    NSString *qp = [response query];
    //expect to either response or error and description, AND correlation_id AND hash.
    NSDictionary* queryParamsMap = [NSDictionary adURLFormDecode:qp];
    ADAuthenticationResult* result;
    
    NSUUID* correlationId = [queryParamsMap valueForKey:OAUTH2_CORRELATION_ID_RESPONSE] ?
    [[NSUUID alloc] initWithUUIDString:[queryParamsMap valueForKey:OAUTH2_CORRELATION_ID_RESPONSE]]
    : nil;
    
    if([queryParamsMap valueForKey:OAUTH2_ERROR_DESCRIPTION]){
        result = [ADAuthenticationResult resultFromBrokerResponse:queryParamsMap];
    }
    else
    {
        HANDLE_ARGUMENT([queryParamsMap valueForKey:BROKER_HASH_KEY]);
        
        NSString* hash = [queryParamsMap valueForKey:BROKER_HASH_KEY];
        NSString* encryptedBase64Response = [queryParamsMap valueForKey:BROKER_RESPONSE_KEY];
        NSString* msgVer = [queryParamsMap valueForKey:BROKER_MESSAGE_VERSION];
        NSInteger protocolVersion = 1;
        
        if (msgVer)
        {
            protocolVersion = [msgVer integerValue];
        }
        
        //decrypt response first
        ADBrokerKeyHelper* brokerHelper = [[ADBrokerKeyHelper alloc] init];
        ADAuthenticationError* error;
        NSData *encryptedResponse = [NSString Base64DecodeData:encryptedBase64Response ];
        NSData* decrypted = [brokerHelper decryptBrokerResponse:encryptedResponse
                                                        version:protocolVersion
                                                          error:&error];
        NSString* decryptedString = nil;
        
        if(!error)
        {
            decryptedString = [[NSString alloc] initWithData:decrypted encoding:NSUTF8StringEncoding];
            //now compute the hash on the unencrypted data
            if([NSString adSame:hash toString:[ADPkeyAuthHelper computeThumbprint:decrypted isSha2:YES]]){
                //create response from the decrypted payload
                queryParamsMap = [NSDictionary adURLFormDecode:decryptedString];
                [ADHelpers removeNullStringFrom:queryParamsMap];
                result = [ADAuthenticationResult resultFromBrokerResponse:queryParamsMap];
                
            }
            else
            {
                result = [ADAuthenticationResult resultFromError:[ADAuthenticationError errorFromNSError:[NSError errorWithDomain:ADAuthenticationErrorDomain
                                                                                                                             code:AD_ERROR_BROKER_RESPONSE_HASH_MISMATCH
                                                                                                                         userInfo:nil]
                                                                                            errorDetails:@"Decrypted response does not match the hash"]
                                                    correlationId:correlationId];
            }
        }
        else
        {
            result = [ADAuthenticationResult resultFromError:error correlationId:correlationId];
        }
    }
    
    if (AD_SUCCEEDED == result.status)
    {
        ADAuthenticationContext* ctx = [ADAuthenticationContext
                                        authenticationContextWithAuthority:result.tokenCacheStoreItem.authority
                                        error:nil];
        
        [ctx updateCacheToResult:result
                       cacheItem:nil
                withRefreshToken:nil
         requestCorrelationId:[correlationId UUIDString]];
        
        NSString* userId = [[[result tokenCacheStoreItem] userInformation] userId];
        [ADAuthenticationContext updateResult:result
                   toUser:[ADUserIdentifier identifierWithId:userId]];
    }
    
    completionBlock(result);
}

- (BOOL)canUseBroker
{
    return _context.credentialsType == AD_CREDENTIALS_AUTO &&
     _context.validateAuthority == YES &&
    [[UIApplication sharedApplication] canOpenURL:[[NSURL alloc] initWithString:[NSString stringWithFormat:@"%@://broker", brokerScheme]]];
}

- (void)callBroker:(ADAuthenticationCallback)completionBlock
{
    CHECK_FOR_NIL(_context.authority);
    CHECK_FOR_NIL(_resource);
    CHECK_FOR_NIL(_clientId);
    CHECK_FOR_NIL(_correlationId);
    
    ADAuthenticationError* error = nil;
    if(![ADAuthenticationRequest respondsToUrl:_redirectUri])
    {
        error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_INVALID_REDIRECT_URI
                                                       protocolCode:nil
                                                       errorDetails:ADRedirectUriInvalidError];
        completionBlock([ADAuthenticationResult resultFromError:error correlationId:_correlationId]);
        return;
    }
    
    AD_LOG_INFO(@"Invoking broker for authentication", _correlationId, nil);
    ADBrokerKeyHelper* brokerHelper = [[ADBrokerKeyHelper alloc] init];
    NSData* key = [brokerHelper getBrokerKey:&error];
    NSString* base64Key = [NSString Base64EncodeData:key];
    NSString* base64UrlKey = [base64Key adUrlFormEncode];
    NSString* adalVersion = [ADLogger getAdalVersion];
    
    CHECK_FOR_NIL(base64UrlKey);
    CHECK_FOR_NIL(adalVersion);
    
    NSDictionary* queryDictionary = @{
                                      @"authority": _context.authority,
                                      @"resource" : _resource,
                                      @"client_id": _clientId,
                                      @"redirect_uri": _redirectUri,
                                      @"username_type": _identifier ? [_identifier typeAsString] : @"",
                                      @"username": _identifier.userId ? _identifier.userId : @"",
                                      @"force" : _promptBehavior == AD_FORCE_PROMPT ? @"YES" : @"NO",
                                      @"correlation_id": _correlationId,
                                      @"broker_key": base64UrlKey,
                                      @"client_version": adalVersion,
									  BROKER_MAX_PROTOCOL_VERSION : @"2",
                                      @"extra_qp": _queryParams ? _queryParams : @"",
                                      };
    
    NSString* query = [queryDictionary adURLFormEncode];
    
    NSURL* appUrl = [[NSURL alloc] initWithString:[NSString stringWithFormat:@"%@://broker?%@", brokerScheme, query]];
    
    [[ADBrokerNotificationManager sharedInstance] enableNotifications:completionBlock];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:appUrl];
    });
}

- (void)saveToPasteBoard:(NSURL*) url
{
    UIPasteboard *appPasteBoard = [UIPasteboard pasteboardWithName:@"WPJ"
                                                            create:YES];
    appPasteBoard.persistent = YES;
    url = [NSURL URLWithString:[NSString stringWithFormat:@"%@&%@=%@", url.absoluteString, @"sourceApplication",[[NSBundle mainBundle] bundleIdentifier]]];
    [appPasteBoard setURL:url];
}

- (void)handleBrokerFromWebiewResponse:(NSString*)urlString
                       completionBlock:(ADAuthenticationCallback)completionBlock
{
    CHECK_FOR_NIL(_resource);
    
    ADAuthenticationError* error = nil;
    if(![ADAuthenticationRequest respondsToUrl:_redirectUri])
    {
        error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_INVALID_REDIRECT_URI
                                                       protocolCode:nil
                                                       errorDetails:ADRedirectUriInvalidError];
        completionBlock([ADAuthenticationResult resultFromError:error correlationId:_correlationId]);
        return;
    }
    
    ADBrokerKeyHelper* brokerHelper = [[ADBrokerKeyHelper alloc] init];
    NSData* key = [brokerHelper getBrokerKey:&error];
    NSString* base64Key = [NSString Base64EncodeData:key];
    NSString* base64UrlKey = [base64Key adUrlFormEncode];
    NSString* adalVersion = [ADLogger getAdalVersion];
    NSString* correlationIdStr = [_correlationId UUIDString];
    NSString* authority = _context.authority;
    
    CHECK_FOR_NIL(base64UrlKey);
    CHECK_FOR_NIL(adalVersion);
    CHECK_FOR_NIL(authority);
    
    NSDictionary* queryDictionary = @{
                                      @"authority": _context.authority,
                                      @"resource" : _resource,
                                      @"client_id": _clientId,
                                      @"redirect_uri": _redirectUri,
                                      @"username_type": _identifier ? [_identifier typeAsString] : @"",
                                      @"username": _identifier.userId ? _identifier.userId : @"",
                                      @"correlation_id": correlationIdStr,
                                      @"broker_key": base64UrlKey,
                                      @"client_version": adalVersion,
                                      @"extra_qp": _queryParams ? _queryParams : @"",
                                      };
    NSString* query = [queryDictionary adURLFormEncode];
    
    NSURL* appUrl = [[NSURL alloc] initWithString:[NSString stringWithFormat:@"%@&%@", urlString, query]];
    [[ADBrokerNotificationManager sharedInstance] enableNotifications:completionBlock];
    
    if([[UIApplication sharedApplication] canOpenURL:appUrl])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:appUrl];
        });
    }
    else
    {
        //no broker installed. go to app store
        NSString* qp = [appUrl query];
        NSDictionary* qpDict = [NSDictionary adURLFormDecode:qp];
        NSString* url = [qpDict valueForKey:@"app_link"];
        [self saveToPasteBoard:appUrl];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:[[NSURL alloc] initWithString:url]];
        });
    }
}

@end
