/*
 *
 * Copyright 2014 Flavio Negrão Torres
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "CoreDataController.h"
#import "APIncrementalStore.h"
#import "NSLogEmoji.h"
#import "Common.h"

NSString* const CoreDataControllerNotificationDidSync = @"CoreDataControllerNotificationDidSync";
NSString* const CoreDataControllerNotificationDidResetTheCache = @"CoreDataControllerNotificationDidResetTheCache";

static NSString* const APLocalCacheFileName = @"APCacheStore.sqlite";

@interface CoreDataController ()

@property (nonatomic, strong) NSPersistentStoreCoordinator *psc;
@property (nonatomic, strong) NSManagedObjectContext *mainContext;
@property (atomic, assign) BOOL isSyncingTheCache;
@property (atomic, assign) BOOL isResetingTheCache;

@end


@implementation CoreDataController

+ (instancetype)sharedInstance {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc]init];
    });
    return sharedInstance;
}

- (instancetype)init {
    
   if (AP_DEBUG_METHODS) {MLog(@"Self:%@",self)}
    
    self = [super init];
    
    if (self) {
        self.isSyncingTheCache = NO;
        self.isResetingTheCache = NO;
        [self registreForNotifications];
    }
    return self;
}


- (void) registreForNotifications {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidStartSync:) name:APNotificationCacheDidStartSync object:nil];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidFinishSync:) name:APNotificationCacheDidFinishSync object:nil];
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(didReceiveNotificationCacheDidReset:) name:APNotificationCacheDidFinishReset object:nil];
}

- (void) dealloc {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheDidFinishReset object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheDidFinishSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationCacheDidStartSync object:nil];
}


#pragma mark - Gettters and Setters

- (void) setRemoteDBAuthenticatedUser:(id)remoteDBAuthenticatedUser {
    
    _remoteDBAuthenticatedUser = remoteDBAuthenticatedUser;
    [self configPersistantStoreCoordinator];
}

- (NSManagedObjectContext*) mainContext {
    
    if (!_mainContext) {
        
        if (!self.remoteDBAuthenticatedUser) {
            ELog(@"Please set remoteDBAuthenticatedUser before starting using the managedContext");
            
        } else {
            _mainContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
            _mainContext.persistentStoreCoordinator = self.psc;
        }
    }
    return _mainContext;
}


- (void) configPersistantStoreCoordinator {
    
    /* Turn on/off to enable different levels of debuging */
    AP_DEBUG_METHODS = YES;
    AP_DEBUG_ERRORS = YES;
    AP_DEBUG_INFO = YES;
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    [NSPersistentStoreCoordinator registerStoreClass:[APIncrementalStore class] forStoreType:[APIncrementalStore type]];
    
    NSManagedObjectModel* model = [NSManagedObjectModel mergedModelFromBundles:nil];
    self.psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    
    [self.psc addPersistentStoreWithType:[APIncrementalStore type]
                           configuration:nil
                                     URL:nil
                                 options:@{APOptionAuthenticatedUserObjectKey:self.remoteDBAuthenticatedUser,
                                           APOptionCacheFileNameKey:APLocalCacheFileName,
                                          // APIncrementalStoreOptionCacheFileReset:@NO,
                                           APOptionMergePolicyKey:APOptionMergePolicyServerWins}
                                   error:nil];
}


#pragma mark - Cache Reset

- (void) requestResetCache {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    self.isResetingTheCache = YES;
    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationCacheRequestReset object:self];
    }];
}


- (void) didReceiveNotificationCacheDidReset:(NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    self.isResetingTheCache = NO;
    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter]postNotificationName:CoreDataControllerNotificationDidResetTheCache object:self];
    }];
}


#pragma mark - Sync

- (void) requestSyncCache {
    
    if (AP_DEBUG_METHODS) {MLog()}
    self.isSyncingTheCache = YES;
    [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationRequestCacheSync object:self];
}


- (void) didReceiveNotificationCacheDidStartSync: (NSNotification*) note {
    
    self.isSyncingTheCache = YES;
}


- (void) didReceiveNotificationCacheDidFinishSync:(NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    self.isSyncingTheCache = NO;
    [[NSOperationQueue mainQueue]addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter]postNotificationName:CoreDataControllerNotificationDidSync object:self];
    }];
}


#pragma mark - Main Context Operations

- (BOOL) saveMainContextAndRequestCacheSync:(NSError* __autoreleasing*) error {
    
    __block BOOL success = YES;
    
    [self.mainContext performBlockAndWait:^{
        NSError* localError;
        if (![self.mainContext save:&localError]) {
            if (AP_DEBUG_ERRORS) ELog(@"Error saving main context: %@",localError);
            success = NO;
            *error = localError;
        } else {
            [self requestSyncCache];
        }
    }];
    
    return success;
}

@end
