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

#import "ADWorkplaceJoined.h"
#import "ADAuthenticationSettings.h"
#import "NSString+ADHelperMethods.h"
#import "ADErrorCodes.h"
#import "ADKeyChainHelper.h"
#import "ADALiOS.h"
#import "HTTPProtocol.h"

@implementation ADWorkplaceJoined

/* Extracts the certificate, verifying that the authority, which requested it is correct. */
+(SecIdentityRef) getCertificateWithError: (ADAuthenticationError* __autoreleasing*) error
                                    group: (NSString*) keychainGroup
{
    SecIdentityRef result = NULL;
 //   NSString* keychainGroup = [ADAuthenticationSettings sharedInstance].clientTLSKeychainGroup;
    ADKeyChainHelper* helper = [[ADKeyChainHelper alloc] initWithClass:(__bridge id)kSecClassCertificate
                                                               generic:nil
                                                           sharedGroup:keychainGroup];
    AD_LOG_VERBOSE_F(@"Workkplace join", @"Attempting to extract the client authentication TLS certificate from the keychain group: %@", keychainGroup);
    NSArray* allCerts = [helper getItemsAttributes:nil error:error];
    if (!allCerts.count)
    {
        return NULL;
    }
    if (allCerts.count > 1)
    {
        //Multiple device join certificates found.
        ADAuthenticationError* adError = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_MULTIPLE_TLS_CERTIFICATES protocolCode:0 errorDetails:@"Cannot extract a client authentication certificate: more than one certificate exists in the keychain."];
        if (error)
        {
            *error = adError;
        }
        return NULL;
    }
    NSDictionary* attributes = [allCerts firstObject];
    NSData* data = [helper getItemDataWithAttributes:attributes error:error];
    SecIdentityRef foo;
 //   OSStatus err1 = [self extractIdentity:&foo fromPKCS12Data:data];
    
    return foo;
}

+(BOOL) startTLSSessionWithError: (ADAuthenticationError *__autoreleasing *) error
{
#error implement me.
    RETURN_ON_INVALID_ARGUMENT(NIL_CONDITION(cert), @"cert", NO);
    RETURN_NO_ON_NIL_ARGUMENT(url);
    [HTTPProtocol setCertificate:cert];
    if (![NSURLProtocol registerClass:[HTTPProtocol class]])
    {
        ADAuthenticationError* adError = [ADAuthenticationError unexpectedInternalError:@"Failed to register NSURLProtocol."];
        if (error)
        {
            *error = adError;
        }
        return NO;
    }
    
    return YES;
}

/* Stops the HTTPS interception. */
+(void) endTLSSession
{
    [NSURLProtocol unregisterClass:[HTTPProtocol class]];
}

//+ (OSStatus)extractIdentity:(SecIdentityRef *)outIdentity fromPKCS12Data:(NSData *) data
//{
//    OSStatus      error   = errSecSuccess;
//    NSDictionary *options = [NSDictionary new];
//    CFArrayRef    items   = CFArrayCreate( NULL, 0, 0, NULL );
//    
//    // Import the PFX/P12 using the options; the items array is the set of identities and certificates in the PFX/P12
//    error = SecPKCS12Import( (__bridge CFDataRef)data, (__bridge CFDictionaryRef)options, &items );
//    
//    if ( error == 0 )
//    {
//        // The client certificate is assumed to be the first one in the set
//        CFDictionaryRef clientIdentity = CFArrayGetValueAtIndex( items, 0);
//        const void     *tempIdentity   = CFDictionaryGetValue( clientIdentity, kSecImportItemIdentity );
//        
//        CFRetain( tempIdentity );
//        *outIdentity = (SecIdentityRef)tempIdentity;
//    }
//    else
//    {
//        DebugLog( @"Failed with error %d", (int)error );
//    }
//    
//    CFRelease( items );
//    
//    return error;
//}


@end
