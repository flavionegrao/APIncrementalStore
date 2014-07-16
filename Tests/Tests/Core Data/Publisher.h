//
//  Publisher.h
//  Tests
//
//  Created by Flavio Negrão Torres on 7/15/14.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Magazine;

@interface Publisher : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) NSSet *magazines;
@end

@interface Publisher (CoreDataGeneratedAccessors)

- (void)addMagazinesObject:(Magazine *)value;
- (void)removeMagazinesObject:(Magazine *)value;
- (void)addMagazines:(NSSet *)values;
- (void)removeMagazines:(NSSet *)values;

@end
