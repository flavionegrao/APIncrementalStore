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

#import "UnitTestingCommon.h"

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
    while (self.coreDataController.isResetingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    /* Create the objects and its relationships
     
     ----------       --------
     | Author |<---->>| Book |
     ----------       --------
     
     */
    dispatch_group_async(self.group, self.queue, ^{
        DLog(@"Populating Parse with test objects");
        
        NSError* saveError = nil;
        PFObject* book = [PFObject objectWithClassName:@"Book"];
        book[@"name"] = kBookName1;
        book[APObjectIsDeletedAttributeName] = @NO;
        book[APObjectEntityNameAttributeName] = @"Book";
        book[APObjectUIDAttributeName] = [self createObjectUID];
        [book save:&saveError];
        
        PFObject* author = [PFObject objectWithClassName:@"Author"];
        author[@"name"] = kAuthorName;
        author[APObjectIsDeletedAttributeName] = @NO;
        author[APObjectEntityNameAttributeName] = @"Author";
        author[APObjectUIDAttributeName] = [self createObjectUID];
        [author save:&saveError];
        
        // Relation (To-Many)
        [[author relationForKey:@"books"] addObject:book];
        [author save:&saveError];
        
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
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    DLog(@"Set-up finished");
}


- (void) tearDown {
    
    MLog();
    
    dispatch_group_async(self.group, self.queue, ^{
        [self removeAllEntriesFromParse];
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    [self.coreDataController requestResetCache];
    while (self.coreDataController.isResetingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    DLog(@"Cache is reset");
    
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
        book2[APObjectIsDeletedAttributeName] = @NO;
        book2 [APObjectEntityNameAttributeName] = @"Book";
        book2[APObjectUIDAttributeName] = [self createObjectUID];
        [book2 save:&error];
        
        PFObject* author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
        [[author relationForKey:@"books"] addObject:book2];
        [author save:&error];
        
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

- (void) testAddBookToAnAuthorCreatedOnAnotherDevice {
   
    Author* author1 = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:self.coreDataController.mainContext];
    author1.name = @"Author#1";
    
    NSError* error;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    dispatch_group_async(self.group, self.queue, ^{
        
        NSError* error;
        PFObject* book1 = [PFObject objectWithClassName:@"Book"];
        book1[@"name"] = @"Book#1";
        book1[APObjectEntityNameAttributeName] = @"Book";
        book1[APObjectIsDeletedAttributeName] = @NO;
        book1[APObjectUIDAttributeName] = [self createObjectUID];
        [book1 save:&error];
        
        PFQuery* authorQuery = [PFQuery queryWithClassName:@"Author"];
        [authorQuery whereKey:@"name" containsString:@"Author#1"];
        PFObject* author = [authorQuery getFirstObject];
        
        [[author relationForKey:@"books"] addObject:book1];
        [author save:&error];
        
        book1[@"author"] = author;
        [book1 save:&error];
        
        XCTAssertNil(error);
    });
    dispatch_group_wait(self.group, DISPATCH_TIME_FOREVER);
    
    // Sync and wait untill it's finished
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
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
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    dispatch_group_async(self.group, self.queue, ^{
        [[[PFQuery queryWithClassName:@"Book"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]);
        }];
        
        [[[PFQuery queryWithClassName:@"Author"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]);
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
 - Be mindful that we don't actually delete the objects, instead we mark it as deleted (APObjectIsDeleted)
   in order to allow other users to sync this change corretly afterwards
 */
- (void) testRemoveObjectFromToManyRelationship {
    
     MLog();
    
    // Create the second Book and Sync
    DLog(@"Creating new book");
    Book* book2 = [NSEntityDescription insertNewObjectForEntityForName:@"Book" inManagedObjectContext:self.coreDataController.mainContext];
    book2.name = kBookName2;
    book2.author = [self fetchAuthor];
    DLog(@"New book created: %@",book2);
    
    NSError* error = nil;
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
    
    [self.coreDataController.mainContext deleteObject: book2];
    
    [self.coreDataController.mainContext save:&error];
    XCTAssertNil(error);
    
    [self.coreDataController requestSyncCache];
    while (self.coreDataController.isSyncingTheCache && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
    
    // Verify that only one books is marked as delete at Parse
    dispatch_group_async(self.group, self.queue, ^{
        [[[PFQuery queryWithClassName:@"Book"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            
            if ([[obj valueForKeyPath:@"name"] isEqualToString:kBookName1]) {
                XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@NO]);
                
            } else if ([[obj valueForKeyPath:@"name"] isEqualToString:kBookName2]) {
                XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@YES]);
                
                PFObject* author = [obj objectForKey:@"author"];
                XCTAssertTrue([author isEqual:[NSNull null]]);
                
            } else {
                XCTFail();
            }
        }];
        
        // Verify that the author is not marked as delete at Parse
        [[[PFQuery queryWithClassName:@"Author"]findObjects]enumerateObjectsUsingBlock:^(PFObject* obj, NSUInteger idx, BOOL *stop) {
            XCTAssertTrue([[obj valueForKey:APObjectIsDeletedAttributeName] isEqualToNumber:@NO]);
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
                [author setValue:@NO forKey:APObjectIsDeletedAttributeName];
                [author setValue:[self createObjectUID] forKey:APObjectUIDAttributeName];
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
    
    // Recreate Coredata stack
    self.coreDataController = nil;
    self.coreDataController = [[CoreDataController alloc]init];
    self.coreDataController.authenticatedUser = [PFUser currentUser];
    
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
    self.coreDataController = nil;
    self.coreDataController = [[CoreDataController alloc]init];
    self.coreDataController.authenticatedUser = [PFUser currentUser];
    
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
            [author setValue:@NO forKey:APObjectIsDeletedAttributeName];
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
        newEBook[APObjectIsDeletedAttributeName] = @NO;
        newEBook[APObjectUIDAttributeName] = [self createObjectUID];
        [newEBook save:&error];
        
        PFObject* author = [[PFQuery queryWithClassName:@"Author"]getFirstObject];
        [[author relationForKey:@"books"] addObject:newEBook];
        [author save:&error];
        
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


#pragma mark - Support Methods

- (Book*) fetchBook {
    NSFetchRequest* bookFetchRequest = [[NSFetchRequest alloc]initWithEntityName:@"Book"];
    bookFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name = %@",kBookName1];
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
