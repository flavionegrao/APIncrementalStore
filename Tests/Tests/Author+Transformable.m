//
//  Author+Transformable.m
//  APIncrementalStore
//
//  Created by Flavio Negrão Torres on 4/15/14.
//  Copyright (c) 2014 Flavio Negrão Torres. All rights reserved.
//

#import "Author+Transformable.h"


@implementation Author (Transformable)

- (void)setPhoto:(id)photo {
    
    [self willChangeValueForKey:@"photo"];
        NSData *data = UIImagePNGRepresentation(photo);
        [self setPrimitiveValue:data forKey:@"photo"];
    [self didChangeValueForKey:@"photo"];
}


- (UIImage*)photo {
    
    [self willAccessValueForKey:@"photo"];
        UIImage *image = [UIImage imageWithData:[self primitiveValueForKey:@"photo"]];
    [self didAccessValueForKey:@"photo"];
    return image;
}

@end
