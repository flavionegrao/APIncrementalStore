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

#import "APDiskCache.h"

#import "NSArray+Enumerable.h"
#import "NSLogEmoji.h"
#import "APCommon.h"
#import "APError.h"


@interface APDiskCache()

@property (nonatomic, strong) NSPersistentStoreCoordinator* psc;
@property (nonatomic, weak) NSManagedObjectModel* model;
@property (nonatomic, strong) NSString* localStoreFileName;
@property (nonatomic, assign) BOOL shouldResetCacheFile;
@property (nonatomic, copy) NSString* (^translateManagedObjectIDToObjectUIDBlock) (NSManagedObjectID*);

// Context used for saving in BG
@property (nonatomic, strong) NSManagedObjectContext* savingToPSCContext;

// Context used for interacting with APincrementalStore
@property (nonatomic, strong) NSManagedObjectContext* mainContext;

/// Observes messages sent by NSManagedObjectContext Save
@property (nonatomic, strong) id contextObserver;


@end


@implementation APDiskCache


- (id)init {
    
    if (AP_DEBUG_METHODS) { MLog()}
    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Use the correct designated initialiser please"];
    return nil;
}


- (void) dealloc {
     [[NSNotificationCenter defaultCenter] removeObserver:self.contextObserver];
}


- (id)initWithManagedModel:(NSManagedObjectModel*) model
 translateToObjectUIDBlock:(NSString* (^)(NSManagedObjectID*)) translateBlock
        localStoreFileName:(NSString*) localStoreFileName {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self = [super init];
    
    if (self) {
        if (model && translateBlock && localStoreFileName) {
            _localStoreFileName = localStoreFileName;
            _translateManagedObjectIDToObjectUIDBlock = translateBlock;
            _model = model;
            
            [self configPersistentStoreCoordinator];
            [self configManagedContexts];
            
            if (AP_DEBUG_INFO) {DLog(@"Disk cache using local store name: %@",[self pathToLocalStore])}
            
        } else {
            if (AP_DEBUG_ERRORS) { ELog(@"Can't init")}
            self = nil;
        }
    }
    return self;
}


- (void) resetCache {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
     [[NSNotificationCenter defaultCenter] removeObserver:self.contextObserver];
    
    [self deleteCacheStore];
    
    _mainContext = nil;
    _savingToPSCContext = nil;
    _psc = nil;
    
    [self configPersistentStoreCoordinator];
    [self configManagedContexts];
    
}


- (void) deleteCacheStore {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    [self removeAllPersistentStores];
    
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


- (void) ap_willRemoveFromPersistentStoreCoordinator {
    
    if (AP_DEBUG_METHODS) { MLog() }
    [[NSNotificationCenter defaultCenter] removeObserver:self.contextObserver];
    _contextObserver = nil;
    _mainContext = nil;
    _savingToPSCContext = nil;
    [self removeAllPersistentStores];
    
}


- (void) removeAllPersistentStores {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    // Remove any previously registred store.
    [self.psc.persistentStores enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSError* error;
        if (![self.psc removePersistentStore:obj error:&error]) {
            [NSException raise:APIncrementalStoreExceptionLocalCacheStore format:@"Não foi possivel remover store - error: %@",error];
        }
    }];
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
    
    NSError *error = nil;
    [self.psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error];
    
    if (error) {
        [NSException raise:APIncrementalStoreExceptionLocalCacheStore format:@"Error creating sqlite persistent store: %@", error];
    }
}


- (void) configManagedContexts {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    self.savingToPSCContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    self.savingToPSCContext.persistentStoreCoordinator = self.psc;
    [self.savingToPSCContext setMergePolicy:NSMergeByPropertyStoreTrumpMergePolicy];

    self.mainContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    self.mainContext.parentContext = self.savingToPSCContext;
    
    self.contextObserver = [[NSNotificationCenter defaultCenter]
                            addObserverForName:NSManagedObjectContextDidSaveNotification
                            object:nil
                            queue:nil
                            usingBlock:^(NSNotification* note) {
                                NSManagedObjectContext* savingContext = (NSManagedObjectContext*) note.object;
                                
                                NSPersistentStoreCoordinator* psc = savingContext.persistentStoreCoordinator;
                                NSArray* savingContextStores = psc.persistentStores;
                                NSAssert([savingContextStores count] == 1, @"Can't handle multiple stores");
                                NSURL* savingContextStoreURL = [psc URLForPersistentStore:[savingContextStores firstObject]];
                                
                                NSPersistentStoreCoordinator* myPSC = self.savingToPSCContext.persistentStoreCoordinator;
                                NSArray* myContextStores = myPSC.persistentStores;
                                NSAssert([myContextStores count] == 1, @"Can't handle multiple stores");
                                NSURL* myContextStoreURL = [myPSC URLForPersistentStore:[myContextStores firstObject]];
                                
                                if ([savingContextStoreURL isEqual:myContextStoreURL]) {
                                    
                                    if (savingContext != self.mainContext) {
                                        
                                        if (savingContext != self.savingToPSCContext) {
                                            [self.savingToPSCContext performBlockAndWait:^{
                                                [self.savingToPSCContext mergeChangesFromContextDidSaveNotification:note];
                                            }];
                                        }
                                        
                                        [self.mainContext performBlock:^{
                                            [self.mainContext mergeChangesFromContextDidSaveNotification:note];
                                        }];
                                    }
                                }
                            }];
}


#pragma mark - Fetching

- (NSArray*) fetchObjectRepresentations:(NSFetchRequest *)fetchRequest
                         requestContext:(NSManagedObjectContext*) requestContext
                                  error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    __block NSError* localError = nil;
    NSFetchRequest* cacheFetchRequest = [self cacheFetchRequestFromFetchRequest:fetchRequest requestContext:requestContext];
    
    __block NSArray *cachedManagedObjects;
    [self.mainContext performBlockAndWait:^{
        NSError* fetchingError = nil;
        cachedManagedObjects = [self.mainContext executeFetchRequest:cacheFetchRequest error:&fetchingError];
        if (fetchingError) {
            localError = fetchingError;
        }
    }];
    
    if (localError) {
        if (error) *error = localError;
        return nil;
    }
    
    __block NSMutableArray* representations = [[NSMutableArray alloc]initWithCapacity:[cachedManagedObjects count]];
    
    [cachedManagedObjects enumerateObjectsUsingBlock:^(NSManagedObject* cacheObject, NSUInteger idx, BOOL *stop) {
        [representations addObject:[self representationFromManagedObject:cacheObject]];
    }];
    return representations;
}


- (NSUInteger) countObjectRepresentations:(NSFetchRequest *)fetchRequest
                           requestContext:(NSManagedObjectContext*) requestContext
                                    error:(NSError *__autoreleasing*)error {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    __block NSError* localError = nil;
    
    NSFetchRequest* cacheFetchRequest = [self cacheFetchRequestFromFetchRequest:fetchRequest requestContext:requestContext];
    
    __block NSUInteger countObjects = 0;
    [self.mainContext performBlockAndWait:^{
        NSError* fetchingError = nil;
        countObjects = [self.mainContext countForFetchRequest:cacheFetchRequest error:&fetchingError];
        if (fetchingError) {
            localError = fetchingError;
        }
    }];
    
    if (localError) {
        if (error) *error = localError;
        return 0;
    } else {
        return countObjects;
    }
}


- (NSDictionary*) representationFromManagedObject: (NSManagedObject*) cacheObject {
    if (AP_DEBUG_METHODS) { MLog()}
    
    
    NSMutableDictionary* representation = [[NSMutableDictionary alloc]init];
    representation[APObjectEntityNameAttributeName] = cacheObject.entity.name;
    NSDictionary* properties = [cacheObject.entity propertiesByName];
    
    NSManagedObjectContext* moc = cacheObject.managedObjectContext;
    NSAssert(moc, @"NSManagedObjectContext can't be nil");
    [moc performBlockAndWait:^{
    
        [properties enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription* propertyDescription, BOOL *stop) {
            [cacheObject willAccessValueForKey:propertyName];
            if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
                
                // Attribute
                if ([[propertyDescription.userInfo valueForKey:APIncrementalStorePrivateAttributeKey] boolValue] != YES ) {
                    representation[propertyName] = [cacheObject primitiveValueForKey:propertyName] ?: [NSNull null];
                }
                
            } else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
                NSRelationshipDescription* relationshipDescription = (NSRelationshipDescription*) propertyDescription;
                
                if (!relationshipDescription.isToMany) {
                    
                    // To-One
                    
                    NSManagedObject* relatedObject = [cacheObject primitiveValueForKey:propertyName];
                    [relatedObject willAccessValueForKey:propertyName];
                    
                    if ([relatedObject valueForKey:APObjectUIDAttributeName]) {
                        representation[propertyName] = @{relatedObject.entity.name:[relatedObject valueForKey:APObjectUIDAttributeName]};
                        
                    } else {
                        representation[propertyName] =  [NSNull null];
                    }
                    [relatedObject didAccessValueForKey:propertyName];
                    
                } else {
                    
                    // To-Many
                    
                    NSSet* relatedObjects = [cacheObject primitiveValueForKey:propertyName];
                    __block NSMutableDictionary* relatedObjectsRepresentation = [[NSMutableDictionary alloc] initWithCapacity:[relatedObjects count]];
                    
                    [relatedObjects enumerateObjectsUsingBlock:^(NSManagedObject* relatedObject, BOOL *stop) {
                        [relatedObject willAccessValueForKey:propertyName];
                        NSMutableArray* relatedObjectsUID = [[relatedObjectsRepresentation valueForKey:relatedObject.entity.name]mutableCopy] ?: [NSMutableArray arrayWithCapacity:1];
                        [relatedObjectsUID addObject:[relatedObject valueForKey:APObjectUIDAttributeName]];
                        [relatedObjectsRepresentation setValue:relatedObjectsUID forKey:relatedObject.entity.name];
                        [relatedObject didAccessValueForKey:propertyName];
                    }];
                    representation[propertyName] = relatedObjectsRepresentation ?: [NSNull null];
                }
            }
            [cacheObject didAccessValueForKey:propertyName];
        }];
    }];
    
    return representation;
}


#pragma mark - Translate Predicates

// Translates a user submited fetchRequest to a "translated" for local cache queries.
- (NSFetchRequest*) cacheFetchRequestFromFetchRequest:(NSFetchRequest*) fetchRequest requestContext:(NSManagedObjectContext*) requestContext {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSFetchRequest* cacheFetchRequest = [fetchRequest copy];
   
    NSMutableArray* predicates = [NSMutableArray array];
    
    NSPredicate* translatedPredicate = [self cachePredicateFromPredicate:fetchRequest.predicate requestContext:requestContext forEntityName:fetchRequest.entityName];
    if (translatedPredicate) [predicates addObject:translatedPredicate];
    
    [predicates addObject:[self controlPropertiesPredicate]];
    [cacheFetchRequest setPredicate:[NSCompoundPredicate andPredicateWithSubpredicates:predicates]];
    
    return cacheFetchRequest;
}


- (NSPredicate*) controlPropertiesPredicate {
    
    // see -[APDiskCache setModel:] for a comprehensive explanation
    NSPredicate* lastModifiedDateIsNil = [NSPredicate predicateWithFormat:@"%K == nil",APObjectLastModifiedAttributeName];
    NSPredicate* isNotCreatedRemotely = [NSPredicate predicateWithFormat:@"%K == NO",APObjectIsCreatedRemotelyAttributeName];
    NSPredicate* wasCreatedLocally = [NSCompoundPredicate andPredicateWithSubpredicates:@[lastModifiedDateIsNil,isNotCreatedRemotely]];
    
    NSPredicate* hasLastModifiedDate = [NSPredicate predicateWithFormat:@"%K != nil",APObjectLastModifiedAttributeName];
    NSPredicate* hasLastModifiedDateOrWasCreatedLocally = [NSCompoundPredicate orPredicateWithSubpredicates:@[hasLastModifiedDate,wasCreatedLocally]];
   
    NSPredicate* onlyPopulatedObjectsObjects = [NSPredicate predicateWithFormat:@"%K == %@",APObjectStatusAttributeName,@(APObjectStatusPopulated)];
    
    return [NSCompoundPredicate andPredicateWithSubpredicates:@[onlyPopulatedObjectsObjects,hasLastModifiedDateOrWasCreatedLocally]];
}


- (NSDictionary*) fetchObjectRepresentationForObjectUID:(NSString*) objectUID
                                         requestContext:(NSManagedObjectContext*) requestContext
                                             entityName:(NSString*) entityName {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSDictionary* managedObjectRep;
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
    
    // Object matching the objectUID and is populated
    NSPredicate* objectUIDPredicate = [NSPredicate predicateWithFormat:@"%K == %@", APObjectUIDAttributeName, objectUID];
    NSPredicate* populatedObjectsPredicate = [NSPredicate predicateWithFormat:@"%K == %@",APObjectStatusAttributeName,@(APObjectStatusPopulated)];
    
    fetchRequest.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[objectUIDPredicate,populatedObjectsPredicate]];
    
    __block NSArray *results;
    __block NSError* localError;
    
    [self.mainContext performBlockAndWait:^{
        NSError *fetchingError = nil;
        results = [self.mainContext executeFetchRequest:fetchRequest error:&fetchingError];
        if (fetchingError) {
            localError = fetchingError;
        }
    }];
   
    if (localError || [results count] > 1) {
        // TODO handle error
        [NSException raise:APIncrementalStoreExceptionInconsistency format:@"It was supposed to fetch only one objects based on the objectUID: %@",objectUID];
        
    } else if ([results count] == 1) {
        managedObjectRep = [self representationFromManagedObject:[results lastObject]];
    }
    
    return managedObjectRep;
}


// Translates a user submited predicate to a "translated" one used on local cache queries.
- (NSPredicate*) cachePredicateFromPredicate:(NSPredicate *)predicate
                              requestContext:(NSManagedObjectContext*) requestContext
                               forEntityName:(NSString*) entityName {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    if (!predicate) {
        return nil;
    }
    
    NSPredicate *adjustedPredicate = [predicate copy];
    
    if ([adjustedPredicate isKindOfClass:[NSCompoundPredicate class]]) {
        NSCompoundPredicate *compoundPredicate = (NSCompoundPredicate*)predicate;
        NSArray *subpredicates = [compoundPredicate subpredicates];
        NSMutableArray *newSubpredicates = [NSMutableArray arrayWithCapacity:[subpredicates count]];
        
        for (NSPredicate *subpredicate in subpredicates) {
            [newSubpredicates addObject:[self cachePredicateFromPredicate:subpredicate requestContext:requestContext  forEntityName:entityName]];
        }
        adjustedPredicate = [[NSCompoundPredicate alloc] initWithType:compoundPredicate.compoundPredicateType subpredicates:newSubpredicates];
        
    } else {
        
        NSComparisonPredicate *comparisonPredicate = (NSComparisonPredicate *)adjustedPredicate;
        NSExpression *rightExpression = comparisonPredicate.rightExpression;
        NSExpression *leftExpression = comparisonPredicate.leftExpression;
        
        if (comparisonPredicate.leftExpression.expressionType == NSConstantValueExpressionType) {
            id leftConstValue = [self cacheTranslatedConstantValueFromConstantValue:comparisonPredicate.leftExpression.constantValue requestContext:requestContext];
            leftExpression = [NSExpression expressionForConstantValue:leftConstValue];
        }
        
        if (comparisonPredicate.rightExpression.expressionType == NSConstantValueExpressionType) {
            id rightConstValue = [self cacheTranslatedConstantValueFromConstantValue:comparisonPredicate.rightExpression.constantValue requestContext:requestContext];
            rightExpression = [NSExpression expressionForConstantValue:rightConstValue];
        }
        
        adjustedPredicate = [NSComparisonPredicate predicateWithLeftExpression:leftExpression
                                                               rightExpression:rightExpression
                                                                      modifier:comparisonPredicate.comparisonPredicateModifier
                                                                          type:comparisonPredicate.predicateOperatorType
                                                                       options:comparisonPredicate.options];
    }
    return adjustedPredicate;
}


- (id) cacheTranslatedConstantValueFromConstantValue:(id) constantValue requestContext:(NSManagedObjectContext*) requestContext {
    
    id cacheTransletedConstantValue;
    
    if ([constantValue isKindOfClass:[NSManagedObject class]]) {
        NSManagedObjectID* objectID = [(NSManagedObject *)constantValue objectID];
        cacheTransletedConstantValue = [self cachedManagedObjectIDFromObjectID:objectID];
        
    } else if ([constantValue isKindOfClass:[NSManagedObjectID class]]) {
        NSManagedObjectID* objectID = (NSManagedObjectID *)constantValue;
        cacheTransletedConstantValue = [self cachedManagedObjectIDFromObjectID:objectID];
        
    //} else if ([constantValue isKindOfClass:[NSMutableSet class]]) {
    } else if ([constantValue isKindOfClass:[NSSet class]]) {
        NSSet* mutableSet = constantValue;
        
        __block NSMutableSet* cacheTranslatedSet;
        __block NSInteger capacity = 0;
        
        [requestContext performBlockAndWait:^{
            capacity = [mutableSet count];
            cacheTranslatedSet = [[NSMutableSet alloc]initWithCapacity:capacity];
            
            [mutableSet enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
                NSManagedObjectID* objectID;
                
                if ([obj isKindOfClass:[NSManagedObject class]]) {
                    objectID = [(NSManagedObject *)obj objectID];
                    
                } else if ([obj isKindOfClass:[NSManagedObjectID class]]) {
                    objectID = (NSManagedObjectID *)obj;
                    
                } else {
                    NSLog(@"Error - Predicate constant %@ not supported by APIncrementalStore yet",constantValue);
                }
                [cacheTranslatedSet addObject:[self cachedManagedObjectIDFromObjectID:objectID]];
            }];
        }];
        cacheTransletedConstantValue = cacheTranslatedSet;
        
    } else if ([constantValue isKindOfClass:[NSArray class]]) {
        NSArray* array = constantValue;
        
        __block NSMutableArray* cacheTranslatedSet;
        __block NSInteger capacity = 0;
        
        [requestContext performBlockAndWait:^{
            capacity = [array count];
            cacheTranslatedSet = [[NSMutableArray alloc]initWithCapacity:capacity];
            
            [array enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                NSManagedObjectID* objectID;
                
                if ([obj isKindOfClass:[NSManagedObject class]]) {
                    objectID = [(NSManagedObject *)obj objectID];
                    
                } else if ([obj isKindOfClass:[NSManagedObjectID class]]) {
                    objectID = (NSManagedObjectID *)obj;
                    
                } else {
                    NSLog(@"Error - Predicate constant %@ not supported by APIncrementalStore yet",constantValue);
                }
                [cacheTranslatedSet addObject:[self cachedManagedObjectIDFromObjectID:objectID]];
            }];
        }];
        cacheTransletedConstantValue = cacheTranslatedSet;
        
    } else if ([constantValue isKindOfClass:[NSString class]] ||
               [constantValue isKindOfClass:[NSNumber class]] ||
               [constantValue isKindOfClass:[NSDate class]] ||
                constantValue == nil) {
        cacheTransletedConstantValue = constantValue;
        
    } else {
        NSLog(@"Error - Predicate constant %@ not supported by APIncrementalStore yet",constantValue);
    }
    
    return cacheTransletedConstantValue;
}


- (NSManagedObjectID*) cachedManagedObjectIDFromObjectID:(NSManagedObjectID*) objectID {
    NSString *objectUID = self.translateManagedObjectIDToObjectUIDBlock(objectID);
    NSManagedObjectID* cacheObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:[[objectID entity] name] createIfNeeded:NO];
    return cacheObjectID;
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
            
            NSError* permanentIdError = nil;
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
                               error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    __block BOOL success = YES;
    
    // Update local context with received representations
    [representations enumerateObjectsUsingBlock:^(NSDictionary* representation, NSUInteger idx, BOOL *stop) {
        NSString* objectUID = [representation valueForKey:APObjectUIDAttributeName];
        if (!objectUID) {
            [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Representation must have objectUID set"];
        }
        NSString* entityName = representation[APObjectEntityNameAttributeName];
        NSManagedObjectID* managedObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:entityName createIfNeeded:NO];
        
        __block NSManagedObject* managedObject;
        if (managedObjectID) {
            
            [self.mainContext performBlockAndWait:^{
                // Object was inserted previously, most likely due to an insertion of an object that contained a relationship reference to this one.
                managedObject = [self.mainContext objectWithID:managedObjectID];
            }];
            
        } else {
            [self.mainContext performBlockAndWait:^{
                managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:self.mainContext];
                NSError* permanentIdError = nil;
                [self.mainContext obtainPermanentIDsForObjects:@[managedObject] error:&permanentIdError];
                // Sanity check
                if (permanentIdError) {
                    [NSException raise:APIncrementalStoreExceptionInconsistency format:@"Could not obtain permanent IDs for objects %@ with error %@", managedObject, permanentIdError];
                }
            }];
        }
        
        [self populateManagedObject:managedObject withRepresentation:representation];
        
        [self.mainContext performBlockAndWait:^{
            [managedObject setValue:@YES forKey:APObjectIsDirtyAttributeName];
            [managedObject setValue:@NO forKey:APObjectIsCreatedRemotelyAttributeName];
            [managedObject setValue:@(APObjectStatusPopulated) forKey:APObjectStatusAttributeName];
        }];
    }];
    
    NSError* saveError = nil;
    if (![self saveAndReset:NO mainContext:&saveError]) {
        success = NO;
        *error = saveError;
    }
    
    return success;
}


- (BOOL)updateObjectRepresentations:(NSArray*) updateObjects
// entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *) error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    
    // Update local context with received representations
    [updateObjects enumerateObjectsUsingBlock:^(NSDictionary* representation, NSUInteger idx, BOOL *stop) {
        NSString* objectUID = [representation valueForKey:APObjectUIDAttributeName];
        NSString* entityName = representation[APObjectEntityNameAttributeName];
        NSManagedObjectID* managedObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:entityName createIfNeeded:NO];
        
        __block NSManagedObject* managedObject;
        [self.mainContext performBlockAndWait:^{
            managedObject = [self.mainContext objectWithID:managedObjectID];
            [managedObject setValue:@YES forKey:APObjectIsDirtyAttributeName];
        }];
        
        [self populateManagedObject:managedObject withRepresentation:representation];
        
    }];
    
    NSError* saveError = nil;
    if (![self saveAndReset:NO mainContext:&saveError]) {
        success = NO;
        *error = saveError;
    }
    
    return success;
}


- (BOOL)deleteObjectRepresentations:(NSArray*) deleteObjects
                              error:(NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    __block BOOL success = YES;
    
    // Update local context with received representations
    [deleteObjects enumerateObjectsUsingBlock:^(NSDictionary* representation, NSUInteger idx, BOOL *stop) {
        NSString* objectUID = [representation valueForKey:APObjectUIDAttributeName];
        NSString* entityName = representation[APObjectEntityNameAttributeName];
        NSManagedObjectID* managedObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:entityName createIfNeeded:NO];
        
        __block NSManagedObject* managedObject;
        [self.mainContext performBlockAndWait:^{
            managedObject = [self.mainContext objectWithID:managedObjectID];
            [managedObject setValue:@(APObjectStatusDeleted) forKey:APObjectStatusAttributeName];
            [managedObject setValue:@YES forKey:APObjectIsDirtyAttributeName];
        }];
    }];
    
    NSError* saveError = nil;
    if (![self saveAndReset:NO mainContext:&saveError]) {
        success = NO;
        *error = saveError;
    }
    
    return success;
}


- (void) populateManagedObject:(NSManagedObject*) managedObject
            withRepresentation:(NSDictionary *)representation {
    
    if (AP_DEBUG_METHODS) {MLog()}
    
    NSManagedObjectContext* moc = managedObject.managedObjectContext;
    NSAssert(moc, @"NSManagedObjectContext can't be nil");
    
    [moc performBlockAndWait:^{
        
        // Enumerate through properties and set internal storage
        [[managedObject.entity propertiesByName] enumerateKeysAndObjectsUsingBlock:^(NSString* propertyName, NSPropertyDescription *propertyDescription, BOOL *stop) {
            [managedObject willChangeValueForKey:propertyName];
            
            // Attributes
            if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
                if (representation[propertyName] == [NSNull null]) {
                    [managedObject setPrimitiveValue:nil forKey:propertyName];
                } else {
                    
                    if (representation[propertyName]) {
                        [managedObject setPrimitiveValue:representation[propertyName] forKey:propertyName];
                    }
                }
                
                // Relationships faulted in
            } else if (![managedObject hasFaultForRelationshipNamed:propertyName]) {
                NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
                
                if ([relationshipDescription isToMany]) {
                    NSMutableSet *relatedObjects = [[managedObject primitiveValueForKey:propertyName] mutableCopy];
                    if (relatedObjects != nil) {
                        [relatedObjects removeAllObjects];
                        NSDictionary *relatedRepresentations = representation[propertyName];
                        
                        [relatedRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString* entityName, NSArray* relatedObjectUIDs, BOOL *stop) {
                            
                            [relatedObjectUIDs enumerateObjectsUsingBlock:^(NSString* objectUID, NSUInteger idx, BOOL *stop) {
                                NSManagedObjectID* relatedManagedObjectID = [self fetchManagedObjectIDForObjectUID:objectUID entityName:entityName createIfNeeded:YES];
                                
                                __block NSManagedObject* relatedObject;
                                [self.mainContext performBlockAndWait:^{
                                    relatedObject = [self.mainContext objectWithID:relatedManagedObjectID];
                                }];
                                [relatedObjects addObject:relatedObject];
                            }];
                        }];
                        [managedObject setPrimitiveValue:relatedObjects forKey:propertyName];
                    }
                    
                } else {
                    
                    //To-one
                    
                    if (representation[propertyName] == [NSNull null]) {
                        [managedObject setValue:nil forKey:propertyName];
                    } else {
                        NSString* relatedEntityName = [[representation[propertyName]allKeys]lastObject];
                        NSString* relatedEntityObjectUID = [[representation[propertyName]allValues]lastObject];
                        NSManagedObjectID* relatedManagedObjectID = [self fetchManagedObjectIDForObjectUID:relatedEntityObjectUID entityName:relatedEntityName createIfNeeded:YES];
                        
                        __block NSManagedObject *relatedObject;
                        [self.mainContext performBlockAndWait:^{
                            relatedObject = [[managedObject managedObjectContext] objectWithID:relatedManagedObjectID];
                        }];
                        
                        [managedObject setPrimitiveValue:relatedObject forKey:propertyName];
                    }
                }
            }
            [managedObject didChangeValueForKey:propertyName];
        }];
    }];
}


- (BOOL) saveAndReset: (BOOL) reset
          mainContext: (NSError *__autoreleasing *)error {
    
    if (AP_DEBUG_METHODS) { MLog() }
    
    __block BOOL success = YES;
    __block NSError* localError = nil;
    
    // Save all contexts
    [self.mainContext performBlockAndWait:^{
        
        if (![self.mainContext save:&localError]) {
            if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",localError)}
            success = NO;
            if (error) *error = localError;
            
        } else {
             if (reset) [self.mainContext reset];
            [self.savingToPSCContext performBlock:^{
                
                if (![self.savingToPSCContext save:&localError]) {
                    if (AP_DEBUG_ERRORS) { ELog(@"Error saving changes: %@",localError)}
                    success = NO;
                    if (error) *error = localError;
                } else {
                     if (reset) [self.savingToPSCContext reset];
                }
            }];
        }
    }];
    return success;
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


- (NSString*) createObjectUID {
    
    if (AP_DEBUG_METHODS) { MLog()}
    
    NSString* objectUID = nil;
    CFUUIDRef uuid = CFUUIDCreate(CFAllocatorGetDefault());
    objectUID = (__bridge_transfer NSString *)CFUUIDCreateString(CFAllocatorGetDefault(), uuid);
    CFRelease(uuid);
    
    return objectUID;
}

@end
