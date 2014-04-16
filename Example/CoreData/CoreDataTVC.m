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


#import "CoreDataTVC.h"
#import "APIncrementalStore.h"
#import "NSLogEmoji.h"


@interface CoreDataTVC() 

/**
 Turn this on before making any changes in the managed object context that
 are a one-for-one result of the user manipulating rows directly in the table view.
 Such changes cause the context to report them (after a brief delay),
 and normally our fetchedResultsController would then try to update the table,
 but that is unnecessary because the changes were made in the table already (by the usuario)
 so the fetchedResultsController has nothing to do and needs to ignore those reports.
 Turn this back off after the usuario has finished the change.
 Note that the effect of setting this to NO actually gets delayed slightly
 so as to ignore previously-posted, but not-yet-processed context-changed notifications,
 therefore it is fine to set this to YES at the beginning of, e.g., tableView:moveRowAtIndexPath:toIndexPath:,
 and then set it back to NO at the end of your implementation of that method.
 It is not necessary (in fact, not desirable) to set this during row deletion or insertion
 (but definitely for row moves).
 */
@property (nonatomic) BOOL suspendAutomaticTrackingOfChangesInManagedObjectContext;

/**
 Causes the fetchedResultsController to refetch the data.
 You almost certainly never need to call this.
 The NSFetchedResultsController class observes the context
 (so if the objects in the context change, you do not need to call performFetch
 since the NSFetchedResultsController will notice and update the table automatically).
 This will also automatically be called if you change the fetchedResultsController @property.
 */
- (void)performFetch:(NSFetchedResultsController*) frc;

/**
 Este FRC é usado quando o usuário esta usando o SearchBar
 When this property is set, this class will set its delegate to itself and
 performfetch on it.
 */
@property (strong,nonatomic) NSFetchedResultsController* searchFRC;


@end

@implementation CoreDataTVC


#pragma mark - View LifeCycle

- (void) awakeFromNib {
    [super awakeFromNib];
    [self configView];
}


- (void) configView {
    
    //defaults
    _noCellSeparatorOnEmptySearch = YES;
    _frcDidFinishPerformingFetch = NO;
    _hideSearchBar = NO;
    
    //TODO Fix it better
    // http://stackoverflow.com/questions/19214286/having-a-zombie-issue-on-uisearchdisplaycontroller/20522914#20522914
    [self.searchDisplayController setActive:YES];
    [self.searchDisplayController setActive:NO];
}


- (void) viewDidLoad {
    
    [super viewDidLoad];
    self.searchDisplayController.searchBar.hidden = self.hideSearchBar;
}


- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tableView flashScrollIndicators];
}


- (void)dealloc {
    
    /* Evitar message sent to dealloc object */
    self.frc.delegate = nil;
    self.frc = nil;
    
    /* Evitar message sent to dealloc object */
    self.searchFRC.delegate = nil;
    self.searchFRC = nil;
}


#pragma mark - Getters and Setters {

- (void) setHideSearchBar:(BOOL)hideSearchBar {
    self.searchDisplayController.searchBar.hidden = hideSearchBar;
    _hideSearchBar = hideSearchBar;
}


- (void) setFrc:(NSFetchedResultsController *)newfrc {
    
    if (newfrc != _frc) {
        _frc = newfrc;
        newfrc.delegate = self;
        
        if (newfrc) {
            self.frcDidFinishPerformingFetch = NO;
            [self performFetch:_frc];
        } else {
            [self.tableView reloadData];
        }
        
        [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(reFetch:) name:APNotificationCacheDidFinishSync object:nil];
    }
}


- (void) setSearchFRC:(NSFetchedResultsController *)newFilteredFRC {
    
    if (_searchFRC != newFilteredFRC) {
        _searchFRC = newFilteredFRC;
        _searchFRC.delegate = self;
        
        if (_searchFRC) {
            self.frcDidFinishPerformingFetch = NO;
            [self performFetch:_searchFRC];
        } else {
            [self.searchDisplayController.searchResultsTableView reloadData];
        }
    }
}


#pragma mark - Notification Handling

- (void) reFetch: (NSNotification*) note {
    
    if (self.frc) [self performFetch:self.frc];
    if (self.searchFRC) [self performFetch:self.searchFRC];
}


#pragma mark - Fetching

- (void) performFetch: (NSFetchedResultsController*) frc {
    
   NSDate* start = [NSDate date];
    if (frc) {
        NSError *error;
        [frc performFetch:&error];
        if (error) {
            ELog(@"Fetching problem - %@",error);
            //[HUDViewController postTemporaryMessage:@"Fetching problem"];
        } else {
            DLog(@"[CoreDataTVC] - %@",[NSString stringWithFormat:@"Fetched: %lu %@ objects in %f seconds",(unsigned long)[frc.fetchedObjects count],self.frc.fetchRequest.entityName,[[NSDate date] timeIntervalSinceDate:start]]);
            DLog(@"[CoreDataTVC] - Fetched objects: %@",self.frc.fetchedObjects);
            //[HUDViewController postTemporaryMessage:msg];
        }
    } else {
        ELog(@"no NSFetchedResultsController (yet?)");
    }
    
    [self setFrcDidFinishPerformingFetch:YES];
    
    if (frc == self.frc) {
        [self.tableView reloadData];
    } else {
        [self.searchDisplayController.searchResultsTableView reloadData];
    }
}


- (NSFetchedResultsController *)frcForTableView:(UITableView *)tableView {
    
    return tableView == self.tableView ? self.frc : self.searchFRC;
}

- (void) refreshTable {
    
    // We reset the context to remove stale in-memory object values.
    // To avoid multiple network calls during the reload, turn on caching.
    [self.frc.managedObjectContext reset];
    [self performFetch:self.frc];
    
    
//    if (![self.fetchedResultsController performFetch:&error]) {
//        // Handle error
//        NSLog(@"An error %@, %@", error, [error userInfo]);
//    }
//    else {
//        [self.tableView reloadData];
//    }
}


#pragma mark - UITableViewDataSource

- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"%@ must override %@ in a subclass",
                                           NSStringFromClass([self class]),
                                           NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}


- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    
    NSInteger count = [[[self frcForTableView:tableView] sections] count];
    
    return count;
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    
    NSInteger numberOfRows = 0;
    NSFetchedResultsController *fetchController = [self frcForTableView:tableView];
    NSArray *sections = fetchController.sections;
    if(sections.count > 0)
    {
        id <NSFetchedResultsSectionInfo> sectionInfo = sections[section];
        numberOfRows = [sectionInfo numberOfObjects];
    }
    
    return numberOfRows;
}


- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	
    NSString* title = [[[self frcForTableView:tableView] sections][section]name];
    
    if (tableView == self.tableView && [self.searchDisplayController isActive])
        return nil;
    
    return title;
}


#pragma mark - NSFetchedResultsControllerDelegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    
    UITableView *tableView = (controller == self.frc) ? self.tableView : self.searchDisplayController.searchResultsTableView;
    if (!self.suspendAutomaticTrackingOfChangesInManagedObjectContext) {
        [tableView beginUpdates];
    }
    
    self.currentSelectionIndexPath = [tableView indexPathForSelectedRow];
}

- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
		   atIndex:(NSUInteger)sectionIndex
	 forChangeType:(NSFetchedResultsChangeType)type {
    
    if (!self.suspendAutomaticTrackingOfChangesInManagedObjectContext)
    {
        UITableView *tableView = (controller == self.frc) ? self.tableView : self.searchDisplayController.searchResultsTableView;
        
        switch(type)
        {
            case NSFetchedResultsChangeInsert:
                [tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:UITableViewRowAnimationFade];
                break;
                
            case NSFetchedResultsChangeDelete:
                [tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:UITableViewRowAnimationFade];
                break;
        }
    }
}


- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
	   atIndexPath:(NSIndexPath *)indexPath
	 forChangeType:(NSFetchedResultsChangeType)type
	  newIndexPath:(NSIndexPath *)newIndexPath
{
    if (!self.suspendAutomaticTrackingOfChangesInManagedObjectContext)
    {
        
        UITableView *tableView = (controller == self.frc) ? self.tableView : self.searchDisplayController.searchResultsTableView;
        
        switch(type)
        {
            case NSFetchedResultsChangeInsert:
                [tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
                break;
                
            case NSFetchedResultsChangeDelete:
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
                DLog(@"Object deleted: %@",anObject);
                break;
                
            case NSFetchedResultsChangeUpdate:
                [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
                break;
                
            case NSFetchedResultsChangeMove:
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
                [tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
                break;
        }
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    UITableView *tableView = (controller == self.frc) ? self.tableView : self.searchDisplayController.searchResultsTableView;
    
    [tableView endUpdates];
    
    [tableView selectRowAtIndexPath:self.currentSelectionIndexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    
}

- (void)endSuspensionOfUpdatesDueToContextChanges
{
    _suspendAutomaticTrackingOfChangesInManagedObjectContext = NO;
}

- (void)setSuspendAutomaticTrackingOfChangesInManagedObjectContext:(BOOL)suspend
{
    if (suspend) {
        _suspendAutomaticTrackingOfChangesInManagedObjectContext = YES;
    } else {
        [self performSelector:@selector(endSuspensionOfUpdatesDueToContextChanges) withObject:0 afterDelay:0];
    }
}



#pragma mark - Searching

- (void)searchDisplayController:(UISearchDisplayController *)controller willUnloadSearchResultsTableView:(UITableView *)tableView {
    
    if ([self conformsToProtocol:@protocol(CoreDataSearching)]) {
        // search is done so get rid of the search FRC and reclaim memory
        self.searchFRC.delegate = nil;
        self.searchFRC = nil;
    }
    ELog(@"Subclass must adopt Protocol CoreDataTVCSearching if it wants to perform searching it the tableview");
}



- (BOOL)searchDisplayController:(UISearchDisplayController *)controller shouldReloadTableForSearchString:(NSString *)searchString {
    
    if ([self conformsToProtocol:@protocol(CoreDataSearching)]) {
        /* Invalidates the last searchFRC */
        self.searchFRC.delegate = nil;
        self.searchFRC = nil;
        
        /* remove separators from cells when the tableview is empty */
        if (self.noCellSeparatorOnEmptySearch)
            [self removeCellSeparator:[controller.searchResultsTableView numberOfSections] == 0];
        
        self.searchFRC = [self createSearchFRC];
        self.searchFRC.delegate = self;
        
    } else {
        ELog(@"Subclass must adopt Protocol CoreDataTVCSearching if it wants to perform searching it the tableview");
    }
    
    
    // Return YES to cause the search result table view to be reloaded.
    return YES;
}

- (BOOL)searchDisplayController:(UISearchDisplayController *)controller shouldReloadTableForSearchScope:(NSInteger)searchOption {
    
    if ([self conformsToProtocol:@protocol(CoreDataSearching)]) {
        /* Invalidates the last searchFRC */
        self.searchFRC.delegate = nil;
        self.searchFRC = nil;
        
        /* remove separators from cells when the tableview is empty */
        if (self.noCellSeparatorOnEmptySearch)
            [self removeCellSeparator:[controller.searchResultsTableView numberOfSections] == 0];
        
        [self setSearchFRC:[self createSearchFRC]];
        self.searchFRC.delegate = self;
        
        
        /* Acertar o Keyboard */
        if ([self respondsToSelector:@selector(keyboardTypeForSearchFilterForScope:)]) {
            [controller.searchBar setKeyboardType: [self keyboardTypeForSearchFilterForScope:searchOption]];
            
            // Hack: force ui to reflect changed keyboard type
            [controller.searchBar resignFirstResponder];
            [controller.searchBar becomeFirstResponder];
        }
    } else {
        NSLog(@"Subclass must adopt Protocol CoreDataTVCSearching if it wants to perform searching it the tableview");
    }
    
    // Return YES to cause the search result table view to be reloaded.
    return YES;
}


- (void) removeCellSeparator:(BOOL) remove {
    if (remove)
        [self.searchDisplayController.searchResultsTableView setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    else
        [self.searchDisplayController.searchResultsTableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
}



- (UIKeyboardType) keyboardTypeForSearchFilterForScope: (NSInteger) selectedScopeButtonIndex {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"%@ must override %@ in a subclass",
                                           NSStringFromClass([self class]),
                                           NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (NSFetchedResultsController*) createSearchFRC {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"%@ must override %@ in a subclass",
                                           NSStringFromClass([self class]),
                                           NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

@end

