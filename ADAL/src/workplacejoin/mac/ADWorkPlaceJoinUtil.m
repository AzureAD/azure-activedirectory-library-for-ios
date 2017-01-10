// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ADWorkPlaceJoinUtil.h"
#import "ADKeychainUtil.h"
#import "ADLogger+Internal.h"
#import "ADWorkPlaceJoinConstants.h"
#import "ADRegistrationInformation.h"

// Convenience macro for checking keychain status codes while looking up the WPJ information.
#define CHECK_KEYCHAIN_STATUS(_operation) \
{ \
  if (status != noErr) \
  { \
    ADAuthenticationError* adError = [ADAuthenticationError keychainErrorFromOperation:_operation status:status correlationId:correlationId];\
    if (error) { *error = adError; } \
    goto _error; \
  } \
}


@implementation ADWorkPlaceJoinUtil

+ (ADRegistrationInformation*) getRegistrationInformation:(NSUUID*)correlationId
                                                    error:(ADAuthenticationError * __autoreleasing *)error
{
    ADRegistrationInformation* info = nil;
    SecIdentityRef identity = nil;
    SecCertificateRef certificate = nil;
    SecKeyRef privateKey = nil;
    NSString *certificateSubject = nil;
    NSData *certificateData = nil;
    NSString *userPrincipalName = nil;
    NSString* certificateIssuer  = nil;
    ADAuthenticationError* adError = nil;
    
    if (error)
        *error = nil;
    
    AD_LOG_VERBOSE(@"Attempting to get WPJ registration information", correlationId, nil);
    
    [self copyCertificate:correlationId identity:&identity certificate:&certificate certificateIssuer:&certificateIssuer error:&adError];
    if (adError)
    {
        if (error)
            *error = adError;
        AD_LOG_ERROR_F(@"Failed to retrieve WPJ certificate and identify - ", adError.code, nil, @"%@ correlation id.", correlationId);
        goto _error;
    }
    
    // If there's no certificate in the keychain, return nil. adError won't be set if the
    // cert can't be found since this isn't considered an error condition.
    if (!certificate)
        return nil;
    
    certificateSubject = (__bridge_transfer NSString*)(SecCertificateCopySubjectSummary(certificate));
    certificateData = (__bridge_transfer NSData*)(SecCertificateCopyData(certificate));
    
    
    // Get the private key
    AD_LOG_VERBOSE(@"Retrieving WPJ private key reference", correlationId, nil);
    
    privateKey = [self copyPrivateKeyRefForIdentifier:privateKeyIdentifier correlationId:correlationId error:&adError];
    if (adError)
    {
        if (error)
            *error = adError;
        AD_LOG_ERROR_F(@"Failed to retrieve WPJ private key reference - ", adError.code, nil, @"%@ correlation id.", correlationId);
        goto _error;
    }
    
    
    // Get user principal name
    AD_LOG_VERBOSE(@"Retrieving WPJ user principal name", correlationId, nil);
    
    userPrincipalName = [self stringDataFromIdentifier:upnIdentifier correlationId:correlationId error:&adError];
    if (adError)
    {
        if (error)
            *error = adError;
        AD_LOG_ERROR_F(@"Failed to retrieve WPJ user principal name from the keychain - ", adError.code, nil, @"%@ correlation id.", correlationId);
        goto _error;
    }
    
    if (!identity || !userPrincipalName || !certificateIssuer || !certificateSubject || !certificateData || !privateKey)
    {
        // The code above will catch missing security items, but not missing item attributes. These are caught here.
        ADAuthenticationError* adError = [ADAuthenticationError unexpectedInternalError:@"Missing some piece of WPJ data" correlationId:correlationId];
        if (error)
            *error = adError;
        goto _error;
    }
    
    // We found all the required WPJ information.
    info = [[ADRegistrationInformation alloc] initWithSecurityIdentity:identity
                                                     userPrincipalName:userPrincipalName
                                                     certificateIssuer:certificateIssuer
                                                           certificate:certificate
                                                    certificateSubject:certificateSubject
                                                       certificateData:certificateData
                                                            privateKey:privateKey];
    SAFE_ARC_AUTORELEASE(info);
    
    // Fall through to clean up resources.
    
_error:
    
    SAFE_ARC_RELEASE(certificateSubject);
    SAFE_ARC_RELEASE(certificateData);
    
    if (identity)
        CFRelease(identity);
    if (certificate)
        CFRelease(certificate);
    if (privateKey)
        CFRelease(privateKey);
    
    return info;
}


+ (void) copyCertificate:(NSUUID*)correlationId
                identity:(SecIdentityRef __nullable * __nonnull)identity
             certificate:(SecCertificateRef __nullable * __nonnull)clientCertificate
       certificateIssuer:(NSString* __nullable * __nonnull)clientCertificateIssuer
                   error:(ADAuthenticationError * __nullable __autoreleasing * __nullable)error
{
    OSStatus status = noErr;
    ADAuthenticationError* adError = nil;
    NSData* issuer = nil;
    NSMutableDictionary *identityQuery = nil;
    CFDictionaryRef result = NULL;
    
    *identity = nil;
    *clientCertificate = nil;
    if (error)
        *error = nil;

    *clientCertificate = [self copyWPJCertificateRef:correlationId error:&adError];
    
    if (adError)
    {
        if (error)
            *error = adError;
        
        AD_LOG_ERROR_F(@"Failed to retrieve WPJ client certificate from keychain - ", adError.code, nil, @"%@ correlation id.", correlationId);
        goto _error;
    }
    
    // If there's no certificate in the keychain, adError won't be set since this isn't an error condition.
    if (!*clientCertificate)
        return;
    
    // In OS X the shared access group cannot be set, so the search needs to be more
    // specific. The code below searches the identity by passing the WPJ cert as reference.
    identityQuery = [[NSMutableDictionary alloc] init];
    SAFE_ARC_AUTORELEASE(identityQuery);
    
    [identityQuery setObject:(__bridge id)kSecClassIdentity forKey:(__bridge id)kSecClass];
    [identityQuery setObject:(__bridge id)kCFBooleanTrue forKey:(__bridge id<NSCopying>)(kSecReturnRef)];
    [identityQuery setObject:(__bridge id)kCFBooleanTrue forKey:(__bridge id<NSCopying>)(kSecReturnAttributes)];
    [identityQuery setObject:(__bridge id)kSecAttrKeyClassPrivate forKey:(__bridge id)kSecAttrKeyClass];
    [identityQuery setObject:(__bridge id)*clientCertificate forKey:(__bridge id)kSecValueRef];
    
    status = SecItemCopyMatching((__bridge CFDictionaryRef)identityQuery, (CFTypeRef*)&result);
    CHECK_KEYCHAIN_STATUS(@"Failed to retrieve WPJ identity from keychain.");
    
    issuer = [(__bridge NSDictionary*)result objectForKey:(__bridge id)kSecAttrIssuer];
    if (issuer)
    {
        *clientCertificateIssuer = [[NSString alloc] initWithData:issuer encoding:NSISOLatin1StringEncoding];
        SAFE_ARC_AUTORELEASE(*clientCertificateIssuer);
    }
    
    *identity = (__bridge SecIdentityRef)([(__bridge NSDictionary*)result objectForKey:(__bridge id)kSecValueRef]);
    if (*identity)
        CFRetain(*identity);
    
    CFRelease(result);
    
    return;
    
_error:
    
    if (*identity)
        CFRelease(*identity);
    *identity = nil;
    
    if (*clientCertificate)
        CFRelease(*clientCertificate);
    *clientCertificate = nil;
    
    *clientCertificateIssuer = nil;
}


+ (SecCertificateRef) copyWPJCertificateRef:(NSUUID*)correlationId
                                      error:(ADAuthenticationError * __nullable __autoreleasing * __nullable)error
{
    OSStatus status= noErr;
    SecCertificateRef certRef = NULL;
    NSData *issuerTag = [self wpjCertIssuerTag];
    
    NSMutableDictionary *queryCert = [[NSMutableDictionary alloc] init];
    SAFE_ARC_AUTORELEASE(queryCert);
    
    // Set the private key query dictionary.
    [queryCert setObject:(__bridge id)kSecClassCertificate forKey:(__bridge id)kSecClass];
    [queryCert setObject:issuerTag forKey:(__bridge id)kSecAttrLabel];
    
    // Get the certificate. If the certificate is not found, this is not considered an error.
    status = SecItemCopyMatching((__bridge CFDictionaryRef)queryCert, (CFTypeRef*)&certRef);
    if (status == errSecItemNotFound)
        return NULL;
    
    CHECK_KEYCHAIN_STATUS(@"Failed to read WPJ certificate.");
    
    return certRef;
    
_error:
    return NULL;
}

+ (NSData*) wpjCertIssuerTag
{
    return [NSData dataWithBytes:certificateIdentifier length:strlen((const char *)certificateIdentifier)];
}

+ (SecKeyRef) copyPrivateKeyRefForIdentifier:(NSString*)identifier
                               correlationId:(NSUUID*)correlationId
                                       error:(ADAuthenticationError* __nullable __autoreleasing * __nullable)error
{
    OSStatus status= noErr;
    SecKeyRef privateKeyReference = NULL;
    
    NSData* privateKeyTag = [NSData dataWithBytes:[identifier UTF8String] length:identifier.length];
    
    NSMutableDictionary* privateKeyQuery = [[NSMutableDictionary alloc] init];
    SAFE_ARC_AUTORELEASE(privateKeyQuery);
    
    // Set the private key query dictionary.
    [privateKeyQuery setObject:(__bridge id)kSecClassKey forKey:(__bridge id)kSecClass];
    [privateKeyQuery setObject:privateKeyTag forKey:(__bridge id)kSecAttrApplicationTag];
    [privateKeyQuery setObject:(__bridge id)kSecAttrKeyTypeRSA forKey:(__bridge id)kSecAttrKeyType];
    [privateKeyQuery setObject:[NSNumber numberWithBool:YES] forKey:(__bridge id)kSecReturnRef];
    
    // Get the key.
    status = SecItemCopyMatching((__bridge CFDictionaryRef)privateKeyQuery, (CFTypeRef*)&privateKeyReference);
    CHECK_KEYCHAIN_STATUS(@"Failed to read WPJ private key for identifier.");
    
    return privateKeyReference;
    
_error:
    return nil;
}

+ (nullable NSString*) stringDataFromIdentifier:(nonnull NSString*)identifier
                                  correlationId:(NSUUID*)correlationId
                                          error:(ADAuthenticationError* __nullable __autoreleasing * __nullable)error
{
    // Building dictionary to retrieve UPN from the keychain
    NSMutableDictionary *query = [[NSMutableDictionary alloc] init];
    SAFE_ARC_AUTORELEASE(query);
    [query setObject:(__bridge id)(kSecClassGenericPassword) forKey:(__bridge id<NSCopying>)(kSecClass)];
    [query setObject:identifier forKey:(__bridge id<NSCopying>)(kSecAttrAccount)];
    [query setObject:(id)kCFBooleanTrue forKey:(__bridge id<NSCopying>)(kSecReturnAttributes)];
    
    CFDictionaryRef result = nil;
    NSString *stringData = nil;
    NSDictionary* resultDict = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef*)&result);
    CHECK_KEYCHAIN_STATUS(@"String data not found for WPJ identifier");
    
    resultDict = (__bridge NSDictionary*)result;
    stringData = [[resultDict objectForKey:(__bridge id)(kSecAttrService)] copy];
    SAFE_ARC_AUTORELEASE(stringData);
    
    if (result)
        CFRelease(result);
    
    if (!stringData || [[stringData stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0)
    {
        if (error)
            *error = [ADAuthenticationError unexpectedInternalError:@"WPJ user principal name is empty" correlationId:correlationId];
        return nil;
    }
    
    return stringData;
    
_error:
    return nil;
}

@end

