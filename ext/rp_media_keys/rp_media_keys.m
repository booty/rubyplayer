#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>

static void publish_command(int command_id) {
    printf("%d\n", command_id);
    fflush(stdout);
}

static void update_playback(NSDictionary *state) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    NSString *title = state[@"title"];
    NSInteger playback_state = [state[@"state"] integerValue];
    if (![title isKindOfClass:[NSString class]] || playback_state == 0) {
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
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(playback_state == 1 ? 1.0 : 0.0);
    center.nowPlayingInfo = info;
    center.playbackState = playback_state == 1 ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
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
        NSArray *commands = @[center.togglePlayPauseCommand, center.nextTrackCommand,
                              center.previousTrackCommand, center.playCommand, center.pauseCommand];
        for (NSUInteger index = 0; index < commands.count; index++) {
            MPRemoteCommand *command = commands[index];
            int command_id = (int)index + 1;
            [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
                publish_command(command_id);
                return MPRemoteCommandHandlerStatusSuccess;
            }];
            command.enabled = YES;
        }

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
