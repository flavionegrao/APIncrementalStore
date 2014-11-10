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

@import XCTest;
@import CoreData;

#import "CoreDataController.h"

#import "NSLogEmoji.h"
#import "APCommon.h"

#import "Author+Transformable.h"
#import "Book.h"
#import "Page.h"
#import "EBook.h" // SubEntity of Book
#import "Magazine.h"
#import "Publisher.h"

#import "UnitTestingCommon.h"

#define WAIT_PATIENTLY [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]

static NSString* const kAuthorName = @"George R. R. Martin";
static NSString* const kBookName1 = @"A Game of Thrones";
static NSString* const kBookName2 = @"A Clash of Kings";

@interface CoreDataControllerTestCase : XCTestCase

@property (strong, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) dispatch_group_t group;
@property CoreDataController* coreDataController;

@end

@implementation CoreDataControllerTestCase

#pragma mark - Set up

- (void)setUp {
    
    MLog();
    
    [super setUp];
    
    if ([APParseApplicationID length] == 0 || [APParseClientKey length] == 0) {
        ELog(@"It seems that you haven't set the correct Parse Keys");
        return;
    }
    
    [Parse setApplicationId:APParseApplicationID clientKey:APParseClientKey];

    self.coreDataController = [[CoreDataController alloc]init];
    
    // All tests will be conducted in background to supress the annoying Parse SDK warnings
    // complening that we are running long calls in the main thread.
    self.queue = dispatch_queue_create("CoreDataControllerTestCase", DISPATCH_QUEUE_CONCURRENT);
    self.group = dispatch_group_create();
    
    if (!self.coreDataController.authenticatedUser) {
    
        __block PFUser* authenticatedUser;
        dispatch_group_async(self.group, self.queue, ^{
            authenticatedUser = [PFUser currentUser];
            if (!authenticatedUser ) {
                authenticatedUser = [PFUser logInWithUsername:APUnitTestingParseUserName password:APUnitTestingParsePassword];
            }
            [self removeAllEntriesFromParse];
        });
        dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
        
        self.coreDataController.authenticatedUser = authenticatedUser;
    }
    
    // Starting fresh
    DLog(@"Reseting Cache");
    [self.coreDataController requestResetCache];
    while (self.coreDataController.isResetingTheCache && WAIT_PATIENTLY);
    
    /* Create the objects and its relationships
     
     ----------       --------
     | Author |<------| Book |
     ----------       --------
     
     */
    dispatch_group_async(self.group, self.queue, ^{
        DLog(@"Populating Parse with test objects");
        
        NSError* saveError = nil;
        PFObject* book = [PFObject objectWithClassName:@"Book"];
        book[@"name"] = kBookName1;
        book[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
        book[APObjectEntityNameAttributeName] = @"Book";
        book[APObjectUIDAttributeName] = [self createObjectUID];
        [book save:&saveError];
        
        PFObject* author = [PFObject objectWithClassName:@"Author"];
        author[@"name"] = kAuthorName;
        author[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
        author[APObjectEntityNameAttributeName] = @"Author";
        author[APObjectUIDAttributeName] = [self createObjectUID];
        [author save:&saveError];
        
//        // Relation (To-Many)
//        [[author relationForKey:@"books"] addObject:book];
//        [author save:&saveError];
        
        // Pointer (To-One)
        book[@"author"] = author;
        [book save:&saveError];
        
        if (saveError) {
            ELog(@"Error saving one of the parse objects: %@",saveError);
        }
    });
    
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    DLog(@"Set-up finished");
}


- (void) tearDown {
    
    MLog();
    
    dispatch_group_async(self.group, self.queue, ^{
        [self removeAllEntriesFromParse];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
//    [self.coreDataController requestResetCache];
//    while (self.coreDataController.isResetingTheCache &&
//           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
//    DLog(@"Cache is reset");
    
    self.coreDataController = nil;
    
   DLog(@"Tear-Down finished");
    
    [super tearDown];
}


#pragma mark - Tests

- (void) testCoreDataControllerIsNotNil {
    
    XCTAssertNotNil(self.coreDataController);
}


- (void) testChangeLoggedUser {
    
    XCTAssertNotNil([PFUser currentUser]);
    
    NSError* error;
    
    // Create a Author object under current logged user.
    Author* author1 = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.coreDataController.mainContext];
    author1.name = @"Author from User#1";
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    [PFUser logOut];
    
    // Switch to the second user
    __block PFUser* anotherUser;
    dispatch_group_async(self.group, self.queue, ^{
        anotherUser = [PFUser logInWithUsername:APUnitTestingParseUserName2 password:APUnitTestingParsePassword];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
   self.coreDataController.authenticatedUser = anotherUser;
    
    // The author created by the original user can't be found
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    fr.predicate = [NSPredicate predicateWithFormat:@"name == %@",@"Author from User#1"];
    NSArray* resultsFromAnotherUser = [self.coreDataController.mainContext executeFetchRequest:fr error:&error];
    XCTAssertTrue([resultsFromAnotherUser count] == 0);
    
    // Switch back to the original user
    [PFUser logOut];
    __block PFUser* originalUser;
    dispatch_group_async(self.group, self.queue, ^{
        originalUser = [PFUser logInWithUsername:APUnitTestingParseUserName password:APUnitTestingParsePassword];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    self.coreDataController.authenticatedUser = originalUser;
    
    // The author created by the original user should be present
    NSArray* resultsFromOriginalUser = [self.coreDataController.mainContext executeFetchRequest:fr error:&error];
    XCTAssertTrue([resultsFromOriginalUser count] == 1);
}


- (void) testExistingRelationshipBetweenBookAndAuthor {
    
    Author* fetchedAuthor = [self fetchAuthor];
    Book* fetchedBook = [self fetchBook];
    XCTAssertEqualObjects(fetchedBook.author, fetchedAuthor);
    
    Book* bookRelatedToFetchedAuthor = [fetchedAuthor.books anyObject];
    XCTAssertEqualObjects(bookRelatedToFetchedAuthor, fetchedBook);
}


- (void) testCountNumberOfAuthors {
    
    NSManagedObjectContext* context = self.coreDataController.mainContext;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSError* error;
    NSUInteger numberOfExistingAuthors = [context countForFetchRequest:fr error:&error];
    if(error){
        ELog(@"Fetching error: %@",error);
    }
    XCTAssertTrue(numberOfExistingAuthors == 1);
}


- (void) testCreateAuthorLocalyThenAddBook {
    
    Author* author1 = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.coreDataController.mainContext];
    author1.name = @"Author#1";
    
    Book* book = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.coreDataController.mainContext];
    book.name = @"Book#1";
    book.author = author1;
    
    NSError* error;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    //fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]];
    fr.predicate = [NSPredicate predicateWithFormat:@"author == %@",author1];
    NSArray* results = [self.coreDataController.mainContext executeFetchRequest:fr error:&error];
    XCTAssertNil(error);
    
    XCTAssertTrue([results count] == 1);
}


- (void) testChangeAuthorNameRemotelyAndMerge {
    
    Author* fetchedAuthor = [self fetchAuthor];
    XCTAssertTrue([fetchedAuthor.name isEqualToString:kAuthorName]);
    
    
    PFQuery* authorQuery = [PFQuery queryWithClassName:@"Author"];
    [authorQuery whereKey:@"name" containsString:kAuthorName];
    
    __block BOOL done = NO;
    __block PFObject* fetchedBookFromParse;
    [authorQuery getFirstObjectInBackgroundWithBlock:^(PFObject *object, NSError *error) {
        XCTAssertNil(error);
        fetchedBookFromParse = object;
        done = YES;
    }];
    while (done == NO && WAIT_PATIENTLY);
    
    fetchedBookFromParse[@"name"] = @"new name";
    
    done = NO;
    [fetchedBookFromParse saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        XCTAssertNil(error);
    }];
    
    // Sync and wait
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    XCTAssertTrue([fetchedAuthor.name isEqualToString:@"new name"]);
    
}

- (void) testAddAnotherBookToTheAuthor {
    
    Book* book2 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.coreDataController.mainContext];
    book2.name = kBookName2;
    
    Author* author = [self fetchAuthor];
    DLog(@"Current books from author %@: %@",author.name,author.books);
    book2.author = author;
    DLog(@"Current books from author %@: %@",author.name,author.books);
    
    NSError* error;
    BOOL success = [self.coreDataController saveMainContextAndRequestCacheSync:&error];
    XCTAssertTrue(success);
    XCTAssertNil(error);
    
    // Sync and wait untill it's finished
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    PFQuery* queryForBook2 = [PFQuery queryWithClassName:@"Book"];
    __block NSArray* results;
    dispatch_group_async(self.group, self.queue, ^{
        results = [queryForBook2 findObjects];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    XCTAssertTrue([results count] == 2);
    
    PFObject* object = [[results filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",kBookName2]]lastObject];
    XCTAssertNotEqual([object valueForKey:@"nome"], kBookName2);
}


- (void) testAddAnotherBookToTheAuthorRemotely {
    
    dispatch_group_async(self.group, self.queue, ^{
        
        NSError* error;
        PFObject* book2 = [PFObject objectWithClassName:@"Book"];
        book2[@"name"] = kBookName2;
        book2[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
        book2[APObjectEntityNameAttributeName] = @"Book";
        book2[APObjectUIDAttributeName] = [self createObjectUID];
        [book2 save:&error];
        
        PFObject* author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
//        [[author relationForKey:@"books"] addObject:book2];
//        [author save:&error];
        
        book2[@"author"] = author;
        [book2 save:&error];
        
        XCTAssertNil(error);
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    // Sync and wait
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName2];
    NSArray* bookResults = [self.coreDataController.mainContext executeFetchRequest:bookFetchRequest error:nil];
    XCTAssertTrue([bookResults count] == 1);
    
    Author* author = [self fetchAuthor];
    XCTAssertTrue([author.books count] == 2);
}


- (void) testAddBookToAnAuthorCreatedOnAnotherDevice {
   
    /*
     During tests an issue happend when executing the following steps:
     1) Create an author#1 on device#1
     2) Sync device#1
     3) Sync device#2 (the author#1 is synced on device#2)
     4) On device#2 add book#1 to author#1
     5) Sync device#2
     6) Sync device#1
     
     Issue: author#1 on device#1 doesn't get updated with book#1
     */
   
    Author* author1 = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.coreDataController.mainContext];
    author1.name = @"Author#1";
    
    NSError* error;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    dispatch_group_async(self.group, self.queue, ^{
        
        NSError* error;
        PFObject* book1 = [PFObject objectWithClassName:@"Book"];
        book1[@"name"] = @"Book#1";
        book1[APObjectEntityNameAttributeName] = @"Book";
        book1[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
        book1[APObjectUIDAttributeName] = [self createObjectUID];
        [book1 save:&error];
        
        PFQuery* authorQuery = [PFQuery queryWithClassName:@"Author"];
        [authorQuery whereKey:@"name" containsString:@"Author#1"];
        PFObject* author = [authorQuery getFirstObject];
        
//        [[author relationForKey:@"books"] addObject:book1];
//        [author save:&error];
        
        book1[@"author"] = author;
        [book1 save:&error];
        
        XCTAssertNil(error);
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    //[self.coreDataController.mainContext refreshObject:author1 mergeChanges:YES];
    
    //Lembrete: não esta recebendo updated na Notification que o Core Data Controller recebe.
    XCTAssertTrue([author1.books count] == 1);
    
    Book* relatedBook = [author1.books anyObject];
    XCTAssertTrue([relatedBook.name isEqualToString:@"Book#1"]);
}

/*
 Author has its relationship to books set with "Delete rule == Cascade", then
 once we delete it, the related books should be deleted as well.
 
 Be mindful that we don't actually delete the objects, instead we mark it as deleted (APObjectIsDeletedAttributeName)
 in order to allow other users to sync the change corretly.
 */
- (void) testRemoveTheAuthor {
    
    MLog();
    
    [self.coreDataController.mainContext deleteObject: [self fetchAuthor]];
    
    NSError* error;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    
    dispatch_group_async(self.group, self.queue, ^{
        [[[PFQuery queryWithClassName:@"Book"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusDeleted)]);
        }];
        
        [[[PFQuery queryWithClassName:@"Author"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusDeleted)]);
        }];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
}


/*
 Scenario:
 - A new book is included to the existing author, thus the author has now 2 books.
 - Book has its relationship to Author set with "Delete rule == Nullify"
 - We delete the new included book.
 
Expected Results:
 - The existing author should remain with only one book.
 - Be mindful that we don't actually delete the objects, instead we mark it as deleted (APObjectStatusDeleted)
   in order to allow other users to sync this change corretly afterwards
 */
- (void) testRemoveObjectFromToManyRelationship {
    
    // Create the second Book and Sync
    Book* book2 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.coreDataController.mainContext];
    book2.name = kBookName2;
    book2.author = [self fetchAuthor];
    DLog(@"New book created: %@",book2);
    
    // Save & sync
    NSError* error = nil;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    // Delete object, Save & Sync
    [self.coreDataController.mainContext deleteObject: book2];
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    // Verify that only one books is marked as delete at Parse
    dispatch_group_async(self.group, self.queue, ^{
        [[[PFQuery queryWithClassName:@"Book"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            
            if ([[obj valueForKeyPath:@"name"] isEqualToString:kBookName1]) {
                XCTAssertTrue([[obj valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusPopulated)]);
                
            } else if ([[obj valueForKeyPath:@"name"] isEqualToString:kBookName2]) {
                XCTAssertTrue([[obj valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusDeleted)]);
                
                PFObject* author = [obj objectForKey:@"author"];
                XCTAssertTrue([author isEqual:[NSNull null]]);
                
            } else {
                XCTFail();
            }
        }];
        
        // Verify that the author is not marked as delete at Parse
        [[[PFQuery queryWithClassName:@"Author"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectStatusAttributeName] isEqualToNumber:@(APObjectStatusPopulated)]);
        }];
        
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
}

/*
 Scenario:
 - 15Mbps down / 1Mbps up ADSL Connection
 - iPhone simulator 32bits
 
 I am aware that Unit Testing does not aim at performance measurements, but this give us a good idea how multithreading affects performance.
 Below are how much time each attempt took when using more than one thread to create 1000 objects at Parse (1st part of the test)
            Average time
 Threads    Simulator   iPhone 5
 1          6'14"       6'29"
 2          3'12"       3'34"
 3          2'09"       1'58"
 4          2'15"       1'46"   <---
 5          2'13"       2'03"
 10         1'58"       1'53"
 20         2'20"       2'01"
 30         2'15"       2'01"
 
 On average it took a little less time to download and sync all objcts to our disk cache, I guess due to better download speed perhaps.
 As no multithreadind is enable on sync process it took on average almost 6" to complete this step.
 
 ATTENTION: This test is disabled by default as it took a considerable amount of time to be completed, turn it on when necessary
*/
- (void) testCreateAThousandObjects_ENABLE_IT_ONDEMAND {
    
    /*
    NSDate* start = [NSDate date];
    
    NSUInteger const numberOfAuthorsToBeCreated = 1000;
    NSUInteger const numberOfThreads = 4;
    NSUInteger skip = numberOfAuthorsToBeCreated / numberOfThreads;
    
    __block NSUInteger numberOfAuthorsCreated;
    
    for (NSUInteger thread = 0; thread < numberOfThreads; thread++) {
        
        dispatch_group_async(self.group, self.queue, ^{
            NSError* saveError = nil;
            
            for (NSUInteger i = 0; i < skip; i++) {
                PFObject* author = [PFObject objectWithClassName:@"Author"];
                [author setValue:[NSString stringWithFormat:@"Author#%lu",(unsigned long) thread * skip + i] forKey:@"name"];
                author[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
                [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
                author[APObjectEntityNameAttributeName] = @"Author";
                [author save:&saveError];
                DLog(@"Author created: %@",[author valueForKeyPath:@"name"])
                XCTAssertNil(saveError);
            }
        });
    }
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    ALog(@"Seconds to create all objects: %f",[[NSDate date]timeIntervalSince1970] - [start timeIntervalSince1970]);
    
    __block NSError* countError;
    dispatch_group_async(self.group, self.queue, ^{
        PFQuery* query = [PFQuery queryWithClassName:@"Author"];
        numberOfAuthorsCreated = [query countObjects:&countError];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    XCTAssertNil(countError);
    XCTAssertTrue(numberOfAuthorsCreated == numberOfAuthorsToBeCreated + 1); //1 from the Setup
    
    // Sync and wait untill it's finished
    
    ALog(@"Start Syncing");
    NSDate* startSync = [NSDate date];
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    ALog(@"Seconds to sync all objects: %f",[[NSDate date]timeIntervalSince1970] - [startSync timeIntervalSince1970]);
    
    NSError* fetchError;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSUInteger numberOfAuthorsFetched = [self.coreDataController.mainContext countForFetchRequest:fr error:&fetchError];
    XCTAssertNil(fetchError);
    XCTAssertTrue(numberOfAuthorsFetched == numberOfAuthorsCreated);
     */
}

/*
 There's a huge bottleneck when syncing a considerable amount of objects with to-many relationships.
 The reason is that in order to keep consistency at all costs for each object fetched from the webservice (ie. Parse)
 it is necessary to create and execute another query for every relationship that it contains. That means we are able to
 fetch in batchs of up to 1000 objects (ie. Parse) but then multiples queries subsequentely are necessary for each object.
 That's how PFRelation (Parse) works, perhaps another baas provider might have a better solution but for now we need to put up
 with that. 
 There's an alternative for PFRelation, wich is the Array, we may read more about the differences at: https://www.parse.com/docs/relations_guide
 
 The intention of this test is to compare the two alternatives in terms of bandwidth, requests and time to finish.
 See the test testStressTestForToManyRelationshipsUsingParseArray for the counterpart of this test.
 
 ATTENTION: This test is disabled by default as it takes a considerable amount of time to be completed, turn it on when necessary
 */
- (void) testStressTestForToManyRelationshipsUsingParseRelation {

}

- (void) testStressTestForToManyRelationshipsUsingParseArray {
    
    NSUInteger const numberOfMagazinescostsToBeCreated = 100;
    
    __block NSUInteger numberOfMagazinesCreated;
    
    PFObject* author1 = [PFObject objectWithClassName:@"Author"];
    [author1 setValue:@"author1" forKey:@"name"];
    author1[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
    [author1 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author1[APObjectEntityNameAttributeName] = @"Author";
    
    PFObject* author2 = [PFObject objectWithClassName:@"Author"];
    [author2 setValue:@"author2" forKey:@"name"];
    author2[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
    [author2 setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
    author2[APObjectEntityNameAttributeName] = @"Author";
    
    dispatch_group_async(self.group, self.queue, ^{
        NSError* authorSaveError = nil;
        [author1 save:&authorSaveError];
        [author2 save:&authorSaveError];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    PFRelation* magazines1 = [author2 relationForKey:@"magazines"];
    PFRelation* magazines2 = [author2 relationForKey:@"magazines"];
    
    dispatch_group_async(self.group, self.queue, ^{
        
        for (NSUInteger i = 0; i < numberOfMagazinescostsToBeCreated; i++) {
            PFObject* magazine = [PFObject objectWithClassName:@"Magazine"];
            [magazine setValue:[NSString stringWithFormat:@"Magaznine#%lu",(unsigned long) i] forKey:@"name"];
            magazine[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
            [magazine setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
            magazine[APObjectEntityNameAttributeName] = @"Magazine";
            [magazine addObject:author1 forKey:@"authors"];
            [magazine addObject:author2 forKey:@"authors"];
            
            NSError* saveError = nil;
            [magazine save:&saveError];
            XCTAssertNil(saveError);
            DLog(@"Magazine created: %@",[magazine valueForKeyPath:@"name"])
            
            [magazines1 addObject:magazine];
            [magazines2 addObject:magazine];
        }
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    dispatch_group_async(self.group, self.queue, ^{
        NSError* authorSaveError = nil;
        [author1 save:&authorSaveError];
        [author2 save:&authorSaveError];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    __block NSError* countError;
    dispatch_group_async(self.group, self.queue, ^{
        PFQuery* query = [PFQuery queryWithClassName:@"Magazine"];
        numberOfMagazinesCreated = [query countObjects:&countError];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    ALog(@"Start Syncing");
    NSDate* startSync = [NSDate date];
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    ALog(@"Seconds to sync all objects: %f",[[NSDate date]timeIntervalSince1970] - [startSync timeIntervalSince1970]);
    
    //Check what has been created on the local core data store
    
    NSError* fetchError;
    NSFetchRequest* frForMagzine = [NSFetchRequest fetchRequestWithEntityName:@"Magazine"];
    NSUInteger numberOfMagazinesFetched = [self.coreDataController.mainContext countForFetchRequest:frForMagzine error:&fetchError];
    XCTAssertNil(fetchError);
    XCTAssertTrue(numberOfMagazinesFetched == numberOfMagazinesCreated);
    
    NSFetchRequest* frForAuthor1 = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    frForAuthor1.predicate = [NSPredicate predicateWithFormat:@"name == %@",@"author1"];
    NSArray* authors1 = [self.coreDataController.mainContext executeFetchRequest:frForAuthor1 error:&fetchError];
    XCTAssertNil(fetchError);
    XCTAssertTrue([authors1 count] == 1);
    Author* fetchedAuthor1 = [authors1 lastObject];
    XCTAssertTrue([fetchedAuthor1.magazines count] == numberOfMagazinesCreated);
    
    NSFetchRequest* frForAuthor2 = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    frForAuthor2.predicate = [NSPredicate predicateWithFormat:@"name == %@",@"author2"];
    NSArray* authors2 = [self.coreDataController.mainContext executeFetchRequest:frForAuthor2 error:&fetchError];
    XCTAssertNil(fetchError);
    XCTAssertTrue([authors2 count] == 1);
    Author* fetchedAuthor2 = [authors2 lastObject];
    XCTAssertTrue([fetchedAuthor2.magazines count] == numberOfMagazinesCreated);
}


- (void) testSaveBinary {
    
    MLog();
    Book* book = [self fetchBook];
    // 495KB JPG Image sample image
    NSURL *imageURL = [[[NSBundle bundleForClass:[self class]]bundleURL] URLByAppendingPathComponent:@"Sample_495KB.jpg"];
    NSData* bookCoverData = [NSData dataWithContentsOfURL:imageURL];
    XCTAssertNotNil(bookCoverData);
    
    book.picture = bookCoverData;
    book.name = kBookName2;
    NSError* savingError;
    [self.coreDataController.mainContext save:&savingError];
    
    [self.coreDataController.mainContext refreshObject:book mergeChanges:NO];
    
    // Check is the updated book has been saved to disk properly.
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName2];
    NSArray* bookResults = [self.coreDataController.mainContext executeFetchRequest:bookFetchRequest error:nil];
    Book* bookReFetched = [bookResults lastObject];
    XCTAssertNotNil(bookReFetched.picture);
}


/*
 Author has a attribute named photo which is a transformable property.
 The accessors are located in Author+Transformable.h and will transform it to NSData before send it to Core Data
 */
- (void) testSaveImageUsingTransformableAttribute {
    
    Author* author = [self fetchAuthor];
    NSURL *imageURL = [[[NSBundle bundleForClass:[self class]]bundleURL] URLByAppendingPathComponent:@"JRR_Tolkien.jpg"];
    NSData* authorPhotoData = [NSData dataWithContentsOfURL:imageURL];
    XCTAssertNotNil(authorPhotoData);
    
    author.photo = [UIImage imageWithData:authorPhotoData];
    NSError* savingError;
    [self.coreDataController.mainContext save:&savingError];
    
    // start sync and wait
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    // Recreate Coredata stack
    [self.coreDataController.mainContext refreshObject:author mergeChanges:NO];
    
    // Check is the updated book has been saved to disk properly.
    Author* authorReFetched = [self fetchAuthor];
    XCTAssertTrue([authorReFetched.photo isKindOfClass:[UIImage class]]);
}


- (void) testSortDescriptors {
    
    NSArray* sortedNames = @[@"Author#10",@"Author#11",@"Author#12",@"Author#13"];
    
    dispatch_group_async(self.group, self.queue, ^{
        NSError* saveError = nil;
        for (NSUInteger i = 0; i < [sortedNames count]; i++) {
            PFObject* author = [PFObject objectWithClassName:@"Author"];
            [author setValue:sortedNames[i] forKey:@"name"];
            author[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
            [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
            author[APObjectEntityNameAttributeName] = @"Author";
            [author save:&saveError];
            DLog(@"Author created: %@",[author valueForKeyPath:@"name"])
            XCTAssertNil(saveError);
        }
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    // Remove the first one created at SetUp
    [self.coreDataController.mainContext deleteObject:[self fetchAuthor]];
    
    NSError* fetchError;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:NO]];
    NSArray* fetchedAuthors = [self.coreDataController.mainContext executeFetchRequest:fr error:&fetchError];
    XCTAssertNil(fetchError);
    
     for (NSUInteger i = 0; i < [sortedNames count]; i++) {
         XCTAssertTrue([[fetchedAuthors[i] valueForKey:@"name"] isEqualToString:sortedNames[[sortedNames count] - i - 1]]);
     }
}


- (void) testFetchRequestOffsetAndLimit {
    
    NSArray* sortedNames = @[@"Author#10",@"Author#11",@"Author#12",@"Author#13"];
    
    dispatch_group_async(self.group, self.queue, ^{
        NSError* saveError = nil;
        for (NSUInteger i = 0; i < [sortedNames count]; i++) {
            PFObject* author = [PFObject objectWithClassName:@"Author"];
            [author setValue:sortedNames[i] forKey:@"name"];
            author[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
            [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
            author[APObjectEntityNameAttributeName] = @"Author";
            [author save:&saveError];
            DLog(@"Author created: %@",[author valueForKeyPath:@"name"])
            XCTAssertNil(saveError);
        }
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && WAIT_PATIENTLY);
    
    // Remove the first one created at SetUp
    [self.coreDataController.mainContext deleteObject:[self fetchAuthor]];
    
    NSError* saveError = nil;
    [self.coreDataController.mainContext save:&saveError];
    XCTAssertNil(saveError);
    
    NSError* fetchError;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    [fr setFetchLimit: 1];
    fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]];
    
    for (NSUInteger i = 0; i < [sortedNames count]; i++) {
        [fr setFetchOffset: i];
        NSArray* results = [self.coreDataController.mainContext executeFetchRequest:fr error:&fetchError];
        XCTAssertTrue([results count] == 1);
        
        Author* fetchedAuthor = [results lastObject];
        XCTAssertNil(fetchError);
        XCTAssertTrue([fetchedAuthor.name isEqualToString:sortedNames[i]]);
    }
}


- (void) testFetchUsing_IN_inThePredicate {
 
    /* 
     There's been a bug in the way APDiskCache translates the incoming predicate 
     replacing the objectIDs to the equivalente ones in the cache store. However
     it's not working as exepected when a predicated contains a IN statement.
     Using the test to isolate e fix the issue.
     */
    
    // Managed Objects
    Author* author1 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Author class]) inManagedObjectContext:self.coreDataController.mainContext];
    author1.name = @"Author#1";
    
    Author* author2 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Author class]) inManagedObjectContext:self.coreDataController.mainContext];
    author2.name = @"Author#2";
    
    Author* author3 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Author class]) inManagedObjectContext:self.coreDataController.mainContext];
    author3.name = @"Author#3";
    
    Magazine* mag1 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Magazine class]) inManagedObjectContext:self.coreDataController.mainContext];
    mag1.name = @"Mag#1";
    
    Magazine* mag2 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Magazine class]) inManagedObjectContext:self.coreDataController.mainContext];
    mag2.name = @"Mag#2";
    
    Magazine* mag3 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Magazine class]) inManagedObjectContext:self.coreDataController.mainContext];
    mag3.name = @"Mag#3";

    Publisher* pub1 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Publisher class]) inManagedObjectContext:self.coreDataController.mainContext];
    pub1.name = @"Publisher#1";
    
    Publisher* pub2 = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Publisher class]) inManagedObjectContext:self.coreDataController.mainContext];
    pub2.name = @"Publisher#2";
    
    // Relations
    [author1 addMagazinesObject:mag1];
    [author2 addMagazinesObject:mag2];
    [author3 addMagazinesObject:mag3];
    
    [pub1 addMagazinesObject:mag1];
    [pub1 addMagazinesObject:mag2];
    [pub2 addMagazinesObject:mag3];
    
    NSError* error = nil;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass([Author class])];
    fr.predicate = [NSPredicate predicateWithFormat:@"ANY magazines IN %@",pub1.magazines];
    NSArray* results = [self.coreDataController.mainContext executeFetchRequest:fr error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(results);
    XCTAssertTrue([results count] == 2);
    XCTAssertTrue([[results firstObject]isKindOfClass:[Author class]]);
    XCTAssertTrue([[results lastObject]isKindOfClass:[Author class]]);
}


- (void) testInheritanceMergeLocalToRemote {
    
    EBook* newEBook = [NSEntityDescription insertNewObjectForEntityForName:@"EBook" inManagedObjectContext:self.coreDataController.mainContext];
    newEBook.name = @"eBook#1";
    newEBook.format = @"PDF";
    
    // Create a local Author, mark is as "dirty" and set the objectUID with the predefined prefix
    Author* author = [self fetchAuthor];
    [author addBooksObject:newEBook];
    
    __block NSError* error = nil;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    PFQuery* queryForEBook = [PFQuery queryWithClassName:@"Book"];
    [queryForEBook whereKey:@"name" equalTo:@"eBook#1"];
    [queryForEBook whereKey:@"format" equalTo:@"PDF"];
    
    __block PFObject* parseEBook;
    __block PFObject* parseAuthor;
    dispatch_group_async(self.group, self.queue, ^{
        parseEBook = [queryForEBook getFirstObject:&error];
        parseAuthor = parseEBook[@"author"];
        [parseAuthor fetchIfNeeded:&error];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    XCTAssertNil(error);
    XCTAssertTrue([parseEBook[APObjectEntityNameAttributeName]isEqualToString:@"EBook"]);
    XCTAssertTrue([parseAuthor[APObjectEntityNameAttributeName]isEqualToString:@"Author"]);
}


- (void) testInheritanceRemoteToLocal {
    
    __block NSError* error;
    NSString* ebookName = @"eBook#1";
    NSString* ebookFormat = @"PDF";
    
    dispatch_group_async(self.group, self.queue, ^{
        
        PFObject* newEBook = [PFObject objectWithClassName:@"Book"];
        newEBook[@"name"] = ebookName;
        newEBook[@"format"] = ebookFormat;
        newEBook[APObjectEntityNameAttributeName] = @"EBook";
        newEBook[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
        newEBook[APObjectUIDAttributeName] = [self createObjectUID];
        [newEBook save:&error];
        
        PFObject* author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
//        [[author relationForKey:@"books"] addObject:newEBook];
//        [author save:&error];
        
        newEBook[@"author"] = author;
        [newEBook save:&error];
        
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    NSFetchRequest* eBookFr = [NSFetchRequest fetchRequestWithEntityName:@"EBook"];
    eBookFr.predicate = [NSPredicate predicateWithFormat:@"name == %@ AND format == %@",ebookName,ebookFormat];
    NSArray* results = [self.coreDataController.mainContext executeFetchRequest:eBookFr error:&error];
    EBook* eBook = [results lastObject];
    XCTAssertNil(error);
    XCTAssertNotNil(eBook);
    XCTAssertTrue([eBook.name isEqualToString:ebookName]);
    XCTAssertTrue([eBook.format isEqualToString:ebookFormat]);
    
    NSFetchRequest* AuthorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    eBookFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kAuthorName];
    NSArray* authors = [self.coreDataController.mainContext executeFetchRequest:AuthorFr error:&error];
    Author* author = [authors lastObject];
    XCTAssertNil(error);
    XCTAssertNotNil(author);
    XCTAssertTrue([author.name isEqualToString:kAuthorName]);
    [author.books enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
        if ([[obj valueForKey:@"name"] isEqualToString:ebookName]) {
            XCTAssertTrue([obj isKindOfClass:[EBook class]]);
        } else {
            XCTAssertTrue([obj isKindOfClass:[Book class]]);
        }
    }];
    
}


- (void) testInheritanceRemoteToLocalFeetchingParentEntity {
    
    __block NSError* error;
    NSString* ebookName = @"eBook#1";
    NSString* ebookFormat = @"PDF";
    
    dispatch_group_async(self.group, self.queue, ^{
        
        PFObject* newEBook = [PFObject objectWithClassName:@"Book"];
        newEBook[@"name"] = ebookName;
        newEBook[@"format"] = ebookFormat;
        newEBook[APObjectEntityNameAttributeName] = @"EBook";
        newEBook[APObjectStatusAttributeName] = @(APObjectStatusPopulated);
        newEBook[APObjectUIDAttributeName] = [self createObjectUID];
        [newEBook save:&error];
        
        PFObject* author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
//        [[author relationForKey:@"books"] addObject:newEBook];
//        [author save:&error];
        
        newEBook[@"author"] = author;
        [newEBook save:&error];
        
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    NSFetchRequest* eBookFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
    eBookFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",ebookName,ebookFormat];
    NSArray* results = [self.coreDataController.mainContext executeFetchRequest:eBookFr error:&error];
    XCTAssertNil(error);
   
    NSManagedObject* object = [results lastObject];
    
    XCTAssertNotNil(object);
    XCTAssertTrue ([object isKindOfClass:[EBook class]]);
    
    EBook* eBook = (EBook*) object;
    XCTAssertTrue([eBook.name isEqualToString:ebookName]);
    XCTAssertTrue([eBook.format isEqualToString:ebookFormat]);
    
    NSFetchRequest* AuthorFr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    eBookFr.predicate = [NSPredicate predicateWithFormat:@"name == %@",kAuthorName];
    NSArray* authors = [self.coreDataController.mainContext executeFetchRequest:AuthorFr error:&error];
    Author* author = [authors lastObject];
    XCTAssertNil(error);
    XCTAssertNotNil(author);
    XCTAssertTrue([author.name isEqualToString:kAuthorName]);
    [author.books enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
        if ([[obj valueForKey:@"name"] isEqualToString:ebookName]) {
            XCTAssertTrue([obj isKindOfClass:[EBook class]]);
        } else {
            XCTAssertTrue([obj isKindOfClass:[Book class]]);
        }
    }];
    
}


- (void) testFetchingDoesNotCauseManagedObjectIsUpdated {
    /*
     Background - An issue was observed when fetching objects from the APIncrementalStore, it was causing
     the faulted in fetched objects to change their property isUpdated to YES. 
     The result was that after saving the context those objects were marked as dirty and 
     subsequently queued to be synced even without any change.
     Solution - That was a bug with the APIncrementalStore class, fixed checking the property 
     shouldRefreshRefetchedObjects from the incoming fetch request before populating already faulted in
     objects.
     */
    
    // Fetch
    Book* book = [self fetchBook];
    XCTAssertFalse([book isUpdated]);
    
    // Fault in
    [book willAccessValueForKey:nil];
     XCTAssertFalse([book isUpdated]);
    
    // Fetch again
    book = [self fetchBook];
    XCTAssertFalse([book isUpdated]);
    
    // FetchRequest has  setShouldRefreshRefetchedObjects = YES;
    book = [self fetchBookRefreshObject];
    XCTAssertTrue([book isUpdated]);
}


- (void) testManagedObjectFromChildContext {
    
    NSManagedObjectContext* childContext = [[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];
    childContext.parentContext = [self.coreDataController mainContext];
    Book* childBook = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:childContext];
    childBook.name = @"child book";
    
    NSError* error = nil;
    if (![childContext save:&error]){
        XCTAssert(NO);
    } else {
        Book* mainBook = (Book*) [self.coreDataController.mainContext objectWithID:[childBook objectID]];
        XCTAssert([childBook.name isEqualToString:mainBook.name]);
    }
}


- (void) testAssyncFetching {
    
    /* Assynchronous Fetching only available in iOS 8 onward */
    
    NSString *reqSysVer = @"8";
    NSString *currSysVer = [[UIDevice currentDevice] systemVersion];
    if ([currSysVer compare:reqSysVer options:NSNumericSearch] != NSOrderedAscending) {
        
        XCTestExpectation* expectation = [self expectationWithDescription:@"Book has been found"];
        
        NSFetchRequest* bookFr = [NSFetchRequest fetchRequestWithEntityName:@"Book"];
        
        NSAsynchronousFetchRequest *asyncBookFr = [[NSAsynchronousFetchRequest alloc]initWithFetchRequest:bookFr completionBlock:^(NSAsynchronousFetchResult *result) {
            if(result.finalResult) {
                Book* book = [result.finalResult lastObject];
                XCTAssert([book.name isEqualToString:kBookName1]);
            } else {
                XCTAssert(NO);
            }
            
            [expectation fulfill];
        }];
        
        NSError* error = nil;
        [self.coreDataController.mainContext executeRequest:asyncBookFr error:&error];
        XCTAssertNil(error);
        
        [self waitForExpectationsWithTimeout:3.0 handler:nil];
    }
}


#pragma mark - Support Methods

- (Book*) fetchBook {
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName1];
    NSArray* bookResults = [self.coreDataController.mainContext executeFetchRequest:bookFetchRequest error:nil];
    return [bookResults lastObject];
}

- (Book*) fetchBookRefreshObject {
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName1];
    [bookFetchRequest setShouldRefreshRefetchedObjects:YES];
    NSArray* bookResults = [self.coreDataController.mainContext executeFetchRequest:bookFetchRequest error:nil];
    return [bookResults lastObject];
}

- (Author*) fetchAuthor {
    NSFetchRequest* authorFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Author"];
    authorFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kAuthorName];
    NSArray* authorResults = [self.coreDataController.mainContext executeFetchRequest:authorFetchRequest error:nil];
    return [authorResults lastObject];
}


- (void) removeAllEntriesFromParse {
    
    MLog();
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Author"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Book"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Page"]];
    [self removeAllObjectsFromParseQuery:[PFQuery queryWithClassName:@"Magazine"]];
}


- (void) removeAllObjectsFromParseQuery:(PFQuery*) query {
    
    // Delete parse object block
    void (^deleteAllObjects)(PFObject*, NSUInteger, BOOL*) = ^(PFObject* obj, NSUInteger idx, BOOL *stop) {
        NSError* error;
        [obj delete:&error];
        if (!error) {
            DLog(@"Object of class: %@ was deleted from Parse",[obj parseClassName]);
        } else {
            ELog(@"Object of class: %@ was not deleted from Parse - error: %@",[obj parseClassName],error);
        }
    };
    
    // count how many objects we have to remove
    // default parse limit of objects per query is 100, can be set to 1000.
    // let's maintain the default.
    NSError* error;
    NSUInteger numberOfObjectsToDelete = [query countObjects:&error];
    if (error) {
        ELog(@"Error counting objects for query for class: %@",query.parseClassName);
        return;
    }
    
    NSUInteger const step = 100;
    NSUInteger deleted = 0;
    while (deleted < numberOfObjectsToDelete) {
        [[query findObjects]enumerateObjectsUsingBlock:deleteAllObjects];
        deleted += step;
    }
}

- (NSString*) createObjectUID {
    
    NSString* objectUID = nil;
    CFUUIDRef uuid = CFUUIDCreate(CFAllocatorGetDefault());
    objectUID = (__bridge_transfer NSString *)CFUUIDCreateString(CFAllocatorGetDefault(), uuid);
    CFRelease(uuid);
    return objectUID;
}

@end
