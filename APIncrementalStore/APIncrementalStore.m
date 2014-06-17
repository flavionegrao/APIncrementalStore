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


#import "APIncrementalStore.h"

#import "APDiskCache.h"
#import "APParseSyncOperation.h"

#import "NSArray+Enumerable.h"
#import "APCommon.h"
#import "APError.h"
#import "NSLogEmoji.h"


#pragma mark - Notifications

/********************
 / Sync Notifications
 ********************/

/****Deprecated************/
NSString* const APNotificationRequestCacheSync = @"com.apetis.apincrementalstore.diskcache.request.sync";
NSString* const APNotificationRequestCacheFullSync = @"com.apetis.apincrementalstore.diskcache.request.fullsync";
NSString* const APNotificationCacheWillStartSync = @"com.apetis.apincrementalstore.diskcache.willstartsync";
NSString* const APNotificationCacheDidSyncObject = @"com.apetis.apincrementalstore.diskcache.didSyncObject";
NSString* const APNotificationCacheDidFinishSync = @"com.apetis.apincrementalstore.diskcache.didfinishsinc";
/**************************/

NSString* const APNotificationRequestStoreSync = @"com.apetis.apincrementalstore.request.sync";
NSString* const APNotificationRequestStoreFullSync = @"com.apetis.apincrementalstore.request.fullsync";
NSString* const APNotificationStoreWillStartSync = @"com.apetis.apincrementalstore.willstartsync";
NSString* const APNotificationStoreDidSyncObject = @"com.apetis.apincrementalstore.didSyncObject";
NSString* const APNotificationStoreDidFinishSync = @"com.apetis.apincrementalstore.didfinishsinc";


NSString* const APNotificationNumberOfLocalObjectsSyncedKey = @"com.apetis.apincrementalstore.diskcache.numberoflocalobjectssynced.key";
NSString* const APNotificationNumberOfRemoteObjectsSyncedKey = @"com.apetis.apincrementalstore.diskcache.numberofremoteobjectssynced.key";


/****Deprecated************/
NSString* const APNotificationCacheNumberOfLocalObjectsKey = @"com.apetis.apincrementalstore.diskcache.numberoflocalobjects.key";
NSString* const APNotificationCacheNumberOfRemoteObjectsKey = @"com.apetis.apincrementalstore.diskcache.numberofremoteobjects.key";

NSString *const APNotificationSyncedObjectsKey = @"com.apetis.apincrementalstore.syncedobjects.key";
NSString *const APNotificationSyncErrorKey = @"com.apetis.apincrementalstore.error.key";
/**************************/


/**************************
 / Cache Reset Notifications
 ***************************/

/****Deprecated************/
NSString* const APNotificationCacheRequestReset = @"com.apetis.apincrementalstore.diskcache.request.reset";
NSString* const APNotificationCacheDidFinishReset = @"com.apetis.apincrementalstore.diskcache.didfinishreset";
/**************************/

NSString* const APNotificationStoreRequestCacheReset = @"com.apetis.apincrementalstore.request.cachereset";
NSString* const APNotificationStoreDidFinishCacheReset = @"com.apetis.apincrementalstore.didfinishcachereset";


#pragma mark - Incremental Store Options

NSString* const APOptionAuthenticatedUserObjectKey = @"com.apetis.apincrementalstore.option.authenticateduserobject.key";
NSString* const APOptionCacheFileNameKey = @"com.apetis.apincrementalstore.option.diskcachefilename.key";
NSString* const APOptionCacheFileResetKey = @"com.apetis.apincrementalstore.option.diskcachereset.key";

NSString* const APOptionMergePolicyKey = @"com.apetis.apincrementalstore.option.mergepolicy.key";
NSString* const APOptionMergePolicyServerWins = @"com.apetis.apincrementalstore.option.mergepolicy.serverwins";
NSString* const APOptionMergePolicyClientWins = @"com.apetis.apincrementalstore.option.mergepolicy.clientwins";


#pragma mark - Local Constants
static NSString* const APDefaultLocalCacheFileName = @"APIncrementalStoreDiskCache.sqlite";

// mapBetweenManagedObjectIDsAndObjectUIDByEntityName Keys
static NSString* const APManagedObjectIDKey = @"APManagedObjectIDKey";
static NSString* const APReferenceCountKey = @"APReferenceCountKey";



@interface APIncrementalStore ()

@property (nonatomic,strong) APDiskCache* diskCache;
@property (nonatomic,strong) NSString* diskCacheFileName;
@property (nonatomic,assign) BOOL shouldResetCacheFile;
@property (nonatomic,strong) APParseSyncOperation* parseConnector;
@property (nonatomic,strong) NSManagedObjectModel* model;
@property (atomic,assign, getter = isSyncing) BOOL syncing;

@property (nonatomic, strong) NSOperationQueue* syncQueue;
@property (nonatomic, strong) APWebServiceSyncOperation* syncOperation;
@property (nonatomic, assign) APMergePolicy mergePolicy;
@property (nonatomic, assign) PFUser* authenticatedUser;


/*
 referenceCount: indicates how many managed object context are using the object identified by object IDs.
 See: managedObjectContextDidUnregisterObjectsWithIDs: and managedObjectContextDidRegisterObjectsWithIDs:
 
 Structure is as follows:
 
 {
 Entity1: {
 objectUID: {
 kAPNSManagedObjectIDKey: objectID,
 kAPReferenceCountKey: referenceCount
 },
 {
 objectUUID: {kAPNSManagedObjectIDKey: objectID,
 kAPReferenceCountKey: referenceCount
 },
 ...
 },
 Entity2: {
 objectUID: {
 kAPNSManagedObjectIDKey: objectID,
 kAPReferenceCountKey: referenceCount
 },
 objectUID: {
 kAPNSManagedObjectIDKey: objectID,
 kAPReferenceCountKey: referenceCount},
 },
 ...
 }
 */
@property (nonatomic, strong) NSMutableDictionary *mapBetweenManagedObjectIDsAndObjectUIDByEntityName;

@end


@implementation APIncrementalStore


#pragma mark - Setup and Takedown

- (id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)psc
                       configurationName:(NSString *)name
                                     URL:(NSURL *)url
                                 options:(NSDictionary *)options {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    self = [super initWithPersistentStoreCoordinator:psc configurationName:name URL:url options:options];
    
    if (self) {
        
        _authenticatedUser = [options valueForKey:APOptionAuthenticatedUserObjectKey];
        if (!_authenticatedUser) {
            if (AP_DEBUG_ERRORS) {ELog(@"Authenticated user is not set")}
            return nil;
        }
        _mergePolicy = [[options valueForKey:APOptionMergePolicyKey] integerValue];
        _model = psc.managedObjectModel;
        
        // There will be one sqlite store file for each user. The file name will be <username>-<APOptionCacheFileNameKey>
        // ie: flavio-apincrementalstorediskcache.sqlite
        NSString* diskCacheFileNameSuffix = [@"-" stringByAppendingString:[options valueForKey:APOptionCacheFileNameKey] ?: APDefaultLocalCacheFileName];
        _diskCacheFileName = [_authenticatedUser.username stringByAppendingString: diskCacheFileNameSuffix];
        _shouldResetCacheFile = [options[APOptionCacheFileResetKey] boolValue];
        
        [self registerForNotifications];
    }
    return self;
}


- (void)dealloc {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [self unregisterForNotifications];
}


/*
 The default implementation does nothing.
 You can override this method in a subclass in order to perform any clean-up
 before the store is removed from the coordinator (and deallocated)
 */
- (void) willRemoveFromPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator {
    if (AP_DEBUG_METHODS) { MLog()}
    
    [self unregisterForNotifications];
}

#pragma mark - Notification Observation

- (void)registerForNotifications {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveSyncNotifcation:) name:APNotificationRequestCacheSync object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveFullSyncNotifcation:) name:APNotificationRequestCacheFullSync object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveResetCacheNotifcation:) name:APNotificationStoreRequestCacheReset object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
}


- (void)unregisterForNotifications {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationRequestCacheSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationRequestCacheFullSync object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:APNotificationStoreRequestCacheReset object:nil];
}


#pragma mark - Getters and Setters

- (NSOperationQueue*) syncQueue {
    if (!_syncQueue) {
        _syncQueue = [[NSOperationQueue alloc]init];
        [_syncQueue setName: @"APDiskCache Sync Queue"];
        [_syncQueue setMaxConcurrentOperationCount: 1]; //Serial
    }
    return _syncQueue;
}

- (APDiskCache*) diskCache {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    if (!_diskCache) {
        
        __weak  typeof(self) weakSelf = self;
        NSString* (^translateBlock)(NSManagedObjectID*) = ^NSString* (NSManagedObjectID* objectID) {
            
            if ([objectID isTemporaryID]) {
                //[NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Can't fetch based on unsaved managed object id (temporary objectID: %@",objectID];
                return nil;
            }
            return [weakSelf referenceObjectForObjectID:objectID];
        };
        
        _diskCache = [[APDiskCache alloc]initWithManagedModel:self.model
                                    translateToObjectUIDBlock:translateBlock
                                           localStoreFileName:self.diskCacheFileName
                                         shouldResetCacheFile:self.shouldResetCacheFile];
    }
    return _diskCache;
}


- (NSMutableDictionary*) mapBetweenManagedObjectIDsAndObjectUIDByEntityName {
    
    if (!_mapBetweenManagedObjectIDsAndObjectUIDByEntityName) {
        _mapBetweenManagedObjectIDsAndObjectUIDByEntityName = [NSMutableDictionary dictionary];
    }
    return _mapBetweenManagedObjectIDsAndObjectUIDByEntityName;
}


#pragma mark - NSIncrementalStore Subclass Methods

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    [self setMetadata:@{NSStoreUUIDKey: [[NSProcessInfo processInfo] globallyUniqueString],
                        NSStoreTypeKey: NSStringFromClass([self class])}];
    return YES;
}


+ (NSString*) type {
    if (AP_DEBUG_METHODS) { MLog()}
    return NSStringFromClass([self class]);
}


/*
 Returns an incremental store node encapsulating the persistent external values of the object with a given object ID.
 Return Value:  An incremental store node encapsulating the persistent external values of the object with object ID objectID, or nil if the corresponding object cannot be found.
 
 Discussion:    The returned node should include all attributes values and may include to-one relationship values as instances of NSManagedObjectID.
 If an object with object ID objectID cannot be found, the method should return nil and—if error is not NULL—create and return an appropriate error object in error.
 
 This method is used in 2 scenarios: When an object is fulfilling a fault, and before a save on updated objects to grab a copy from the server for merge conflict purposes.
 */
- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError **)error {
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSString* objectUID = [self referenceObjectForObjectID:objectID];
    //if (AP_DEBUG_INFO) {DLog(@"New values for entity: %@ with id %@", objectID.entity.name, objectUID)}
    
    NSDictionary *objectFromCache = [self.diskCache fetchObjectRepresentationForObjectUID:objectUID entityName:objectID.entity.name];
    
    if (!objectFromCache) {
        //        [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Cache object with managed objectUID %@ not found.", objectUID];
        // object has been deleted ?
        return nil;
    }
    
    // Create dictionary of keys and values for incremental store node
    NSMutableDictionary *dictionaryRepresentationOfCacheObject = [NSMutableDictionary dictionary];
    
    // Attributes
    NSArray* entityAttributes = [[[objectID entity] attributesByName] allKeys];
    [[objectFromCache dictionaryWithValuesForKeys:entityAttributes] enumerateKeysAndObjectsUsingBlock:^(id attributeName, id attributeValue, BOOL *stop) {
        if (attributeValue != [NSNull null]) {
            dictionaryRepresentationOfCacheObject[attributeName] = attributeValue;
        }
    }];
    
    // To-One relationships
    NSArray* entityRelationships = [[[objectID entity] relationshipsByName] allKeys];
    [[objectFromCache dictionaryWithValuesForKeys:entityRelationships] enumerateKeysAndObjectsUsingBlock:^(id relationshipName, id relationshipValue, BOOL *stop) {
        
        if (![[[objectID entity]relationshipsByName][relationshipName] isToMany]) {
            
            if (relationshipValue == [NSNull null] || relationshipValue == nil) {
                dictionaryRepresentationOfCacheObject[relationshipName] = [NSNull null];
                
            } else {
                NSRelationshipDescription* relationship = [[objectID entity] relationshipsByName][relationshipName];
                NSString* relatedObjectID = [[relationshipValue allValues]lastObject];
                NSManagedObjectID *relationshipObjectID = [self managedObjectIDForEntity:relationship.destinationEntity withObjectUID:relatedObjectID];
                dictionaryRepresentationOfCacheObject[relationshipName] = relationshipObjectID;
            }
        }
    }];
    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:dictionaryRepresentationOfCacheObject version:1];
    return node;
}


/*
 Return Value
 The value of the relationship specified relationship of the object with object ID objectID, or nil if an error occurs.
 
 Discussion
 If the relationship is a to-one, the method should return an NSManagedObjectID instance that identifies the destination, or an instance of NSNull if the relationship value is nil.
 
 If the relationship is a to-many, the method should return a collection object containing NSManagedObjectID instances to identify the related objects. Using an NSArray instance is preferred because it will be the most efficient. A store may also return an instance of NSSet or NSOrderedSet; an instance of NSDictionary is not acceptable.
 
 If an object with object ID objectID cannot be found, the method should return nil and—if error is not NULL—create and return an appropriate error object in error.
 */
- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError * __autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSString* objectUID = [self referenceObjectForObjectID:objectID];
    
    //if (AP_DEBUG_INFO) {DLog(@"New values for relationship: %@ for entity: %@ with id %@", relationship, objectID.entity.name, objectUID)}
    
    NSFetchRequest *fr = [[NSFetchRequest alloc] initWithEntityName:objectID.entity.name];
    fr.predicate = [NSPredicate predicateWithFormat:@"%K == %@", APObjectUIDAttributeName, objectUID];
    
    NSError *fetchError = nil;
    NSArray *results = [self.diskCache fetchObjectRepresentations:fr error:&fetchError];
    
    if (fetchError || [results count] > 1) {
        // TODO handle error
    }
    
    NSDictionary* objectFromCache = [results lastObject];
    
    if (!objectFromCache) {
        // [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Cache object with managed objectUUID %@ not found.", objectUUID];
        // object has been deleted ?
        return nil;
    }
    
    if ([relationship isToMany]) {
        
        // to-many: pull related object set from cache
        // value should be the cache object reference for the related object, if the relationship value is not nil
        
        __block NSMutableArray *arrayToReturn = [NSMutableArray array];
        
        NSDictionary *relatedObjectCacheReferenceDict = objectFromCache[[relationship name]];
        if ([relatedObjectCacheReferenceDict count] > 0) {
            
            [relatedObjectCacheReferenceDict enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* cacheManagedObjectReferences, BOOL *stop) {
                NSEntityDescription* destinationEntity = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
                [cacheManagedObjectReferences enumerateObjectsUsingBlock:^(NSString* cacheManagedObjectReference, NSUInteger idx, BOOL *stop) {
                    NSManagedObjectID *managedObjectID = [self managedObjectIDForEntity:destinationEntity withObjectUID:cacheManagedObjectReference];
                    [arrayToReturn addObject:managedObjectID];
                }];
            }];
        }
        
        return arrayToReturn;
        
    } else {
        
        // to-one: pull related object from cache
        // value should be the cache object reference for the related object, if the relationship value is not nil
        
        NSDictionary *relatedObjectCacheReferenceDict = objectFromCache[[relationship name]];
        
        if (!relatedObjectCacheReferenceDict) {
            return nil; //[NSNull null];
            
        } else {
            
            NSString *entityName = [[relatedObjectCacheReferenceDict allValues]lastObject];
            NSString *relatedObjectUID = [[relatedObjectCacheReferenceDict allKeys]lastObject];
            NSEntityDescription* destinationEntity = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
            
            // Use primary key id to create in-memory context managed object ID equivalent
            NSManagedObjectID *managedObjectID = [self managedObjectIDForEntity:destinationEntity withObjectUID:relatedObjectUID];
            
            return managedObjectID;
        }
    }
}

/*
 Returns an array containing the object IDs for a given array of newly-inserted objects.
 This method is called before executeRequest:withContext:error: with a save request, to assign permanent IDs to newly-inserted objects.
 */
- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    if (array == nil) {
        return @[];
    }
    
    return [array map:^id(NSManagedObject* managedObject) {
        NSString *tempObjectUID = [self.diskCache createObjectUID];
        if (!tempObjectUID) {
            // Redundant Exception
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Error obtaining permanent objectID for object:%@", managedObject];
        }
        
        NSManagedObjectID *permanentID = [self managedObjectIDForEntity: managedObject.entity withObjectUID:tempObjectUID];
        //if (AP_DEBUG_INFO) { DLog(@"Entity: %@ had its temporary ID: %@ replaced by a permanent ID: %@", managedObject.entity.name, tempObjectUID, permanentID) }
        
        return permanentID;
    }];
}


- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    id result = nil;
    
    switch (request.requestType) {
            
        case NSSaveRequestType:
            result = [self AP_handleSaveRequest:(NSSaveChangesRequest *) request withContext:context error:error];
            break;
            
        case NSFetchRequestType:
            result = [self AP_handleFetchRequest:(NSFetchRequest *) request withContext:context error:error];
            break;
            
        default:
            [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Unknown request type."];
            break;
    }
    return result;
}


#pragma mark - Fetching

- (id)AP_handleFetchRequest:(NSFetchRequest *)request
                withContext:(NSManagedObjectContext *)context
                      error:(NSError * __autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    switch (request.resultType) {
            
        case NSManagedObjectResultType:
            return [self AP_fetchManagedObjects:request withContext:context error:error];
            break;
            
        case NSManagedObjectIDResultType:
            return [self AP_fetchManagedObjectIDs:request withContext:context error:error];
            break;
            
        case NSDictionaryResultType:
            [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Unimplemented result type requested."];
            break;
            
        case NSCountResultType:
            return [self AP_fetchCount:request withContext:context error:error];
            break;
            
        default:
            [NSException raise:APIncrementalStoreExceptionIncompatibleRequest format:@"Unknown result type requested."];
            break;
    }
    
    return nil;
}


// Returns NSArray of NSManagedObjects
- (NSArray*) AP_fetchManagedObjects:(NSFetchRequest *)fetchRequest
                        withContext:(NSManagedObjectContext *)context
                              error:(NSError * __autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSError *localCacheError = nil;
    NSArray *cacheRepresentations = [self.diskCache fetchObjectRepresentations:fetchRequest error:&localCacheError];
    
    if (localCacheError != nil) {
        if (error != NULL) {
            *error = localCacheError;
        }
        return nil;
    }
    
    __block NSMutableArray *results = [NSMutableArray array];
    
    [cacheRepresentations enumerateObjectsUsingBlock:^(id cacheManagedObjectRep, NSUInteger idx, BOOL *stop) {
        NSString *objectUID = [cacheManagedObjectRep valueForKey:APObjectUIDAttributeName];
        NSString* entityName = [cacheManagedObjectRep valueForKey:APObjectEntityNameAttributeName];
        NSEntityDescription* entityDescription = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
        NSManagedObjectID* managedObjectID = [self managedObjectIDForEntity:entityDescription withObjectUID:objectUID];
        
        // Allows us to always return object, faulted or not
        NSManagedObject* managedObject = [context objectWithID:managedObjectID];
        
        if (![managedObject isFault]) {
            [self populateManagedObject:managedObject withRepresentation:cacheManagedObjectRep callingContext:context];
        }
        [results addObject:managedObject];
    }];
    
    return results;
}


// Returns NSArray<NSManagedObjectID>
- (id) AP_fetchManagedObjectIDs:(NSFetchRequest *)fetchRequest
                    withContext:(NSManagedObjectContext *)context
                          error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSFetchRequest *fetchCopy = [fetchRequest copy];
    
    [fetchCopy setResultType:NSManagedObjectResultType];
    
    if ([fetchRequest fetchBatchSize] > 0) {
        [fetchCopy setFetchBatchSize:[fetchRequest fetchBatchSize]];
    }
    
    NSArray *objects = [self AP_fetchManagedObjects:fetchCopy withContext:context error:error];
    
    if (error != NULL && *error != nil) {
        return nil;
    }
    
    return [objects map:^(id item) {
        return [item objectID];
    }];
}


- (NSArray *) AP_fetchCount:(NSFetchRequest *)fetchRequest
                withContext:(NSManagedObjectContext *)context
                      error:(NSError * __autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSError *localCacheError = nil;
    NSUInteger localCacheCount = [self.diskCache countObjectRepresentations:fetchRequest error:&localCacheError];
    
    // Error check
    if (localCacheError != nil) {
        *error = localCacheError;
        return nil;
    }
    
    return @[@(localCacheCount)];
}


#pragma mark - Saving

/*
 If the request is a save request, you record the changes provided in the request’s insertedObjects, updatedObjects, and deletedObjects collections. Note there is also a lockedObjects collection; this collection contains objects which were marked as being tracked for optimistic locking (through the detectConflictsForObject:: method); you may choose to respect this or not.
 In the case of a save request containing objects which are to be inserted, executeRequest:withContext:error: is preceded by a call to obtainPermanentIDsForObjects:error:; Core Data will assign the results of this call as the objectIDs for the objects which are to be inserted. Once these IDs have been assigned, they cannot change.
 
 Note that if an empty save request is received by the store, this must be treated as an explicit request to save the metadata, but that store metadata should always be saved if it has been changed since the store was loaded.
 
 If the request is a save request, the method should return an empty array.
 If the save request contains nil values for the inserted/updated/deleted/locked collections; you should treat it as a request to save the store metadata.
 
 @note: We are *IGNORING* locked objects. We are also not handling the metadata save requests, because AFAIK we don't need to generate any.
 */
- (id)AP_handleSaveRequest:(NSSaveChangesRequest *)saveRequest
               withContext:(NSManagedObjectContext *)context
                     error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSSet *insertedObjects = [saveRequest insertedObjects];
    NSSet *updatedObjects = [saveRequest updatedObjects];
    NSSet *deletedObjects = [saveRequest deletedObjects];
    
    __block NSError* localError;
    
    if ([insertedObjects count] > 0) {
        NSDictionary* insertedObjectRepresentations = [self representationsFromManagedObjects:[insertedObjects allObjects]];
        
        [insertedObjectRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* representations, BOOL *stop) {
            
            if (![self.diskCache inserteObjectRepresentations:representations error:&localError]) {
                *stop = YES;
                *error = localError;
            }
        }];
        if (localError) return nil;
    }
    
    if ([updatedObjects count] > 0) {
        NSDictionary* updatedObjectRepresentations = [self representationsFromManagedObjects:[updatedObjects allObjects]];
        
        [updatedObjectRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* representations, BOOL *stop) {
            
            if (![self.diskCache updateObjectRepresentations:representations error:&localError]){
                *stop = YES;
                *error = localError;
            }
        }];
        if (localError) return nil;
    }
    
    if ([deletedObjects count] > 0) {
        NSDictionary* deletedObjectRepresentations = [self representationsFromManagedObjects:[deletedObjects allObjects]];
        
        [deletedObjectRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* representations, BOOL *stop) {
            
            if (![self.diskCache deleteObjectRepresentations:representations error:&localError]) {
                *stop = YES;
                *error = localError;
            }
        }];
        if (localError) return nil;
    }
    
    return @[];
}


#pragma mark - NSIncrementalStore Subclass Optional Methods

/*
 Once the incremental store registers a new managedObjectID we cache it and
 increment its reference count by 1
 */
- (void) managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    // [super managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        id objectUID = [self referenceObjectForObjectID:objectID];
        
        if (!objectUID) {
            if (AP_DEBUG_ERRORS) { ELog(@"ObjectID: %@ does not have objectUID??", objectID)}
            continue;
        }
        
        NSMutableDictionary *objectIDsAndRefereceCountByObjectUID = self.mapBetweenManagedObjectIDsAndObjectUIDByEntityName[objectID.entity.name];
        NSDictionary* objectUIDDictEntry;
        
        if (!objectIDsAndRefereceCountByObjectUID) {
            
            /*
             Entry: {objectID: refereceCount}
             As the entry was present this is the first reference then @1
             */
            
            objectIDsAndRefereceCountByObjectUID = [NSMutableDictionary dictionary];
            objectUIDDictEntry = @{APManagedObjectIDKey:objectID,
                                   APReferenceCountKey:@1};
            
        } else {
            
            /*
             Entry: {objectID: refereceCount}
             get existing entry and increment referece count by 1
             */
            
            NSNumber* referenceCount = [objectIDsAndRefereceCountByObjectUID valueForKey:APReferenceCountKey];
            objectUIDDictEntry = @{APManagedObjectIDKey:objectID,
                                   APReferenceCountKey:@([referenceCount integerValue] + 1)};
        }
        
        objectIDsAndRefereceCountByObjectUID[objectUID] = objectUIDDictEntry;
        self.mapBetweenManagedObjectIDsAndObjectUIDByEntityName[objectID.entity.name] = objectIDsAndRefereceCountByObjectUID;
    }
}


/*
 Once the incremental store a managedObjectID we check if its reference count and
 decrease it by 1 and remove it from the objectIDsAndRefereceCountByObjectUUID if the count == 0
 */
- (void) managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    // [super managedObjectContextDidUnregisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        id objectUID = [self referenceObjectForObjectID:objectID];
        
        if (!objectUID) {
            if (AP_DEBUG_ERRORS) { ELog(@"ObjectID: %@ does not have objectUID??", objectID)}
            continue;
        }
        
        NSMutableDictionary *objectIDsAndRefereceCountByObjectUID = self.mapBetweenManagedObjectIDsAndObjectUIDByEntityName[objectID.entity.name];
        NSDictionary* objectUIDDictEntry;
        
        if (!objectIDsAndRefereceCountByObjectUID) {
            if (AP_DEBUG_ERRORS) { ELog(@"ObjectID: %@ isn't registred in self.mapBetweenObjectIDsAndObjectUIDByEntityName ??", objectID)}
            continue;
            
        } else {
            
            /*
             Entry: {objectID: refereceCount}
             get existing entry and increment referece count by 1
             */
            
            NSNumber* referenceCount = objectIDsAndRefereceCountByObjectUID[APReferenceCountKey];
            
            if ([referenceCount integerValue] == 1) {
                
                /*
                 No context holds reference for this managedObjectID anymore,
                 we can remove it from objectIDsAndRefereceCountByObjectUUID
                 */
                
                [objectIDsAndRefereceCountByObjectUID removeObjectForKey:objectUID];
                
            } else {
                objectUIDDictEntry = @{APManagedObjectIDKey:objectID,
                                       APReferenceCountKey:@([referenceCount integerValue] - 1)};
            }
        }
    }
}


#pragma mark - Notification Handlers

- (void) didReceiveSyncNotifcation: (NSNotification*) note {
    
    if (AP_DEBUG_METHODS) {MLog() }
    [self syncLocalCacheAllRemoteObjects:NO];
}


- (void) didReceiveFullSyncNotifcation: (NSNotification*) note {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [self syncLocalCacheAllRemoteObjects:YES];
}


- (void) didReceiveResetCacheNotifcation: (NSNotification*) note {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [self.diskCache resetCache];
    [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationStoreDidFinishCacheReset object:self];
}

- (void) didReceiveAppDidEnterBackground: (NSNotification*) note {
    if (AP_DEBUG_METHODS) { MLog()}
    [self.syncQueue cancelAllOperations];
}


#pragma mark - Sync Local Cache

- (void) syncLocalCacheAllRemoteObjects:(BOOL) allRemoteObjects {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    if ([self.syncOperation isExecuting]){
        if (AP_DEBUG_INFO) { DLog(@"Already syncing... can't request another one until the previous process is finished")};
        return;
    }
    
    self.syncOperation = [[APParseSyncOperation alloc]initWithMergePolicy:self.mergePolicy authenticatedParseUser:self.authenticatedUser];
    [self.syncOperation setEnvID:[NSString stringWithFormat:@"%@-%@",self.diskCache.localStoreFileName,self.authenticatedUser.username]];
    [self.diskCache.syncContext reset];
    self.syncOperation.context = self.diskCache.syncContext;
    self.syncOperation.fullSync = allRemoteObjects;
    
    __weak  typeof(self) weakSelf = self;
    
    [self.syncOperation setPerObjectCompletionBlock:^(BOOL isRemote) {
        
        /* Saving and reseting the sync context for every remote object synced 
         to avoid unecessary high memory usage. This is particulary true for an initial sync when many
         objects are likely to be fetched from the webservice (i.e. 10K objects). Without reseting the context 
         the app may potentlialy go over the iOS memory threshold and get terminated 
         Perhaps with iOS 8 it might be changed and the APDiskcache be able to save directly to the SQLite database
         without having to materilaize ManagedObjects in memory....*/
        
        NSError* saveSyncContextError = nil;
        BOOL shouldResetSyncContext = (isRemote) ? YES : NO;
        if (![weakSelf.diskCache saveAndReset:shouldResetSyncContext syncContext:&saveSyncContextError]) {
            [weakSelf.syncOperation cancel];
        }
        
        NSString* userInfoKey = (isRemote)? APNotificationNumberOfRemoteObjectsSyncedKey: APNotificationNumberOfLocalObjectsSyncedKey;
        NSDictionary* userInfo = @{userInfoKey: @1};
        
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationStoreDidSyncObject object:weakSelf userInfo:userInfo];
        
    }];
    
    [self.syncOperation setSyncCompletionBlock:^(NSDictionary* mergedObjectsUIDsNestedByEntityName, NSError* operationError) {
        
        if (!operationError) {
            
            NSError* saveSyncContextError = nil;
            if (![weakSelf.diskCache saveAndReset:NO syncContext:&saveSyncContextError]) {
                [weakSelf.syncOperation cancel];
            }
        }
        
        NSMutableDictionary* syncResults = [NSMutableDictionary dictionaryWithCapacity:2];
        if (mergedObjectsUIDsNestedByEntityName) {
            syncResults[APNotificationSyncedObjectsKey] = [weakSelf translateObjectUIDsToManagedObjectIDs:mergedObjectsUIDsNestedByEntityName];
        }
        if (operationError) {
            syncResults[APNotificationSyncErrorKey] = operationError;
        }
        
        [[NSNotificationCenter defaultCenter]postNotificationName:APNotificationStoreDidFinishSync object:weakSelf userInfo:[syncResults copy]];
        
        weakSelf.syncing = NO;
    }];
    
    [self.syncQueue addOperation:self.syncOperation];
}

/*
 objectUIDsNestedByEntityName has the following format:
 
 { EntityName1 = {
 inserted = (
 objectUID,
 objectUID,
 ...,
 objectUID
 );
 updated = (
 objectUID,
 objectUID,
 ...,
 objectUID
 );
 deleted = (
 objectUID,
 objectUID,
 ...,
 objectUID
 );
 }
 EntityName2 = {...}
 }
 
 The objective is to create a translated dictionary with the same formart that Core Data sends the NSManagedObjectContextObjectsDidChangeNotification
 */
- (NSDictionary*) translateObjectUIDsToManagedObjectIDs: (NSDictionary*) objectUIDsNestedByEntityNameAndStatus {
    
    __block NSMutableDictionary* translatedDictionary = [NSMutableDictionary dictionary];
    
    [objectUIDsNestedByEntityNameAndStatus enumerateKeysAndObjectsUsingBlock:^(NSString* entity, NSDictionary* objectsUIDsNestedByStatus, BOOL *stop) {
        NSEntityDescription* entityDescription = [[self.model entitiesByName] objectForKey:entity];
        
        [objectsUIDsNestedByStatus enumerateKeysAndObjectsUsingBlock:^(NSString* status, NSArray* objectUIDs, BOOL *stop) {
            __block NSMutableArray* managedObjectIDs = [NSMutableArray array];
            
            [objectUIDs enumerateObjectsUsingBlock:^(NSString* objectUID, NSUInteger idx, BOOL *stop) {
                [managedObjectIDs addObject:[self managedObjectIDForEntity:entityDescription withObjectUID:objectUID]];
            }];
            NSMutableArray* entriesForStatus = translatedDictionary[status] ?: [NSMutableArray array];
            [entriesForStatus addObjectsFromArray:managedObjectIDs];
            translatedDictionary[status] = entriesForStatus;
        }];
    }];
    return translatedDictionary;
}


#pragma mark - Translating Between Objects UIDs and Managed Object IDs

- (NSManagedObjectID*) managedObjectIDForEntity:(NSEntityDescription*) entityDescription
                                  withObjectUID:(NSString*) objectUID {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    if (!objectUID) {
        if (AP_DEBUG_ERRORS) {ELog(@"Error - uniqueIdentifier == nil")}
        return nil;
    }
    
    NSManagedObjectID *managedObjectID = nil;
    
    // Check if we have it created already
    NSMutableDictionary *objectIDsAndRefCountByObjectUID = self.mapBetweenManagedObjectIDsAndObjectUIDByEntityName[entityDescription.name];
    
    if (objectIDsAndRefCountByObjectUID) {
        NSDictionary* objectUIDEntry = objectIDsAndRefCountByObjectUID[objectUID];
        
        if (!objectUIDEntry) {
            managedObjectID = [self newObjectIDForEntity:entityDescription referenceObject:objectUID];
            
        } else {
            managedObjectID = objectUIDEntry[APManagedObjectIDKey];
            NSAssert([managedObjectID isKindOfClass:[NSManagedObjectID class]],@"returned object should be of NSManagedObjectId kind");
        }
        
    } else {
        /*
         After created it will call managedObjectContextDidRegisterObjectsWithIDs:
         then we have the oportunity cache it in self.mapBetweenObjectIDsAndObjectUIDByEntityName
         */
        managedObjectID = [self newObjectIDForEntity:entityDescription referenceObject:objectUID];
    }
    return managedObjectID;
}


#pragma mark - Translate Managed Objects to Representations

/**
 Returns a NSDictionary keyed by entity name with NSArrays of representations as objects.
 */
- (NSDictionary*) representationsFromManagedObjects: (NSArray*) managedObjects {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSMutableDictionary* representations = [[NSMutableDictionary alloc]init];
    
    [managedObjects enumerateObjectsUsingBlock:^(NSManagedObject* managedObject, NSUInteger idx, BOOL *stop) {
        NSString* entityName = managedObject.entity.name;
        NSMutableArray* objectsForEntity = representations[entityName] ?: [NSMutableArray array];
        [objectsForEntity addObject:[self representationFromManagedObject:managedObject]];
        representations[entityName] = objectsForEntity;
    }];
    
    return representations;
}


- (NSDictionary*) representationFromManagedObject: (NSManagedObject*) managedObject {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSMutableDictionary* representation = [NSMutableDictionary dictionary];
    representation[APObjectEntityNameAttributeName] = managedObject.entity.name;
    
    NSDictionary* properties = [managedObject.entity propertiesByName];
    
    [properties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDescription, BOOL *stop) {
        [managedObject willAccessValueForKey:propertyName];
        [representation setValue:[self referenceObjectForObjectID:managedObject.objectID] forKey:APObjectUIDAttributeName];
        if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
            
            // Attribute
            representation[propertyName] = [managedObject primitiveValueForKey:propertyName] ?: [NSNull null];
            
            
        } else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDescription;
            
            if (!relationshipDescription.isToMany) {
                
                // To-One
                
                NSManagedObject* relatedObject = [managedObject primitiveValueForKey:propertyName];
                
                if (relatedObject) {
                    NSString* objectUID = [self referenceObjectForObjectID:relatedObject.objectID];
                    representation[propertyName] = @{relatedObject.entity.name:objectUID};
                } else {
                    representation[propertyName] = [NSNull null];
                }
                
            } else {
                
                // To-Many
                
                NSSet* relatedObjects = [managedObject primitiveValueForKey:propertyName];
                __block NSMutableDictionary* relatedObjectsRepresentation = [NSMutableDictionary dictionary];
                
                [relatedObjects enumerateObjectsUsingBlock:^(NSManagedObject* relatedObject, BOOL *stop) {
                    NSString* objectUID = [self referenceObjectForObjectID:relatedObject.objectID];
                    NSMutableArray* relatedObjectsUIDs = [relatedObjectsRepresentation objectForKey:relatedObject.entity.name] ?: [NSMutableArray array];
                    [relatedObjectsUIDs addObject:objectUID];
                    relatedObjectsRepresentation[relatedObject.entity.name] = relatedObjectsUIDs;
                }];
                representation[propertyName] = relatedObjectsRepresentation;
            }
        }
        [managedObject didAccessValueForKey:propertyName];
    }];
    return representation;
}


#pragma mark - Translate Representations to Managed Objects

- (void) populateManagedObject:(NSManagedObject*) managedObject
            withRepresentation:(NSDictionary *)dictionary
                callingContext:(NSManagedObjectContext*)context {
    //entity:(NSEntityDescription *)entity {
    
    if (AP_DEBUG_METHODS) {MLog(@"%@",[NSThread isMainThread] ? @"" : @" - [BG Thread]")}
    
    // Enumerate through properties and set internal storage
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id propertyName, id propertyValue, BOOL *stop) {
        [managedObject willChangeValueForKey:propertyName];
        NSPropertyDescription *propertyDescription = [managedObject.entity propertiesByName][propertyName];
        
        // Ignore keys that don't belong to our model
        if (propertyDescription) {
            
            // Attributes
            if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
                if (dictionary[propertyName] == [NSNull null]) {
                    [managedObject setPrimitiveValue:nil forKey:propertyName];
                } else {
                    [managedObject setPrimitiveValue:dictionary[propertyName] forKey:propertyName];
                }
                
                // Relationships
            } else if (![managedObject hasFaultForRelationshipNamed:propertyName]) {
                NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
                
                if ([relationshipDescription isToMany]) {
                    NSMutableSet *relatedObjects = [[managedObject primitiveValueForKey:propertyName] mutableCopy];
                    if (relatedObjects != nil) {
                        [relatedObjects removeAllObjects];
                        NSDictionary *serializedDictSet = dictionary[propertyName];
                        
                        [serializedDictSet enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* objectUIDs, BOOL *stop) {
                            
                            [objectUIDs enumerateObjectsUsingBlock:^(NSString* objectUID, NSUInteger idx, BOOL *stop) {
                                NSEntityDescription* relatedEntity = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
                                NSManagedObjectID* relatedManagedObjectID = [self managedObjectIDForEntity:relatedEntity withObjectUID:objectUID];
                                [relatedObjects addObject:[[managedObject managedObjectContext] objectWithID:relatedManagedObjectID]];
                            }];
                        }];
                        [managedObject setPrimitiveValue:relatedObjects forKey:propertyName];
                    }
                    
                } else {
                    
                    // To-one
                    
                    if (dictionary[propertyName] == [NSNull null]) {
                        [managedObject setPrimitiveValue:nil forKey:propertyName];
                        
                    } else {
                        NSString* relatedObjectUID = [[dictionary[propertyName]allValues]lastObject];
                        NSString* relatedEntityName = [[dictionary[propertyName]allKeys]lastObject];
                        NSEntityDescription* relatedEntity = [NSEntityDescription entityForName:relatedEntityName inManagedObjectContext:context];
                        NSManagedObjectID* relatedManagedObjectID = [self managedObjectIDForEntity:relatedEntity withObjectUID:relatedObjectUID];
                        NSManagedObject *relatedManagedObject = [[managedObject managedObjectContext] objectWithID:relatedManagedObjectID];
                        [managedObject setPrimitiveValue:relatedManagedObject forKey:propertyName];
                    }
                }
            }
        }
        [managedObject didChangeValueForKey:propertyName];
    }];
}

@end
