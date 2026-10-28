// pilot-media: pauses and resumes what is playing while Pilot dictates (Dictation › Pause media while dictating).
// macOS 15.4 and later answer MediaRemote's now-playing questions only to Apple's own programs, so this library runs
// inside /usr/bin/perl, which macOS lets ask, loaded by pilot-media.pl: the approach of ungive/mediaremote-adapter
// (BSD-3-Clause), which Wispr Flow ships for the same setting; this code is Pilot's own. Each function is called as a
// Perl XSUB, its two arguments unused, prints one line and returns.
//   pause   paused, when the now-playing app was playing and was sent Pause; else idle
//   play    played: the now-playing app was sent Play
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>

typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*SendFn)(int, CFDictionaryRef);
// MRMediaRemoteCommand: kMRPlay 0, kMRPause 1.
enum { Play = 0, Pause = 1 };

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
