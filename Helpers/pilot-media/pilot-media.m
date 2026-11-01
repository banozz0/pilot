// pilot-media: pauses and resumes what is playing while Pilot dictates (Dictation › Pause media while dictating), and
// feeds the Now playing widget (WidgetNowPlaying.swift) what plays, its artwork and its controls.
// macOS 15.4 and later answer MediaRemote's now-playing questions only to Apple's own programs, so this library runs
// inside /usr/bin/perl, which macOS lets ask, loaded by pilot-media.pl: the approach of ungive/mediaremote-adapter
// (BSD-3-Clause), which Wispr Flow ships for the same setting; this code is Pilot's own. Each function is called as a
// Perl XSUB, its two arguments unused, prints one line and returns.
//   pause   paused, when the now-playing app was playing and was sent Pause; else idle
//   play    played: the now-playing app was sent Play
//   info    what plays now: a state line, then an art line when it has artwork (the Widgets page's preview)
//   watch   a state line now and at each change MediaRemote tells of, an art line after one whose artwork changed; stdin
//           takes toggle, next, previous (each reported 0.4 s after) and read, one a line; it ends with stdin
//   toggle, next, previous   sends that command once: sent or failed
// A state line: {"kind":"state","title","artist","album","app","bundle","playing","duration","elapsed","art"}, elapsed as of
// the line, art the artwork's id; no title when nothing has played. An art line: {"kind":"art","art","data"}, data base64.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdio.h>

typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*SendFn)(int, CFDictionaryRef);
typedef void (*InfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*RegisterFn)(dispatch_queue_t);
// MRMediaRemoteCommand: kMRPlay 0, kMRPause 1, kMRTogglePlayPause 2, kMRNextTrack 4, kMRPreviousTrack 5.
enum { Play = 0, Pause = 1, Toggle = 2, Next = 4, Previous = 5 };

static void *remote(const char *name) {
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return framework ? dlsym(framework, name) : NULL;
}

/// Whether the now-playing app is playing; false when MediaRemote does not answer within a second.
static BOOL playing(void) {
    IsPlayingFn isPlaying = (IsPlayingFn)remote("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!isPlaying) return NO;
    __block BOOL answer = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    isPlaying(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(Boolean is) { answer = is; dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    return answer;
}

static BOOL send(int command) {
    SendFn sendCommand = (SendFn)remote("MRMediaRemoteSendCommand");
    return sendCommand && sendCommand(command, NULL);
}

__attribute__((visibility("default"))) void pilot_media_pause(void *perl, void *cv) {
    puts(playing() && send(Pause) ? "paused" : "idle");
    fflush(stdout);
}

__attribute__((visibility("default"))) void pilot_media_play(void *perl, void *cv) {
    puts(send(Play) ? "played" : "failed");
    fflush(stdout);
}

// MARK: - Now playing

/// The command a word names, -1 for none.
static int command(NSString *word) {
    NSDictionary *commands = @{@"toggle": @(Toggle), @"next": @(Next), @"previous": @(Previous)};
    NSNumber *found = commands[word];
    return found ? found.intValue : -1;
}

static void line(NSDictionary *fields) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:fields options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// MediaRemote's now-playing info, nil when nothing has played or it does not answer within a second.
static NSDictionary *nowPlayingInfo(void) {
    InfoFn get = (InfoFn)remote("MRMediaRemoteGetNowPlayingInfo");
    if (!get) return nil;
    __block NSDictionary *info = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    get(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(CFDictionaryRef found) {
        info = [(__bridge NSDictionary *)found copy];
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    return info;
}

/// The artwork's bytes as the player hands them over when asked (the info lists most players' artwork without them),
/// else as the info carries them; nil without.
static NSData *artwork(NSDictionary *info) {
    __block NSData *bytes = nil;
    Class request = objc_getClass("MRNowPlayingRequest");
    SEL ask = sel_registerName("requestNowPlayingItemArtworkOnQueue:completion:");
    if (request && [request instancesRespondToSelector:ask]) {
        id asking = [[request alloc] init];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        void (^answer)(id, id) = ^(id art, id error) {
            @try { id data = [art valueForKey:@"imageData"]; if ([data isKindOfClass:NSData.class]) bytes = data; } @catch (id e) {}
            dispatch_semaphore_signal(done);
        };
        ((void (*)(id, SEL, dispatch_queue_t, id))objc_msgSend)(asking, ask, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), answer);
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    if (!bytes.length) {
        id data = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([data isKindOfClass:NSData.class]) bytes = data;
    }
    // Past 4 MB it is left out: Pilot draws a thumbnail of it.
    return bytes.length && bytes.length <= 4 << 20 ? bytes : nil;
}

/// The app playing: its name and bundle id, from MediaRemote's player path.
static void player(NSMutableDictionary *state) {
    @try {
        id client = [[objc_getClass("MRNowPlayingRequest") valueForKey:@"localNowPlayingPlayerPath"] valueForKey:@"client"];
        id name = [client valueForKey:@"displayName"], bundle = [client valueForKey:@"bundleIdentifier"];
        if ([name isKindOfClass:NSString.class]) state[@"app"] = name;
        if ([bundle isKindOfClass:NSString.class]) state[@"bundle"] = bundle;
    } @catch (id e) {}
}

/// The art id a state line carried last, so an art line follows only a change.
static NSString *lastArt;

/// Prints what plays now as a state line, then, when its artwork changed (or `always`), an art line.
static void report(BOOL always) {
    NSDictionary *info = nowPlayingInfo();
    NSMutableDictionary *state = [@{@"kind": @"state", @"playing": @(playing())} mutableCopy];
    NSString *(^text)(NSString *) = ^NSString *(NSString *name) {
        id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:name]];
        return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
    };
    double (^number)(NSString *) = ^double(NSString *name) {
        id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:name]];
        return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : -1;
    };
    NSString *title = text(@"Title");
    if (title) {
        state[@"title"] = title;
        if (text(@"Artist")) state[@"artist"] = text(@"Artist");
        if (text(@"Album")) state[@"album"] = text(@"Album");
        double duration = number(@"Duration"), elapsed = MAX(number(@"ElapsedTime"), 0), rate = number(@"PlaybackRate");
        // The elapsed time is as of the info's timestamp: carried on to now at its rate while it plays.
        id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([stamp isKindOfClass:NSDate.class] && rate > 0) elapsed += -[stamp timeIntervalSinceNow] * rate;
        if (duration > 0) { state[@"duration"] = @(duration); elapsed = MIN(elapsed, duration); }
        state[@"elapsed"] = @(elapsed);
        player(state);
    }
    NSString *art = nil;
    if (title && (text(@"ArtworkIdentifier") || text(@"ArtworkMIMEType") || info[@"kMRMediaRemoteNowPlayingInfoArtworkData"])) {
        art = text(@"ArtworkIdentifier") ?: [NSString stringWithFormat:@"%lx", (unsigned long)[@[title, text(@"Artist") ?: @"", text(@"Album") ?: @""] hash]];
        state[@"art"] = art;
    }
    line(state);
    BOOL changed = !(art == lastArt || [art isEqualToString:lastArt]);
    lastArt = art;
    if (art && (changed || always)) {
        NSData *bytes = artwork(info);
        if (bytes) line(@{@"kind": @"art", @"art": art, @"data": [bytes base64EncodedStringWithOptions:0]});
    }
}

__attribute__((visibility("default"))) void pilot_media_info(void *perl, void *cv) { report(YES); }

static void sendOnce(int which) {
    puts(send(which) ? "sent" : "failed");
    fflush(stdout);
}

__attribute__((visibility("default"))) void pilot_media_toggle(void *perl, void *cv) { sendOnce(Toggle); }
__attribute__((visibility("default"))) void pilot_media_next(void *perl, void *cv) { sendOnce(Next); }
__attribute__((visibility("default"))) void pilot_media_previous(void *perl, void *cv) { sendOnce(Previous); }

/// A report a quarter second after the last change asked for one: a track change posts several notifications at once.
static void soon(double seconds) {
    static NSUInteger asked;
    NSUInteger mine = ++asked;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == asked) report(NO);
    });
}

/// stdin's lines: a command is sent and reported 0.4 s after, as the player moves; read reports now. Its end ends this.
static void take(NSString *word) {
    if ([word isEqualToString:@"read"]) return report(NO);
    int which = command(word);
    if (which >= 0 && send(which)) soon(0.4);
}

__attribute__((visibility("default"))) void pilot_media_watch(void *perl, void *cv) {
    RegisterFn listen = (RegisterFn)remote("MRMediaRemoteRegisterForNowPlayingNotifications");
    if (listen) listen(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        CFStringRef *exported = (CFStringRef *)remote(name.UTF8String);
        NSString *posted = exported && *exported ? (__bridge NSString *)*exported : name;
        [NSNotificationCenter.defaultCenter addObserverForName:posted object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { soon(0.25); }];
    }
    static NSMutableData *pending;
    pending = [NSMutableData data];
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char chunk[256];
        ssize_t got = read(STDIN_FILENO, chunk, sizeof chunk);
        if (got <= 0) exit(0);
        [pending appendBytes:chunk length:(NSUInteger)got];
        for (;;) {
            NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSString *word = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, newline.location)] encoding:NSUTF8StringEncoding];
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            take([word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"");
        }
        if (pending.length > 1024) exit(0);
    });
    dispatch_resume(input);
    report(YES);
    CFRunLoopRun();
}
