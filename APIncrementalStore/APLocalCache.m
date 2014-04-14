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

#import "APLocalCache.h"

#import "NSArray+Enumerable.h"
#import "NSLogEmoji.h"
#import "Common.h"
#import "APError.h"

static NSString* const kAPIncrementalStorePrivateAttribute = @"kAPIncrementalStorePrivateAttribute";
static NSString* const kAPIncrementalStoreLocalPrivateAttribute = @"kAPIncrementalStoreLocalPrivateAttribute";


@interface APLocalCache()

@property (nonatomic, strong) NSPersistentStoreCoordinator* psc;
@property (nonatomic, strong) NSManagedObjectModel* model;
@property (nonatomic, strong) NSString* localStoreFileName;
@property (nonatomic, assign) BOOL shouldResetCacheFile;
@property (nonatomic, strong) NSString* (^translateManagedObjectIDToObjectUIDBlock) (NSManagedObjectID*);

@property (nonatomic, weak) id <APRemoteDBConnector> remoteDBConnector;

// Context used for saving in BG
@property (nonatomic, strong) NSManagedObjectContext* privateContext;

// Context used for interacting with APincrementalStore
@property (nonatomic, strong) NSManagedObjectContext* mainContext;

// Context used for Syncing with Remote DB
@property (nonatomic, strong) NSManagedObjectContext* syncContext;


@end


@implementation APLocalCache

- (id)init {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Use the correct designated initialiser please"];
    return nil;
}


- (id)initWithManagedModel: (NSManagedObjectModel*) model
 translateToObjectUIDBlock: (NSString* (^)(NSManagedObjectID*)) translateBlock
        localStoreFileName: (NSString*) localStoreFileName
      shouldResetCacheFile: (BOOL) shouldResetCache
         remoteDBConnector: (id <APRemoteDBConnector>) remoteDBConnector {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self = [super init];
    
    if (self) {
        if (model && translateBlock && localStoreFileName && remoteDBConnector) {
            self.localStoreFileName = localStoreFileName;
            self.translateManagedObjectIDToObjectUIDBlock = translateBlock;
            self.shouldResetCacheFile = shouldResetCache;
            self.remoteDBConnector = remoteDBConnector;
            self.model = model;
            
        } else {
            if (AP_DEBUG_ERRORS) { ELog(@"Can't init")}
            self = nil;
        }
    }
    return self;
}


#pragma mark - Getters and Setters

- (void) setModel:(NSManagedObjectModel *)model {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSManagedObjectModel *cacheModel = [model copy];
    
    /*
     Adding support properties
     kAPIncrementalStoreUUIDAttributeName, APObjectLastModifiedAttributeName and APObjectIsDeletedAttributeName
     for each entity present on model, then we don't need to mess up with the user coredata model
     */
    
    for (NSEntityDescription *entity in cacheModel.entities) {
        
        // Don't add properties for sub-entities, as they already exist in the super-entity
        if ([entity superentity]) {
            continue;
        }
        
        NSAttributeDescription *uuidProperty = [[NSAttributeDescription alloc] init];
        [uuidProperty setName:APObjectUIDAttributeName];
        [uuidProperty setAttributeType:NSStringAttributeType];
        [uuidProperty setIndexed:YES];
        
        NSAttributeDescription *lastModifiedProperty = [[NSAttributeDescription alloc] init];
        [lastModifiedProperty setName:APObjectLastModifiedAttributeName];
        [lastModifiedProperty setAttributeType:NSDateAttributeType];
        [lastModifiedProperty setIndexed:NO];
        [lastModifiedProperty setUserInfo:@{kAPIncrementalStoreLocalPrivateAttribute:@YES}];
        
        NSAttributeDescription *deletedProperty = [[NSAttributeDescription alloc] init];
        [deletedProperty setName:APObjectIsDeletedAttributeName];
        [deletedProperty setAttributeType:NSBooleanAttributeType];
        [deletedProperty setIndexed:NO];
        [deletedProperty setOptional:NO];
        [deletedProperty setDefaultValue:@NO];
        [deletedProperty setUserInfo:@{kAPIncrementalStorePrivateAttribute:@YES}];
        
        NSAttributeDescription *isDirtyProperty = [[NSAttributeDescription alloc] init];
        [isDirtyProperty setName:APObjectIsDirtyAttributeName];
        [isDirtyProperty setAttributeType:NSBooleanAttributeType];
        [isDirtyProperty setIndexed:NO];
        [isDirtyProperty setOptional:NO];
        [isDirtyProperty setDefaultValue:@NO];
        [isDirtyProperty setUserInfo:@{kAPIncrementalStoreLocalPrivateAttribute:@YES}];
        
        [entity setProperties:[entity.properties arrayByAddingObjectsFromArray:@[uuidProperty,
                                                                                 lastModifiedProperty,
                                                                                 deletedProperty,
                                                                                 isDirtyProperty]]];
    }
    _model = cacheModel;
    
    [self configPersistentStoreCoordinator];
    [self configManagedContexts];
}


- (NSManagedObjectContext*) syncContext {
    
//    if (AP_DEBUG_METHODS) { MLog()}
    
    if (!_syncContext) {
        _syncContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        _syncContext.parentContext = self.mainContext;
        _syncContext.retainsRegisteredObjects = YES;
    }
    return _syncContext;
}


#pragma mark - Config

// Local Cache
- (void) configPersistentStoreCoordinator {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self.psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
    NSDictionary *options = @{ NSMigratePersistentStoresAutomaticallyOption: @YES,
                               NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"}, // DEBUG ONLY: Disable WAL mode to be able to visualize the content of the sqlite file.
                               NSInferMappingModelAutomaticallyOption: @YES};
    
    NSURL *storeURL = [NSURL fileURLWithPath:[self pathToLocalStore]];
    
    if (self.shouldResetCacheFile) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:[storeURL path] isDirectory:nil]){
            NSError* deleteError;
            if (![[NSFileManager defaultManager] removeItemAtURL:storeURL error:&deleteError]){
                if (AP_DEBUG_ERRORS) { ELog(@"Error deleting cachefile:%@",deleteError)}
            } else {
                if (AP_DEBUG_INFO) { DLog(@"Cache file deleted")};
            }
        }
    }
    
    NSError *error = nil;
    [self.psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error];
    
    if (error) {
        [NSException raise:APIncrementalStoreExceptionLocalCacheStore format:@"Error creating sqlite persistent store: %@", error];
    }
}


- (void) configManagedContexts {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self.privateContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    self.privateContext.persistentStoreCoordinator = self.psc;
    
    self.mainContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
    self.mainContext.parentContext = self.privateContext;
}


#pragma mark - Utils

- (NSString *)documentsDirectory {
    
    NSString *documentsDirectory = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    documentsDirectory = paths[0];
    return documentsDirectory;
}


- (NSString *)pathToLocalStore {
    
    return [[self documentsDirectory] stringByAppendingPathComponent:self.localStoreFileName];
}


- (NSString*) newTemporaryObjectUID {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSString* objectUUID = nil;
    CFUUIDRef uuid = CFUUIDCreate(CFAllocatorGetDefault());
    objectUUID = (__bridge_transfer NSString *)CFUUIDCreateString(CFAllocatorGetDefault(), uuid);
    CFRelease(uuid);
    
    NSString* tempObjectUUID = [NSString stringWithFormat:@"%@%@",APObjectTemporaryUIDPrefix,objectUUID];
    
    if (AP_DEBUG_INFO) { DLog(@"New temporary objectUUID generated: %@",tempObjectUUID)}
    
    return tempObjectUUID;
}


#pragma mark - Sync

- (void) syncAllObjects: (BOOL) allObjects
      onCountingObjects: (void (^)(NSUInteger localObjects, NSUInteger remoteObjects)) countingBlock
           onSyncObject: (void (^)(BOOL isRemoteObject)) syncObjectBlock
           onCompletion: (void (^)(NSArray* objectUIDs, NSError* syncError)) conpletionBlock {

    if (AP_DEBUG_METHODS) { MLog()}
    
    self.syncContext = nil;
    
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    
    [self.syncContext performBlock:^ {
        
        __block NSError* error;
        __block NSArray* syncedFromServerManagedObjectIDs;
        
        void(^failureBlock)(void) = ^{
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            if (conpletionBlock) conpletionBlock(nil,error);
        };
        
        void(^successBlock)(void) = ^{
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            if (conpletionBlock) conpletionBlock(syncedFromServerManagedObjectIDs,error);
        };
        
        // Count objects to be synced and report it via block
        if (countingBlock) {
            NSUInteger localObjects = [self.remoteDBConnector countLocalObjectsToBeSyncedInContext:self.syncContext error:&error];
            NSUInteger remoteObjects = [self.remoteDBConnector countRemoteObjectsToBeSyncedInContext:self.syncContext fullSync:allObjects error:&error];
            [[NSOperationQueue mainQueue]addOperationWithBlock:^{
                if (!error) {
                    countingBlock(localObjects, remoteObjects);
                } else {
                    failureBlock();
                }
            }];
        }
        
        // Local Updates - all objects marked as "dirty" and add entries from temporary to permanent objectsUID
        BOOL mergeSuccess = [self.remoteDBConnector
                             mergeManagedContext: self.syncContext
                             onSyncObject:^{
                                 if (syncObjectBlock) syncObjectBlock(NO);
                             } error:&error];
        
        if (!mergeSuccess) {
            if (AP_DEBUG_ERRORS) { ELog(@"Error syncing local changes: %@",error)}
            [[NSOperationQueue mainQueue]addOperationWithBlock:failureBlock];
            return;
        }
        
        // Remote Updates - all objects that have updated date earlier than our last successful sync
        
        syncedFromServerManagedObjectIDs = [self.remoteDBConnector
                                            mergeRemoteObjectsWithContext:self.syncContext
                                            fullSync:allObjects onSyncObject:^{
                                                if (syncObjectBlock) syncObjectBlock(YES);
                                            } error:&error];
        
        if (error) {
            if (AP_DEBUG_ERRORS) { ELog(@"Error syncing remote changes: %@",error)}
            [[NSOperationQueue mainQueue]addOperationWithBlock:failureBlock];
            return;
        }
        
        // Save all contexts
        
        if (![self.syncContext hasChanges]) {
            
            [[NSOperationQueue mainQueue]addOperationWithBlock:successBlock];
            
            if (AP_DEBUG_INFO) { ALog(@"Sync context doesn't have any change to be synced")}
            
        } else {
            
            if (![self.syncContext save:&error]) {
                if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",error)}
                [[NSOperationQueue mainQueue]addOperationWithBlock:failureBlock];
                
            } else {
                
                [self.mainContext performBlockAndWait:^{
                    
                    if (![self.mainContext save:&error]) {
                        
                        if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",error)}
                            failureBlock();
                        
                    } else {
                        
                        [self.privateContext performBlock:^{
                            
                            // Save to disk (in BG not wowrking yet)
                            
                            if (![self.privateContext save:&error]) {
                                
                                if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",error)}
                                [[NSOperationQueue mainQueue]addOperationWithBlock:failureBlock];
                                
                            } else {
                                
                                [[NSOperationQueue mainQueue]addOperationWithBlock:successBlock];
                            }
                        }];
                    }
                }];
            }
        }
    }];
}


#pragma mark - Fetching

- (NSArray*) fetchObjectRepresentations:(NSFetchRequest *)fetchRequest
                                  error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    //NSFetchRequest *cacheFetchRequest = [fetchRequest copy];
    NSFetchRequest *cacheFetchRequest = [[NSFetchRequest alloc]initWithEntityName:fetchRequest.entityName];
    //[cacheFetchRequest setResultType:NSDictionaryResultType];
    [cacheFetchRequest setEntity:[NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:self.mainContext]];
    [cacheFetchRequest setReturnsDistinctResults:YES];
    [cacheFetchRequest setPredicate:[self cachePredicateFromPredicate:fetchRequest.predicate]];
    
    NSArray *cachedManagedObjects = [self.mainContext executeFetchRequest:cacheFetchRequest error:error];
    __block NSMutableArray* representations = [[NSMutableArray alloc]initWithCapacity:[cachedManagedObjects count]];
    
    [cachedManagedObjects enumerateObjectsUsingBlock:^(NSManagedObject* cacheObject, NSUInteger idx, BOOL *stop) {
        [representations addObject:[self representationFromManagedObject:cacheObject forEntity:cacheFetchRequest.entity]];
    }];
    return representations;
}


- (NSUInteger) countObjectRepresentations:(NSFetchRequest *)fetchRequest
                                    error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSFetchRequest *cacheFetchRequest = [[NSFetchRequest alloc]initWithEntityName:fetchRequest.entityName];
    [cacheFetchRequest setEntity:[NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:self.mainContext]];
    [cacheFetchRequest setPredicate:[self cachePredicateFromPredicate:fetchRequest.predicate]];
    
    return  [self.mainContext countForFetchRequest:cacheFetchRequest error:error];
}


- (NSDictionary*) representationFromManagedObject: (NSManagedObject*) cacheObject
                                        forEntity: (NSEntityDescription*) entity {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSMutableDictionary* representation = [[NSMutableDictionary alloc]init];
    NSDictionary* properties = [entity propertiesByName];
    
    [properties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDescription, BOOL *stop) {
        
        if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
            
            // Attribute
            if ([[propertyDescription.userInfo valueForKey:kAPIncrementalStorePrivateAttribute] boolValue] != YES ) {
                
                representation[propertyName] = [cacheObject valueForKey:propertyName] ?: [NSNull null];
            }
            
        } else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDescription;
            
            if (!relationshipDescription.isToMany) {
                
                // To-One
                
                NSManagedObject* relatedObject = [cacheObject valueForKey:propertyName];
                representation[propertyName] = [relatedObject valueForKey:APObjectUIDAttributeName] ?: [NSNull null];
                
            } else {
                
                // To-Many
                
                NSSet* relatedObjects = [cacheObject valueForKey:propertyName];
                __block NSMutableArray* relatedObjectsRepresentation = [[NSMutableArray alloc] initWithCapacity:[relatedObjects count]];
                [relatedObjects enumerateObjectsUsingBlock:^(NSManagedObject* relatedObject, BOOL *stop) {
                    [relatedObjectsRepresentation addObject:[relatedObject valueForKey:APObjectUIDAttributeName]];
                }];
                representation[propertyName] = relatedObjectsRepresentation ?: [NSNull null];
            }
        }
    }];
    
    return representation;
}

/*
 Translates a user submited predicate to a one suitable for local cache queries.
 
 */
- (NSPredicate*) cachePredicateFromPredicate:(NSPredicate *)predicate {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    if (!predicate) {
        return nil;
    }
    
    NSPredicate *predicateToReturn = predicate;
    
    if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
        
        // apply SM_parsePredicate to each subpredicate of the compound predicate
        
        NSCompoundPredicate *compoundPredicate = (NSCompoundPredicate*)predicate;
        NSArray *subpredicates = compoundPredicate.subpredicates;
        NSMutableArray *newSubpredicates = [NSMutableArray arrayWithCapacity:[subpredicates count]];
        
        for (NSPredicate *subpredicate in subpredicates) {
            [newSubpredicates addObject:[self cachePredicateFromPredicate:subpredicate]];
        }
        
        predicateToReturn = [[NSCompoundPredicate alloc] initWithType:compoundPredicate.compoundPredicateType subpredicates:newSubpredicates];
        
    } else {
        
        NSComparisonPredicate *comparisonPredicate = (NSComparisonPredicate *)predicate;
        NSManagedObjectID *objectID = nil;
        
        if ([comparisonPredicate.rightExpression.constantValue isKindOfClass:[NSManagedObject class]]) {
            
            objectID = [(NSManagedObject *)comparisonPredicate.rightExpression.constantValue objectID];
            NSString *referenceObject = self.translateManagedObjectIDToObjectUIDBlock(objectID);
            NSManagedObjectID *cacheObjectID = [self fetchManagedObjectIDForObjectUID:referenceObject entityName:[[objectID entity] name] createIfNeeded:NO];
            
            NSExpression *rightExpression = [NSExpression expressionForConstantValue:cacheObjectID];
            predicateToReturn = [NSComparisonPredicate predicateWithLeftExpression:comparisonPredicate.leftExpression rightExpression:rightExpression modifier:comparisonPredicate.comparisonPredicateModifier type:comparisonPredicate.predicateOperatorType options:comparisonPredicate.options];
            
            
        } else if ([comparisonPredicate.rightExpression.constantValue isKindOfClass:[NSManagedObjectID class]]) {
            
            objectID = (NSManagedObjectID *)comparisonPredicate.rightExpression.constantValue;
            NSString *referenceObject = self.translateManagedObjectIDToObjectUIDBlock(objectID);
            NSManagedObjectID *cacheObjectID = [self fetchManagedObjectIDForObjectUID:referenceObject entityName:[[objectID entity] name] createIfNeeded:NO];
            
            NSExpression *rightExpression = [NSExpression expressionForConstantValue:cacheObjectID];
            predicateToReturn = [NSComparisonPredicate predicateWithLeftExpression:comparisonPredicate.leftExpression rightExpression:rightExpression modifier:comparisonPredicate.comparisonPredicateModifier type:comparisonPredicate.predicateOperatorType options:comparisonPredicate.options];
        }
    }
    
    NSPredicate* excludeDeletedOjects = [NSPredicate predicateWithFormat:@"%K != YES",APObjectIsDeletedAttributeName];
    return [NSCompoundPredicate andPredicateWithSubpredicates:@[predicateToReturn,excludeDeletedOjects]];
}


- (NSDictionary*) fetchObjectRepresentationForObjectUUID:(NSString*) objectUID
                                              entityName:(NSString*) entityName {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSDictionary* managedObjectRep;
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
    
    NSString* permanentObjectUUID;
    if ([objectUID hasPrefix:APObjectTemporaryUIDPrefix]) {
        NSDictionary* mapOfTempToPermanentUID = [self.remoteDBConnector mapOfTemporaryToPermanentUID];
        permanentObjectUUID = mapOfTempToPermanentUID[objectUID];
        if (!permanentObjectUUID) {
            permanentObjectUUID = objectUID;
        }
    } else {
        permanentObjectUUID = objectUID;
    }
    
    // Object matching the objectUID and is not deleted
    NSPredicate* objectUIDPredicate = [NSPredicate predicateWithFormat:@"%K == %@", APObjectUIDAttributeName, permanentObjectUUID];
    NSPredicate* notDeletedUIDPredicate = [NSPredicate predicateWithFormat:@"%K == NO", APObjectIsDeletedAttributeName];
    fetchRequest.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[objectUIDPredicate,notDeletedUIDPredicate]];
    
    NSError *fetchError = nil;
    NSArray *results = [self.mainContext executeFetchRequest:fetchRequest error:&fetchError];
    
    if (fetchError || [results count] > 1) {
        // TODO handle error
        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"It was supposed to fetch only one objects based on the objectUID: %@",objectUID];
        
    } else if ([results count] == 1) {
        managedObjectRep = [self representationFromManagedObject:[results lastObject] forEntity:fetchRequest.entity];
    }
    
    return managedObjectRep;
}


- (NSManagedObjectID*) fetchManagedObjectIDForObjectUID:(NSString *)objectUID
                                             entityName:(NSString *)entityName
                                         createIfNeeded:(BOOL)createIfNeeded {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
    //NSEntityDescription *desc = [NSEntityDescription entityForName:entityName inManagedObjectContext:self.localContext];
    
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K == %@", APObjectUIDAttributeName, objectUID];
    
    __block NSError *fetchError = nil;
    __block NSArray *results;
    
    [self.mainContext performBlockAndWait:^{
        results = [self.mainContext executeFetchRequest:fetchRequest error:&fetchError];
    }];
    
    if (fetchError || [results count] > 1) {
        // TODO handle error
    }
    
    __block NSManagedObject *cacheObject = nil;
    if ([results count] == 0 && createIfNeeded) {
        
        __block NSError *permanentIdError = nil;
        
        [self.mainContext performBlockAndWait:^{
            // Create new cache object
            cacheObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:self.mainContext];
            [cacheObject setValue:objectUID forKey:APObjectUIDAttributeName];
            
            NSError* permanentIdError;
            [self.mainContext obtainPermanentIDsForObjects:@[cacheObject] error:&permanentIdError];
            // Sanity check
            if (permanentIdError) {
                [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", cacheObject, permanentIdError];
            }
        }];
        
        // Sanity check
        if (permanentIdError) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", cacheObject, permanentIdError];
        }
        
    } else {
        // result count == 1
        cacheObject = [results lastObject];
    }
    return cacheObject ? [cacheObject objectID] : nil;
}


#pragma mark - Inserting/Creating/Updating

- (BOOL)inserteObjectRepresentations:(NSArray*) representations
                          entityName:(NSString*) entityName
                               error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    __block BOOL success = YES;
    
    // Update local context with received representations
    [representations enumerateObjectsUsingBlock:^(NSDictionary* representation, NSUInteger idx, BOOL *stop) {
        NSString* objectUID = [representation valueForKey:APObjectUIDAttributeName];
        if (!objectUID) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Representation must have objectUID set"];
        }
        
        NSManagedObjectID* managedObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:entityName createIfNeeded:NO];
        
        NSManagedObject* managedObject;
        if (managedObjectID) {
            // Object was inserted previously, mos likely due to an insertion of an object that contained a relationship reference to this one.
            managedObject = [self.mainContext objectWithID:managedObjectID];
        } else {
            managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:self.mainContext];
            
            NSError* permanentIdError;
            [self.mainContext obtainPermanentIDsForObjects:@[managedObject] error:&permanentIdError];
            // Sanity check
            if (permanentIdError) {
                [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", managedObject, permanentIdError];
            }
        }
        
        [self populateManagedObject:managedObject withRepresentation:representation];
        [managedObject setValue:@YES forKey:APObjectIsDirtyAttributeName];
        [managedObject setValue:@NO forKey:APObjectIsDeletedAttributeName];
    }];
    
    NSError* saveError;
    if (![self saveMainContext:&saveError]) {
        success = NO;
        *error = saveError;
    }
    
    return success;
}


- (BOOL)updateObjectRepresentations:(NSArray*) updateObjects
                         entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    
    // Update local context with received representations
    [updateObjects enumerateObjectsUsingBlock:^(NSDictionary* representation, NSUInteger idx, BOOL *stop) {
        NSString* objectUID = [representation valueForKey:APObjectUIDAttributeName];
        NSManagedObjectID* managedObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:entityName createIfNeeded:NO];
        NSManagedObject* managedObject = [self.mainContext objectWithID:managedObjectID];
        [self populateManagedObject:managedObject withRepresentation:representation];
        [managedObject setValue:@YES forKey:APObjectIsDirtyAttributeName];
    }];
    
    NSError* saveError;
    if (![self saveMainContext:&saveError]) {
        success = NO;
        *error = saveError;
    }
    
    return success;
}


- (BOOL)deleteObjectRepresentations:(NSArray*) deleteObjects
                         entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    
    // Update local context with received representations
    [deleteObjects enumerateObjectsUsingBlock:^(NSDictionary* representation, NSUInteger idx, BOOL *stop) {
        NSString* objectUUID = [representation valueForKey:APObjectUIDAttributeName];
        
        NSString* permanentObjectUID;
        if ([objectUUID hasPrefix:APObjectTemporaryUIDPrefix]) {
            NSDictionary* mapOfTempToPemanent = [self.remoteDBConnector mapOfTemporaryToPermanentUID];
            permanentObjectUID = mapOfTempToPemanent[objectUUID];
            if (!permanentObjectUID) {
                permanentObjectUID = objectUUID;
            }
        } else {
            permanentObjectUID = objectUUID;
        }
        
        NSManagedObjectID* managedObjectID = [self fetchManagedObjectIDForObjectUID:permanentObjectUID entityName:entityName createIfNeeded:NO];
        NSManagedObject* managedObject = [self.mainContext objectWithID:managedObjectID];
        [managedObject setValue:@YES forKey:APObjectIsDeletedAttributeName];
        [managedObject setValue:@YES forKey:APObjectIsDirtyAttributeName];
    }];
    
    NSError* saveError = nil;
    if (![self saveMainContext:&saveError]) {
        success = NO;
        *error = saveError;
    }
    
    return success;
}


- (void) populateManagedObject:(NSManagedObject*) managedObject
            withRepresentation:(NSDictionary *)representation {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    // Enumerate through properties and set internal storage
    [representation enumerateKeysAndObjectsUsingBlock:^(id propertyName, id propertyValue, BOOL *stop) {
        NSPropertyDescription *propertyDescription = [managedObject.entity propertiesByName][propertyName];
        
        // Attributes
        if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
            if (representation[propertyName] == [NSNull null]) {
                [managedObject setPrimitiveValue:nil forKey:propertyName];
            } else {
                [managedObject setPrimitiveValue:representation[propertyName] forKey:propertyName];
            }
            
            // Relationships faulted in
        } else if (![managedObject hasFaultForRelationshipNamed:propertyName]) {
            NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
            
            //To-many
            if ([relationshipDescription isToMany]) {
                NSMutableSet *relatedObjects = [[managedObject primitiveValueForKey:propertyName] mutableCopy];
                if (relatedObjects != nil) {
                    [relatedObjects removeAllObjects];
                    NSArray *relatedRepresentations = representation[propertyName];
                    [relatedRepresentations enumerateObjectsUsingBlock:^(NSString* objectUUID, NSUInteger idx, BOOL *stop) {
                        NSManagedObjectID* relatedManagedObjectID = [self fetchManagedObjectIDForObjectUID:objectUUID entityName:relationshipDescription.destinationEntity.name createIfNeeded:YES];
                        [relatedObjects addObject:[self.mainContext objectWithID:relatedManagedObjectID]];
                    }];
                    [managedObject setPrimitiveValue:relatedObjects forKey:propertyName];
                }
                
                //To-one
            } else {
                if (representation[propertyName] == [NSNull null]) {
                    [managedObject setPrimitiveValue:nil forKey:propertyName];
                } else {
                    NSManagedObjectID* relatedManagedObjectID = [self fetchManagedObjectIDForObjectUID:representation[propertyName] entityName:relationshipDescription.destinationEntity.name createIfNeeded:YES];
                    NSManagedObject *relatedObject = [[managedObject managedObjectContext] objectWithID:relatedManagedObjectID];
                    [managedObject setPrimitiveValue:relatedObject forKey:propertyName];
                }
            }
        }
    }];
}


- (BOOL) saveMainContext: (NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    __block BOOL success = YES;
    
    // Save all contexts
    [self.mainContext performBlockAndWait:^{
        
        if (![self.mainContext save:error]) {
            if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",*error)}
            success = NO;
            
        } else {
            [self.privateContext performBlockAndWait:^{
                
                if (![self.privateContext save:error]) {
                    if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",*error)}
                    success = NO;
                    
                } else {
                    if (AP_DEBUG_INFO) { DLog(@"Saved to disk") }
                }
            }];
        }
    }];
    
    return success;
}

- (void) resetCache {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    [self removeCacheStore];
    _syncContext = nil;
    _mainContext = nil;
    _privateContext = nil;
    _psc = nil;
    
    [self configPersistentStoreCoordinator];
    [self configManagedContexts];
    
}

- (void) removeCacheStore {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:[self pathToLocalStore]]) {
        NSError *deleteError = nil;
        BOOL delete = [fileManager removeItemAtURL:[NSURL fileURLWithPath:[self pathToLocalStore]] error:&deleteError];
        if (!delete) {
            [NSException raise:APIncrementalStoreExceptionLocalCacheStore format:@""];
        } else {
            if (AP_DEBUG_INFO) { DLog(@"Cache store removed succesfuly") };
        }
    }
}

@end
