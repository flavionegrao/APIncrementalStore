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
 * The cache is only populated assyncronously through the method -[APDiskCache syncAllObjects:onCountingObjects:onSyncObject:onCompletion:],
 * so that fetching the cache will not triger any network operation.
 */

@import CoreData;


@interface APDiskCache : NSObject

/**
 Designated Initializar
 @param model
 @param translateBlock block that translates ManagedObjectID to reference ObjectUID, usually implemented by -[NSIncrementalStore referenceObjectForObjectID:]. This class use it to translate the predicates to ones complatible for query the local cache.
 @param incrementalStore the NSIncrementalStore subclass that this instance is providing cache support
 @param localStoreURL the name of the SQLite store to be used by this class
 */
- (id)initWithManagedModel:(NSManagedObjectModel*) model
 translateToObjectUIDBlock:(NSString* (^)(NSManagedObjectID*)) translateBlock
        localStoreFileName:(NSString*) localStoreFileName
      shouldResetCacheFile:(BOOL) shouldResetCache;

@property (nonatomic, readonly) NSManagedObjectContext* syncContext;

@property (nonatomic, readonly) NSString* localStoreFileName;

- (BOOL) saveAndReset:(BOOL) reset
          syncContext:(NSError *__autoreleasing*) error;


/**
 Retrieve cached objects representations using the following format:
 [
 {
 "APObjectUIDAttributeName": objectUID,
 "APObjectEntityNameAttributeName": entityName,
 "AttributeName1": provertyValue1,
 "AttributeName2": provertyValue2,
 "AttributeData1": NSData,
 "RelationshipToOneName": obectUIDValue,
 "RelationshipToMany":
 [
 obectUID,
 obectUID,
 obectUID,
 ]
 },
 ...
 ]
 
 If         PropertyName is a to-one relationhip then propertyValue has the related object objectUID
 Else If    PropertyName is a to-many relationhip then propertyValue has a array of related objectsUID
 Else       PropertyName is a attribute then propertyValue has the value of its attribute
 
 @param fetchRequest the fetchRequest requested (same requested by the NSIncremental Store)
 @param error case something goes wrong, this will have more info about the problem
 @returns Array of representations or nil if error occurs
 */
- (NSArray*) fetchObjectRepresentations:(NSFetchRequest *)fetchRequest
                                  error:(NSError *__autoreleasing*)error;

- (NSUInteger) countObjectRepresentations:(NSFetchRequest *)fetchRequest
                                    error:(NSError *__autoreleasing*)error;

- (NSDictionary*) fetchObjectRepresentationForObjectUID:(NSString*) objectUID
                                             entityName:(NSString*) entityName;

- (BOOL)inserteObjectRepresentations:(NSArray*) insertedObjects
// entityName:(NSString*) entityName
                               error:(NSError *__autoreleasing *)error;

- (BOOL)updateObjectRepresentations:(NSArray*) updateObjects
// entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error;

- (BOOL)deleteObjectRepresentations:(NSArray*) deleteObjects
// entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error;

/**
 Permanent objectIDs are only allocated when the objects are syncronized with the remote webservice. Before that
 we must allocate a temporary objectID to allow for unique identification of objects between the APIncrementalStore
 context and the disk cache context.
 @returns a new temporary object identifier
 */
- (NSString*) createObjectUID;

- (void) resetCache;

@end