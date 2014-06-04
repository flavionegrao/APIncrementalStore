//
//  Magazine.h
//  Tests
//
//  Created by Flavio Negrão Torres on 6/4/14.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Author, Page;

@interface Magazine : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) NSSet *authors;
@property (nonatomic, retain) NSSet *pages;
@end

@interface Magazine (CoreDataGeneratedAccessors)

- (void)addAuthorsObject:(Author *)value;
- (void)removeAuthorsObject:(Author *)value;
- (void)addAuthors:(NSSet *)values;
- (void)removeAuthors:(NSSet *)values;

- (void)addPagesObject:(Page *)value;
- (void)removePagesObject:(Page *)value;
- (void)addPages:(NSSet *)values;
- (void)removePages:(NSSet *)values;

@end
