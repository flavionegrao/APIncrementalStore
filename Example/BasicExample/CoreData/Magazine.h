//
//  Magazine.h
//  Example
//
//  Created by Flavio Negrão Torres on 6/4/14.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Author, Page;

@interface Magazine : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) NSSet *pages;
@property (nonatomic, retain) Author *authors;
@end

@interface Magazine (CoreDataGeneratedAccessors)

- (void)addPagesObject:(Page *)value;
- (void)removePagesObject:(Page *)value;
- (void)addPages:(NSSet *)values;
- (void)removePages:(NSSet *)values;

@end
