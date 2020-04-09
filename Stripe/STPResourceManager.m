//
//  STPResourceManager.m
//  StripeiOS
//
//  Created by David Estes on 4/7/20.
//  Copyright © 2020 Stripe, Inc. All rights reserved.
//

#import "STPResourceManager.h"
#import "STPBundleLocator.h"

static NSString * const ResourceBaseURL = @"https://d37fzvdshh1bs8.cloudfront.net";

typedef void(^STPResourceManagerImageUpdateBlock)(UIImage * _Nullable);
typedef void(^STPResourceManagerJSONUpdateBlock)(NSDictionary * _Nullable);
static NSTimeInterval const STPCacheExpirationInterval = (60 * 60 * 24 * 7);
typedef NS_ENUM(NSInteger, STPResourceType) {
    STPResourceTypeImage,
    STPResourceTypeJSON
};


@interface NSFileManager (STPOverwriting)
- (BOOL)stp_destructivelyMoveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error;
@end

@implementation NSFileManager (STPOverwriting)
- (BOOL)stp_destructivelyMoveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
    NSError *moveError;
    BOOL didMove = [[NSFileManager defaultManager] moveItemAtURL:srcURL toURL:dstURL error:&moveError];
    // The file may already exist, in which case we'd like to replace it:
    if (moveError.code == NSFileWriteFileExistsError) {
        [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];
        didMove = [[NSFileManager defaultManager] moveItemAtURL:srcURL toURL:dstURL error:&moveError];
    }
    
    if (error) {
        *error = moveError;
    }
    return didMove;
}
@end

@interface UIImage (STPBlankImage)
+ (UIImage *)stp_blankImage;
@end

@implementation UIImage (STPBlankImage)
+ (UIImage *)stp_blankImage {
    static UIImage *blankImage;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(100, 100), NO, 0);
        blankImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return blankImage;
}
@end

@interface NSJSONSerialization (STPDeserializeDictionary)
+ (NSDictionary * _Nullable)stp_JSONDictionaryWithData:(NSData *)data;
@end

@implementation NSJSONSerialization (STPDeserializeDictionary)
+ (NSDictionary * _Nullable)stp_JSONDictionaryWithData:(NSData *)data {
    if (data == nil) {
        return nil;
    }
    NSError *jsonError;
    NSDictionary *json = nil;

    // This can throw exceptions internally if we give it bad data.
    // Wrap it in a try/catch block and return nil on failures. We can't do anything sensible if the JSON isn't valid.
    @try {
        json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    } @catch (NSException *exception) {
        return nil;
    }

    if (jsonError == nil && json != nil && [json isKindOfClass:[NSDictionary class]]) {
        return json;
    }
    
    return nil;
}

@end

@implementation STPResourceManager {
    dispatch_queue_t _resourceQueue;
    NSURLSession *_urlSession;
    NSOperationQueue *_resourceOperationQueue;
    NSMutableDictionary<NSString *, UIImage *> *_imageCache;
    NSMutableDictionary<NSString *, NSDictionary *> *_jsonCache;
    NSMutableDictionary<NSString *, NSURLSessionTask *> *_pendingRequests;
    NSMutableDictionary<NSString *, NSMutableArray *> *_updateBlocks;
}

+ (instancetype)sharedManager {
    static id sharedManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedManager = [[self alloc] init]; });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    _resourceQueue = dispatch_queue_create("Stripe Resource Cache", DISPATCH_QUEUE_CONCURRENT);
    _resourceOperationQueue = [[NSOperationQueue alloc] init];
    _resourceOperationQueue.underlyingQueue = _resourceQueue;
    _urlSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:_resourceOperationQueue];
    _imageCache = [[NSMutableDictionary alloc] init];
    _jsonCache = [[NSMutableDictionary alloc] init];
    _updateBlocks = [[NSMutableDictionary alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resetMemoryCache) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)resetMemoryCache {
    @synchronized (_imageCache) {
        [_imageCache removeAllObjects];
    }
    @synchronized (_jsonCache) {
        [_jsonCache removeAllObjects];
    }
}

- (void)resetDiskCache {
    @synchronized (_imageCache) {
        NSURL *resourceBaseURL = [self cacheUrlForResource:@""];
        [[NSFileManager defaultManager] removeItemAtURL:resourceBaseURL error:nil];
        [_imageCache removeAllObjects];
    }
    @synchronized (_jsonCache) {
        [_jsonCache removeAllObjects];
    }
}

#pragma mark Download Management

- (BOOL)shouldRefreshResource:(NSString *)name {
    NSURL *cacheURL = [self cacheUrlForResource:name];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[cacheURL path] error:nil];
    if (attributes == nil || [[attributes fileModificationDate] timeIntervalSinceNow] < -STPCacheExpirationInterval) {
        return YES;
    }
    return NO;
}

- (NSURL *)cacheUrlForResource:(NSString *)name
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *temporaryDirectory = [paths objectAtIndex:0];
    NSString *stpCachePath = [temporaryDirectory stringByAppendingPathComponent:@"STPCache"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:stpCachePath]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:stpCachePath withIntermediateDirectories:NO attributes:nil error:nil];
    }
    NSString *filePath = [stpCachePath stringByAppendingPathComponent:name];
    return [NSURL fileURLWithPath:filePath];
}

- (void)_addUpdateHandler:(id)block forName:(NSString *)name {
    if (!block) {
        return;
    }
    NSMutableArray *blocks = [_updateBlocks objectForKey:name];
    if (blocks == nil) {
        blocks = [[NSMutableArray alloc] init];
        _updateBlocks[name] = blocks;
    }
    [blocks addObject:block];
}


- (void)_downloadFile:(NSString *)name ofType:(STPResourceType)resourceType {
    // TODO: add @2x or @3x here for images depending on our screen size. imageWithContentsOfFile and imageNamed will do this automatically. make sure the right name is still used for completion blocks.
    NSString *filename = [ResourceBaseURL stringByAppendingPathComponent:name];
    NSURL *url = [[NSURL alloc] initWithString:filename];
    if ([_pendingRequests objectForKey:name]) {
        return; // We're still waiting on an existing request.
    }
    NSURLSessionDownloadTask *task = [_urlSession downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, __unused NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error != nil) {
            [self->_pendingRequests removeObjectForKey:name];
            [self->_updateBlocks removeObjectForKey:name];
            return;
        }
        if (resourceType == STPResourceTypeImage) {
            [self _handleDownloadedImage:location forName:name];
        } else if (resourceType == STPResourceTypeJSON) {
            [self _handleDownloadedJSON:location forName:name];
        }
    }];
    [_pendingRequests setObject:task forKey:name];
    [task resume];
}


#pragma mark Images

- (UIImage *)imageNamed:(NSString *)name {
    return [self imageNamed:name updateHandler:nil];
}

- (UIImage *)imageNamed:(NSString *)name updateHandler:(nullable void (^)(UIImage * _Nullable))updateHandler {
    // First, check the in-memory cache.
    UIImage *image = nil;
    @synchronized (_imageCache) {
        image = [_imageCache objectForKey:name];
    }
    if (image != nil) {
        return image;
    }

    // If not available, check the disk cache:
    image = [UIImage imageWithContentsOfFile:[[self cacheUrlForResource:name] path]];
    if (image != nil) {
        @synchronized (_imageCache) {
            _imageCache[name] = image;
        }
        // If the resource isn't too old, we can stop here.
        if (![self shouldRefreshResource:name]) {
            return image;
        }
    }
    
    // If there isn't an image in the cache, it might be in our bundle.
    if (image == nil) {
        image = [UIImage imageNamed:name];
    }
    
    // And if we *still* have nothing, return an empty UIImage as a placeholder.
    if (image == nil) {
        image = [UIImage stp_blankImage];
    }
    
    // Enqueue the update handler and kick off the update request:
    dispatch_async(_resourceQueue, ^{
        @synchronized (self->_pendingRequests) {
            [self _addUpdateHandler:updateHandler forName:name];
            [self _downloadFile:name ofType:STPResourceTypeImage];
        }
    });
    return image;
}

- (void)_handleDownloadedImage:(NSURL *)location forName:(NSString *)name {
    UIImage *image = [UIImage imageWithContentsOfFile:[location path]];
    
    // If this isn't a valid image, we'll give up and try again on the next request.
    if (image == nil) {
        @synchronized (self->_pendingRequests) {
            [self->_pendingRequests removeObjectForKey:name];
            [self->_updateBlocks removeObjectForKey:name];
        }
        return;
    }
    
    NSURL *destLocation = [self cacheUrlForResource:name];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] stp_destructivelyMoveItemAtURL:location toURL:destLocation error:&moveError];

    @synchronized (self->_imageCache) {
        self->_imageCache[name] = image;
        @synchronized (self->_pendingRequests) {
            // Notify all our stored update blocks:
            [self->_pendingRequests removeObjectForKey:name];
            NSArray<STPResourceManagerImageUpdateBlock> *updates = [self->_updateBlocks objectForKey:name];
            for (STPResourceManagerImageUpdateBlock update in updates) {
                update(image);
            }
            [self->_updateBlocks removeObjectForKey:name];
        }
    }
}

#pragma mark JSON

- (NSDictionary *)jsonNamed:(NSString *)name {
    return [self jsonNamed:name updateHandler:nil];
}

- (NSDictionary *)jsonNamed:(NSString *)name updateHandler:(nullable void (^)(NSDictionary * _Nullable))updateHandler {
    // Get JSON from cache:
    NSDictionary *json = nil;
    @synchronized (_jsonCache) {
        json = [_jsonCache objectForKey:name];
    }
    if (json != nil) {
        return json;
    }
    // If it isn't available, check the disk:
    NSData *jsonData = [NSData dataWithContentsOfURL:[self cacheUrlForResource:name]];
    json = [NSJSONSerialization stp_JSONDictionaryWithData:jsonData];
    if (json != nil) {
        @synchronized (_jsonCache) {
            _jsonCache[name] = json;
        }
        // If we don't need to refresh it, we can stop here.
        if (![self shouldRefreshResource:name]) {
            return json;
        }
    }

    if (json == nil) {
        // If there isn't a JSON file in the cache, try checking our bundle.
        NSURL *resourceURL = [[STPBundleLocator stripeResourcesBundle] URLForResource:[name stringByDeletingPathExtension] withExtension:[name pathExtension]];
        if (resourceURL != nil) {
            jsonData = [NSData dataWithContentsOfURL:resourceURL];
            json = [NSJSONSerialization stp_JSONDictionaryWithData:jsonData];
            @synchronized (_jsonCache) {
                _jsonCache[name] = json;
            }
        }
    }

    // Enqueue the update block and kick off the update request:
    dispatch_async(_resourceQueue, ^{
        @synchronized (self->_pendingRequests) {
            [self _addUpdateHandler:updateHandler forName:name];
            [self _downloadFile:name ofType:STPResourceTypeJSON];
        }
    });
    return json;
}

- (void)_handleDownloadedJSON:(NSURL *)location forName:(NSString *)name {
    NSData *jsonData = [NSData dataWithContentsOfURL:location];
    NSDictionary *json = [NSJSONSerialization stp_JSONDictionaryWithData:jsonData];
    
    // If we failed to deserialize this into a dictionary, give up and try again on the next request.
    if (json == nil) {
        [self->_pendingRequests removeObjectForKey:name];
        [self->_updateBlocks removeObjectForKey:name];
        return;
    }
    NSURL *destLocation = [self cacheUrlForResource:name];
    
    [[NSFileManager defaultManager] stp_destructivelyMoveItemAtURL:location toURL:destLocation error:nil];

    @synchronized (self->_jsonCache) {
        self->_jsonCache[name] = json;
        @synchronized (self->_pendingRequests) {
            [self->_pendingRequests removeObjectForKey:name];
            NSArray<STPResourceManagerJSONUpdateBlock> *updates = [self->_updateBlocks objectForKey:name];
            for (STPResourceManagerJSONUpdateBlock update in updates) {
                update(json);
            }
            [self->_updateBlocks removeObjectForKey:name];
        }
    }
}

@end