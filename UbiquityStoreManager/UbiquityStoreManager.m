/**
 * Copyright Maarten Billemont (http://www.lhunath.com, lhunath@lyndir.com)
 *
 * See the enclosed file LICENSE for license information (LASGPLv3).
 *
 * @author   Maarten Billemont <lhunath@lyndir.com>
 * @license  Lesser-AppStore General Public License
 */

//
//  UbiquityStoreManager.m
//  UbiquityStoreManager
//

#import "UbiquityStoreManager.h"
#import "JRSwizzle.h"
#import "NSError+UbiquityStoreManager.h"
#import "NSURL+UbiquityStoreManager.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

#define IfOut(__out, __value) ({ __typeof__(*__out) __var = __value; if (__out) { *__out = __var; }; __var; })

NSString *const USMStoreWillChangeNotification = @"USMStoreWillChangeNotification";
NSString *const USMStoreDidChangeNotification = @"USMStoreDidChangeNotification";
NSString *const USMStoreDidImportChangesNotification = @"USMStoreDidImportChangesNotification";

NSString *const USMCloudEnabledKey = @"USMCloudEnabledKey"; // local: Whether the user wants the app on this device to use iCloud.

NSString *const USMCloudContentName = @"UbiquityStore";
NSString *const USMCloudStoreDirectory = @"CloudStore";
NSString *const USMCloudStoreMigrationSource = @"MigrationSource.sqlite";
NSString *const USMCloudContentDirectory = @"CloudLogs";
NSString *const USMCloudContentStoreUUID = @"StoreUUID";
NSString *const USMCloudContentCorruptedUUID = @"CorruptedUUID";

extern NSString *NSStringFromUSMCause(UbiquityStoreErrorCause cause) {

    switch (cause) {
        case UbiquityStoreErrorCauseNoError:
            return @"UbiquityStoreErrorCauseNoError";
        case UbiquityStoreErrorCauseDeleteStore:
            return @"UbiquityStoreErrorCauseDeleteStore";
        case UbiquityStoreErrorCauseCreateStorePath:
            return @"UbiquityStoreErrorCauseCreateStorePath";
        case UbiquityStoreErrorCauseClearStore:
            return @"UbiquityStoreErrorCauseClearStore";
        case UbiquityStoreErrorCauseOpenActiveStore:
            return @"UbiquityStoreErrorCauseOpenActiveStore";
        case UbiquityStoreErrorCauseOpenSeedStore:
            return @"UbiquityStoreErrorCauseOpenSeedStore";
        case UbiquityStoreErrorCauseSeedStore:
            return @"UbiquityStoreErrorCauseSeedStore";
        case UbiquityStoreErrorCauseImportChanges:
            return @"UbiquityStoreErrorCauseImportChanges";
        case UbiquityStoreErrorCauseConfirmActiveStore:
            return @"UbiquityStoreErrorCauseConfirmActiveStore";
        case UbiquityStoreErrorCauseCorruptActiveStore:
            return @"UbiquityStoreErrorCauseCorruptActiveStore";
    }

    return [NSString stringWithFormat:@"UnsupportedCause:%d", cause];
}

/** USMFilePresenter monitors a file for NSFilePresenter related changes. */
@interface USMFilePresenter : NSObject<NSFilePresenter>

@property(nonatomic, weak) UbiquityStoreManager *delegate;

- (id)initWithURL:(NSURL *)presentedItemURL delegate:(UbiquityStoreManager *)delegate;

- (void)start;
- (void)stop;

@end

/** USMFileContentPresenter extends USMFilePresenter to add metadata change monitoring. */
@interface USMFileContentPresenter : USMFilePresenter

@property(nonatomic, strong) NSMetadataQuery *query;

@end

/** USMStoreFilePresenter monitors our active store file. */
@interface USMStoreFilePresenter : USMFilePresenter
@end

/** USMStoreFilePresenter monitors the file that contains the active store UUID.
 * Changes to this file mean the active store has changed and we need to load the new store.
 */
@interface USMStoreUUIDPresenter : USMFileContentPresenter
@end

/** USMStoreFilePresenter monitors the file that contains the corrupted store UUID.
 * Changes to this file mean a device has detected cloud corruption and we try to fix it.
 */
@interface USMCorruptedUUIDPresenter : USMFileContentPresenter
@end

@interface UbiquityStoreManager()

@property(nonatomic, copy) NSString *contentName;
@property(nonatomic, strong) NSManagedObjectModel *model;
@property(nonatomic, copy) NSString *containerIdentifier;
@property(nonatomic, copy) NSDictionary *additionalStoreOptions;
@property(nonatomic, readonly) NSString *storeUUID;
@property(nonatomic, strong) NSString *tentativeStoreUUID;
@property(nonatomic, strong) NSOperationQueue *persistentStorageQueue;
@property(nonatomic, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property(nonatomic, strong) id<NSObject, NSCopying, NSCoding> currentIdentityToken;
@property(nonatomic, strong) NSURL *migrationStoreURL;
@property(nonatomic) BOOL attemptingCloudRecovery;
@property(nonatomic) NSString *localCloudStoreCorruptedUUID;
@property(nonatomic) NSString *activeCloudStoreUUID;
@property(nonatomic) BOOL cloudWasEnabled;
@property(nonatomic, strong) USMStoreFilePresenter *storeFilePresenter;
@property(nonatomic, strong) USMStoreUUIDPresenter *storeUUIDPresenter;
@property(nonatomic, strong) USMCorruptedUUIDPresenter *corruptedUUIDPresenter;
@property(nonatomic, assign) BOOL cloudAvailable;
@end

@implementation UbiquityStoreManager {
    NSPersistentStoreCoordinator *_persistentStoreCoordinator;
}

+ (void)initialize {

    if (![self respondsToSelector:@selector(jr_swizzleMethod:withMethod:error:)]) {
        NSLog( @"UbiquityStoreManager: Warning: JRSwizzle not present, won't be able to detect desync issues." );
        return;
    }

    NSError *error = nil;
    if (![NSError jr_swizzleMethod:@selector(initWithDomain:code:userInfo:)
                        withMethod:@selector(init_USM_WithDomain:code:userInfo:)
                             error:&error])
        NSLog( @"UbiquityStoreManager: Warning: Failed to swizzle, won't be able to detect desync issues.  Cause: %@", error );
}

- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions
            delegate:(id<UbiquityStoreManagerDelegate>)delegate {

    if (!(self = [super init]))
        return nil;

    // Parameters.
    _delegate = delegate;
    _contentName = contentName == nil? USMCloudContentName: contentName;
    _model = model == nil? [NSManagedObjectModel mergedModelFromBundles:nil]: model;
    if (!localStoreURL)
        localStoreURL = [[[self URLForApplicationContainer]
                URLByAppendingPathComponent:[self localContentName] isDirectory:NO]
                URLByAppendingPathExtension:@"sqlite"];
    _localStoreURL = localStoreURL;
    _containerIdentifier = containerIdentifier;
    _additionalStoreOptions = additionalStoreOptions == nil? [NSDictionary dictionary]: additionalStoreOptions;

    // Private vars.
    _currentIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    _cloudAvailable = (_currentIdentityToken != nil);
    _migrationStrategy = &NSPersistentStoreUbiquitousContainerIdentifierKey?
                         UbiquityStoreMigrationStrategyIOS: UbiquityStoreMigrationStrategyCopyEntities;
//    _migrationStrategy = UbiquityStoreMigrationStrategyCopyEntities;
    _persistentStorageQueue = [NSOperationQueue new];
    _persistentStorageQueue.name = [NSString stringWithFormat:@"%@PersistenceQueue", NSStringFromClass( [self class] )];
    _persistentStorageQueue.maxConcurrentOperationCount = 1;

    // Observe application events.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cloudStoreChanged:)
                                                 name:NSUbiquityIdentityDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ubiquityStoreManagerDidDetectCorruption:)
                                                 name:UbiquityManagedStoreDidDetectCorruptionNotification
                                               object:nil];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDefaultsDidChange:)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];
#else
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
#endif

    [self reloadStore];

    return self;
}

- (void)dealloc {

    // Stop listening for store changes.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.storeFilePresenter stop];
    [self.storeUUIDPresenter stop];
    [self.corruptedUUIDPresenter stop];

    // Unload the store.
    [self enqueue:^{ [self clearStore]; } waitUntilFinished:YES];
}

#pragma mark - File Handling

- (NSString *)localContentName {

    return _contentName;
}

/**
 * Get the name of the cloud content for the given cloud store.
 *
 * For version 0 (iOS 6) this defaults to USMCloudContentName, for version 1 this is the StoreUUID.
 */
- (NSString *)cloudContentNameForStoreURL:(NSURL *)storeURL {

    if ([self cloudVersionForStoreURL:storeURL] == 0)
        return _contentName;

    return storeURL? [[storeURL URLByDeletingPathExtension] lastPathComponent]: self.storeUUID;
}

/**
 * Get a versioned version of the identifier by appending +'s to it.  The version to use is determined from the storeURL.
 */
- (NSString *)cloudVersionedIdentifier:(NSString *)identifier forStoreURL:(NSURL *)storeURL {

    return [self versionedIdentifier:identifier version:[self cloudVersionForStoreURL:storeURL]];
}

/**
 * Get a versioned version of the identifier by appending +'s to it.
 */
- (NSString *)versionedIdentifier:(NSString *)identifier version:(int)version {

    for (int v = 0; v < version; ++v)
        identifier = [identifier stringByAppendingString:@"+"];

    return identifier;
}

/**
 * The version preferred for cloud content by the current platform when not in compatibility mode (eg. for new stores).
 *
 * For iOS 6, this returns 0.  For iOS 7+, the version is 1.
 */
- (int)desiredCloudVersion {

    if (&NSPersistentStoreUbiquitousContainerIdentifierKey)
        return 1;

    return 0;
}

/**
 * Determine the version of the cloud store at the given URL.
 *
 * We find a StoreUUID file that mentions the cloud store's UUID and return its version.
 * If there isn't one, this is deemed a new store and we return the desired version.
 */
- (int)cloudVersionForStoreURL:(NSURL *)storeURL {

    // Determine the cloud version to use by trying the desired version for the platform and backing down
    // until a StoreUUID for the version is found.
    int desiredCloudVersion = [self desiredCloudVersion];
    int cloudVersion = desiredCloudVersion;
    NSString *forStoreUUID = [[storeURL URLByDeletingPathExtension] lastPathComponent];

    for (; cloudVersion >= 0; --cloudVersion) {
        NSString *storeUUIDPath = [self URLForCloudStoreUUIDForVersion:cloudVersion].path;
        if ([[NSFileManager defaultManager] fileExistsAtPath:storeUUIDPath] &&
            (!forStoreUUID ||
             [[NSString stringWithContentsOfFile:storeUUIDPath encoding:NSUTF8StringEncoding error:nil]
                     isEqualToString:forStoreUUID]))
            break;
    }
    if (cloudVersion < 0)
        return desiredCloudVersion;

    return cloudVersion;
}

- (NSURL *)URLForApplicationContainer {

    NSURL *applicationSupportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask] lastObject];

#if TARGET_OS_IPHONE
    // On iOS, each app is in a sandbox so we don't need to app-scope this directory.
    return applicationSupportURL;
#else
    // The directory is shared between all apps on the system so we need to scope it for the running app.
    applicationSupportURL = [applicationSupportURL URLByAppendingPathComponent:[NSRunningApplication currentApplication].bundleIdentifier isDirectory:YES];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:applicationSupportURL
                                  withIntermediateDirectories:YES attributes:nil error:&error])
        [self error:error cause:UbiquityStoreErrorCauseCreateStorePath context:applicationSupportURL.path];

    return applicationSupportURL;
#endif
}

- (NSURL *)URLForCloudContainer {

    return [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:self.containerIdentifier];
}

/**
 * The directory where cloud store files are kept.
 *
 * For iOS 6, this is in a .nosync in the cloud container.  For iOS 7+ in the application sandbox.
 */
- (NSURL *)URLForCloudStoreDirectory {

    if (&NSPersistentStoreUbiquitousContainerIdentifierKey)
            // On iOS7+ the store needs to be in the application container and is managed by the iCloud framework.
        return [[self URLForApplicationContainer] URLByAppendingPathComponent:USMCloudStoreDirectory isDirectory:YES];

    // We put the database in the ubiquity container with a .nosync extension (must not be synced by iCloud),
    // so that its presence is tied closely to whether iCloud is enabled or not on the device
    // and the user can delete the store by deleting his iCloud data for the app from Settings.
    return [[[self URLForCloudContainer] URLByAppendingPathComponent:USMCloudStoreDirectory isDirectory:YES]
            URLByAppendingPathExtension:@"nosync"];
}

- (NSURL *)URLForCloudStore {

    // Our cloud store is in the cloud store databases directory and is identified by the active storeUUID.
    return [[[self URLForCloudStoreDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:NO]
            URLByAppendingPathExtension:@"sqlite"];
}

- (NSURL *)URLForCloudContentDirectory {

    // The transaction logs are in the ubiquity container and are synced by iCloud.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:USMCloudContentDirectory isDirectory:YES];
}

- (id)URLForCloudContent {

    return [self URLForCloudContentForStoreURL:nil];
}

- (id)URLForCloudContentForStoreURL:(NSURL *)storeURL {

    NSString *storeUUID = storeURL? [[storeURL URLByDeletingPathExtension] lastPathComponent]: self.storeUUID;
    if (&NSPersistentStoreUbiquitousContainerIdentifierKey)
        return [USMCloudContentDirectory stringByAppendingPathComponent:storeUUID];

    // Our cloud store's logs are in the cloud store transaction logs directory and is identified by the active storeUUID.
    return [[self URLForCloudContentDirectory] URLByAppendingPathComponent:storeUUID isDirectory:YES];
}

/**
 * Contrary to -URLForCloudContent, this method can return nil, in which case the location of the cloud content has not yet been established.
 */
- (id)URLForCloudContent_ThreadSafe {

    NSString *storeUUID = [self storeUUID_ThreadSafe];
    if (!storeUUID)
        return nil;

    if (&NSPersistentStoreUbiquitousContainerIdentifierKey)
        return [USMCloudContentDirectory stringByAppendingPathComponent:storeUUID];

    // Our cloud store's logs are in the cloud store transaction logs directory and is identified by the active storeUUID.
    return [[self URLForCloudContentDirectory] URLByAppendingPathComponent:storeUUID isDirectory:YES];
}

- (NSURL *)URLForCloudStoreUUID {

    // The UUID of the active cloud store is in the cloud store transaction logs directory.
    return [[self URLForCloudContentDirectory]
            URLByAppendingPathComponent:[self cloudVersionedIdentifier:USMCloudContentStoreUUID forStoreURL:nil]
                            isDirectory:NO];
}

- (NSURL *)URLForCloudStoreUUIDForVersion:(int)version {

    // The UUID of the active cloud store is in the cloud store transaction logs directory.
    return [[self URLForCloudContentDirectory]
            URLByAppendingPathComponent:[self versionedIdentifier:USMCloudContentStoreUUID version:version]
                            isDirectory:NO];
}

- (NSURL *)URLForCloudCorruptedUUID {

    // The UUID of the corrupted cloud store is in the cloud store transaction logs directory.
    return [[self URLForCloudContentDirectory]
            URLByAppendingPathComponent:[self cloudVersionedIdentifier:USMCloudContentCorruptedUUID forStoreURL:nil]
                            isDirectory:NO];
}

- (NSURL *)URLForCloudCorruptedUUIDForVersion:(int)version {

    // The UUID of the corrupted cloud store is in the cloud store transaction logs directory.
    return [[self URLForCloudContentDirectory]
            URLByAppendingPathComponent:[self versionedIdentifier:USMCloudContentCorruptedUUID version:version]
                            isDirectory:NO];
}

- (NSURL *)URLForLocalStoreDirectory {

    return [self.localStoreURL URLByDeletingLastPathComponent];
}

- (NSURL *)URLForLocalStore {

    return self.localStoreURL;
}


#pragma mark - Utilities

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {

    va_list argList;
    va_start(argList, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:log:)])
        [self.delegate ubiquityStoreManager:self log:message];
    else
        NSLog( @"UbiquityStoreManager: %@", message );
}

- (void)logError:(NSString *)error cause:(UbiquityStoreErrorCause)cause context:(id)context {

    [self error:[NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:@{ NSLocalizedFailureReasonErrorKey : error }]
          cause:cause context:context];
}

- (void)error:(NSError *)error cause:(UbiquityStoreErrorCause)cause context:(id)context {

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didEncounterError:cause:context:)])
        [self.delegate ubiquityStoreManager:self didEncounterError:error cause:cause context:context];
    else {
        [self log:@"Error (cause:%@): %@", NSStringFromUSMCause( cause ), error];

        if (context)
            [self log:@"    - Context   : %@", context];
        NSError *underlyingError = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
        if (underlyingError)
            [self log:@"    - Underlying: %@", underlyingError];
        NSArray *detailedErrors = [[error userInfo] objectForKey:NSDetailedErrorsKey];
        for (NSError *detailedError in detailedErrors)
            [self log:@"    - Detail    : %@", detailedError];
    }
}

- (void)assertQueued {

    NSAssert([NSOperationQueue currentQueue] == self.persistentStorageQueue, @"This call may only be invoked from the persistence queue.");
}

/**
 * @return YES if we are currently on the persistence queue.  NO if we aren't and the enqueueBlock has been submitted to it.
 */
- (BOOL)ensureQueued:(void (^)())enqueueBlock {

    if ([NSOperationQueue currentQueue] == self.persistentStorageQueue)
        return YES;

    [self enqueue:enqueueBlock];
    return NO;
}

- (void)enqueue:(void (^)())enqueueBlock {

    [self enqueue:enqueueBlock waitUntilFinished:NO];
}

- (void)enqueue:(void (^)())enqueueBlock waitUntilFinished:(BOOL)wait {

    [self.persistentStorageQueue addOperations:@[
            [NSBlockOperation blockOperationWithBlock:^{
                @try {
                    [self.persistentStoreCoordinator lock];
                    enqueueBlock();
                }
                @catch (NSException *exception) {
                    [self logError:[(id<NSObject>)exception description]
                             cause:UbiquityStoreErrorCauseOpenActiveStore context:exception];
                }
                @finally {
                    [self.persistentStoreCoordinator unlock];
                }
            }]
    ]                        waitUntilFinished:wait];
}

#pragma mark - Store Management

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {

    [self assertQueued];

    if (!_persistentStoreCoordinator) {
        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mergeChanges:)
                                                     name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                                   object:_persistentStoreCoordinator];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willChange:)
                                                     name:NSPersistentStoreCoordinatorStoresWillChangeNotification
                                                   object:_persistentStoreCoordinator];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didChange:)
                                                     name:NSPersistentStoreCoordinatorStoresDidChangeNotification
                                                   object:_persistentStoreCoordinator];
    }

    return _persistentStoreCoordinator;
}

- (void)resetPersistentStoreCoordinator {

    [self assertQueued];

    if (_persistentStoreCoordinator) {
        [_persistentStoreCoordinator unlock];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_persistentStoreCoordinator];
        _persistentStoreCoordinator = nil;
    }

    [self.persistentStoreCoordinator lock];
}

- (void)clearStore {

    [self log:@"Clearing stores..."];
    [self assertQueued];

    // Stop listening for store changes.
    [self.storeFilePresenter stop];
    [self.storeUUIDPresenter stop];
    [self.corruptedUUIDPresenter stop];

    // Let the application clean up its MOCs.
    [self.persistentStoreCoordinator unlock];
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)])
        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];

    [[NSNotificationCenter defaultCenter] postNotificationName:USMStoreWillChangeNotification
                                                        object:self userInfo:nil];

    // Remove the store from the coordinator.
    NSError *error = nil;
    self.activeCloudStoreUUID = nil;
    for (NSPersistentStore *store in self.persistentStoreCoordinator.persistentStores)
        if (![self.persistentStoreCoordinator removePersistentStore:store error:&error])
            [self error:error cause:UbiquityStoreErrorCauseClearStore context:store];

    // If we failed to remove all the stores, throw away the PSC and create a new one.
    if ([[self.persistentStoreCoordinator persistentStores] count])
        [self resetPersistentStoreCoordinator];
    else
        [self.persistentStoreCoordinator lock];
}

- (void)reloadStore {

    if (![self ensureQueued:^{ [self reloadStore]; }])
        return;

//    [[NSFileManager defaultManager] removeItemAtURL:[self URLForCloudStoreUUIDForVersion:1] error:nil];

    [self log:@"(Re)loading store..."];
    if (self.cloudEnabled)
        [self loadCloudStore];
    else
        [self loadLocalStore];
}

- (void)loadCloudStore {

    [self log:@"Will load cloud store."];
    [self assertQueued];

    // Mark store as healthy: opening the store now will tell us whether it's still corrupt.
    [self clearStore];
    self.activeCloudStoreUUID = nil;

    // Check if the user is logged into iCloud on the device.
    if (![[NSFileManager defaultManager] ubiquityIdentityToken] || ![self URLForCloudContainer]) {
        [self log:@"Could not load cloud store: User is not logged into iCloud.  Falling back to local store."];
        self.cloudEnabled = NO;
        return;
    }

    id context = nil;
    UbiquityStoreErrorCause cause = UbiquityStoreErrorCauseNoError;
    @try {
        NSURL *cloudStoreURL = [self URLForCloudStore];
        [self log:@"Loading cloud store: %@, v%d (%@).", [self storeUUIDForLog], [self cloudVersionForStoreURL:cloudStoreURL],
                        _tentativeStoreUUID? @"tentative": @"definite"];

        // Check if we need to seed the store by migrating another store into it.
        UbiquityStoreMigrationStrategy migrationStrategy = self.migrationStrategy;
        NSURL *migrationStoreURL = self.migrationStoreURL? self.migrationStoreURL: [self localStoreURL];
        NSDictionary *migrationStoreOptions = [self optionsForMigrationStoreURL:migrationStoreURL];
        if (migrationStrategy == UbiquityStoreMigrationStrategyNone ||
            !migrationStoreOptions || ![self cloudSafeForSeeding] ||
            // We want to migrate from migrationStoreURL, check with application.
            ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:shouldMigrateFromStoreURL:toStoreURL:isCloud:)] &&
             ![self.delegate ubiquityStoreManager:self
                        shouldMigrateFromStoreURL:migrationStoreURL toStoreURL:cloudStoreURL
                                          isCloud:NO])) {
            migrationStrategy = UbiquityStoreMigrationStrategyNone;
            migrationStoreURL = nil;
        }
        else
            [self log:@"Will migrate to cloud store from: %@ (strategy: %d).", [migrationStoreURL lastPathComponent], migrationStrategy];

        // Load the cloud store.
        [self loadStoreAtURL:cloudStoreURL withOptions:[self optionsForCloudStoreURL:cloudStoreURL]
         migratingStoreAtURL:migrationStoreURL withOptions:migrationStoreOptions
               usingStrategy:migrationStrategy cause:&cause context:&context];

        self.storeFilePresenter = nil;
        [self.storeUUIDPresenter = [[USMStoreUUIDPresenter alloc] initWithURL:[self URLForCloudStoreUUID] delegate:self] start];
        [self.corruptedUUIDPresenter = [[USMCorruptedUUIDPresenter alloc] initWithURL:[self URLForCloudCorruptedUUID] delegate:self] start];
    }
    @catch (id exception) {
        [self logError:[(id<NSObject>)exception description]
                 cause:UbiquityStoreErrorCauseOpenActiveStore context:exception];
    }
    @finally {
        BOOL wasExplicitMigration = self.migrationStoreURL != nil;
        self.migrationStoreURL = nil;

        if (cause == UbiquityStoreErrorCauseNoError) {
            // Store loaded successfully.
            [self confirmTentativeStoreUUID];
            self.activeCloudStoreUUID = [self storeUUID];
            self.attemptingCloudRecovery = NO;

            [self log:@"Successfully loaded cloud store."];

            // Give it some "time" to import any incoming transaction logs. This is important:
            // 1. To see if this store is a healthy candidate for content corruption rebuild.
            // 2. To make sure our store is up-to-date before we destroy the cloud content and rebuild it from the store.
            dispatch_after( dispatch_time( DISPATCH_TIME_NOW, NSEC_PER_SEC * 20 ),
                    dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0 ), ^{
                        [self enqueue:^{
                            // TODO: Make better sure the store is up to date with the cloud.
                            if ([self cloudVersionForStoreURL:nil] != [self desiredCloudVersion])
                                [self rebuildCloudContentFromCloudStoreOrLocalStore:NO];

                            else if (self.activeCloudStoreUUID && ![self.localCloudStoreCorruptedUUID isEqualToString:self.storeUUID])
                                    // The wait is over and this store is still healthy.
                                    // It is now eligible for rebuilding corrupt content if there is any.
                                [self handleCloudContentCorruption];
                        }];
                    } );
        }
        else {
            // An error occurred in the @try block.
            [self unsetTentativeStoreUUID];
            [self clearStore];

            // If we were performing explicit migration, try without in case the problem was caused by the migration store.
            if (wasExplicitMigration) {
                [self logError:@"Failed to load cloud store. Was performing explicit migration; will try without."
                         cause:cause context:context];
                [self reloadStore];
                return;
            }

            // If we haven't attempted recovery yet (ie. delete the local store), try that first.
            if (!self.attemptingCloudRecovery) {
                [self logError:@"Failed to load cloud store. Attempting recovery by rebuilding from cloud content."
                         cause:cause context:context];
                self.attemptingCloudRecovery = YES;
                [self deleteCloudStoreLocalOnly:YES];
                return;
            }
            self.attemptingCloudRecovery = NO;

            // Failed to load regardless of recovery attempt.  Mark store as corrupt.
            [self logError:@"Failed to load cloud store. Marking cloud store as corrupt. Store will be unavailable."
                     cause:cause context:context];
            [self markCloudStoreCorrupted];
        }

        NSPersistentStoreCoordinator *psc = self.persistentStoreCoordinator;
        dispatch_async( dispatch_get_main_queue(), ^{
            if (cause == UbiquityStoreErrorCauseNoError) {
                // Store loaded successfully.
                // Make sure the PSC is still valid.
                @try {
                    if (![psc tryLock] || ![[psc persistentStores] count])
                        return;
                }
                @finally {
                    [psc unlock];
                }

                // Notify the application.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:psc isCloud:YES];
                [[NSNotificationCenter defaultCenter] postNotificationName:USMStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            }
            else {
                // Store failed to load, inform delegate.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                    [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:YES];
            }
        } );
    }
}

- (void)loadLocalStore {

    [self log:@"Will load local store."];
    [self assertQueued];

    [self clearStore];

    id context = nil;
    NSError *error = nil;
    UbiquityStoreErrorCause cause = UbiquityStoreErrorCauseNoError;
    @try {
        // Make sure local store directory exists.
        NSURL *localStoreURL = [self URLForLocalStore];
        NSURL *localStoreDirectoryURL = [self URLForLocalStoreDirectory];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:localStoreDirectoryURL
                                      withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = localStoreDirectoryURL.path];
            return;
        }

        // If the local store doesn't exist yet and a migrationStore is set, copy it.
        // Check if we need to seed the store by migrating another store into it.
        UbiquityStoreMigrationStrategy migrationStrategy = self.migrationStrategy;
        NSURL *migrationStoreURL = self.migrationStoreURL;
        NSDictionary *migrationStoreOptions = [self optionsForMigrationStoreURL:migrationStoreURL];
        if (migrationStrategy == UbiquityStoreMigrationStrategyNone ||
            !migrationStoreOptions ||
            // We want to migrate from migrationStoreURL, check with application.
            ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:shouldMigrateFromStoreURL:toStoreURL:isCloud:)] &&
             ![self.delegate ubiquityStoreManager:self
                        shouldMigrateFromStoreURL:migrationStoreURL toStoreURL:localStoreURL
                                          isCloud:NO]) ||
            // Migration OK'ed by application, make sure destination store doesn't exist.
            [[NSFileManager defaultManager] fileExistsAtPath:localStoreURL.path])
            migrationStrategy = UbiquityStoreMigrationStrategyNone;
        else
            [self log:@"Will migrate to local store from: %@ (strategy: %d).", migrationStoreURL, migrationStrategy];

        // Load the local store.
        [self loadStoreAtURL:localStoreURL withOptions:[self optionsForLocalStore]
         migratingStoreAtURL:migrationStoreURL withOptions:migrationStoreOptions
               usingStrategy:migrationStrategy cause:&cause context:&context];

        [self.storeFilePresenter = [[USMStoreFilePresenter alloc] initWithURL:localStoreURL delegate:self] start];
    }
    @catch (id exception) {
        [self logError:[(id<NSObject>)exception description]
                 cause:UbiquityStoreErrorCauseOpenActiveStore context:exception];
    }
    @finally {
        BOOL wasExplicitMigration = self.migrationStoreURL != nil;
        self.migrationStoreURL = nil;

        if (cause == UbiquityStoreErrorCauseNoError) {
            // Store loaded successfully.
            [self log:@"Successfully loaded local store."];
        }
        else {
            // An error occurred in the @try block.
            [self clearStore];

            // If we were performing explicit migration, try without in case the problem was caused by the migration store.
            if (wasExplicitMigration) {
                [self logError:@"Failed to load local store. Was performing explicit migration; will try without."
                         cause:cause context:context];
                [self reloadStore];
                return;
            }

            [self logError:@"Failed to load local store.  Store will be unavailable."
                     cause:cause context:context];
        }

        NSPersistentStoreCoordinator *psc = self.persistentStoreCoordinator;
        dispatch_async( dispatch_get_main_queue(), ^{
            if (cause == UbiquityStoreErrorCauseNoError) {
                // Store loaded successfully.
                // Make sure the PSC is still valid.
                @try {
                    if (![psc tryLock] || ![[psc persistentStores] count])
                        return;
                }
                @finally {
                    [psc unlock];
                }

                // Notify the application.
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:psc isCloud:NO];
                [[NSNotificationCenter defaultCenter] postNotificationName:USMStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            }
            else if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                    // Store failed to load, inform delegate.
                [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:NO];
        } );
    }
}

- (NSDictionary *)optionsForLocalStore {

    NSMutableDictionary *localStoreOptions = [@{
            NSMigratePersistentStoresAutomaticallyOption : @YES,
            NSInferMappingModelAutomaticallyOption       : @YES
    } mutableCopy];
    [localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];

    return localStoreOptions;
}

- (NSDictionary *)optionsForCloudStoreURL:(NSURL *)cloudStoreURL {

    NSString *cloudContentName = [self cloudContentNameForStoreURL:cloudStoreURL];
    NSURL *cloudStoreContentURL = [self URLForCloudContentForStoreURL:cloudStoreURL];

    NSMutableDictionary *cloudStoreOptions;
    if (&NSPersistentStoreUbiquitousContainerIdentifierKey) {
        // iOS 7+
        // Cloud store loading options.
        cloudStoreOptions = [@{
                NSPersistentStoreUbiquitousContentNameKey         : cloudContentName,
                NSPersistentStoreUbiquitousContentURLKey          : cloudStoreContentURL,
                NSPersistentStoreUbiquitousContainerIdentifierKey : self.containerIdentifier,
                NSMigratePersistentStoresAutomaticallyOption      : @YES,
                NSInferMappingModelAutomaticallyOption            : @YES
        } mutableCopy];
    }
    else {
        // iOS 6
        // Create the path to the cloud store and content if it doesn't exist yet.
        NSError *error = nil;
        NSURL *cloudStoreDirectoryURL = [self URLForCloudStoreDirectory];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:cloudStoreDirectoryURL
                                      withIntermediateDirectories:YES attributes:nil error:&error])
            [self error:error cause:UbiquityStoreErrorCauseCreateStorePath context:cloudStoreDirectoryURL.path];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:cloudStoreContentURL
                                      withIntermediateDirectories:YES attributes:nil error:&error])
            [self error:error cause:UbiquityStoreErrorCauseCreateStorePath context:cloudStoreContentURL.path];

        // Clean up the cloud store if the cloud content got deleted.
        BOOL storeExists = [[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path];
        BOOL storeContentExists = [[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:cloudStoreContentURL error:nil];
        if (storeExists && !storeContentExists) {
            // We have a cloud store but no cloud content.  The cloud content was deleted:
            // The existing store cannot sync anymore and needs to be recreated.
            [self log:@"Deleting cloud store: it has no cloud content."];
            [self removeItemAtURL:cloudStoreURL localOnly:NO];
        }

        // Cloud store loading options.
        cloudStoreOptions = [@{
                NSPersistentStoreUbiquitousContentNameKey    : cloudContentName,
                NSPersistentStoreUbiquitousContentURLKey     : cloudStoreContentURL,
                NSMigratePersistentStoresAutomaticallyOption : @YES,
                NSInferMappingModelAutomaticallyOption       : @YES
        } mutableCopy];
    }

    [cloudStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
    return cloudStoreOptions;
}

- (NSDictionary *)optionsForMigrationStoreURL:(NSURL *)migrationStoreURL {

    if (!migrationStoreURL)
        return nil;

    NSMutableDictionary *migrationStoreOptions = [self.additionalStoreOptions mutableCopy];
    if ([[migrationStoreURL lastPathComponent] isEqualToString:USMCloudStoreMigrationSource]) {
        // Migration store is a migration cloud store.  We want to treat it as a local store.
        [migrationStoreOptions addEntriesFromDictionary:@{
                NSMigratePersistentStoresAutomaticallyOption : @YES,
                NSInferMappingModelAutomaticallyOption       : @YES
        }];
        if (&NSPersistentStoreRemoveUbiquitousMetadataOption)
            [migrationStoreOptions setObject:@YES forKey:NSPersistentStoreRemoveUbiquitousMetadataOption];
    }
    else if ([[migrationStoreURL absoluteString] rangeOfString:USMCloudStoreDirectory].location != NSNotFound)
            // Migration store is a regular cloud store.
        migrationStoreOptions = [[self optionsForCloudStoreURL:migrationStoreURL] mutableCopy];
    else if ([[NSFileManager defaultManager] fileExistsAtPath:migrationStoreURL.path])
            // Migration store is something else.
        [migrationStoreOptions addEntriesFromDictionary:@{
                NSReadOnlyPersistentStoreOption : @YES,
        }];
    else
            // Migration store doesn't exist and is not a cloud store.
        return nil;

    return migrationStoreOptions;
}

- (void)loadStoreAtURL:(NSURL *)targetStoreURL withOptions:(NSDictionary *)targetStoreOptions
   migratingStoreAtURL:(NSURL *)migrationStoreURL withOptions:(NSDictionary *)migrationStoreOptions
         usingStrategy:(UbiquityStoreMigrationStrategy)migrationStrategy
                 cause:(UbiquityStoreErrorCause *)cause context:(__autoreleasing id *)context {

    [self assertQueued];
    NSAssert([self.persistentStoreCoordinator.persistentStores count] == 0, @"PSC should have no stores before trying to load one.");

    NSError *error = nil;
    @try {
        // Migrating migration store if necessary.
        if (![self migrateStore:migrationStoreURL withOptions:migrationStoreOptions
                        toStore:targetStoreURL withOptions:targetStoreOptions
                       strategy:migrationStrategy error:&error cause:cause context:context])
            return;

        // Ready, loading target store.
        if ([[self.persistentStoreCoordinator persistentStores] count] == 1 &&
            [[[[[self.persistentStoreCoordinator persistentStores] firstObject] URL] lastPathComponent]
                    isEqual:[targetStoreURL lastPathComponent]])
                // Target store already loaded as a result of migration.
            return;

        [self log:@"Loading store: %@", [targetStoreURL lastPathComponent]];
        if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                                                     URL:targetStoreURL options:targetStoreOptions
                                                                   error:&error])
            [self error:error cause:IfOut(cause, UbiquityStoreErrorCauseOpenActiveStore)
                context:IfOut(context, targetStoreURL.path)];
    }
    @catch (id exception) {
        [self logError:[(id<NSObject>)exception description]
                 cause:IfOut(cause, UbiquityStoreErrorCauseOpenActiveStore) context:IfOut(context, exception)];
    }
}

- (BOOL)migrateStore:(NSURL *)migrationStoreURL withOptions:(NSDictionary *)migrationStoreOptions
             toStore:(NSURL *)targetStoreURL withOptions:(NSDictionary *)targetStoreOptions
            strategy:(UbiquityStoreMigrationStrategy)migrationStrategy
               error:(__autoreleasing NSError **)outError cause:(UbiquityStoreErrorCause *)cause context:(__autoreleasing id *)context {

    NSError *error = nil;
    @try {
        IfOut(cause, UbiquityStoreErrorCauseNoError);
        switch (migrationStrategy) {
            case UbiquityStoreMigrationStrategyCopyEntities: {
                [self log:@"Seeding store (strategy: UbiquityStoreMigrationStrategyCopyEntities): %@ -> %@",
                          [migrationStoreURL lastPathComponent], [targetStoreURL lastPathComponent]];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Handle failure by cleaning up the target store.
                if (![self copyMigrateStore:migrationStoreURL withOptions:migrationStoreOptions
                                    toStore:targetStoreURL withOptions:targetStoreOptions
                                      error:&error cause:cause context:context]) {
                    IfOut(outError, error);
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    return NO;
                }

                return YES;
            }

            case UbiquityStoreMigrationStrategyIOS: {
                [self log:@"Seeding store (strategy: UbiquityStoreMigrationStrategyIOS): %@ -> %@",
                          [migrationStoreURL lastPathComponent], [targetStoreURL lastPathComponent]];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Add the store to migrate.
                NSPersistentStore *migrationStore = [self.persistentStoreCoordinator
                        addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                               URL:migrationStoreURL options:migrationStoreOptions
                                             error:&error];
                if (!migrationStore) {
                    [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseOpenSeedStore)
                        context:IfOut(context, migrationStoreURL.path)];
                    return NO;
                }

                if (![self.persistentStoreCoordinator migratePersistentStore:migrationStore
                                                                       toURL:targetStoreURL options:targetStoreOptions
                                                                    withType:NSSQLiteStoreType error:&error]) {
                    [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseSeedStore)
                        context:IfOut(context, targetStoreURL.path)];
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    return NO;
                }

                return YES;
            }

            case UbiquityStoreMigrationStrategyManual: {
                [self log:@"Seeding store (strategy: UbiquityStoreMigrationStrategyManual): %@ -> %@",
                          [migrationStoreURL lastPathComponent], [targetStoreURL lastPathComponent]];
                NSAssert(migrationStoreURL, @"Cannot migrate: No migration store specified.");

                // Instruct the delegate to migrate the migration store to the target store.
                if (![self.delegate ubiquityStoreManager:self
                                    manuallyMigrateStore:migrationStoreURL withOptions:migrationStoreOptions
                                                 toStore:targetStoreURL withOptions:targetStoreOptions error:&error]) {
                    // Handle failure by cleaning up the target store.
                    [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseSeedStore)
                        context:IfOut(context, migrationStoreURL.path)];
                    [self removeItemAtURL:targetStoreURL localOnly:NO];
                    return NO;
                }

                return YES;
            }

            case UbiquityStoreMigrationStrategyNone:
                return YES;
        }
    }
    @catch (id exception) {
        [self logError:[(id<NSObject>)exception description]
                 cause:IfOut(cause, UbiquityStoreErrorCauseSeedStore) context:IfOut(context, exception)];
    }

    return NO;
}

- (BOOL)copyMigrateStore:(NSURL *)migrationStoreURL withOptions:(NSDictionary *)migrationStoreOptions
                 toStore:(NSURL *)targetStoreURL withOptions:(NSDictionary *)targetStoreOptions
                   error:(__autoreleasing NSError **)outError cause:(UbiquityStoreErrorCause *)cause context:(__autoreleasing id *)context {

    [self assertQueued];

    NSError *error = nil;
    NSURL *migrationWorkCopyStoreURL = nil;
    @try {
        // If the migration store is read-only, copy it so we can open it without read-only to migrate its model if necessary.
        NSURL *migrationWorkStoreURL = migrationStoreURL;
        NSMutableDictionary *migrationWorkStoreOptions = [migrationStoreOptions mutableCopy];
        if ([migrationWorkStoreOptions[NSReadOnlyPersistentStoreOption] isEqual:@YES] &&
            [[NSFileManager defaultManager] fileExistsAtPath:migrationStoreURL.path]) {
            migrationWorkStoreURL = migrationWorkCopyStoreURL = [[[migrationStoreURL URLByDeletingLastPathComponent]
                    URLByAppendingPathComponent:@"CopyMigrationStore" isDirectory:NO] URLByAppendingPathExtension:@"sqlite"];
            [[NSFileManager defaultManager] removeItemAtURL:migrationWorkStoreURL error:nil];
            if (![[NSFileManager defaultManager] copyItemAtURL:migrationStoreURL toURL:migrationWorkStoreURL error:&error]) {
                [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseOpenSeedStore)
                    context:IfOut(context, migrationStoreURL.path)];
                return NO;
            }
            migrationWorkStoreOptions[NSReadOnlyPersistentStoreOption] = @NO;
            migrationWorkStoreOptions[NSMigratePersistentStoresAutomaticallyOption] = @YES;
            migrationWorkStoreOptions[NSInferMappingModelAutomaticallyOption] = @YES;
        }

        // Open migration store.
        NSPersistentStoreCoordinator *migrationCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
        if (&NSPersistentStoreRemoveUbiquitousMetadataOption && !targetStoreOptions[NSPersistentStoreUbiquitousContentNameKey])
            migrationWorkStoreOptions[NSPersistentStoreRemoveUbiquitousMetadataOption] = @YES;
        NSPersistentStore *migrationStore = [migrationCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                                                                         URL:migrationWorkStoreURL
                                                                                     options:migrationWorkStoreOptions
                                                                                       error:&error];
        if (!migrationStore) {
            [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseOpenSeedStore)
                context:IfOut(context, migrationWorkStoreURL.path)];
            return NO;
        }

        // Open target store.
        NSURL *targetStoreDirectoryURL = [targetStoreURL URLByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:targetStoreDirectoryURL
                                      withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseCreateStorePath)
                context:IfOut(context, targetStoreDirectoryURL.path)];
            return NO;
        }
        NSPersistentStoreCoordinator *targetCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
        NSPersistentStore *targetStore = [targetCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                                                                   URL:targetStoreURL options:targetStoreOptions
                                                                                 error:&error];
        if (!targetStore) {
            [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseOpenActiveStore)
                context:IfOut(context, targetStoreURL.path)];
            return NO;
        }

        // Set up contexts for them.
        NSManagedObjectContext *migrationContext = [NSManagedObjectContext new];
        NSManagedObjectContext *targetContext = [NSManagedObjectContext new];
        migrationContext.persistentStoreCoordinator = migrationCoordinator;
        targetContext.persistentStoreCoordinator = targetCoordinator;

        // Migrate metadata.
        NSMutableDictionary *metadata = [[migrationCoordinator metadataForPersistentStore:migrationStore] mutableCopy];
        for (NSString *key in [[metadata allKeys] copy])
            if ([key hasPrefix:@"com.apple.coredata.ubiquity"])
                    // Don't migrate ubiquitous metadata.
                [metadata removeObjectForKey:key];
        [metadata addEntriesFromDictionary:[targetCoordinator metadataForPersistentStore:targetStore]];
        [targetCoordinator setMetadata:metadata forPersistentStore:targetStore];

        // Migrate entities.
        BOOL migrationFailure = NO;
        NSMutableDictionary *migratedIDsBySourceID = [[NSMutableDictionary alloc] initWithCapacity:500];
        for (NSEntityDescription *entity in self.model.entities) {
            NSFetchRequest *fetch = [NSFetchRequest new];
            fetch.entity = entity;
            fetch.fetchBatchSize = 500;
            fetch.relationshipKeyPathsForPrefetching = entity.relationshipsByName.allKeys;

            NSArray *localObjects = [migrationContext executeFetchRequest:fetch error:&error];
            if (!localObjects) {
                [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseSeedStore)
                    context:IfOut(context, migrationStoreURL.path)];
                migrationFailure = YES;
                break;
            }

            for (NSManagedObject *localObject in localObjects)
                [self copyMigrateObject:localObject toContext:targetContext usingMigrationCache:migratedIDsBySourceID];
        }

        // Save migrated entities and unload the stores.
        if (!migrationFailure && ![targetContext save:&error]) {
            [self error:IfOut(outError, error) cause:IfOut(cause, UbiquityStoreErrorCauseSeedStore)
                context:IfOut(context, migrationStoreURL.path)];
            migrationFailure = YES;
        }
        if (![migrationCoordinator removePersistentStore:migrationStore error:&error])
            [self error:error cause:IfOut(cause, UbiquityStoreErrorCauseClearStore) context:IfOut(context, migrationStore)];
        if (![targetCoordinator removePersistentStore:targetStore error:&error])
            [self error:error cause:IfOut(cause, UbiquityStoreErrorCauseClearStore) context:IfOut(context, targetStore)];
        return !migrationFailure;
    }
    @finally {
        if (migrationWorkCopyStoreURL)
            [[NSFileManager defaultManager] removeItemAtURL:migrationWorkCopyStoreURL error:nil];
    }
}

- (id)copyMigrateObject:(NSManagedObject *)sourceObject toContext:(NSManagedObjectContext *)destinationContext
    usingMigrationCache:(NSMutableDictionary *)migratedIDsBySourceID {

    [self assertQueued];

    if (!sourceObject)
        return nil;

    NSManagedObjectID *destinationObjectID = [migratedIDsBySourceID objectForKey:sourceObject.objectID];
    if (destinationObjectID)
        return [destinationContext objectWithID:destinationObjectID];

    @autoreleasepool {
        // Create migrated object.
        NSEntityDescription *entity = sourceObject.entity;
        NSManagedObject *destinationObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name
                                                                           inManagedObjectContext:destinationContext];
        [migratedIDsBySourceID setObject:destinationObject.objectID forKey:sourceObject.objectID];

        // Set attributes
        for (NSString *key in entity.attributesByName.allKeys)
            [destinationObject setPrimitiveValue:[sourceObject primitiveValueForKey:key] forKey:key];

        // Set relationships recursively
        for (NSRelationshipDescription *relationDescription in entity.relationshipsByName.allValues) {
            NSString *key = relationDescription.name;
            id value = nil;

            if (relationDescription.isToMany) {
                value = [[destinationObject primitiveValueForKey:key] mutableCopy];

                for (NSManagedObject *element in [sourceObject primitiveValueForKey:key])
                    [(NSMutableArray *)value addObject:[self copyMigrateObject:element toContext:destinationContext
                                                           usingMigrationCache:migratedIDsBySourceID]];
            }
            else
                value = [self copyMigrateObject:[sourceObject primitiveValueForKey:key] toContext:destinationContext
                            usingMigrationCache:migratedIDsBySourceID];

            [destinationObject setPrimitiveValue:value forKey:key];
        }

        return destinationObject;
    }
}

- (BOOL)cloudSafeForSeeding {

    if (!self.tentativeStoreUUID && [self storeUUID_ThreadSafe])
            // Migration is not safe when the store UUID is set and not tentative.
        return NO;

    return YES;
}

- (void)removeItemAtURL:(NSURL *)directoryURL localOnly:(BOOL)localOnly {

    // The file coordination below fails without an error, when the file at directoryURL doesn't exist.  We ignore this.
    NSError *error = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil]
            coordinateWritingItemAtURL:directoryURL options:NSFileCoordinatorWritingForDeleting
                                 error:&error byAccessor:
            ^(NSURL *newURL) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:newURL.path])
                    return;

                NSError *error_ = nil;
                if (localOnly && [[NSFileManager defaultManager] isUbiquitousItemAtURL:newURL]) {
                    if (![[NSFileManager defaultManager] evictUbiquitousItemAtURL:newURL error:&error_])
                        [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
                }
                else {
                    if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
                        [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
                }
            }];

    if (error)
        [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:directoryURL.path];
}

- (void)deleteCloudContainerLocalOnly:(BOOL)localOnly {

    if (![self ensureQueued:^{ [self deleteCloudContainerLocalOnly:localOnly]; }])
        return;

    [self log:@"Will delete the cloud container %@.", localOnly? @"on this device": @"on this device and in the cloud"];
    @try {
        if (self.cloudEnabled)
            [self clearStore];

        // Delete the whole cloud container.
        [self removeItemAtURL:[self URLForCloudContainer] localOnly:localOnly];

        // Unset the storeUUID so a new one will be created.
        if (!localOnly) {
            [self createTentativeStoreUUID];
            NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
            [cloud synchronize];
            for (id key in [[cloud dictionaryRepresentation] allKeys])
                [cloud removeObjectForKey:key];
            // Don't synchronize.  Otherwise another devices might recreate the cloud store before we do.
        }
    }
    @finally {
        if (self.cloudEnabled)
            [self reloadStore];
    }
}

- (void)deleteCloudStoreLocalOnly:(BOOL)localOnly {

    if (![self ensureQueued:^{ [self deleteCloudStoreLocalOnly:localOnly]; }])
        return;

    [self log:@"Will delete the cloud store (UUID:%@) %@.", [self storeUUIDForLog],
              localOnly? @"on this device": @"on this device and in the cloud"];
    @try {
        if (self.cloudEnabled)
            [self clearStore];

        // Clean up any cloud stores and transaction logs.
        NSURL *cloudStoreURL = [self URLForCloudStore];
        if ([NSPersistentStoreCoordinator respondsToSelector:@selector(removeUbiquitousContentAndPersistentStoreAtURL:options:error:)]) {
            // iOS 7+
            NSError *error = nil;
            NSDictionary *options = [self optionsForCloudStoreURL:cloudStoreURL];
            if (localOnly) {
                NSMutableDictionary *rebuildOptions = [options mutableCopy];
                [rebuildOptions setObject:@YES forKey:NSPersistentStoreRebuildFromUbiquitousContentOption];
                if (![[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model]
                        addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                               URL:cloudStoreURL options:rebuildOptions error:&error])
                    [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:cloudStoreURL];
            }
            else {
                if (![NSPersistentStoreCoordinator removeUbiquitousContentAndPersistentStoreAtURL:cloudStoreURL
                                                                                          options:options error:&error])
                    [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:cloudStoreURL];
            }
        }
        else {
            // iOS 6
            [self removeItemAtURL:cloudStoreURL localOnly:localOnly];
            [self removeItemAtURL:[self URLForCloudContentForStoreURL:cloudStoreURL] localOnly:localOnly];

            // Create a tentative StoreUUID so a new cloud store will be created.
            if (!localOnly)
                [self createTentativeStoreUUID];
        }
    }
    @finally {
        if (self.cloudEnabled)
            [self reloadStore];
    }
}

- (void)deleteLocalStore {

    if (![self ensureQueued:^{ [self deleteLocalStore]; }])
        return;

    [self log:@"Will delete the local store."];
    @try {
        if (!self.cloudEnabled)
            [self clearStore];

        // Remove just the local store.
        [self removeItemAtURL:[self URLForLocalStore] localOnly:YES];
    }
    @finally {
        if (!self.cloudEnabled)
            [self reloadStore];
    }
}

- (void)migrateCloudToLocal {

    if (![self ensureQueued:^{ [self migrateCloudToLocal]; }])
        return;

    [self log:@"Will overwrite the local store with the cloud store."];
    self.migrationStoreURL = [self URLForCloudStore];
    [self deleteLocalStore];
    self.cloudEnabled = NO;
}

- (void)migrateLocalToCloud {

    if (![self ensureQueued:^{ [self migrateLocalToCloud]; }])
        return;

    NSURL *localStoreURL = self.localStoreURL;
    if (![[NSFileManager defaultManager] fileExistsAtPath:localStoreURL.path]) {
        [self logError:@"Cannot migrate local to cloud: Local store doesn't exist."
                 cause:UbiquityStoreErrorCauseSeedStore context:localStoreURL.path];
        return;
    }

    [self log:@"Will overwrite the cloud store with the local store."];
    self.migrationStoreURL = localStoreURL;
    [self deleteCloudStoreLocalOnly:NO];
    self.cloudEnabled = YES;
}

- (void)rebuildCloudContentFromCloudStoreOrLocalStore:(BOOL)allowRebuildFromLocalStore {

    if (![self ensureQueued:^{ [self rebuildCloudContentFromCloudStoreOrLocalStore:allowRebuildFromLocalStore]; }])
        return;

    NSURL *cloudStoreURL = [self URLForCloudStore];
    NSURL *cloudContentURL = [self URLForCloudContentForStoreURL:cloudStoreURL];
    if ([cloudContentURL isKindOfClass:[NSString class]])
        cloudContentURL = [[self URLForCloudContentDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:YES];

    if (![[NSFileManager defaultManager] fileExistsAtPath:cloudContentURL.path] &&
        ![[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path]) {
        // Cloud content not found.
        if (allowRebuildFromLocalStore) {
            [self log:@"Cannot rebuild cloud content: Cloud store doesn't exist.  Will rebuild from local store."];
            [self deleteCloudStoreLocalOnly:NO];
        }
        else {
            [self log:@"Cannot rebuild cloud content: Cloud store doesn't exist.  Giving up."];
            [self reloadStore];
        }

        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path]) {
        // iOS 7+
        [self log:@"Will rebuild cloud content from the cloud store (using cloud logs)."];
        self.migrationStoreURL = [self URLForCloudStore];
        [self createTentativeStoreUUID];
        [self reloadStore];
    }
    else {
        // iOS 6
        [self log:@"Will rebuild cloud content from the cloud store (ignoring cloud logs)."];
        [self clearStore];

        NSError *error = nil;
        self.migrationStoreURL = [[self URLForCloudStoreDirectory] URLByAppendingPathComponent:USMCloudStoreMigrationSource isDirectory:NO];
        [[NSFileManager defaultManager] removeItemAtURL:self.migrationStoreURL error:nil];
        if (![[NSFileManager defaultManager] moveItemAtURL:cloudStoreURL toURL:self.migrationStoreURL error:&error]) {
            [self error:error cause:UbiquityStoreErrorCauseSeedStore context:self.migrationStoreURL.path];
            [self reloadStore];
            return;
        }

        [self deleteCloudStoreLocalOnly:NO];
        self.cloudEnabled = YES;
    }
}

#pragma mark - Properties

- (BOOL)cloudEnabled {

    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    return self.cloudWasEnabled = [local boolForKey:USMCloudEnabledKey];
}

- (void)setCloudEnabled:(BOOL)enabled {

    if (self.cloudEnabled == enabled)
            // No change, do nothing to avoid a needless store reload.
        return;

    id identityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    if (enabled && !identityToken)
            // Can't enable iCloud: No iCloud account is configured on the device.
        return;

    if (![self ensureQueued:^{ [self setCloudEnabled:enabled]; }])
        return;

    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    [local setBool:self.cloudWasEnabled = enabled forKey:USMCloudEnabledKey];

    [self reloadStore];
}

- (void)setCloudEnabledAndOverwriteCloudWithLocalIfConfirmed:(void (^)(void (^setConfirmationAnswer)(BOOL answer)))confirmationBlock {

    if (self.cloudEnabled)
        return;

    if (![self ensureQueued:^{ [self setCloudEnabledAndOverwriteCloudWithLocalIfConfirmed:confirmationBlock]; }])
        return;

    [self.persistentStoreCoordinator unlock];
    BOOL overwriteCloud = ![self cloudSafeForSeeding] && [self dispatchAndWaitFor:confirmationBlock];
    [self.persistentStoreCoordinator lock];

    if (overwriteCloud)
        [self migrateLocalToCloud];
    else
        [self setCloudEnabled:YES];
}

- (void)setCloudDisabledAndOverwriteLocalWithCloudIfConfirmed:(void (^)(void (^setConfirmationAnswer)(BOOL answer)))confirmationBlock {

    if (!self.cloudEnabled)
        return;

    if (![self ensureQueued:^{ [self setCloudDisabledAndOverwriteLocalWithCloudIfConfirmed:confirmationBlock]; }])
        return;

    [self.persistentStoreCoordinator unlock];
    BOOL overwriteLocal = [[NSFileManager defaultManager] fileExistsAtPath:self.localStoreURL.path] &&
                          [self dispatchAndWaitFor:confirmationBlock];
    [self.persistentStoreCoordinator lock];

    if (overwriteLocal)
        [self migrateCloudToLocal];
    else
        [self setCloudEnabled:NO];
}

- (BOOL)dispatchAndWaitFor:(void (^)(void (^setConfirmationAnswer)(BOOL answer)))confirmationBlock {

    NSAssert(![[NSThread currentThread] isMainThread], @"Cannot dispatch a confirmation from the main thread.");

    __block BOOL confirmation = NO;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter( group );
    dispatch_async( dispatch_get_main_queue(), ^{
        confirmationBlock( ^(BOOL answer) {
            confirmation = answer;
            dispatch_group_leave( group );
        } );
    } );
    dispatch_group_wait( group, DISPATCH_TIME_FOREVER );

    return confirmation;
}

/**
 * Contrary to -storeUUID, this method can return nil, in which case a cloud UUID has not yet been established.
 */
- (NSString *)storeUUID_ThreadSafe {

    if (self.tentativeStoreUUID)
            // A tentative StoreUUID is set; this means a new cloud store is being created.
        return self.tentativeStoreUUID;

    NSURL *storeUUIDFile = [self URLForCloudStoreUUID];
    if (![storeUUIDFile downloadUbiquitousContent])
            // No cloud UUID has ever been set.
        return nil;

    NSError *error = nil;
    NSString *activeUUID = [[NSString alloc] initWithContentsOfURL:storeUUIDFile encoding:NSASCIIStringEncoding error:&error];
    if (!activeUUID || error) {
        // Failed to read StoreUUIDFile.  Without it, we cannot proceed.  Disable iCloud.
        // Delete the file locally in case the user wants to try again.
        [self error:error cause:UbiquityStoreErrorCauseOpenActiveStore context:storeUUIDFile.path];
        self.cloudEnabled = NO;
        [self removeItemAtURL:storeUUIDFile localOnly:YES];
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to obtain active store UUID."
                                     userInfo:@{ NSUnderlyingErrorKey : error? error: [NSNull null] }];
    }

    return activeUUID;
}

- (NSString *)storeUUIDForLog {

    @try {
        return [self storeUUID_ThreadSafe];
    }
    @catch (NSException *exception) {
        return [NSString stringWithFormat:@"<Error:%@>", [exception reason]];
    }
}

- (NSString *)storeUUID {

    [self assertQueued];

    NSString *storeUUID = [self storeUUID_ThreadSafe];

    if (!storeUUID)
            // No StoreUUID is set; this means there is no cloud store yet.  Set a new tentative StoreUUID to create one.
        return [self createTentativeStoreUUID];

    return storeUUID;
}

- (void)setStoreUUID:(NSString *)newStoreUUID {

    if (![self ensureQueued:^{ [self setStoreUUID:newStoreUUID]; }])
        return;

    int cloudVersion = [self desiredCloudVersion];

    // A new cloud store went live: clear any old cloud corruption.
    [self removeItemAtURL:[self URLForCloudCorruptedUUIDForVersion:cloudVersion] localOnly:NO];

    // Tell all other devices about our new cloud store's UUID.
    NSError *error = nil;
    NSURL *storeUUIDFile = [self URLForCloudStoreUUIDForVersion:cloudVersion];
    if (![newStoreUUID writeToURL:storeUUIDFile atomically:NO encoding:NSASCIIStringEncoding error:&error])
        [self error:error cause:UbiquityStoreErrorCauseConfirmActiveStore context:storeUUIDFile];
}

/**
 * When a tentative StoreUUID is set, this operation confirms it and writes it as the new StoreUUID to the iCloud KVS.
 */
- (void)confirmTentativeStoreUUID {

    [self assertQueued];

    if (!self.tentativeStoreUUID)
        return;

    [self log:@"Confirming tentative StoreUUID: %@", self.tentativeStoreUUID];
    [self setStoreUUID:self.tentativeStoreUUID];
    [self unsetTentativeStoreUUID];
}

/**
 * Creates a new a tentative StoreUUID.  This will result in a new cloud store being created.
 */
- (NSString *)createTentativeStoreUUID {

    [self assertQueued];

    return self.tentativeStoreUUID = [[NSUUID UUID] UUIDString];
}

/**
 * Creates a new a tentative StoreUUID.  This will result in a new cloud store being created.
 */
- (void)unsetTentativeStoreUUID {

    [self assertQueued];

    self.tentativeStoreUUID = nil;
}

#pragma mark - Notifications

- (void)storeUUIDDidChange {

    if (![self ensureQueued:^{ [self storeUUIDDidChange]; }])
        return;

    // The UUID of the active store changed.  We need to switch to the newly activated store.
    if ([self.activeCloudStoreUUID isEqualToString:[self storeUUID]])
        return;

    [self log:@"StoreUUID changed %@ -> %@", self.activeCloudStoreUUID, [self storeUUIDForLog]];
    [self unsetTentativeStoreUUID];
    [self cloudStoreChanged:nil];
}

// Cloud content corruption was detected or cleared.
- (void)corruptedUUIDDidChange {

    if (!self.cloudEnabled)
        return;

    if (![self ensureQueued:^{ [self corruptedUUIDDidChange]; }])
        return;

    if (![self handleCloudContentCorruption] && !self.activeCloudStoreUUID)
            // Corruption was removed and our cloud store is not yet loaded.  Try loading the store again.
        [self reloadStore];
}

- (void)accommodateLocalDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    // Clean up.
    [self enqueue:^{ [self clearStore]; } waitUntilFinished:YES];

    // Accommodate deletion.
    completionHandler( nil );

    // Recover.
    [self reloadStore];
}

- (void)accommodateCloudDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    // Clean up.
    [self       enqueue:^{
        if (self.cloudEnabled)
            [self clearStore];

        [self removeItemAtURL:[self URLForCloudStore] localOnly:NO];
        [self removeItemAtURL:[self URLForCloudStoreUUID] localOnly:NO];
        [self removeItemAtURL:[self URLForCloudCorruptedUUID] localOnly:NO];
    } waitUntilFinished:YES];

    // Accommodate deletion.
    completionHandler( nil );

    // Recover.
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManagerHandleCloudContentDeletion:)])
        [self.delegate ubiquityStoreManagerHandleCloudContentDeletion:self];
    else
        self.cloudEnabled = NO;
}

- (void)userDefaultsDidChange:(NSNotification *)note {

    if (self.cloudWasEnabled != self.cloudEnabled)
        [self reloadStore];
}

- (void)applicationDidBecomeActive:(NSNotification *)note {

    // Check for iCloud identity changes (ie. user logs into another iCloud account).
    if (![self.currentIdentityToken isEqual:[[NSFileManager defaultManager] ubiquityIdentityToken]])
        [self cloudStoreChanged:nil];
}

/**
 * Triggered when:
 * 1. An NSError is created describing a transaction log import failure (UbiquityManagedStoreDidDetectCorruptionNotification).
 */
- (void)ubiquityStoreManagerDidDetectCorruption:(NSNotification *)note {

    NSMutableArray *storeURLs = [note.object valueForKey:USMStoreURLsErrorKey];
    if (storeURLs && (id)storeURLs != [NSNull null]) {
        BOOL isForActiveStore = NO;
        NSString *activeStoreUUID = self.storeUUID_ThreadSafe;
        if (!activeStoreUUID)
                // Import failure was not for our store: We don't even have a StoreUUID yet.
            return;
        for (NSURL *storeURL in storeURLs)
            if ((isForActiveStore = ([[storeURL absoluteString] rangeOfString:activeStoreUUID].location != NSNotFound)))
                break;
        if (!isForActiveStore)
                // Import failure was not for our store: Its store URL doesn't contain our StoreUUID.
            return;
    }

    [self logError:@"Detected iCloud transaction log import failure."
             cause:UbiquityStoreErrorCauseCorruptActiveStore context:note.object];
    [self markCloudStoreCorrupted];
}

- (void)markCloudStoreCorrupted {

    self.localCloudStoreCorruptedUUID = self.storeUUID_ThreadSafe;
    if (!self.localCloudStoreCorruptedUUID) {
        NSAssert(self.localCloudStoreCorruptedUUID, @"Corruption detected on a tentative store?");
        return;
    }

    NSError *error = nil;
    NSURL *corruptedUUIDFile = [self URLForCloudCorruptedUUID];
    if (![self.localCloudStoreCorruptedUUID writeToURL:corruptedUUIDFile atomically:NO encoding:NSASCIIStringEncoding error:&error])
        [self error:error cause:UbiquityStoreErrorCauseCorruptActiveStore context:corruptedUUIDFile.path];

    [self enqueue:^{ [self handleCloudContentCorruption]; }];
}

- (BOOL)handleCloudContentCorruption {

    [self assertQueued];

    if (!self.cloudEnabled)
            // Cloud not enabled: cannot handle corruption.
        return NO;

    NSURL *corruptedUUIDFile = [self URLForCloudCorruptedUUID];
    if (![corruptedUUIDFile downloadUbiquitousContent])
            // No corrupted UUID: cloud content is not corrupt.
        return NO;

    NSError *error = nil;
    NSString *corruptedUUID = [[NSString alloc] initWithContentsOfURL:corruptedUUIDFile encoding:NSASCIIStringEncoding error:&error];
    if (!corruptedUUID || error)
        [self error:error cause:UbiquityStoreErrorCauseCorruptActiveStore context:corruptedUUIDFile.path];
    if (![corruptedUUID isEqualToString:self.storeUUID])
            // Our store is not corrupt.
        return NO;

    // Unload the cloud store if it's loaded and corrupt.
    BOOL localStoreCorrupted = [self.localCloudStoreCorruptedUUID isEqualToString:self.storeUUID];
    if (localStoreCorrupted) {
        [self clearStore];
        [self.storeUUIDPresenter = [[USMStoreUUIDPresenter alloc] initWithURL:[self URLForCloudStoreUUID] delegate:self] start];
        [self.corruptedUUIDPresenter = [[USMCorruptedUUIDPresenter alloc] initWithURL:[self URLForCloudCorruptedUUID] delegate:self] start];
    }

    // Notify the delegate of corruption.
    [self log:@"Cloud content corruption detected (store %@).", localStoreCorrupted? @"corrupt": @"healthy"];
    BOOL defaultStrategy = YES;
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:handleCloudContentCorruptionWithHealthyStore:)])
        defaultStrategy = ![self.delegate ubiquityStoreManager:self handleCloudContentCorruptionWithHealthyStore:!localStoreCorrupted];

    // Handle corruption.
    if (!defaultStrategy)
        [self log:@"Application handled cloud corruption."];

    else {
        if (localStoreCorrupted)
                // Store is corrupt: no store available.
            [self log:@"Handling cloud corruption with default strategy: Wait for a remote rebuild."];
        else {
            // Store is healthy: rebuild cloud store.
            [self log:@"Handling cloud corruption with default strategy: Rebuilding cloud content."];
            [self rebuildCloudContentFromCloudStoreOrLocalStore:NO];
        }
    }

    return YES;
}

/**
 * Triggered when:
 * 1. Ubiquity identity changed (NSUbiquityIdentityDidChangeNotification).
 * 2. Store file was deleted (eg. iCloud container deleted in settings).
 * 3. StoreUUID changed (eg. switched to a new cloud store on another device).
 */
- (void)cloudStoreChanged:(NSNotification *)note {

    // Update the identity token in case it changed.
    id newIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];
    if (![self.currentIdentityToken isEqual:newIdentityToken] || (self.currentIdentityToken == nil && newIdentityToken)) {
        [self log:@"Identity token changed: %@ -> %@", self.currentIdentityToken, newIdentityToken];
        self.currentIdentityToken = newIdentityToken;
        self.cloudAvailable = (self.currentIdentityToken != nil);
    }

    // If the cloud store was active, reload it.
    if (self.cloudEnabled)
        [self reloadStore];
}

- (void)mergeChanges:(NSNotification *)note {

    NSManagedObjectContext *moc = nil;
    if ([self.delegate respondsToSelector:@selector(managedObjectContextForUbiquityChangesInManager:)])
        moc = [self.delegate managedObjectContextForUbiquityChangesInManager:self];
    if (moc) {
        [self log:@"Importing ubiquity changes into application's MOC.  Changes:\n%@", note.userInfo];
        [moc performBlockAndWait:^{
            [moc mergeChangesFromContextDidSaveNotification:note];

            NSError *error = nil;
            if ([moc hasChanges] && ![moc save:&error]) {
                [self error:error cause:UbiquityStoreErrorCauseImportChanges context:note];
                [self reloadStore];
                return;
            }
        }];
    }
    else
        [self log:@"Application did not specify an import MOC, not importing ubiquity changes:\n%@", note.userInfo];

    dispatch_async( dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:USMStoreDidImportChangesNotification
                                                            object:self userInfo:[note userInfo]];
    } );
}

- (void)willChange:(NSNotification *)note {

    if (![self ensureQueued:^{ [self willChange:note]; }])
        return;

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)]) {
        [self.persistentStoreCoordinator unlock];

        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];
        [[NSNotificationCenter defaultCenter] postNotificationName:USMStoreWillChangeNotification
                                                            object:self userInfo:nil];

        [self.persistentStoreCoordinator lock];
    }
}

- (void)didChange:(NSNotification *)note {

    if (![self ensureQueued:^{ [self didChange:note]; }])
        return;

    NSPersistentStoreCoordinator *psc = self.persistentStoreCoordinator;
    dispatch_async( dispatch_get_main_queue(), ^{
        // Make sure the PSC is still valid.
        @try {
            if (![psc tryLock] || ![[psc persistentStores] count])
                return;
        }
        @finally {
            [psc unlock];
        }

        // Notify the application.
        if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
            [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:psc isCloud:self.cloudEnabled];
        [[NSNotificationCenter defaultCenter] postNotificationName:USMStoreDidChangeNotification
                                                            object:self userInfo:nil];
    } );
}

@end

// The presenters used to monitor cloud files.

@implementation USMStoreFilePresenter

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    [self.delegate accommodateLocalDeletionWithCompletionHandler:completionHandler];
}

@end

@implementation USMStoreUUIDPresenter

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    [self.delegate accommodateCloudDeletionWithCompletionHandler:completionHandler];
}

- (void)presentedItemDidChange {

    [self.delegate storeUUIDDidChange];
}

@end

@implementation USMCorruptedUUIDPresenter

- (void)presentedItemDidChange {

    [self.delegate corruptedUUIDDidChange];
}

@end

// Monitoring implementation.

@implementation USMFilePresenter {
    NSURL *_presentedItemURL;
    NSOperationQueue *_presentedItemOperationQueue;
}

- (id)initWithURL:(NSURL *)presentedItemURL delegate:(UbiquityStoreManager *)delegate {

    if (!(self = [super init]))
        return nil;

    _delegate = delegate;
    _presentedItemURL = presentedItemURL;
    _presentedItemOperationQueue = [NSOperationQueue new];
    _presentedItemOperationQueue.name = [NSString stringWithFormat:@"%@PresenterQueue", NSStringFromClass( [self class] )];

    return self;
}

- (void)start {

    [NSFileCoordinator addFilePresenter:self];
}

- (void)stop {

    [NSFileCoordinator removeFilePresenter:self];
}

- (NSURL *)presentedItemURL {

    return _presentedItemURL;
}

- (NSOperationQueue *)presentedItemOperationQueue {

    return _presentedItemOperationQueue;
}

@end

@implementation USMFileContentPresenter

- (id)initWithURL:(NSURL *)presentedItemURL delegate:(UbiquityStoreManager *)delegate {

    if (!(self = [super initWithURL:presentedItemURL delegate:delegate]))
        return nil;

    _query = [NSMetadataQuery new];
    _query.searchScopes = @[ NSMetadataQueryUbiquitousDataScope ];
    _query.predicate = [NSPredicate predicateWithFormat:@"%K == %@", NSMetadataItemFSNameKey, [presentedItemURL lastPathComponent]];

    return self;
}

- (void)start {

    [super start];

    [[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidUpdateNotification object:_query queue:nil usingBlock:
            ^(NSNotification *note) {
                [self.query disableUpdates];
                for (NSUInteger r = 0; r < [self.query resultCount]; ++r)
                    if ([[self.query valueOfAttribute:NSMetadataItemURLKey forResultAtIndex:r] isEqual:[self presentedItemURL]])
                        [self presentedItemDidChange];
                [self.query enableUpdates];
            }];

    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (![self.query startQuery])
            [self.delegate log:@"Couldn't start monitor query for %@, already running?", [self.presentedItemURL lastPathComponent]];
    }];
}

- (void)stop {

    [super stop];

    [self.query stopQuery];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
