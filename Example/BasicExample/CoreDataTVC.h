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

#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

/**
 If the SubClass implementes searching via searchDisplayController
 it must implement this protocol
 */
@protocol CoreDataSearching;


/**
 This class mostly just copies the code from NSFetchedResultsController's documentation page
 into a subclass of UITableViewController.
 
 Just subclass this and set the fetchedResultsController.
 The only UITableViewDataSource method you'll HAVE to implement is tableView:cellForRowAtIndexPath:.
 And you can use the NSFetchedResultsController method objectAtIndexPath: to do it.
 
 If you want to have a searchDisplayController, subclass needs to implement:
 - (NSFetchedResultsController*) searchFRC
 
 Remember that once you create an NSFetchedResultsController, you CANNOT modify its @propertys.
 If you want new fetch parameters (predicate, sorting, etc.),
 create a NEW NSFetchedResultsController and set this class's fetchedResultsController @property again.
 */
@interface CoreDataTVC : UIViewController <UITableViewDataSource,UITableViewDelegate, NSFetchedResultsControllerDelegate>


/**
 This class used to be a UITableViewControler. 
 Now is has been changed to UIViewController and this outlet holds the reference
 to the tableview configured via storyboard.
 */
@property (strong, nonatomic) IBOutlet UITableView *tableView;


/**
 The controller (this class fetches nothing if this is not set).
 When this property is set, this class will set its delegate to itself and
 performfetch on it.
 */
@property (strong, nonatomic) NSFetchedResultsController *frc;


/**
 When the tableview has a searchBarController implemented, it ussualy has two
 NSFetchedResutCOntroller, one for the normal tableView and other for the searchTableView.
 @param tableview The tableview that you want to know what is the FRC associated
 */
- (NSFetchedResultsController *)frcForTableView:(UITableView *)tableView;



/**
 This property is set to YES when data has arrived from the frc performFetch.
 Since fetching is assyncronous now you may want to override the setFrcDidFinishPerformingFetch
 to perform additional actions on subclasses.
 */
@property (assign,nonatomic) BOOL frcDidFinishPerformingFetch;


@property (nonatomic,strong) NSIndexPath* currentSelectionIndexPath;


#pragma mark - UISearchDisplayController

/**
 Removes UITableViewCell Line separator for empty searches
 default is YES
 */
@property (nonatomic, assign) BOOL noCellSeparatorOnEmptySearch;

@property (nonatomic, assign) BOOL hideSearchBar;

@end



@protocol CoreDataSearching

/**
 If the subclass is implementing Searching it needs to implement
 this method. It creates the SearchFRC used by this class to filter the
 contentes of the searchDisplayController.
 When creating the FRC use the following NSStrings to implement the predicate
 self.searchDisplayController.searchBar.selectedScopeButtonIndex
 self.searchDisplayController.searchBar.text
 */
- (NSFetchedResultsController*) createSearchFRC;

/**
 If you want to change the keyboard for a given
 searchScope (button below searchBar) return what kind of keyboard
 the view should present
 */
- (UIKeyboardType) keyboardTypeForSearchFilterForScope: (NSInteger) selectedScopeButtonIndex;


@end
