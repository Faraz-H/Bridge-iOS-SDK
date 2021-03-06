//
//  SBBAuthManager.m
//  BridgeSDK
//
//	Copyright (c) 2014-2018, Sage Bionetworks
//	All rights reserved.
//
//	Redistribution and use in source and binary forms, with or without
//	modification, are permitted provided that the following conditions are met:
//	    * Redistributions of source code must retain the above copyright
//	      notice, this list of conditions and the following disclaimer.
//	    * Redistributions in binary form must reproduce the above copyright
//	      notice, this list of conditions and the following disclaimer in the
//	      documentation and/or other materials provided with the distribution.
//	    * Neither the name of Sage Bionetworks nor the names of BridgeSDk's
//		  contributors may be used to endorse or promote products derived from
//		  this software without specific prior written permission.
//
//	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//	ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//	WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//	DISCLAIMED. IN NO EVENT SHALL SAGE BIONETWORKS BE LIABLE FOR ANY
//	DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//	(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//	LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//	ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//	(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//	SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "SBBAuthManagerInternal.h"
#import "UICKeyChainStore.h"
#import "NSError+SBBAdditions.h"
#import "SBBComponentManager.h"
#import "BridgeSDK+Internal.h"
#import "SBBUserManagerInternal.h"
#import "SBBBridgeNetworkManager.h"
#import "SBBParticipantManagerInternal.h"
#import "ModelObjectInternal.h"
#import "SBBJSONValue.h"
#import <objc/runtime.h>

#define AUTH_API V3_API_PREFIX @"/auth"
#define V4_AUTH_API V4_API_PREFIX @"/auth"

NSString * const kSBBAuthSignUpAPI =       AUTH_API @"/signUp";
NSString * const kSBBAuthResendAPI =       AUTH_API @"/resendEmailVerification";
NSString * const kSBBAuthSignInAPI =       V4_AUTH_API @"/signIn";
NSString * const kSBBAuthReauthAPI =       AUTH_API @"/reauth";
NSString * const kSBBAuthEmailAPI =        AUTH_API @"/email";
NSString * const kSBBAuthEmailSignInAPI =  AUTH_API @"/email/signIn";
NSString * const kSBBAuthPhoneAPI =        AUTH_API @"/phone";
NSString * const kSBBAuthPhoneSignInAPI =  AUTH_API @"/phone/signIn";
NSString * const kSBBAuthSignOutAPI =      AUTH_API @"/signOut";
NSString * const kSBBAuthRequestResetAPI = AUTH_API @"/requestResetPassword";
NSString * const kSBBAuthResetAPI =        AUTH_API @"/resetPassword";

NSString *kBridgeKeychainService = @"SageBridge";
NSString *kBridgeAuthManagerFirstRunKey = @"SBBAuthManagerFirstRunCompleted";
NSString *kSignInType = @"SignIn";

NSString * const kSBBUserSessionUpdatedNotification = @"SBBUserSessionUpdatedNotification";
NSString * const kSBBUserSessionInfoKey = @"SBBUserSessionInfoKey";

static NSString *envReauthTokenKeyFormat[] = {
    @"SBBReauthToken-%@",
    @"SBBReauthTokenStaging-%@",
    @"SBBReauthTokenDev-%@",
    @"SBBReauthTokenCustom-%@"
};

static NSString *envSessionTokenKeyFormat[] = {
    @"SBBSessionToken-%@",
    @"SBBSessionTokenStaging-%@",
    @"SBBSessionTokenDev-%@",
    @"SBBSessionTokenCustom-%@"
};

static NSString *envPasswordKeyFormat[] = {
    @"SBBPassword-%@",
    @"SBBPasswordStaging-%@",
    @"SBBPasswordDev-%@",
    @"SBBPasswordCustom-%@"
};


dispatch_queue_t AuthQueue()
{
    static dispatch_queue_t q;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("org.sagebase.BridgeAuthQueue", DISPATCH_QUEUE_SERIAL);
    });
    
    return q;
}

// use with care--not protected. Used for serializing access to the auth manager's internal
// copy of the accountAccessToken.
void dispatchSyncToAuthQueue(dispatch_block_t dispatchBlock)
{
    dispatch_sync(AuthQueue(), dispatchBlock);
}

dispatch_queue_t KeychainQueue()
{
    static dispatch_queue_t q;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("org.sagebase.BridgeAuthKeychainQueue", DISPATCH_QUEUE_SERIAL);
    });
    
    return q;
}

// use with care--not protected. Used for serializing access to the auth credentials stored in the keychain.
// This method can be safely called from within the AuthQueue, but the provided dispatch block must
// never dispatch back to the AuthQueue either directly or indirectly, to prevent deadlocks.
void dispatchSyncToKeychainQueue(dispatch_block_t dispatchBlock)
{
    dispatch_sync(KeychainQueue(), dispatchBlock);
}

// standard auth keychain manager implementation -- only intended to be replaced for testing purposes
@interface _SBBAuthKeychainManager : NSObject <SBBAuthKeychainManagerProtocol>

@end

@implementation _SBBAuthKeychainManager

// Find the bundle seed ID of the app that's using our SDK.
// Adapted from this StackOverflow answer: http://stackoverflow.com/a/11841898/931658

+ (NSString *)bundleSeedID {
    static NSString *_bundleSeedID = nil;
    
    // This is always called in the non-concurrent keychain queue, so the dispatch_once
    // construct isn't necessary to ensure it doesn't happen in two threads simultaneously;
    // also apparently it can fail under rare circumstances (???), so we'll handle it this
    // way instead so the app can at least potentially recover the next time it tries.
    // Apps that use an auth delegate to get and store credentials (which currently is
    // all of them) should only call this on first run, once, and it really doesn't matter
    // if it fails because it won't be used.
    if (!_bundleSeedID) {
        NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                               (__bridge id)(kSecClassGenericPassword), kSecClass,
                               @"bundleSeedID", kSecAttrAccount,
                               @"", kSecAttrService,
                               (id)kCFBooleanTrue, kSecReturnAttributes,
                               nil];
        CFDictionaryRef result = nil;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecItemNotFound)
            status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecSuccess) {
            NSString *accessGroup = [(__bridge NSDictionary *)result objectForKey:(__bridge id)(kSecAttrAccessGroup)];
            NSArray *components = [accessGroup componentsSeparatedByString:@"."];
            _bundleSeedID = [[components objectEnumerator] nextObject];
        }
        if (result) {
            CFRelease(result);
        }
    }
    
    return _bundleSeedID;
}

+ (NSString *)sdkKeychainAccessGroup
{
    NSString *bundleSeedID = [self bundleSeedID];
    if (!bundleSeedID) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@.org.sagebase.Bridge", bundleSeedID];
}

+ (UICKeyChainStore *)sdkKeychainStore
{
    NSString *accessGroup = self.sdkKeychainAccessGroup;
    if (!accessGroup) {
        return nil;
    }
    return [UICKeyChainStore keyChainStoreWithService:kBridgeKeychainService accessGroup:accessGroup];
}

- (void)clearKeychainStore
{
    dispatchSyncToKeychainQueue(^{
        UICKeyChainStore *store = [self.class sdkKeychainStore];
        [store removeAllItems];
        [store synchronize];
    });
}

- (void)setKeysAndValues:(NSDictionary<NSString *,NSString *> *)keysAndValues
{
    dispatchSyncToKeychainQueue(^{
        UICKeyChainStore *store = [self.class sdkKeychainStore];
        NSArray *keys = keysAndValues.allKeys;
        for (NSString *key in keys) {
            NSString *value = keysAndValues[key];
            [store setString:value forKey:key];
        }
        [store synchronize];
    });
}

- (NSString *)valueForKey:(NSString *)key
{
    __block NSString *value;
    dispatchSyncToKeychainQueue(^{
        UICKeyChainStore *store = [self.class sdkKeychainStore];
        value = [store stringForKey:key];
    });
    return value;
}

- (void)removeValuesForKeys:(NSArray<NSString *> *)keys
{
    dispatchSyncToKeychainQueue(^{
        UICKeyChainStore *store = [self.class sdkKeychainStore];
        for (NSString *key in keys) {
            [store removeItemForKey:key];
        }
        [store synchronize];
    });
}

@end

@interface SBBAuthManager()

@end

@implementation SBBAuthManager
@synthesize authDelegate = _authDelegate;
@synthesize sessionToken = _sessionToken;

+ (instancetype)defaultComponent
{
    static SBBAuthManager *shared;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<SBBNetworkManagerProtocol> networkManager = SBBComponent(SBBNetworkManager);
        shared = [[self alloc] initWithNetworkManager:networkManager];
        [shared setupForEnvironment];
    });
    
    return shared;
}

+ (instancetype)authManagerForEnvironment:(SBBEnvironment)environment study:(NSString *)study baseURLPath:(NSString *)baseURLPath
{
    SBBNetworkManager *networkManager = [SBBNetworkManager networkManagerForEnvironment:environment study:study
                                                                            baseURLPath:baseURLPath];
    SBBAuthManager *authManager = [[self alloc] initWithNetworkManager:networkManager];
    [authManager setupForEnvironment];
    return authManager;
}

+ (instancetype)authManagerWithNetworkManager:(id<SBBNetworkManagerProtocol>)networkManager
{
    SBBAuthManager *authManager = [[self alloc] initWithNetworkManager:networkManager];
    [authManager setupForEnvironment];
    return authManager;
}

+ (instancetype)authManagerWithBaseURL:(NSString *)baseURL
{
    id<SBBNetworkManagerProtocol> networkManager = [[SBBNetworkManager alloc] initWithBaseURL:baseURL];
    SBBAuthManager *authManager = [[self alloc] initWithNetworkManager:networkManager];
    [authManager setupForEnvironment];
    return authManager;
}

- (void)setupForEnvironment
{
    dispatchSyncToAuthQueue(^{
        _sessionToken = self.savedSessionToken;
    });
}

- (instancetype)initWithNetworkManager:(SBBNetworkManager *)networkManager
{
    if (self = [super init]) {
        _networkManager = networkManager;
        _keychainManager = [_SBBAuthKeychainManager new];
        
        // Clear keychain on first run in case of reinstallation
        NSUserDefaults *defaults = [BridgeSDK sharedUserDefaults];
        BOOL firstRunDone = [defaults boolForKey:kBridgeAuthManagerFirstRunKey];
        if (!firstRunDone) {
            [self.keychainManager clearKeychainStore];
            [defaults setBool:YES forKey:kBridgeAuthManagerFirstRunKey];
            [defaults synchronize];
        }
    }
    
    return self;
}

- (instancetype)initWithBaseURL:(NSString *)baseURL
{
    SBBNetworkManager *networkManager = [[SBBNetworkManager alloc] initWithBaseURL:baseURL];
    if (self = [self initWithNetworkManager:networkManager]) {
        //
    }
    
    return self;
}

- (void)postNewSessionInfo:(id)info
{
    NSDictionary *userInfo = @{ kSBBUserSessionInfoKey : info };
    [[NSNotificationCenter defaultCenter] postNotificationName:kSBBUserSessionUpdatedNotification object:self userInfo:userInfo];
}

- (SBBUserSessionInfo *)cachedSessionInfo
{
    NSString *userSessionInfoType = SBBUserSessionInfo.entityName;
    return (SBBUserSessionInfo *)[self.cacheManager cachedSingletonObjectOfType:userSessionInfoType createIfMissing:NO];
}

- (void)postUserSessionUpdatedNotification
{
    SBBUserSessionInfo *info = self.cachedSessionInfo;
    if (info) {
        self.placeholderSessionInfo = nil;
    } else {
        info = self.placeholderSessionInfo;
    }
    [self postNewSessionInfo:info];
}

- (id<SBBCacheManagerProtocol>)cacheManager {
    if (!_cacheManager) {
        if ([self.objectManager conformsToProtocol:@protocol(SBBObjectManagerInternalProtocol)]) {
            _cacheManager = ((id<SBBObjectManagerInternalProtocol>)self.objectManager).cacheManager;
        } else {
            _cacheManager = SBBComponent(SBBCacheManager);
        }
    }
    
    return _cacheManager;
}

- (id<SBBObjectManagerProtocol>)objectManager {
    if (!_objectManager) {
        _objectManager = SBBComponent(SBBObjectManager);
    }
    
    return _objectManager;
}


- (SBBUserSessionInfo *)placeholderSessionInfo {
    // If we're using cache, and not authed yet, and we've set an auth delegate that expects to receive
    // UserSessionInfo updates, the app is in the onboarding phase and may find it useful to have a
    // StudyParticipant object to pre-populate before calling signUp. In that case, we create a blank placeholder
    // SBBUserSessionInfo with SBBStudyParticipant, and SBBStudyParticipantCustomAttributes (if any have been declared),
    // to give to the delegate. Otherwise, we just return whatever we have (presumably nil but we really don't care).
    if (!_placeholderSessionInfo) {
        SBBUserSessionInfo *info = [[SBBUserSessionInfo alloc] init];
        info.studyParticipant = [[SBBStudyParticipant alloc] init];
        
        // if the custom attributes object has any properties (they'd be defined in a category), include it as well
        unsigned int numProperties;
        objc_property_t *properties = class_copyPropertyList(SBBStudyParticipantCustomAttributes.class, &numProperties);
        free(properties);
        
        if (numProperties > 0) {
            info.studyParticipant.attributes = [[SBBStudyParticipantCustomAttributes alloc] init];
        }
        _placeholderSessionInfo = info;
    }

    return _placeholderSessionInfo;
}

- (NSString *)sessionToken
{
    return _sessionToken;
}

- (NSURLSessionTask *)signUpStudyParticipant:(SBBSignUp *)signUp completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to sign up study participant before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    // If there's a placeholder StudyParticipant object, it may be partially filled-in, so let's start with that
    SBBStudyParticipant *studyParticipant = self.placeholderSessionInfo.studyParticipant;
    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    NSMutableDictionary *attributesJson = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *dataGroups = [NSMutableSet set];
    NSString *attributesKey = NSStringFromSelector(@selector(attributes));
    NSString *dataGroupsKey = NSStringFromSelector(@selector(dataGroups));
    if (studyParticipant) {
        json = [[self.objectManager bridgeJSONFromObject:studyParticipant] mutableCopy];
        attributesJson = [[json valueForKey:attributesKey] mutableCopy];
        dataGroups = [studyParticipant.dataGroups mutableCopy];
    }
    
    // now overwrite with entries from signUp object
    NSDictionary *signUpJson = [signUp dictionaryRepresentation];
    NSDictionary *signUpAttributesJson = [signUpJson valueForKey:attributesKey];
    NSSet<NSString *> *signUpDataGroups = signUp.dataGroups;
    [json addEntriesFromDictionary:signUpJson];
    
    // also merge attributes and dataGroups by overwriting with entries from signUp
    [attributesJson addEntriesFromDictionary:signUpAttributesJson];
    [json setValue:attributesJson forKey:attributesKey];
    [dataGroups unionSet:signUpDataGroups];
    NSArray *dataGroupsArray = [dataGroups allObjects];
    [json setValue:dataGroupsArray forKey:dataGroupsKey];
    
    json[NSStringFromSelector(@selector(study))] = SBBBridgeInfo.shared.studyIdentifier;
    return [_networkManager post:kSBBAuthSignUpAPI headers:nil parameters:json completion:completion];
}

- (NSURLSessionTask *)signUpWithEmail:(NSString *)email username:(NSString *)username password:(NSString *)password dataGroups:(NSArray<NSString *> *)dataGroups completion:(SBBNetworkManagerCompletionBlock)completion
{
    SBBSignUp *signUp = [[SBBSignUp alloc] init];
    signUp.email = email;
    // username is long-since deprecated on Bridge server; ignore
    signUp.password = password;
    signUp.dataGroups = [NSSet setWithArray:dataGroups];
    return [self signUpStudyParticipant:signUp completion:completion];
}

- (NSURLSessionTask *)signUpWithEmail:(NSString *)email username:(NSString *)username password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self signUpWithEmail:email username:username password:password dataGroups:nil completion:completion];
#pragma clang diagnostic pop
}

- (NSURLSessionTask *)resendEmailVerification:(NSString *)email completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to request resending email verification before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    NSDictionary *params = @{ NSStringFromSelector(@selector(study)):SBBBridgeInfo.shared.studyIdentifier,
                              NSStringFromSelector(@selector(email)):email
                              };
    return [_networkManager post:kSBBAuthResendAPI headers:nil parameters:params completion:completion];
}

- (void)resetUserSessionInfo
{
    // clear the UserSessionInfo object (and the StudyParticipant, which hangs off it) from core data cache
    [self.cacheManager removeFromCacheObjectOfType:SBBUserSessionInfo.entityName withId:SBBUserSessionInfo.entityName];
    
    // clear the placeholder session info so it will be recreated fresh
    _placeholderSessionInfo = nil;
    
    // now, post the session info updated notification again so any subscribers will get a fresh set of placeholders.
    [self postUserSessionUpdatedNotification];
}

- (NSURLSessionTask *)signInWithUsername:(NSString *)username password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
    return [self signInWithEmail:username password:password completion:completion];
}

- (void)handleSignInWithCredential:(NSString *)credentialKey value:(id<SBBJSONValue>)credentialValue password:(NSString *)password task:(NSURLSessionTask *)task response:(id)responseObject error:(NSError *)error completion:(SBBNetworkManagerCompletionBlock)completion
{
    // check for and handle app version out of date error (n.b.: our networkManager instance is a vanilla one, and we need
    // a Bridge network manager for this)
    id<SBBBridgeNetworkManagerProtocol> bridgeNetworkManager = (id<SBBBridgeNetworkManagerProtocol>)SBBComponent(SBBBridgeNetworkManager);
    BOOL handledUnsupportedAppVersionError = [bridgeNetworkManager checkForAndHandleUnsupportedAppVersionHTTPError:error];
    if (handledUnsupportedAppVersionError) {
        // don't call the completion handler, just bail
        return;
    }
    
    // Save session token, reauth token, and password in the keychain
    // ??? Save credentials in the keychain?
    NSString *sessionToken = responseObject[NSStringFromSelector(@selector(sessionToken))];
    NSString *reauthToken = responseObject[NSStringFromSelector(@selector(reauthToken))];
    if (sessionToken.length) {
        // Sign-in was successful.
        dispatchSyncToAuthQueue(^{
            _sessionToken = sessionToken;
        });
        
        // UserSessionInfo will always include a sessionToken and a reauthToken.
        NSMutableDictionary *keysAndValues = [@{
                                                self.reauthTokenKey: reauthToken,
                                                self.sessionTokenKey: sessionToken
                                                } mutableCopy];
        if (password) {
            keysAndValues[self.passwordKey] = password;
        }
        
        [self.keychainManager setKeysAndValues:keysAndValues];
    
        // If a user's StudyParticipant object is edited in the researcher UI, the session will be invalidated.
        // Since client-writable objects are not updated from the server once first cached, we need to clear this
        // out of our cache before reading the response object into the cache so we will get the server-side changes.
        // We wait until now to do it because until sign-in succeeds, to the best of our knowledge what's in
        // the cache is still valid; and if the user's email is retrievable (if auth delegate exists, it implements
        // emailForAuthManager:) then that is used in generating the persistent store path so we need to do this
        // here, were we know it will be available.
        
        [(id <SBBUserManagerInternalProtocol>)SBBComponent(SBBUserManager) clearUserInfoFromCache];
        [(id <SBBParticipantManagerInternalProtocol>)SBBComponent(SBBParticipantManager) clearUserInfoFromCache];
        
        // This method's signature was set in stone before UserSessionInfo existed, let alone StudyParticipant
        // (which UserSessionInfo now extends), so we can't return the values directly from here. But we do
        // want to update them in the cache, which calling objectFromBridgeJSON: will do.
        
        // Since the StudyParticipant is stored encrypted and uses the reauthToken as the encryption key,
        // we need to do this *after* storing the reauthToken to the keychain.
        id sessionInfo = [self.objectManager objectFromBridgeJSON:responseObject];
        [self postNewSessionInfo:sessionInfo];
    }
    
    if (completion) {
        completion(task, responseObject, error);
    }
}

- (NSURLSessionTask *)signInWithEmail:(NSString *)email password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
    return [self signInWithCredential:NSStringFromSelector(@selector(email)) value:email password:password completion:completion];
}

- (NSURLSessionTask *)signInWithPhoneNumber:(NSString *)phoneNumber regionCode:(NSString *)regionCode password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSDictionary *phone = @{ NSStringFromSelector(@selector(type)): SBBPhone.entityName,
                             NSStringFromSelector(@selector(number)): phoneNumber,
                             NSStringFromSelector(@selector(regionCode)): regionCode
                             };
    return [self signInWithCredential:NSStringFromSelector(@selector(phone)) value:phone password:password completion:completion];
}

- (NSURLSessionTask *)signInWithPhone:(SBBPhone *)phone password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
    id<SBBJSONValue> phoneJSON = [self.objectManager bridgeJSONFromObject:phone];
    return [self signInWithCredential:NSStringFromSelector(@selector(phone)) value:phoneJSON password:password completion:completion];
}

- (NSURLSessionTask *)signInWithExternalId:(NSString *)externalId password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
    return [self signInWithCredential:NSStringFromSelector(@selector(externalId)) value:externalId password:password completion:completion];
}

- (NSURLSessionTask *)signInWithCredential:(NSString *)credentialKey value:(id<SBBJSONValue>)credentialValue password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to sign in with %@/password before BridgeSDK has been set up!", credentialKey);
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    NSDictionary *params = @{ NSStringFromSelector(@selector(study)):SBBBridgeInfo.shared.studyIdentifier,
                              credentialKey:credentialValue,
                              NSStringFromSelector(@selector(password)):password,
                              NSStringFromSelector(@selector(type)):kSignInType};
    return [_networkManager post:kSBBAuthSignInAPI headers:nil parameters:params completion:^(NSURLSessionTask *task, id responseObject, NSError *error) {
        [self handleSignInWithCredential:credentialKey value:credentialValue password:password task:task response:responseObject error:error completion:completion];
    }];
}

- (BOOL)accountIdentifyingCredential:(NSString **)credentialKey value:(id<SBBJSONValue> *)credentialValue errorMessage:(NSString *)message earlyCompletion:(SBBNetworkManagerCompletionBlock)completion
{
    SBBStudyParticipant *participant = (SBBStudyParticipant *)[self.cacheManager cachedSingletonObjectOfType:SBBStudyParticipant.entityName createIfMissing:NO];
    if (!participant) {
        participant = _placeholderSessionInfo.studyParticipant;
    }
    
    NSString *email = participant.email;
    BOOL emailVerified = participant.emailVerifiedValue;
    SBBPhone *phone = participant.phone;
    BOOL phoneVerified = participant.phoneVerifiedValue;
    NSString *externalId = participant.externalId;
    
    // early exit if no account-identifying credential is available
    if (!(email.length && emailVerified) && !(phone.number.length && phone.regionCode.length && phoneVerified) && !externalId.length) {
        NSAssert(false, @"%@", message);
        if (completion) {
            completion(nil, nil, [NSError SBBNoCredentialsError]);
        }
        return NO;
    }
    
    // try email first, then phone, then externalId
    *credentialKey = NSStringFromSelector(@selector(email));
    *credentialValue = email;
    if (!(email.length && emailVerified)) {
        if (phone.number.length && phone.regionCode.length && phoneVerified) {
            *credentialKey = NSStringFromSelector(@selector(phone));
            *credentialValue = [self.objectManager bridgeJSONFromObject:phone];
        } else {
            *credentialKey = NSStringFromSelector(@selector(externalId));
            *credentialValue = externalId;
        }
    }
    return YES;
}

- (NSURLSessionTask *)reauthWithCompletion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet
        NSAssert(false, @"Coding error: Attempting to reauth before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    NSString *reauthToken = self.reauthTokenFromKeychain;
    if (!reauthToken.length) {
        // we don't have a reauth token, so do nothing
        if (completion) {
            completion(nil, nil, NSError.SBBNoCredentialsError);
        }
        return nil;
    }
    NSMutableDictionary *params = [@{ NSStringFromSelector(@selector(study)): study,
                                      NSStringFromSelector(@selector(reauthToken)): reauthToken
                                      } mutableCopy];
    
    // get a suitable account-identifying credential key/value pair, again exiting early if none found
    NSString *credentialKey;
    id<SBBJSONValue> credentialValue;
    if (![self accountIdentifyingCredential:&credentialKey value:&credentialValue errorMessage:@"Attempting to reauth an account with a reauth token but with no email, phone, or externalId--something is seriously wrong here" earlyCompletion:completion]) {
        return nil;
    }

    params[credentialKey] = credentialValue;

    return [_networkManager post:kSBBAuthReauthAPI headers:nil parameters:params completion:^(NSURLSessionTask *task, id responseObject, NSError *error) {
        [self handleSignInWithCredential:credentialKey value:credentialValue password:nil task:task response:responseObject error:error completion:completion];
    }];
}

- (NSURLSessionTask *)emailSignInLinkTo:(NSString *)email completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to request sign in link before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    if (!email.length) {
        // no email address given, so do nothing
        if (completion) {
            completion(nil, nil, NSError.SBBNoCredentialsError);
        }
        return nil;
    }
    NSDictionary *params = @{ NSStringFromSelector(@selector(study)): study,
                              NSStringFromSelector(@selector(email)): email };
    return [_networkManager post:kSBBAuthEmailAPI headers:nil parameters:params completion:completion];
}

- (NSURLSessionTask *)signInWithEmail:(NSString *)email token:(NSString *)token completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet
        NSAssert(false, @"Coding error: Attempting to sign in with email and token before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    if (!email.length || !token.length) {
        // no email address and/or no token given, so do nothing
        if (completion) {
            completion(nil, nil, NSError.SBBNoCredentialsError);
        }
        return nil;
    }
    
    NSDictionary *params = @{ NSStringFromSelector(@selector(study)): study,
                              NSStringFromSelector(@selector(email)): email,
                              NSStringFromSelector(@selector(token)): token
                              };
    return [_networkManager post:kSBBAuthEmailSignInAPI headers:nil parameters:params completion:^(NSURLSessionTask *task, id responseObject, NSError *error) {
        [self handleSignInWithCredential:NSStringFromSelector(@selector(email)) value:email password:nil task:task response:responseObject error:error completion:completion];
    }];
}

- (NSURLSessionTask *)textSignInTokenTo:(NSString *)phoneNumber regionCode:(NSString *)regionCode completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet
        NSAssert(false, @"Coding error: Attempting to request sign in token via SMS before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    if (!phoneNumber.length || !regionCode.length) {
        // no phone and/or no region given, so do nothing
        if (completion) {
            completion(nil, nil, NSError.SBBNoCredentialsError);
        }
        return nil;
    }
    
    NSDictionary *phone = @{ NSStringFromSelector(@selector(type)): SBBPhone.entityName,
                             NSStringFromSelector(@selector(number)): phoneNumber,
                             NSStringFromSelector(@selector(regionCode)): regionCode
                             };
    NSDictionary *params = @{ NSStringFromSelector(@selector(study)): study,
                              NSStringFromSelector(@selector(phone)): phone
                              };
    return [_networkManager post:kSBBAuthPhoneAPI headers:nil parameters:params completion:completion];
}

- (NSURLSessionTask *)signInWithPhoneNumber:(NSString *)phoneNumber regionCode:(NSString *)regionCode token:(NSString *)token completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet
        NSAssert(false, @"Coding error: Attempting to sign in with phone and token before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    if (!phoneNumber.length || !regionCode.length || !token.length) {
        // no phone number and/or no regionCode and/or no token given, so do nothing
        if (completion) {
            completion(nil, nil, NSError.SBBNoCredentialsError);
        }
        return nil;
    }
    
    NSDictionary *phone = @{ NSStringFromSelector(@selector(type)): SBBPhone.entityName,
                             NSStringFromSelector(@selector(number)): phoneNumber,
                             NSStringFromSelector(@selector(regionCode)): regionCode
                             };
    NSDictionary *params = @{ NSStringFromSelector(@selector(study)): study,
                              NSStringFromSelector(@selector(phone)): phone,
                              NSStringFromSelector(@selector(token)): token
                              };
    return [_networkManager post:kSBBAuthPhoneSignInAPI headers:nil parameters:params completion:^(NSURLSessionTask *task, id responseObject, NSError *error) {
        [self handleSignInWithCredential:NSStringFromSelector(@selector(phone)) value:phone password:nil task:task response:responseObject error:error completion:completion];
    }];
}

- (NSURLSessionTask *)signOutWithCompletion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to sign out before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    [self addAuthHeaderToHeaders:headers];
    return [_networkManager post:kSBBAuthSignOutAPI headers:headers parameters:nil completion:^(NSURLSessionTask *task, id responseObject, NSError *error) {
        // Remove the session tokens and credentials from the keychain
        // ??? Do we want to not do this in case of error?
        [self.keychainManager removeValuesForKeys:@[ self.reauthTokenKey, self.sessionTokenKey, self.passwordKey ]];

        // clear the in-memory copy of the session token, too
        dispatchSyncToAuthQueue(^{
            _sessionToken = nil;
        });
    
        [self.cacheManager resetCache];

        [self resetUserSessionInfo];

        if (completion) {
            completion(task, responseObject, error);
        }
    }];
}

- (NSString *)savedEmail
{
    return self.cachedSessionInfo.studyParticipant.email;
}

- (NSString *)savedPassword
{
    return self.passwordFromKeychain;
}

- (NSString *)savedReauthToken
{
    return self.reauthTokenFromKeychain;
}

- (NSString *)savedSessionToken
{
    return self.sessionTokenFromKeychain;
}

- (NSURLSessionTask *)attemptSignInWithStoredCredentialsWithCompletion:(SBBNetworkManagerCompletionBlock)completion
{
    // sign (back) in with stored account identifying credential + password
    NSString *password = [self passwordFromKeychain];
    
    // early exit if no stored password is available
    if (!password.length) {
        if (completion) {
            completion(nil, nil, [NSError SBBNoCredentialsError]);
        }
        return nil;
    }
    
    // get a suitable account-identifying credential key/value pair, again exiting early if none found
    NSString *credentialKey;
    id<SBBJSONValue> credentialValue;
    if (![self accountIdentifyingCredential:&credentialKey value:&credentialValue errorMessage:@"Attempting to reauth an account with a password but with no email, phone, or externalId--something is seriously wrong here" earlyCompletion:completion]) {
        return nil;
    }

    return [self signInWithCredential:credentialKey value:credentialValue password:password completion:completion];
}

- (void)ensureSignedInWithCompletion:(SBBNetworkManagerCompletionBlock)completion
{
    if ([self isAuthenticated]) {
        if (completion) {
            completion(nil, nil, nil);
        }
    } else {
        if (self.reauthTokenFromKeychain.length) {
            [self reauthWithCompletion:^(NSURLSessionTask *task, id responseObject, NSError *error) {
                // if the response was a 401, try again the other way
                if (error.code == SBBErrorCodeServerNotAuthenticated) {
                    [self attemptSignInWithStoredCredentialsWithCompletion:completion];
                    return;
                }
                
                if (completion) {
                    completion(task, responseObject, error);
                }
            }];
        } else {
            [self attemptSignInWithStoredCredentialsWithCompletion:completion];
        }
    }
}

- (NSURLSessionTask *)requestPasswordResetForEmail:(NSString *)email completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to request password reset before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
    return [_networkManager post:kSBBAuthRequestResetAPI headers:nil parameters:@{@"study":SBBBridgeInfo.shared.studyIdentifier, @"email":email} completion:completion];
}

- (NSURLSessionTask *)resetPasswordToNewPassword:(NSString *)password resetToken:(NSString *)token completion:(SBBNetworkManagerCompletionBlock)completion
{
    NSString *study = SBBBridgeInfo.shared.studyIdentifier;
    if (!study.length) {
        // BridgeSDK hasn't been set up yet, so do nothing
        NSAssert(false, @"Coding error: Attempting to reset password before BridgeSDK has been set up!");
        if (completion) {
            completion(nil, nil, NSError.SBBNotSetUpError);
        }
        return nil;
    }
    
   return [_networkManager post:kSBBAuthResetAPI headers:nil parameters:@{@"password":password, @"sptoken":token, @"type":@"PasswordReset"} completion:completion];
}

#pragma mark Internal helper methods

- (BOOL)isAuthenticated
{
    return (self.sessionToken.length > 0);
}

- (void)addAuthHeaderToHeaders:(NSMutableDictionary *)headers
{
    if (self.isAuthenticated) {
        [headers setObject:self.sessionToken forKey:@"Bridge-Session"];
    }
}

#pragma mark Internal keychain-related methods

- (NSString *)reauthTokenKey
{
    return [NSString stringWithFormat:envReauthTokenKeyFormat[_networkManager.environment], [SBBBridgeInfo shared].studyIdentifier];
}

- (NSString *)reauthTokenFromKeychain
{
    if (![SBBBridgeInfo shared].studyIdentifier) {
        return nil;
    }
    
    return [self.keychainManager valueForKey:self.reauthTokenKey];
}

- (NSString *)sessionTokenKey
{
    return [NSString stringWithFormat:envSessionTokenKeyFormat[_networkManager.environment], [SBBBridgeInfo shared].studyIdentifier];
}

- (NSString *)sessionTokenFromKeychain
{
    if (![SBBBridgeInfo shared].studyIdentifier) {
        return nil;
    }
    
    return [self.keychainManager valueForKey:self.sessionTokenKey];
}

- (NSString *)passwordKey
{
    return [NSString stringWithFormat:envPasswordKeyFormat[_networkManager.environment], [SBBBridgeInfo shared].studyIdentifier];
}

- (NSString *)passwordFromKeychain
{
    if (![SBBBridgeInfo shared].studyIdentifier) {
        return nil;
    }
    
    return [self.keychainManager valueForKey:self.passwordKey];
}

#pragma mark SDK-private methods

// used internally for unit testing
- (void)setSessionToken:(NSString *)sessionToken
{
    dispatchSyncToAuthQueue(^{
        _sessionToken = sessionToken;
    });
    
    if (sessionToken) {
        [self.keychainManager setKeysAndValues:@{ self.sessionTokenKey: sessionToken }];
    } else {
        [self.keychainManager removeValuesForKeys:@[ self.sessionTokenKey ]];
    }
}

// used by SBBBridgeNetworkManager to auto-reauth when session tokens expire
- (void)clearSessionToken
{
    [self setSessionToken:nil];
}

@end

