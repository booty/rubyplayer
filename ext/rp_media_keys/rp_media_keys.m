#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>

/* Line protocol shared with lib/rubyplayer/media_keys.rb: commands go out
 * by name, and playback state arrives as "playing", "paused" or "stopped". */
static void publish_command(NSString *command_name) {
    printf("%s\n", command_name.UTF8String);
    fflush(stdout);
}

static void update_playback(NSDictionary *state) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    NSString *title = state[@"title"];
    BOOL playing = [state[@"state"] isEqual:@"playing"];
    BOOL paused = [state[@"state"] isEqual:@"paused"];
    if (![title isKindOfClass:[NSString class]] || !(playing || paused)) {
        center.nowPlayingInfo = nil;
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        return;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = title;
    if ([state[@"artist"] isKindOfClass:[NSString class]])
        info[MPMediaItemPropertyArtist] = state[@"artist"];
    if ([state[@"album"] isKindOfClass:[NSString class]])
        info[MPMediaItemPropertyAlbumTitle] = state[@"album"];
    double duration_s = [state[@"duration_s"] doubleValue];
    if (duration_s > 0) info[MPMediaItemPropertyPlaybackDuration] = @(duration_s);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state[@"position_s"] ?: @0;
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(playing ? 1.0 : 0.0);
    center.nowPlayingInfo = info;
    center.playbackState = playing ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
            puts([NSBundle mainBundle].bundleIdentifier.UTF8String ?: "");
            return 0;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
        NSDictionary<NSString *, MPRemoteCommand *> *commands = @{
            @"toggle_play": center.togglePlayPauseCommand, @"next_track": center.nextTrackCommand,
            @"previous_track": center.previousTrackCommand, @"play": center.playCommand,
            @"pause": center.pauseCommand
        };
        [commands enumerateKeysAndObjectsUsingBlock:^(NSString *name, MPRemoteCommand *command, BOOL *stop) {
            [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
                publish_command(name);
                return MPRemoteCommandHandlerStatusSuccess;
            }];
            command.enabled = YES;
        }];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char line[65536];
            while (fgets(line, sizeof(line), stdin)) {
                /* Hand raw bytes to the JSON parser: it rejects bad UTF-8 by
                 * returning nil, where a nil NSData would throw instead. */
                NSData *data = [NSData dataWithBytes:line length:strlen(line)];
                NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([state isKindOfClass:[NSDictionary class]]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ update_playback(state); });
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
        [NSApp run];
    }
    return 0;
}
