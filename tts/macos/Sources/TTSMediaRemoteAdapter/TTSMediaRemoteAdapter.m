// Derived from mediaremote-adapter by Jonas van den Berg and contributors.
// Licensed under the BSD 3-Clause License; see ThirdParty/MediaRemoteAdapter-LICENSE.txt.

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import "TTSMediaRemoteAdapter.h"

typedef bool (*MRSendCommand)(NSInteger command, id userInfo);
typedef void (*MRGetPID)(dispatch_queue_t queue, void (^completion)(int pid));
typedef void (*MRGetPlaying)(dispatch_queue_t queue, void (^completion)(Boolean playing));
typedef void (*MRGetInfo)(dispatch_queue_t queue, void (^completion)(CFDictionaryRef info));

static MRSendCommand sendCommand;
static MRGetPID getPID;
static MRGetPlaying getPlaying;
static MRGetInfo getInfo;
static dispatch_queue_t mediaQueue;

static void printLine(NSString *line) {
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static void printError(NSString *line) {
    fprintf(stderr, "%s\n", line.UTF8String);
    fflush(stderr);
}

static void printJSON(NSDictionary *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (data == nil) {
        printError([NSString stringWithFormat:@"MediaRemote JSON error: %@", error]);
        printLine(@"null");
        return;
    }
    printLine([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}

__attribute__((constructor)) static void loadMediaRemote(void) {
    NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
    if (bundle == NULL) {
        return;
    }
    sendCommand = (MRSendCommand)CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteSendCommand")
    );
    getPID = (MRGetPID)CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationPID")
    );
    getPlaying = (MRGetPlaying)CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
    );
    getInfo = (MRGetInfo)CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteGetNowPlayingInfo")
    );
    mediaQueue = dispatch_queue_create("tts.mediaremote.adapter", DISPATCH_QUEUE_SERIAL);
}

static void copyValue(NSMutableDictionary *payload, NSDictionary *info, NSString *outputKey,
                      NSString *mediaRemoteKey) {
    id value = info[mediaRemoteKey];
    if (value != nil) {
        payload[outputKey] = value;
    }
}

void tts_media_remote_get(void) {
    if (getPID == NULL || getPlaying == NULL || getInfo == NULL || mediaQueue == nil) {
        printError(@"MediaRemote functions are unavailable");
        printLine(@"null");
        return;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    getPID(mediaQueue, ^(int pid) {
        if (pid > 0) {
            payload[@"processIdentifier"] = @(pid);
            NSRunningApplication *app = [NSRunningApplication
                runningApplicationWithProcessIdentifier:pid];
            if (app.bundleIdentifier != nil) {
                payload[@"bundleIdentifier"] = app.bundleIdentifier;
            }
        }
        dispatch_group_leave(group);
    });

    dispatch_group_enter(group);
    getPlaying(mediaQueue, ^(Boolean playing) {
        payload[@"playing"] = @((BOOL)playing);
        dispatch_group_leave(group);
    });

    dispatch_group_enter(group);
    getInfo(mediaQueue, ^(CFDictionaryRef rawInfo) {
        if (rawInfo != NULL) {
            NSDictionary *info = (__bridge NSDictionary *)rawInfo;
            copyValue(payload, info, @"title", @"kMRMediaRemoteNowPlayingInfoTitle");
            copyValue(payload, info, @"artist", @"kMRMediaRemoteNowPlayingInfoArtist");
            copyValue(payload, info, @"album", @"kMRMediaRemoteNowPlayingInfoAlbum");
            copyValue(payload, info, @"uniqueIdentifier",
                      @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier");
            copyValue(payload, info, @"contentItemIdentifier",
                      @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier");
        }
        dispatch_group_leave(group);
    });

    long result = dispatch_group_wait(
        group, dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC)
    );
    if (result != 0) {
        printError(@"Reading MediaRemote state timed out");
        printLine(@"null");
        return;
    }

    if (payload[@"title"] == nil && payload[@"bundleIdentifier"] == nil) {
        printLine(@"null");
        return;
    }
    printJSON(payload);
}

void tts_media_remote_send_env(void) {
    const char *rawCommand = getenv("TTS_MEDIA_REMOTE_COMMAND");
    NSString *command = rawCommand == NULL ? @"" : [NSString stringWithUTF8String:rawCommand];
    NSInteger commandID = [command isEqualToString:@"play"] ? 0 : 1;
    bool valid = [command isEqualToString:@"play"] || [command isEqualToString:@"pause"];
    bool accepted = valid && sendCommand != NULL && sendCommand(commandID, nil);

    if (accepted && getPlaying != NULL) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        getPlaying(mediaQueue, ^(Boolean playing) {
            dispatch_semaphore_signal(semaphore);
        });
        dispatch_semaphore_wait(
            semaphore, dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC)
        );
    }
    printJSON(@{@"accepted": @(accepted)});
}
