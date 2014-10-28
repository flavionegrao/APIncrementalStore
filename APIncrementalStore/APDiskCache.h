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
 *
 *
 * This class implements what is described on Apple's NSIncrementalStore Programing
 * Guide as "The Disk Cache".
 * https://developer.apple.com/library/mac/documentation/DataManagement/Conceptual/IncrementalStorePG/Introduction/Introduction.html#//apple_ref/doc/uid/TP40010706
 *
 */

@import CoreData;


@interface APDiskCache : NSObject

/**
 Designated Initializer
 @param model
 @param translateBlock block that translates ManagedObjectID to reference ObjectUID, usually implemented by -[NSIncrementalStore referenceObjectForObjectID:]. This class uses it to translate the predicates to ones compatible for querying the local cache.
 @param incrementalStore the NSIncrementalStore subclass that this instance is providing cache support
 @param localStoreURL the name of the SQLite store to be used by this class
 */
- (id)initWithManagedModel:(NSManagedObjectModel*) model
 translateToObjectUIDBlock:(NSString* (^)(NSManagedObjectID*)) translateBlock
        localStoreFileName:(NSString*) localStoreFileName;


@property (nonatomic, readonly) NSString* localStoreFileName;


/**
 Retrieve cached objects representations using the following format:
 [
 {
 "APObjectUIDAttributeName": objectUID,
 "APObjectEntityNameAttributeName": entityName,
 "AttributeName1": propertyValue1,
 "AttributeName2": propertyValue2,
 "AttributeData1": NSData,
 "RelationshipToOneName": objectUID,
 "RelationshipToMany":
 [
 objectUID,
 objectUID,
 objectUID,
 ]
 },
 ...
 ]
 
 If         PropertyName is a to-one relationship then propertyValue has the related object objectUID
 Else If    PropertyName is a to-many relationship then propertyValue has a array of related objectsUID
 Else       PropertyName is an attribute then propertyValue has the value of its attribute
 
 @param fetchRequest the fetchRequest requested (same requested by the NSIncremental Store)
 @param error in case something goes wrong, this will have more info about the problem
 @returns Array of representations or nil if error occurs
 */
- (NSArray*) fetchObjectRepresentations:(NSFetchRequest *)fetchRequest
                         requestContext:(NSManagedObjectContext*) requestContext
                                  error:(NSError *__autoreleasing*)error;

- (NSUInteger) countObjectRepresentations:(NSFetchRequest *)fetchRequest
                           requestContext:(NSManagedObjectContext*) requestContext
                                    error:(NSError *__autoreleasing*)error;

- (NSDictionary*) fetchObjectRepresentationForObjectUID:(NSString*) objectUID
                                         requestContext:(NSManagedObjectContext*) requestContext
                                             entityName:(NSString*) entityName;

- (NSArray*) fetchDictionaryRepresentations:(NSFetchRequest *)fetchRequest
                              requestContext:(NSManagedObjectContext*) requestContext
                                       error:(NSError *__autoreleasing*)error;

- (BOOL)insertObjectRepresentations:(NSArray*) insertedObjects
// entityName:(NSString*) entityName
                               error:(NSError *__autoreleasing *)error;

- (BOOL)updateObjectRepresentations:(NSArray*) updateObjects
// entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error;

- (BOOL)deleteObjectRepresentations:(NSArray*) deleteObjects
// entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error;

- (void) ap_willRemoveFromPersistentStoreCoordinator;

/**
 Permanent objectIDs are only allocated when the objects are syncronized with the remote webservice. Before that
 we must allocate a temporary objectID to allow for unique identification of objects between the APIncrementalStore
 context and the disk cache context.
 @returns a new temporary object identifier
 */
- (NSString*) createObjectUID;

- (void) resetCache;

- (NSString *)pathToLocalStore;

@end